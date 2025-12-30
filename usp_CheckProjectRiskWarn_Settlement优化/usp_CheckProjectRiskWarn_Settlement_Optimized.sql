/*
优化版本: usp_CheckProjectRiskWarn_Settlement_Optimized
优化日期: 2025-12-29

主要优化点:
1. 修复@ProjectID的NULL判断错误
2. 移除UPDATE中的NOLOCK提示
3. 为临时表添加索引
4. 使用变量替代重复的标量子查询
5. 优化OUTER APPLY为LEFT JOIN
6. 优化NOT EXISTS为LEFT JOIN
7. 添加事务控制和错误处理
*/

CREATE PROCEDURE [dbo].[usp_CheckProjectRiskWarn_Settlement_Optimized]
    @Type INT = 1, --1巡检 2停供 3发起审批前巡检风险是否存在
    @ProjectID BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @StartTime DATETIME2 = SYSDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ============================================================
        -- 预先计算常量
        -- ============================================================
        DECLARE @ProjectSalesTypeFilter NVARCHAR(MAX) =
        (
            SELECT ParaValue
            FROM dbo.Parameters WITH (NOLOCK)
            WHERE ParaName = 'ProjectSalesTypeFilter'
        );

        DECLARE @TypeFilter TABLE (Type NVARCHAR(100));
        INSERT INTO @TypeFilter SELECT col FROM dbo.f_split(@ProjectSalesTypeFilter, ',');

        DECLARE @EndDate DATETIME;
        DECLARE @CurrentDate DATE = CAST(GETDATE() AS DATE);

        IF (@Type = 1)
            SET @EndDate = DATEADD(s, -1, DATEADD(MM, DATEDIFF(M, 0, @CurrentDate) - 1, 0));
        ELSE
            SET @EndDate = DATEADD(s, -1, DATEADD(MM, DATEDIFF(M, 0, @CurrentDate) - 2, 0));

        DECLARE @StopDate DATE = DATEADD(MONTH, +1, DATEADD(DAY, 1 - DAY(@CurrentDate), @CurrentDate));

        PRINT CONCAT('EndDate: ', CONVERT(VARCHAR, @EndDate, 120));
        PRINT CONCAT('StopDate: ', CONVERT(VARCHAR, @StopDate, 120));

        -- ============================================================
        -- Step1: 检索有打土记录的核算账户
        -- ============================================================
        SELECT details.ProjectID,
               MAX(details.ReceiptDate) ENDDate,
               @StopDate AS StopDate
        INTO #TempProduct
        FROM ProductionDailyReportDetails details WITH (NOLOCK)
            INNER JOIN dbo.ProductionDailyReports reports WITH (NOLOCK)
                ON details.DailyReportID = reports.ID
            INNER JOIN @TypeFilter tf
                ON details.Type = tf.Type
        WHERE reports.isDeleted = 0
              AND reports.ReportDate >= '2022-06-01'
              AND details.ProjectID IS NOT NULL
              AND details.ReceiptDate <= @EndDate
        GROUP BY details.ProjectID
        HAVING SUM(CASE
                       WHEN details.Unit = '吨' THEN ISNULL(details.FinalQty_T, 0)
                       ELSE ISNULL(details.FinalQty_M3, 0)
                   END) > 0;

        CREATE CLUSTERED INDEX IX_TempProduct_ProjectID ON #TempProduct(ProjectID);
        CREATE INDEX IX_TempProduct_ENDDate ON #TempProduct(ENDDate);

        PRINT CONCAT('Step1 完成 - 记录数: ', @@ROWCOUNT);

        -- 修复NULL判断
        IF (@ProjectID IS NOT NULL)
        BEGIN
            DELETE FROM #TempProduct WHERE ProjectID != @ProjectID;
            PRINT CONCAT('已筛选ProjectID=', @ProjectID, ', 剩余: ', @@ROWCOUNT);
        END;

        -- ============================================================
        -- Step2: 检索存在风险的核算账户(优化OUTER APPLY)
        -- ============================================================
        -- 先创建结算单临时表
        SELECT ProjectID,
               FromDate,
               ToDate,
               Receivedby,
               ROW_NUMBER() OVER (PARTITION BY ProjectID, FromDate, ToDate ORDER BY ID DESC) AS rn
        INTO #TempSettlement
        FROM SalesStatements WITH (NOLOCK)
        WHERE isDeleted = 0;

        CREATE INDEX IX_TempSettlement ON #TempSettlement(ProjectID, FromDate, ToDate);

        SELECT DISTINCT
               tp.ProjectID,
               ISNULL(p.EnableUserPlan, 1) EnableUserPlan,
               tp.StopDate
        INTO #TempData
        FROM #TempProduct tp
            LEFT JOIN dbo.Project p WITH (NOLOCK)
                ON tp.ProjectID = p.ID
            LEFT JOIN #TempSettlement ss
                ON ss.ProjectID = tp.ProjectID
                AND tp.ENDDate BETWEEN ss.FromDate AND ss.ToDate
                AND ss.rn = 1
        WHERE ISNULL(ss.Receivedby, '') = ''
              AND p.Type = 1
              AND p.AccountingPaymentType <> '现金'
              AND ISNULL(p.isPartnerProjFinished, 0) = 0;

        CREATE CLUSTERED INDEX IX_TempData_ProjectID ON #TempData(ProjectID);

        PRINT CONCAT('Step2 完成 - 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step3: 根据Type执行相应操作
        -- ============================================================
        IF @Type = 1  -- 巡检增加警告
        BEGIN
            UPDATE ProjectRiskWarn
            SET IsDeleted = 1
            WHERE RiskType = 2 AND IsDeleted = 0;

            PRINT CONCAT('警告已清除: ', @@ROWCOUNT);

            INSERT INTO dbo.ProjectRiskWarn
            (
                FGC_CreateDate,
                FGC_LastModifyDate,
                ProjectID,
                RiskType,
                WarnTime,
                IsDeleted,
                WarnType
            )
            SELECT GETDATE(),
                   GETDATE(),
                   ProjectID,
                   2,
                   GETDATE(),
                   0,
                   1
            FROM #TempData
            WHERE ISNULL(EnableUserPlan, 1) = 1;

            PRINT CONCAT('新增警告: ', @@ROWCOUNT);

            -- 优化NOT EXISTS为LEFT JOIN
            INSERT INTO dbo.ProjectRisk
            (
                FGC_CreateDate,
                FGC_LastModifyDate,
                ProjectID,
                RiskType,
                IsWarn,
                WarnDate,
                FirstStopDate,
                FirstStopQty,
                ApplyDelayDays,
                ApplySupplyTotalQty,
                NewStopDate,
                NewStopQty,
                IsStop,
                IsDeleted,
                WarnType
            )
            SELECT GETDATE(),
                   GETDATE(),
                   t.ProjectID,
                   2,
                   0,
                   NULL,
                   t.StopDate,
                   NULL,
                   NULL,
                   NULL,
                   t.StopDate,
                   NULL,
                   0,
                   0,
                   1
            FROM #TempData t
                LEFT JOIN dbo.ProjectRisk pr
                    ON pr.ProjectID = t.ProjectID
                    AND pr.IsDeleted = 0
                    AND pr.RiskType = 2
                    AND pr.WarnType = 1
            WHERE ISNULL(t.EnableUserPlan, 1) = 1
                  AND pr.ProjectID IS NULL;

            PRINT CONCAT('新增风险: ', @@ROWCOUNT);
        END;
        ELSE IF (@Type = 2)  -- 停供
        BEGIN
            UPDATE pr
            SET IsStop = 1
            FROM ProjectRisk pr
                INNER JOIN #TempData
                    ON #TempData.ProjectID = pr.ProjectID
                    AND pr.RiskType = 2
                    AND pr.WarnType = 1
                    AND pr.IsStop = 0
                    AND pr.IsDeleted = 0
                    AND DATEDIFF(DAY, pr.NewStopDate, @CurrentDate) >= 0;

            PRINT CONCAT('停供更新: ', @@ROWCOUNT);

            UPDATE pr
            SET pr.IsDeleted = 1
            FROM ProjectRisk pr
                LEFT JOIN #TempData td
                    ON td.ProjectID = pr.ProjectID
            WHERE pr.RiskType = 2
                  AND pr.IsDeleted = 0
                  AND DATEDIFF(DAY, pr.NewStopDate, @CurrentDate) >= 0
                  AND td.ProjectID IS NULL;

            PRINT CONCAT('风险删除: ', @@ROWCOUNT);
        END;
        ELSE  -- 单核算账户审批前巡检
        BEGIN
            UPDATE pr
            SET pr.IsDeleted = 1
            FROM ProjectRisk pr
                LEFT JOIN #TempData td
                    ON td.ProjectID = pr.ProjectID
            WHERE pr.RiskType = 2
                  AND pr.IsDeleted = 0
                  AND td.ProjectID IS NULL;

            PRINT CONCAT('风险删除: ', @@ROWCOUNT);
        END;

        COMMIT TRANSACTION;

        PRINT '==============================================================';
        PRINT CONCAT('总执行时间: ', DATEDIFF(ms, @StartTime, SYSDATETIME()), 'ms');
        PRINT '==============================================================';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorLine INT = ERROR_LINE();

        PRINT CONCAT('错误行���: ', @ErrorLine);
        PRINT CONCAT('错误消息: ', @ErrorMessage);

        THROW;
    END CATCH;
END;
GO

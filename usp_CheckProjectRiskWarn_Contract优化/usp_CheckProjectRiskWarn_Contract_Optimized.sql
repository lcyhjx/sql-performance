/*
优化版本: usp_CheckProjectRiskWarn_Contract_Optimized
优化日期: 2025-12-29
优化说明: 性能优化和数据一致性改进

主要优化点:
1. 移除所有UPDATE中的NOLOCK提示
2. 为所有临时表添加索引
3. 使用变量替代重复的标量子查询
4. 合并UNION查询
5. 优化NOT EXISTS为LEFT JOIN
6. 修复@ProjectID的NULL判断错误
7. 添加事务控制和错误处理
8. 添加执行日志
*/

CREATE PROCEDURE [dbo].[usp_CheckProjectRiskWarn_Contract_Optimized]
    @Type INT = 1, --1巡检 2停供 3发起审批前巡检风险是否存在
    @ProjectID BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- 性能监控变量
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @StepTime DATETIME2;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ============================================================
        -- 预先计算常量和变量
        -- ============================================================
        DECLARE @ProjectSalesTypeFilter NVARCHAR(MAX) =
        (
            SELECT ParaValue
            FROM dbo.Parameters WITH (NOLOCK)
            WHERE ParaName = 'ProjectSalesTypeFilter'
        );

        -- 创建类型过滤临时表 (优化 f_split 性能)
        DECLARE @TypeFilter TABLE (Type NVARCHAR(100));
        INSERT INTO @TypeFilter(Type)
        SELECT col FROM dbo.f_split(@ProjectSalesTypeFilter, ',');

        DECLARE @CurrentDate DATE = CAST(GETDATE() AS DATE);

        -- ============================================================
        -- Step1: 查询所有核算账户的第一次打土时间
        -- ============================================================
        SET @StepTime = SYSDATETIME();

        SELECT prod.*,
               ISNULL(ProjFinalTotalQty, 0) FinalQty
        INTO #TempProduct
        FROM
        (
            SELECT details.ProjectID,
                   MIN(details.ReceiptDate) OpenningDate,
                   SUM(ISNULL(details.Unpaid, 0)) unpaid
            FROM ProductionDailyReportDetails details WITH (NOLOCK)
                LEFT JOIN dbo.ProductionDailyReports reports WITH (NOLOCK)
                    ON details.DailyReportID = reports.ID
                INNER JOIN @TypeFilter tf
                    ON details.Type = tf.Type  -- 优化: 使用 JOIN 替代 IN (SELECT)
            WHERE reports.isDeleted = 0
                  AND details.ProjectID IS NOT NULL
            GROUP BY details.ProjectID
            HAVING SUM(CASE
                           WHEN details.Unit = '吨' THEN
                               ISNULL(details.FinalQty_T, 0)
                           ELSE
                               ISNULL(details.FinalQty_M3, 0)
                       END) > 0
        ) prod
            LEFT JOIN dbo.ProjectRiskRelationInfo WITH (NOLOCK)
                ON prod.ProjectID = ProjectRiskRelationInfo.ProjectID;

        -- 为临时表创建聚集索引
        CREATE CLUSTERED INDEX IX_TempProduct_ProjectID ON #TempProduct(ProjectID);

        PRINT CONCAT('Step1 完成 - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- 单核算账户发起审批前巡检一次 (修复NULL判断错误)
        IF (@ProjectID IS NOT NULL)  -- ✅ 修复: 使用 IS NOT NULL
        BEGIN
            DELETE FROM #TempProduct
            WHERE ProjectID != @ProjectID;

            PRINT CONCAT('已筛选ProjectID=', @ProjectID, ', 剩余记录数: ', @@ROWCOUNT);
        END;

        -- ============================================================
        -- Step2: 查询存在风险的核算账户 (合并UNION查询)
        -- ============================================================
        SET @StepTime = SYSDATETIME();

        SELECT p.*, c.CorpType
        INTO #TempProjdata
        FROM dbo.Project p WITH (NOLOCK)
            INNER JOIN dbo.SalesContracts c WITH (NOLOCK)
                ON p.SalesContractID = c.ID
        WHERE p.Type = 1
              AND p.AccountingPaymentType <> '现金'
              AND ISNULL(p.isPartnerProjFinished, 0) = 0
              AND (
                  -- 合并两个条件,避免UNION
                  (p.AgentID IS NULL AND LTRIM(RTRIM(ISNULL(c.SignStatus, ''))) NOT IN ( '已签', '付清', '此合同号作废' ))
                  OR
                  (p.AgentID IS NOT NULL AND LTRIM(RTRIM(ISNULL(p.AgentAgreementSignStatus, ''))) NOT IN ( '已签' ))
              );

        CREATE CLUSTERED INDEX IX_TempProjdata_ID ON #TempProjdata(ID);
        CREATE INDEX IX_TempProjdata_CorpType ON #TempProjdata(CorpType);

        PRINT CONCAT('Step2 完成 - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step3: 按日期计算风险
        -- ============================================================
        SET @StepTime = SYSDATETIME();

        -- 国企在打土开始的第90-15或90-3天触发警告，第90天停供
        -- 私企在打土开始的第60-15或60-3天触发警告，第60天停供
        SELECT p.CorpType,
               p.ID ProjectID,
               ISNULL(p.EnableUserPlan, 1) EnableUserPlan,
               p.Number,
               p.ProjectName,
               p.SalesDepartment,
               p.Salesman,
               p.AccountingPaymentType,
               p.ProductCategory CategoryName,
               #TempProduct.OpenningDate,
               ISNULL(ProjectRisk.NewStopDate,
                      #TempProduct.OpenningDate + (CASE
                                                       WHEN p.CorpType = '国企' THEN 90
                                                       ELSE 60
                                                   END)) StopDate
        INTO #Temp1
        FROM #TempProjdata p
            INNER JOIN #TempProduct
                ON #TempProduct.ProjectID = p.ID
            LEFT JOIN
            (
                SELECT ProjectID,
                       MAX(NewStopDate) NewStopDate
                FROM dbo.ProjectRisk WITH (NOLOCK)
                WHERE RiskType = 1
                      AND WarnType = 1
                      AND IsDeleted = 0
                      AND IsStop = 0
                GROUP BY ProjectID
            ) ProjectRisk
                ON ProjectRisk.ProjectID = p.ID;

        CREATE CLUSTERED INDEX IX_Temp1_ProjectID ON #Temp1(ProjectID);
        CREATE INDEX IX_Temp1_StopDate ON #Temp1(StopDate);

        PRINT CONCAT('Step3 (Temp1) 完成 - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step4: 按量计算风险
        -- ============================================================
        SET @StepTime = SYSDATETIME();

        -- 砂浆（包含特种砼）供应量>=【1000(有最新的供应量就用最新的)-500】吨
        -- 混凝土达到>=【2000(有最新的供应量就用最新的)-100】方
        SELECT p.CorpType,
               p.ID ProjectID,
               ISNULL(p.EnableUserPlan, 1) EnableUserPlan,
               p.Number,
               p.ProjectName,
               p.SalesDepartment,
               p.Salesman,
               p.AccountingPaymentType,
               p.ProductCategory CategoryName,
               FinalQty,
               ISNULL(NewStopQty,
                      CASE
                          WHEN p.ProductCategory IN ( '砂浆', '干混砂浆', '陶粒', '透水' ) THEN 1000
                          WHEN p.ProductCategory IN ( '普混' ) THEN 2000
                          ELSE 0
                      END) StopQty
        INTO #Temp2
        FROM #TempProjdata p
            INNER JOIN #TempProduct
                ON #TempProduct.ProjectID = p.ID
            LEFT JOIN
            (
                SELECT ProjectID,
                       MAX(NewStopQty) NewStopQty
                FROM dbo.ProjectRisk WITH (NOLOCK)
                WHERE RiskType = 1
                      AND WarnType = 2
                      AND IsDeleted = 0
                      AND IsStop = 0
                GROUP BY ProjectID
            ) ProjectRisk
                ON ProjectRisk.ProjectID = p.ID;

        CREATE CLUSTERED INDEX IX_Temp2_ProjectID ON #Temp2(ProjectID);
        CREATE INDEX IX_Temp2_StopQty ON #Temp2(StopQty, FinalQty);

        PRINT CONCAT('Step4 (Temp2) 完成 - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step5: 添加数据到警告表
        -- ============================================================
        IF @Type = 1
        BEGIN
            SET @StepTime = SYSDATETIME();

            /*今天需要发警告的数据*/
            SELECT *
            INTO #Temp1Warn
            FROM #Temp1
            WHERE ISNULL(EnableUserPlan, 1) = 1
                  AND (
                      DATEDIFF(DAY, (StopDate - 15), @CurrentDate) = 0
                      OR DATEDIFF(DAY, (StopDate - 3), @CurrentDate) = 0
                  );

            CREATE CLUSTERED INDEX IX_Temp1Warn_ProjectID ON #Temp1Warn(ProjectID);

            SELECT *
            INTO #Temp2Warn
            FROM #Temp2
            WHERE ISNULL(EnableUserPlan, 1) = 1
                  AND (StopQty - FinalQty) <= (CASE
                                                   WHEN CategoryName IN ( '砂浆', '干混砂浆', '陶粒', '透水' ) THEN 500
                                                   WHEN CategoryName IN ( '普混' ) THEN 1000
                                                   ELSE 0
                                               END);

            CREATE CLUSTERED INDEX IX_Temp2Warn_ProjectID ON #Temp2Warn(ProjectID);

            PRINT CONCAT('警告数据筛选完成 - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms');
            PRINT CONCAT('  Temp1Warn记录数: ', (SELECT COUNT(*) FROM #Temp1Warn));
            PRINT CONCAT('  Temp2Warn记录数: ', (SELECT COUNT(*) FROM #Temp2Warn));

            -- 更新警告表
            UPDATE ProjectRiskWarn  -- ✅ 移除 NOLOCK
            SET IsDeleted = 1
            WHERE RiskType = 1
                  AND IsDeleted = 0;

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
            SELECT FGC_CreateDate = GETDATE(),
                   FGC_LastModifyDate = GETDATE(),
                   ProjectID,
                   1 RiskType,
                   GETDATE() WarnTime,
                   0 IsDeleted,
                   1 WarnType
            FROM #Temp1Warn
            UNION ALL
            SELECT FGC_CreateDate = GETDATE(),
                   FGC_LastModifyDate = GETDATE(),
                   ProjectID,
                   1 RiskType,
                   GETDATE() WarnTime,
                   0 IsDeleted,
                   2 WarnType
            FROM #Temp2Warn;

            PRINT CONCAT('警告记录插入数: ', @@ROWCOUNT);

            -- 插入风险记录 (优化NOT EXISTS)
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
            SELECT GETDATE() FGC_CreateDate,
                   GETDATE() FGC_LastModifyDate,
                   t.ProjectID,
                   1 RiskType,
                   0 IsWarn,
                   NULL WarnDate,
                   t.StopDate FirstStopDate,
                   NULL FirstStopQty,
                   NULL ApplyDelayDays,
                   NULL ApplySupplyTotalQty,
                   t.StopDate NewStopDate,
                   NULL NewStopQty,
                   0 IsStop,
                   0 IsDeleted,
                   1 WarnType
            FROM #Temp1Warn t
                LEFT JOIN dbo.ProjectRisk pr
                    ON pr.ProjectID = t.ProjectID
                    AND pr.IsDeleted = 0
                    AND pr.RiskType = 1
                    AND pr.WarnType = 1
            WHERE pr.ProjectID IS NULL  -- ✅ 优化: 使用 LEFT JOIN 替代 NOT EXISTS
            UNION ALL
            SELECT GETDATE() FGC_CreateDate,
                   GETDATE() FGC_LastModifyDate,
                   t.ProjectID,
                   1 RiskType,
                   0 IsWarn,
                   NULL WarnDate,
                   NULL FirstStopDate,
                   t.StopQty FirstStopQty,
                   NULL ApplyDelayDays,
                   NULL ApplySupplyTotalQty,
                   NULL NewStopDate,
                   t.StopQty NewStopQty,
                   0 IsStop,
                   0 IsDeleted,
                   2 WarnType
            FROM #Temp2Warn t
                LEFT JOIN dbo.ProjectRisk pr
                    ON pr.ProjectID = t.ProjectID
                    AND pr.IsDeleted = 0
                    AND pr.RiskType = 1
                    AND pr.WarnType = 2
            WHERE pr.ProjectID IS NULL;

            PRINT CONCAT('风险记录插入数: ', @@ROWCOUNT);
        END;
        ELSE IF (@Type = 2) --巡检依旧异常就停供，不异常就删除之前的停供风险数据
        BEGIN
            SET @StepTime = SYSDATETIME();

            UPDATE pr  -- ✅ 移除 NOLOCK
            SET IsStop = 1
            FROM ProjectRisk pr
                INNER JOIN #Temp1
                    ON #Temp1.ProjectID = pr.ProjectID
                    AND pr.RiskType = 1
                    AND WarnType = 1
                    AND pr.IsStop = 0
                    AND IsDeleted = 0
                    AND DATEDIFF(DAY, pr.NewStopDate, @CurrentDate) >= 0;

            PRINT CONCAT('按日期停供更新数: ', @@ROWCOUNT);

            UPDATE pr  -- ✅ 移除 NOLOCK
            SET IsStop = 1
            FROM ProjectRisk pr
                INNER JOIN #Temp2
                    ON #Temp2.ProjectID = pr.ProjectID
                    AND pr.RiskType = 1
                    AND WarnType = 2
                    AND pr.IsStop = 0
                    AND IsDeleted = 0
                    AND FinalQty >= pr.NewStopQty;

            PRINT CONCAT('按数量停供更新数: ', @@ROWCOUNT);

            -- 删除已签合同的风险(AgentID IS NULL)
            UPDATE pr  -- ✅ 移除 NOLOCK
            SET pr.IsDeleted = 1
            FROM ProjectRisk pr
            WHERE pr.RiskType = 1
                  AND IsDeleted = 0
                  AND EXISTS
            (
                SELECT 1
                FROM dbo.Project p WITH (NOLOCK)
                    LEFT JOIN dbo.SalesContracts sc WITH (NOLOCK)
                        ON p.SalesContractID = sc.ID
                WHERE p.AgentID IS NULL
                      AND p.isDeleted = 0
                      AND sc.isDeleted = 0
                      AND p.ID = pr.ProjectID
                      AND LTRIM(RTRIM(ISNULL(sc.SignStatus, ''))) IN ( '已签', '付清', '此合同号作废' )
            );

            PRINT CONCAT('合同已签风险删除数: ', @@ROWCOUNT);

            -- 删除已签代理协议的风险(AgentID IS NOT NULL)
            UPDATE pr  -- ✅ 移除 NOLOCK
            SET pr.IsDeleted = 1
            FROM ProjectRisk pr
            WHERE pr.RiskType = 1
                  AND IsDeleted = 0
                  AND EXISTS
            (
                SELECT 1
                FROM dbo.Project p WITH (NOLOCK)
                WHERE p.AgentID IS NOT NULL
                      AND p.isDeleted = 0
                      AND p.ID = pr.ProjectID
                      AND LTRIM(RTRIM(ISNULL(p.AgentAgreementSignStatus, ''))) IN ( '已签' )
            );

            PRINT CONCAT('代理协议已签风险删除数: ', @@ROWCOUNT);
            PRINT CONCAT('Type=2 完成 - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms');
        END;
        ELSE --单核算账户发起审批前再巡检一次是否存在风险  不存在就把风险删除
        BEGIN
            SET @StepTime = SYSDATETIME();

            UPDATE pr  -- ✅ 移除 NOLOCK
            SET pr.IsDeleted = 1
            FROM ProjectRisk pr
            WHERE pr.RiskType = 1
                  AND IsDeleted = 0
                  AND EXISTS
            (
                SELECT 1
                FROM dbo.Project p WITH (NOLOCK)
                    LEFT JOIN dbo.SalesContracts sc WITH (NOLOCK)
                        ON p.SalesContractID = sc.ID
                WHERE p.AgentID IS NULL
                      AND p.isDeleted = 0
                      AND sc.isDeleted = 0
                      AND p.ID = pr.ProjectID
                      AND LTRIM(RTRIM(sc.SignStatus)) IN ( '已签', '付清', '此合同号作废' )
            );

            PRINT CONCAT('合同已签风险删除数: ', @@ROWCOUNT);

            UPDATE pr  -- ✅ 移除 NOLOCK
            SET pr.IsDeleted = 1
            FROM ProjectRisk pr
            WHERE pr.RiskType = 1
                  AND IsDeleted = 0
                  AND EXISTS
            (
                SELECT 1
                FROM dbo.Project p WITH (NOLOCK)
                WHERE p.AgentID IS NOT NULL
                      AND p.isDeleted = 0
                      AND p.ID = pr.ProjectID
                      AND LTRIM(RTRIM(p.AgentAgreementSignStatus)) IN ( '已签' )
            );

            PRINT CONCAT('代理协议已签风险删除数: ', @@ROWCOUNT);
            PRINT CONCAT('Type=3 完成 - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms');
        END;

        -- 提交事务
        COMMIT TRANSACTION;

        -- 总执行时间
        PRINT '==============================================================';
        PRINT CONCAT('总执行时间: ', DATEDIFF(ms, @StartTime, SYSDATETIME()), 'ms');
        PRINT CONCAT('完成时间: ', CONVERT(VARCHAR(23), SYSDATETIME(), 121));
        PRINT '==============================================================';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- 记录错误信息
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();
        DECLARE @ErrorLine INT = ERROR_LINE();

        PRINT '==============================================================';
        PRINT '错误发生!';
        PRINT CONCAT('错误行号: ', @ErrorLine);
        PRINT CONCAT('错误消息: ', @ErrorMessage);
        PRINT '==============================================================';

        -- 重新抛出错误
        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH;
END;
GO

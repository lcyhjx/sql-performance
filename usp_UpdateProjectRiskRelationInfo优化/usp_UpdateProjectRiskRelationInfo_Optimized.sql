/*
优化版本: usp_UpdateProjectRiskRelationInfo_Optimized
优化日期: 2025-12-29
优化说明: 性能优化和数据一致性改进

主要优化点:
1. 移除 UPDATE 中的 NOLOCK 提示
2. 为所有临时表添加索引
3. 使用变量替代重复的标量子查询
4. 优化日期计算,使用变量存储
5. 合并对 AccountReceivable 的重复查询
6. 使用 MERGE 替代 UPDATE + INSERT
7. 优化 f_split 函数使用
8. 添加事务控制和错误处理
9. 添加执行日志
*/

CREATE PROCEDURE [dbo].[usp_UpdateProjectRiskRelationInfo_Optimized]
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;  -- 错误时自动回滚

    -- 性能监控变量
    DECLARE @StartTime DATETIME2 = SYSDATETIME();
    DECLARE @StepTime DATETIME2;
    DECLARE @StepName NVARCHAR(100);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ============================================================
        -- 预先计算常量和变量
        -- ============================================================
        DECLARE @PeriodID BIGINT =
        (
            SELECT ID
            FROM dbo.Periods WITH (NOLOCK)
            WHERE isDeleted = 0
                  AND CAST(GETDATE() AS DATE) BETWEEN StartDate AND EndDate
        );

        DECLARE @ProjectSalesTypeFilter NVARCHAR(MAX) =
        (
            SELECT ParaValue
            FROM dbo.Parameters WITH (NOLOCK)
            WHERE ParaName = 'ProjectSalesTypeFilter'
        );

        -- 预计算日期常量
        DECLARE @CurrentDate DATE = CAST(GETDATE() AS DATE);
        DECLARE @StartDate_3MonthsAgo DATE = DATEADD(MM, DATEDIFF(MM, 0, DATEADD(MM, -2, @CurrentDate)), 0); -- 3.1
        DECLARE @StartDate_1MonthAgo DATE = DATEADD(MM, DATEDIFF(MM, 0, DATEADD(MM, -1, @CurrentDate)), 0);  -- 5.1

        -- 创建类型过滤临时表 (优化 f_split 性能)
        DECLARE @TypeFilter TABLE (Type NVARCHAR(100));
        INSERT INTO @TypeFilter(Type)
        SELECT col FROM dbo.f_split(@ProjectSalesTypeFilter, ',');

        -- ============================================================
        -- Step1: 获取需要更新的核算账户
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step1: 获取核算账户';

        SELECT p.ID ProjectID,
               p.SalesContractID,
               sc.SignStatus ContractSignStatus,
               p.ProductCategory,
               pc.Unit
        INTO #TempProj
        FROM dbo.Project p WITH (NOLOCK)
            LEFT JOIN dbo.SalesContracts sc WITH (NOLOCK)
                ON p.SalesContractID = sc.ID
            LEFT JOIN dbo.ProductCategories pc WITH (NOLOCK)
                ON sc.ProductCategory = pc.CategoryName;

        -- 为临时表创建聚集索引
        CREATE CLUSTERED INDEX IX_TempProj_ProjectID ON #TempProj(ProjectID);
        CREATE INDEX IX_TempProj_SalesContractID ON #TempProj(SalesContractID);

        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step2: 获取销售相关信息
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step2: 获取销售信息';

        SELECT details.ProjectID,
               MIN(details.ReceiptDate) ProductionOpenningDate,
               MAX(details.ReceiptDate) ProductionEndDate
        INTO #TempProduct
        FROM ProductionDailyReportDetails details WITH (NOLOCK)
            INNER JOIN dbo.ProductionDailyReports reports WITH (NOLOCK)
                ON details.DailyReportID = reports.ID
            INNER JOIN @TypeFilter tf
                ON details.Type = tf.Type  -- 优化: 使用 JOIN 替代 IN (SELECT)
        WHERE reports.isDeleted = 0
              AND EXISTS (SELECT 1 FROM #TempProj WHERE ProjectID = details.ProjectID)
        GROUP BY details.ProjectID;

        CREATE CLUSTERED INDEX IX_TempProduct_ProjectID ON #TempProduct(ProjectID);

        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step3: 获取两月前和上月的项目回款比例 (合并查询)
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step3: 获取历史数据';

        -- 合并两次 AccountReceivable 查询
        SELECT details.ProjectID,
               MAX(p.ProductCategory) AS ProductCategory,
               MAX(p.SalesContractID) AS SalesContractID,
               MAX(p.Unit) AS Unit,
               -- Period-3 的数据
               SUM(CASE WHEN fr.PeriodID = @PeriodID - 3
                        THEN details.CurrentACCUSalesIncomeTotalAmt ELSE 0 END) AS ProjSalesTotalAmt_P3,
               SUM(CASE WHEN fr.PeriodID = @PeriodID - 3 AND p.Unit = '吨'
                        THEN ISNULL(details.CurrentACCUFinalQty_T, 0) + ISNULL(details.CurrentACCUSalesIncomeAdjAdjustQty_T, 0)
                        WHEN fr.PeriodID = @PeriodID - 3
                        THEN ISNULL(details.CurrentACCUFinalQty_M3, 0) + ISNULL(details.CurrentACCUSalesIncomeAdjAdjustQty_M3, 0)
                        ELSE 0 END) AS ProjSalesTotalQty_P3,
               SUM(CASE WHEN fr.PeriodID = @PeriodID - 3
                        THEN details.CurrentACCUSalesPayTotalAmt ELSE 0 END) AS ProjReturnAmt_P3,
               -- Period-2 的数据
               SUM(CASE WHEN fr.PeriodID = @PeriodID - 2
                        THEN details.CurrentACCUSalesIncomeTotalAmt ELSE 0 END) AS YearSalesIncomeTotalAmt_P2,
               SUM(CASE WHEN fr.PeriodID = @PeriodID - 2 AND p.Unit = '吨'
                        THEN ISNULL(details.CurrentACCUFinalQty_T, 0) + ISNULL(details.CurrentACCUSalesIncomeAdjAdjustQty_T, 0)
                        WHEN fr.PeriodID = @PeriodID - 2
                        THEN ISNULL(details.CurrentACCUFinalQty_M3, 0) + ISNULL(details.CurrentACCUSalesIncomeAdjAdjustQty_M3, 0)
                        ELSE 0 END) AS SalesTotalQty_P2
        INTO #TempAccountReceivable
        FROM AccountReceivable details WITH (NOLOCK)
            INNER JOIN dbo.FinanceReports fr WITH (NOLOCK)
                ON details.FinanceRptID = fr.ID
            LEFT JOIN #TempProj p
                ON p.ProjectID = details.ProjectID
        WHERE fr.isDeleted = 0
              AND details.isDeleted = 0
              AND fr.PeriodID IN (@PeriodID - 3, @PeriodID - 2)
        GROUP BY details.ProjectID;

        CREATE CLUSTERED INDEX IX_TempAR_ProjectID ON #TempAccountReceivable(ProjectID);

        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step4: 获取当前销售数据
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step4: 获取当前销售数据';

        SELECT Project.ID ProjectID,
               ProductCategory,
               SalesContractID,
               ISNULL(ar.YearSalesIncomeTotalAmt_P2, 0) + ISNULL(report.SalesTotalAmt, 0)
               + ISNULL(Adj.AdjustAmt, 0) CurrentProjSalesTotalAmt,
               ISNULL(ar.SalesTotalQty_P2, 0) + ISNULL(report.SalesTotalQty, 0)
               + ISNULL(CASE WHEN Unit = '吨' THEN Adj.AdjustQty_T ELSE Adj.AdjustQty_M3 END, 0) CurrentProjSalesTotalQty
        INTO #TempCurrentSales
        FROM dbo.Project
            LEFT JOIN dbo.ProductCategories
                ON ProductCategories.CategoryName = Project.ProductCategory
            LEFT JOIN #TempAccountReceivable ar
                ON Project.ID = ar.ProjectID
            LEFT JOIN
            (
                SELECT d.ProjectID,
                       SUM(d.SalesTotalAmt1) SalesTotalAmt,
                       SUM(ISNULL(CASE WHEN d.Unit = '吨' THEN d.FinalQty_T ELSE d.FinalQty_M3 END, 0)) SalesTotalQty
                FROM dbo.ProductionDailyReportDetails d WITH (NOLOCK)
                    INNER JOIN dbo.ProductionDailyReports r WITH (NOLOCK)
                        ON d.DailyReportID = r.ID
                    INNER JOIN @TypeFilter tf
                        ON d.Type = tf.Type
                WHERE r.isDeleted = 0
                      AND r.ReportDate BETWEEN @StartDate_1MonthAgo AND @CurrentDate
                GROUP BY d.ProjectID
            ) report
                ON Project.ID = report.ProjectID
            LEFT JOIN
            (
                SELECT ProjectID,
                       SUM(ISNULL(AdjustAmt, 0)) AdjustAmt,
                       SUM(ISNULL(AdjustQty_T, 0)) AdjustQty_T,
                       SUM(ISNULL(AdjustQty_M3, 0)) AdjustQty_M3
                FROM SalesIncomeAdjustment WITH (NOLOCK)
                WHERE [CurrentPeriodID] > @PeriodID - 2
                      AND ISNULL([isDeleted], 0) = 0
                GROUP BY ProjectID
            ) Adj
                ON Project.ID = Adj.ProjectID
        WHERE Project.isDeleted = 0;

        CREATE CLUSTERED INDEX IX_TempCurrentSales_ProjectID ON #TempCurrentSales(ProjectID);
        CREATE INDEX IX_TempCurrentSales_SalesContractID ON #TempCurrentSales(SalesContractID);

        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step5: 获取当前回款数据
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step5: 获取当前回款数据';

        SELECT P.ID ProjectID,
               P.ProductCategory,
               P.SalesContractID,
               ISNULL(CurrentReturnAmt, 0) - ISNULL(CurrentRefundAmt, 0) ReturnTotalAmt
        INTO #TempCurrentReturn
        FROM dbo.Project P WITH (NOLOCK)
            LEFT JOIN
            (
                SELECT ProjectID,
                       CAST(SUM(ISNULL(Amount, 0)) AS DECIMAL(18, 2)) CurrentReturnAmt
                FROM dbo.SalesPayment WITH (NOLOCK)
                WHERE PaymentDate BETWEEN @StartDate_3MonthsAgo AND @CurrentDate
                      AND ISNULL(isDeleted, 0) = 0
                GROUP BY ProjectID
            ) SalesReturn
                ON SalesReturn.ProjectID = P.ID
            LEFT JOIN
            (
                SELECT ProjectID,
                       CAST(SUM(ISNULL(RefundAmt, 0)) AS DECIMAL(18, 2)) CurrentRefundAmt
                FROM dbo.SalesServiceIncome WITH (NOLOCK)
                WHERE PaymentDate BETWEEN @StartDate_3MonthsAgo AND @CurrentDate
                      AND ServiceType = '支出'
                      AND ISNULL(isDeleted, 0) = 0
                GROUP BY ProjectID
            ) SalesRefund
                ON SalesRefund.ProjectID = P.ID;

        CREATE CLUSTERED INDEX IX_TempCurrentReturn_ProjectID ON #TempCurrentReturn(ProjectID);
        CREATE INDEX IX_TempCurrentReturn_SalesContractID ON #TempCurrentReturn(SalesContractID);

        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step6: 计算回款率
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step6: 计算回款率';

        SELECT p.ID ProjectID,
               p.ProductCategory,
               ProductCategoryType = CASE
                                         WHEN p.ProductCategory IN ( '砂浆', '干混砂浆' ) THEN 1
                                         WHEN p.ProductCategory IN ( '普混', '陶粒', '透水' ) THEN 2
                                     END,
               p.SalesContractID,
               ProjFinalTotalQty = ISNULL(#TempCurrentSales.CurrentProjSalesTotalQty, 0),
               ProjSalesTotalAmt = ISNULL(ar.ProjSalesTotalAmt_P3, 0),
               ContractSalesTotalAmt = CAST(0 AS DECIMAL(18, 2)),
               CurrentProjSalesTotalAmt = ISNULL(#TempCurrentSales.CurrentProjSalesTotalAmt, 0),
               CurrentContractSalesTotalAmt = CAST(0 AS DECIMAL(18, 2)),
               CurrentProjReturnTotalAmt = ISNULL(ar.ProjReturnAmt_P3, 0) + ISNULL(#TempCurrentReturn.ReturnTotalAmt, 0),
               CurrentContractReturnTotalAmt = CAST(0 AS DECIMAL(18, 2)),
               ContractReturnRate = CAST(0 AS DECIMAL(18, 4)),
               CurrentContractReturnRate = CAST(0 AS DECIMAL(18, 4))
        INTO #TempReturnRate
        FROM dbo.Project p WITH (NOLOCK)
            LEFT JOIN #TempAccountReceivable ar
                ON p.ID = ar.ProjectID
            LEFT JOIN #TempCurrentSales
                ON p.ID = #TempCurrentSales.ProjectID
            LEFT JOIN #TempCurrentReturn
                ON p.ID = #TempCurrentReturn.ProjectID;

        CREATE CLUSTERED INDEX IX_TempReturnRate_ProjectID ON #TempReturnRate(ProjectID);
        CREATE INDEX IX_TempReturnRate_Contract ON #TempReturnRate(SalesContractID, ProductCategoryType);

        -- 更新项目级别的回款率
        UPDATE #TempReturnRate
        SET ContractSalesTotalAmt = ISNULL(cr.ContractSalesTotalAmt, 0),
            CurrentContractSalesTotalAmt = ISNULL(cr.CurrentContractSalesTotalAmt, 0),
            CurrentContractReturnTotalAmt = ISNULL(cr.CurrentContractReturnTotalAmt, 0),
            ContractReturnRate = CASE
                                     WHEN ISNULL(cr.ContractSalesTotalAmt, 0) = 0 THEN 1
                                     ELSE CAST((ISNULL(cr.CurrentContractReturnTotalAmt, 0) / ISNULL(cr.ContractSalesTotalAmt, 0)) AS DECIMAL(18, 4))
                                 END,
            CurrentContractReturnRate = CASE
                                            WHEN ISNULL(cr.CurrentContractSalesTotalAmt, 0) = 0 THEN 1
                                            ELSE CAST((ISNULL(cr.CurrentContractReturnTotalAmt, 0) / ISNULL(cr.CurrentContractSalesTotalAmt, 0)) AS DECIMAL(18, 4))
                                        END
        FROM #TempReturnRate
            LEFT JOIN
            (
                SELECT SalesContractID,
                       ProductCategoryType,
                       SUM(ISNULL(ProjSalesTotalAmt, 0)) ContractSalesTotalAmt,
                       SUM(ISNULL(CurrentProjSalesTotalAmt, 0)) CurrentContractSalesTotalAmt,
                       SUM(ISNULL(CurrentProjReturnTotalAmt, 0)) CurrentContractReturnTotalAmt
                FROM #TempReturnRate
                GROUP BY SalesContractID, ProductCategoryType
            ) cr
                ON cr.SalesContractID = #TempReturnRate.SalesContractID
                   AND cr.ProductCategoryType = #TempReturnRate.ProductCategoryType;

        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step7: 获取结算数据
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step7: 获取结算数据';

        SELECT p.ID ProjectID,
               CASE
                   WHEN p.ProductCategory IN ( '砂浆', '干混砂浆' ) THEN 1
                   WHEN p.ProductCategory IN ( '普混', '陶粒', '透水' ) THEN 2
               END ProductCategoryType,
               p.SalesContractID,
               ROUND(SUM(ISNULL(SalesAmt, 0)), 2) AS CurrentProjSettleTotalAmt,
               CAST(0 AS DECIMAL(18, 2)) CurrentContractSettleTotalAmt
        INTO #TempStatement
        FROM Project p WITH (NOLOCK)
            LEFT JOIN SalesStatements WITH (NOLOCK)
                ON ProjectID = p.ID
                   AND SalesStatements.isDeleted = 0
                   AND ISNULL(IsVoid, 0) = 0
                   AND ISNULL(SalesStatements.ifCalculate, 0) = 1
                   AND SignDate IS NOT NULL
        WHERE p.isDeleted = 0
        GROUP BY p.ID,
                 CASE
                     WHEN p.ProductCategory IN ( '砂浆', '干混砂浆' ) THEN 1
                     WHEN p.ProductCategory IN ( '普混', '陶粒', '透水' ) THEN 2
                 END,
                 SalesContractID;

        CREATE CLUSTERED INDEX IX_TempStatement_ProjectID ON #TempStatement(ProjectID);
        CREATE INDEX IX_TempStatement_Contract ON #TempStatement(SalesContractID, ProductCategoryType);

        -- 更新项目级别的结算金额
        UPDATE #TempStatement
        SET CurrentContractSettleTotalAmt = ISNULL(cr.CurrentContractSettleTotalAmt, 0)
        FROM #TempStatement
            LEFT JOIN
            (
                SELECT SalesContractID,
                       ProductCategoryType,
                       SUM(ISNULL(CurrentProjSettleTotalAmt, 0)) CurrentContractSettleTotalAmt
                FROM #TempStatement
                GROUP BY SalesContractID, ProductCategoryType
            ) cr
                ON cr.SalesContractID = #TempStatement.SalesContractID
                   AND cr.ProductCategoryType = #TempStatement.ProductCategoryType;

        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step8: 汇总最终数据
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step8: 汇总最终数据';

        SELECT #TempProj.ProjectID ProjectID,
               ContractSignStatus,
               #TempProduct.ProductionOpenningDate,
               #TempProduct.ProductionEndDate,
               ProjFinalTotalQty = ISNULL(#TempReturnRate.ProjFinalTotalQty, 0),
               ContractSalesTotalAmt = ISNULL(#TempReturnRate.ContractSalesTotalAmt, 0),
               CurrentContractSalesTotalAmt = ISNULL(#TempReturnRate.CurrentContractSalesTotalAmt, 0),
               CurrentProjSalesTotalAmt = ISNULL(#TempReturnRate.CurrentProjSalesTotalAmt, 0),
               CurrentProjReturnTotalAmt = ISNULL(#TempReturnRate.CurrentProjReturnTotalAmt, 0),
               CurrentContractReturnTotalAmt = ISNULL(#TempReturnRate.CurrentContractReturnTotalAmt, 0),
               ContractReturnRate = ISNULL(#TempReturnRate.ContractReturnRate, 0),
               CurrentContractReturnRate = ISNULL(#TempReturnRate.CurrentContractReturnRate, 0),
               CurrentContractSettleTotalAmt = ISNULL(#TempStatement.CurrentContractSettleTotalAmt, 0),
               CurrentContractUnSettleTotalAmt = ISNULL(#TempReturnRate.CurrentContractSalesTotalAmt, 0)
                                                 - ISNULL(#TempStatement.CurrentContractSettleTotalAmt, 0),
               CurrentProjSettleTotalAmt = ISNULL(#TempStatement.CurrentProjSettleTotalAmt, 0),
               CurrentProjUnSettleTotalAmt = ISNULL(#TempReturnRate.CurrentProjSalesTotalAmt, 0)
                                             - ISNULL(#TempStatement.CurrentProjSettleTotalAmt, 0),
               @PeriodID ReturnNewPeriodID
        INTO #TempData
        FROM #TempProj
            LEFT JOIN #TempProduct
                ON #TempProduct.ProjectID = #TempProj.ProjectID
            LEFT JOIN #TempReturnRate
                ON #TempReturnRate.ProjectID = #TempProj.ProjectID
            LEFT JOIN #TempStatement
                ON #TempStatement.ProjectID = #TempProj.ProjectID;

        CREATE CLUSTERED INDEX IX_TempData_ProjectID ON #TempData(ProjectID);

        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 记录数: ', @@ROWCOUNT);

        -- ============================================================
        -- Step9: 使用 MERGE 更新目标表 (替代 UPDATE + INSERT)
        -- ============================================================
        SET @StepTime = SYSDATETIME();
        SET @StepName = 'Step9: MERGE 更新目标表';

        MERGE INTO dbo.ProjectRiskRelationInfo AS target
        USING #TempData AS source
        ON target.ProjectID = source.ProjectID
        WHEN MATCHED THEN
            UPDATE SET
                FGC_LastModifyDate = GETDATE(),
                ContractSignStatus = source.ContractSignStatus,
                ProductionOpenningDate = source.ProductionOpenningDate,
                ProductionEndDate = source.ProductionEndDate,
                ProjFinalTotalQty = source.ProjFinalTotalQty,
                ContractSalesTotalAmt = source.ContractSalesTotalAmt,
                CurrentContractSalesTotalAmt = source.CurrentContractSalesTotalAmt,
                CurrentProjSalesTotalAmt = source.CurrentProjSalesTotalAmt,
                CurrentProjReturnTotalAmt = source.CurrentProjReturnTotalAmt,
                CurrentContractReturnTotalAmt = source.CurrentContractReturnTotalAmt,
                ContractReturnRate = source.ContractReturnRate,
                CurrentContractReturnRate = source.CurrentContractReturnRate,
                CurrentContractSettleTotalAmt = source.CurrentContractSettleTotalAmt,
                CurrentContractUnSettleTotalAmt = source.CurrentContractUnSettleTotalAmt,
                CurrentProjSettleTotalAmt = source.CurrentProjSettleTotalAmt,
                CurrentProjUnSettleTotalAmt = source.CurrentProjUnSettleTotalAmt,
                ReturnNewPeriodID = source.ReturnNewPeriodID
        WHEN NOT MATCHED THEN
            INSERT
            (
                FGC_CreateDate,
                FGC_LastModifyDate,
                ProjectID,
                ContractSignStatus,
                ProductionOpenningDate,
                ProductionEndDate,
                ProjFinalTotalQty,
                ContractSalesTotalAmt,
                CurrentContractSalesTotalAmt,
                CurrentProjSalesTotalAmt,
                CurrentProjReturnTotalAmt,
                CurrentContractReturnTotalAmt,
                ContractReturnRate,
                CurrentContractReturnRate,
                CurrentContractSettleTotalAmt,
                CurrentContractUnSettleTotalAmt,
                CurrentProjSettleTotalAmt,
                CurrentProjUnSettleTotalAmt,
                ReturnNewPeriodID
            )
            VALUES
            (GETDATE(), GETDATE(), source.ProjectID, source.ContractSignStatus, source.ProductionOpenningDate,
             source.ProductionEndDate, source.ProjFinalTotalQty, source.ContractSalesTotalAmt,
             source.CurrentContractSalesTotalAmt, source.CurrentProjSalesTotalAmt, source.CurrentProjReturnTotalAmt,
             source.CurrentContractReturnTotalAmt, source.ContractReturnRate, source.CurrentContractReturnRate,
             source.CurrentContractSettleTotalAmt, source.CurrentContractUnSettleTotalAmt,
             source.CurrentProjSettleTotalAmt, source.CurrentProjUnSettleTotalAmt, source.ReturnNewPeriodID);

        DECLARE @UpdatedRows INT = @@ROWCOUNT;
        PRINT CONCAT(@StepName, ' - 耗时: ', DATEDIFF(ms, @StepTime, SYSDATETIME()), 'ms, 影响行数: ', @UpdatedRows);

        -- 提交事务
        COMMIT TRANSACTION;

        -- 总执行时间
        PRINT CONCAT('总执行时间: ', DATEDIFF(ms, @StartTime, SYSDATETIME()), 'ms');
        PRINT CONCAT('完成时间: ', CONVERT(VARCHAR(23), SYSDATETIME(), 121));

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- 记录错误信息
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();
        DECLARE @ErrorLine INT = ERROR_LINE();

        PRINT CONCAT('错误发生在 Step: ', @StepName);
        PRINT CONCAT('错误行号: ', @ErrorLine);
        PRINT CONCAT('错误消息: ', @ErrorMessage);

        -- 重新抛出错误
        THROW;
    END CATCH;
END;
GO

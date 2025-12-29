-- ============================================================
-- 索引创建脚本
-- 用于优化 usp_UpdateProjectRiskRelationInfo 存储过程性能
-- 创建日期: 2025-12-29
-- ============================================================

USE [Statistics-CT-test];
GO

PRINT '开始创建优化索引...';
PRINT '创建时间: ' + CONVERT(VARCHAR(23), GETDATE(), 121);
PRINT '============================================================';

-- ============================================================
-- 1. ProductionDailyReportDetails 表索引
-- ============================================================
PRINT '';
PRINT '[1/6] 优化 ProductionDailyReportDetails 表...';

-- 检查索引是否存在,不存在则创建
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('ProductionDailyReportDetails') AND name = 'IX_ProductionDetails_Type_ProjectID_Optimized')
BEGIN
    CREATE NONCLUSTERED INDEX IX_ProductionDetails_Type_ProjectID_Optimized
    ON dbo.ProductionDailyReportDetails(Type, ProjectID, DailyReportID)
    INCLUDE (ReceiptDate, FinalQty_M3, FinalQty_T, SalesTotalAmt1, Unit)
    WITH (ONLINE = ON, MAXDOP = 4);  -- 在线创建,避免锁表

    PRINT '  [+] 已创建索引: IX_ProductionDetails_Type_ProjectID_Optimized';
END
ELSE
BEGIN
    PRINT '  [=] 索引已存在: IX_ProductionDetails_Type_ProjectID_Optimized';
END

-- ============================================================
-- 2. AccountReceivable 表索引
-- ============================================================
PRINT '';
PRINT '[2/6] 优化 AccountReceivable 表...';

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('AccountReceivable') AND name = 'IX_AccountReceivable_PeriodID_ProjectID_Optimized')
BEGIN
    CREATE NONCLUSTERED INDEX IX_AccountReceivable_PeriodID_ProjectID_Optimized
    ON dbo.AccountReceivable(PeriodID, ProjectID, isDeleted, FinanceRptID)
    INCLUDE (
        CurrentACCUSalesIncomeTotalAmt,
        CurrentACCUFinalQty_T,
        CurrentACCUFinalQty_M3,
        CurrentACCUSalesIncomeAdjAdjustQty_T,
        CurrentACCUSalesIncomeAdjAdjustQty_M3,
        CurrentACCUSalesPayTotalAmt
    )
    WITH (ONLINE = ON, MAXDOP = 4);

    PRINT '  [+] 已创建索引: IX_AccountReceivable_PeriodID_ProjectID_Optimized';
END
ELSE
BEGIN
    PRINT '  [=] 索引已存在: IX_AccountReceivable_PeriodID_ProjectID_Optimized';
END

-- ============================================================
-- 3. SalesPayment 表索引
-- ============================================================
PRINT '';
PRINT '[3/6] 优化 SalesPayment 表...';

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('SalesPayment') AND name = 'IX_SalesPayment_PaymentDate_ProjectID_Optimized')
BEGIN
    CREATE NONCLUSTERED INDEX IX_SalesPayment_PaymentDate_ProjectID_Optimized
    ON dbo.SalesPayment(PaymentDate, ProjectID, isDeleted)
    INCLUDE (Amount)
    WITH (ONLINE = ON, MAXDOP = 4);

    PRINT '  [+] 已创建索引: IX_SalesPayment_PaymentDate_ProjectID_Optimized';
END
ELSE
BEGIN
    PRINT '  [=] 索引已存在: IX_SalesPayment_PaymentDate_ProjectID_Optimized';
END

-- ============================================================
-- 4. SalesServiceIncome 表索引
-- ============================================================
PRINT '';
PRINT '[4/6] 优化 SalesServiceIncome 表...';

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('SalesServiceIncome') AND name = 'IX_SalesServiceIncome_PaymentDate_Type_Optimized')
BEGIN
    CREATE NONCLUSTERED INDEX IX_SalesServiceIncome_PaymentDate_Type_Optimized
    ON dbo.SalesServiceIncome(PaymentDate, ServiceType, ProjectID, isDeleted)
    INCLUDE (RefundAmt)
    WITH (ONLINE = ON, MAXDOP = 4);

    PRINT '  [+] 已创建索引: IX_SalesServiceIncome_PaymentDate_Type_Optimized';
END
ELSE
BEGIN
    PRINT '  [=] 索引已存在: IX_SalesServiceIncome_PaymentDate_Type_Optimized';
END

-- ============================================================
-- 5. SalesStatements 表索引
-- ============================================================
PRINT '';
PRINT '[5/6] 优化 SalesStatements 表...';

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('SalesStatements') AND name = 'IX_SalesStatements_ProjectID_Calculated_Optimized')
BEGIN
    CREATE NONCLUSTERED INDEX IX_SalesStatements_ProjectID_Calculated_Optimized
    ON dbo.SalesStatements(ProjectID, isDeleted, IsVoid, ifCalculate)
    INCLUDE (SalesAmt, SignDate)
    WITH (ONLINE = ON, MAXDOP = 4);

    PRINT '  [+] 已创建索引: IX_SalesStatements_ProjectID_Calculated_Optimized';
END
ELSE
BEGIN
    PRINT '  [=] 索引已存在: IX_SalesStatements_ProjectID_Calculated_Optimized';
END

-- ============================================================
-- 6. ProjectRiskRelationInfo 表索引
-- ============================================================
PRINT '';
PRINT '[6/6] 优化 ProjectRiskRelationInfo 表...';

-- 确保 ProjectID 有唯一索引用于 MERGE 操作
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('ProjectRiskRelationInfo') AND name = 'IX_ProjectRiskRelationInfo_ProjectID_Unique')
BEGIN
    -- 检查是否已有重复数据
    IF EXISTS (SELECT ProjectID FROM dbo.ProjectRiskRelationInfo GROUP BY ProjectID HAVING COUNT(*) > 1)
    BEGIN
        PRINT '  [!] 警告: ProjectRiskRelationInfo 表中存在重复的 ProjectID';
        PRINT '  [!] 请先清理重复数据后再创建唯一索引';
        PRINT '  [!] 查询重复数据: SELECT ProjectID, COUNT(*) FROM ProjectRiskRelationInfo GROUP BY ProjectID HAVING COUNT(*) > 1';
    END
    ELSE
    BEGIN
        CREATE UNIQUE NONCLUSTERED INDEX IX_ProjectRiskRelationInfo_ProjectID_Unique
        ON dbo.ProjectRiskRelationInfo(ProjectID)
        WITH (ONLINE = ON, MAXDOP = 4);

        PRINT '  [+] 已创建唯一索引: IX_ProjectRiskRelationInfo_ProjectID_Unique';
    END
END
ELSE
BEGIN
    PRINT '  [=] 唯一索引已存在: IX_ProjectRiskRelationInfo_ProjectID_Unique';
END

-- ============================================================
-- 索引创建完成,更新统计信息
-- ============================================================
PRINT '';
PRINT '============================================================';
PRINT '索引创建完成,正在更新统计信息...';

-- 更新所有表的统计信息
UPDATE STATISTICS dbo.ProductionDailyReportDetails WITH FULLSCAN;
PRINT '  [+] ProductionDailyReportDetails 统计信息已更新';

UPDATE STATISTICS dbo.AccountReceivable WITH FULLSCAN;
PRINT '  [+] AccountReceivable 统计信息已更新';

UPDATE STATISTICS dbo.SalesPayment WITH FULLSCAN;
PRINT '  [+] SalesPayment 统计信息已更新';

UPDATE STATISTICS dbo.SalesServiceIncome WITH FULLSCAN;
PRINT '  [+] SalesServiceIncome 统计信息已更新';

UPDATE STATISTICS dbo.SalesStatements WITH FULLSCAN;
PRINT '  [+] SalesStatements 统计信息已更新';

UPDATE STATISTICS dbo.ProjectRiskRelationInfo WITH FULLSCAN;
PRINT '  [+] ProjectRiskRelationInfo 统计信息已更新';

PRINT '';
PRINT '============================================================';
PRINT '所有优化索引创建完成!';
PRINT '完成时间: ' + CONVERT(VARCHAR(23), GETDATE(), 121);
PRINT '============================================================';

-- ============================================================
-- 查看索引使用情况的查询(供后续监控使用)
-- ============================================================
/*
-- 查看新创建的索引大小和使用情况
SELECT
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    ps.used_page_count * 8 / 1024 AS SizeMB,
    ps.row_count AS RowCount
FROM sys.indexes i
INNER JOIN sys.dm_db_partition_stats ps
    ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE i.name LIKE '%_Optimized'
ORDER BY ps.used_page_count DESC;

-- 查看索引使用统计
SELECT
    OBJECT_NAME(s.object_id) AS TableName,
    i.name AS IndexName,
    s.user_seeks,
    s.user_scans,
    s.user_lookups,
    s.user_updates,
    s.last_user_seek,
    s.last_user_scan
FROM sys.dm_db_index_usage_stats s
INNER JOIN sys.indexes i
    ON s.object_id = i.object_id AND s.index_id = i.index_id
WHERE s.database_id = DB_ID()
    AND i.name LIKE '%_Optimized'
ORDER BY s.user_seeks + s.user_scans + s.user_lookups DESC;
*/

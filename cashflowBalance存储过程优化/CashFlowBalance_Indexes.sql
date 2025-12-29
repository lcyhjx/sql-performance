-- =============================================
-- CashFlowBalance 存储过程性能优化 - 索引脚本
-- 创建日期：2025-12-29
-- =============================================

USE [Statistics-CT-test]
GO

-- =============================================
-- 第一阶段：核心索引（高优先级）
-- =============================================

PRINT '开始创建核心索引...'
GO

-- 索引1：BankCashFlow 表的主要查询索引
-- 覆盖存储过程中的主要查询条件
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_BankCashFlow_AccountDate' AND object_id = OBJECT_ID('BankCashFlow'))
BEGIN
    PRINT '创建索引: IX_BankCashFlow_AccountDate'

    CREATE NONCLUSTERED INDEX IX_BankCashFlow_AccountDate
    ON dbo.BankCashFlow (BankAccountID, TxnDate, isDeleted, ifSplited)
    INCLUDE (IncomeAmt, ExpenditureAmt, id)
    WITH (
        PAD_INDEX = OFF,
        STATISTICS_NORECOMPUTE = OFF,
        SORT_IN_TEMPDB = ON,
        DROP_EXISTING = OFF,
        ONLINE = ON,  -- 在线创建，不影响业务
        ALLOW_ROW_LOCKS = ON,
        ALLOW_PAGE_LOCKS = ON
    );

    PRINT '✓ 索引创建成功: IX_BankCashFlow_AccountDate'
END
ELSE
BEGIN
    PRINT '索引已存在: IX_BankCashFlow_AccountDate'
END
GO

-- =============================================
-- 第二阶段：辅助索引（中优先级）
-- =============================================

-- 索引2：BankCashBalance 表的查询优化索引
IF NOT EXISTS (SELECT * FROM sys.indexes WHERE name = 'IX_BankCashBalance_Lookup' AND object_id = OBJECT_ID('BankCashBalance'))
BEGIN
    PRINT '创建索引: IX_BankCashBalance_Lookup'

    CREATE NONCLUSTERED INDEX IX_BankCashBalance_Lookup
    ON dbo.BankCashBalance (BankAccountID, idd)
    INCLUDE (CashFlowID, IncomeAmt, ExpenditureAmt, Balance)
    WITH (
        PAD_INDEX = OFF,
        STATISTICS_NORECOMPUTE = OFF,
        SORT_IN_TEMPDB = ON,
        DROP_EXISTING = OFF,
        ONLINE = ON,
        ALLOW_ROW_LOCKS = ON,
        ALLOW_PAGE_LOCKS = ON
    );

    PRINT '✓ 索引创建成功: IX_BankCashBalance_Lookup'
END
ELSE
BEGIN
    PRINT '索引已存在: IX_BankCashBalance_Lookup'
END
GO

-- =============================================
-- 索引统计信息更新
-- =============================================

PRINT '更新统计信息...'

UPDATE STATISTICS dbo.BankCashFlow WITH FULLSCAN;
UPDATE STATISTICS dbo.BankCashBalance WITH FULLSCAN;

PRINT '✓ 统计信息更新完成'
GO

-- =============================================
-- 索引信息查询
-- =============================================

PRINT '索引创建完成摘要:'
PRINT '=================='

SELECT
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    ds.name AS FileGroup,
    CAST(ps.reserved_page_count * 8.0 / 1024 AS DECIMAL(10,2)) AS SizeMB,
    i.is_disabled AS IsDisabled
FROM sys.indexes i
INNER JOIN sys.data_spaces ds ON i.data_space_id = ds.data_space_id
INNER JOIN sys.dm_db_partition_stats ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
WHERE i.name IN ('IX_BankCashFlow_AccountDate', 'IX_BankCashBalance_Lookup')
ORDER BY TableName, IndexName;

PRINT ''
PRINT '索引创建完成！'
PRINT '建议：在非业务高峰期执行此脚本'
GO

-- =============================================
-- 索引维护脚本（定期执行）
-- =============================================

/*
-- 检查索引碎片率
SELECT
    OBJECT_NAME(ips.object_id) AS TableName,
    i.name AS IndexName,
    ips.index_type_desc,
    ips.avg_fragmentation_in_percent,
    ips.page_count,
    CASE
        WHEN ips.avg_fragmentation_in_percent > 30 THEN '建议重建'
        WHEN ips.avg_fragmentation_in_percent > 10 THEN '建议重组'
        ELSE '状态良好'
    END AS Recommendation
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE OBJECT_NAME(ips.object_id) IN ('BankCashFlow', 'BankCashBalance')
  AND i.name IS NOT NULL
ORDER BY ips.avg_fragmentation_in_percent DESC;

-- 重建索引（如果碎片率 > 30%）
ALTER INDEX IX_BankCashFlow_AccountDate ON dbo.BankCashFlow REBUILD
WITH (ONLINE = ON, MAXDOP = 4);

ALTER INDEX IX_BankCashBalance_Lookup ON dbo.BankCashBalance REBUILD
WITH (ONLINE = ON, MAXDOP = 4);

-- 重组索引（如果碎片率 10-30%）
ALTER INDEX IX_BankCashFlow_AccountDate ON dbo.BankCashFlow REORGANIZE;
ALTER INDEX IX_BankCashBalance_Lookup ON dbo.BankCashBalance REORGANIZE;
*/

-- =============================================
-- 回滚脚本（如需删除索引）
-- =============================================

/*
-- 警告：仅在确认索引不再需要时执行

DROP INDEX IF EXISTS IX_BankCashFlow_AccountDate ON dbo.BankCashFlow;
DROP INDEX IF EXISTS IX_BankCashBalance_Lookup ON dbo.BankCashBalance;

PRINT '索引已删除'
*/

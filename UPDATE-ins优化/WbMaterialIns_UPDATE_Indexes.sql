-- ============================================
-- 推荐索引创建脚本
-- ============================================
-- 说明: 为跨数据库UPDATE语句创建性能优化索引
-- 预期性能提升: 50-90%（如果之前没有这些索引）
-- 注意: 使用ONLINE=ON，不会阻塞现有查询

-- ============================================
-- 索引1: WbMaterialIns查询优化（最重要！）
-- ============================================
USE [logistics-test];
GO

PRINT '正在检查索引 IX_WbMaterialIns_TenantSite...';

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.WbMaterialIns')
      AND name = 'IX_WbMaterialIns_TenantSite'
)
BEGIN
    PRINT '开始创建索引 IX_WbMaterialIns_TenantSite...';

    CREATE NONCLUSTERED INDEX IX_WbMaterialIns_TenantSite
    ON dbo.WbMaterialIns(TenantId, SiteDate)
    INCLUDE (Id, ReceivingDailyReportID)
    WITH (
        ONLINE = ON,              -- 在线创建，不阻塞查询
        SORT_IN_TEMPDB = ON,      -- 使用tempdb排序，提高性能
        FILLFACTOR = 90,          -- 留10%空间给未来数据
        MAXDOP = 4                -- 并行度（根据服务器CPU调整）
    );

    PRINT '✓ 索引 IX_WbMaterialIns_TenantSite 创建成功';
    PRINT '  - 优化列: TenantId, SiteDate';
    PRINT '  - 包含列: Id, ReceivingDailyReportID';
    PRINT '  - 预期性能提升: 50-80%';
END
ELSE
BEGIN
    PRINT '! 索引 IX_WbMaterialIns_TenantSite 已存在';
END
GO

-- ============================================
-- 索引2: ReceivingDailyReportDetails优化（关键！）
-- ============================================
USE [Statistics-CT-test];
GO

PRINT '';
PRINT '正在检查索引 IX_ReceivingDailyReportDetails_OriginalID...';

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.ReceivingDailyReportDetails')
      AND name = 'IX_ReceivingDailyReportDetails_OriginalID'
)
BEGIN
    PRINT '开始创建索引 IX_ReceivingDailyReportDetails_OriginalID...';

    CREATE NONCLUSTERED INDEX IX_ReceivingDailyReportDetails_OriginalID
    ON dbo.ReceivingDailyReportDetails(OriginalID)
    INCLUDE (DailyReportID)
    WITH (
        ONLINE = ON,
        SORT_IN_TEMPDB = ON,
        FILLFACTOR = 90,
        MAXDOP = 4
    );

    PRINT '✓ 索引 IX_ReceivingDailyReportDetails_OriginalID 创建成功';
    PRINT '  - 优化列: OriginalID';
    PRINT '  - 包含列: DailyReportID';
    PRINT '  - 预期性能提升: 60-90% (这是最���键的索引!)';
END
ELSE
BEGIN
    PRINT '! 索引 IX_ReceivingDailyReportDetails_OriginalID 已存在';
END
GO

-- ============================================
-- 索引3: ReceivingDailyReports优化
-- ============================================
PRINT '';
PRINT '正在检查索引 IX_ReceivingDailyReports_ID_isDeleted...';

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.ReceivingDailyReports')
      AND name = 'IX_ReceivingDailyReports_ID_isDeleted'
)
BEGIN
    PRINT '开始创建索引 IX_ReceivingDailyReports_ID_isDeleted...';

    CREATE NONCLUSTERED INDEX IX_ReceivingDailyReports_ID_isDeleted
    ON dbo.ReceivingDailyReports(ID, isDeleted)
    WITH (
        ONLINE = ON,
        SORT_IN_TEMPDB = ON,
        FILLFACTOR = 90,
        MAXDOP = 4
    );

    PRINT '✓ 索引 IX_ReceivingDailyReports_ID_isDeleted 创建成功';
    PRINT '  - 优化列: ID, isDeleted';
    PRINT '  - 预期性能提升: 20-40%';
END
ELSE
BEGIN
    PRINT '! 索引 IX_ReceivingDailyReports_ID_isDeleted 已存在';
END
GO

PRINT '';
PRINT '============================================';
PRINT '索引创建完成！';
PRINT '============================================';
PRINT '';
PRINT '建议后续操作:';
PRINT '1. 更新统计信���（建议每周执行一次）';
PRINT '2. 监控索引碎片率（如果>30%则重建）';
PRINT '3. 使用优化后的UPDATE语句测试性能';
PRINT '';
GO

-- ============================================
-- 索引维护脚本（可选）
-- ============================================

-- 更新统计信息
/*
USE [logistics-test];
UPDATE STATISTICS dbo.WbMaterialIns WITH FULLSCAN;

USE [Statistics-CT-test];
UPDATE STATISTICS dbo.ReceivingDailyReportDetails WITH FULLSCAN;
UPDATE STATISTICS dbo.ReceivingDailyReports WITH FULLSCAN;
*/

-- 查看索引碎片率
/*
SELECT
    OBJECT_NAME(ips.object_id) AS TableName,
    i.name AS IndexName,
    ips.avg_fragmentation_in_percent,
    ips.page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.avg_fragmentation_in_percent > 10
  AND ips.page_count > 1000
ORDER BY ips.avg_fragmentation_in_percent DESC;
*/

-- 重建索引（如果碎片率>30%）
/*
USE [logistics-test];
ALTER INDEX IX_WbMaterialIns_TenantSite ON dbo.WbMaterialIns REBUILD WITH (ONLINE = ON);

USE [Statistics-CT-test];
ALTER INDEX IX_ReceivingDailyReportDetails_OriginalID ON dbo.ReceivingDailyReportDetails REBUILD WITH (ONLINE = ON);
ALTER INDEX IX_ReceivingDailyReports_ID_isDeleted ON dbo.ReceivingDailyReports REBUILD WITH (ONLINE = ON);
*/

-- ============================================
-- ProductionDailyReportDetails INSERT优化索引
-- ============================================
-- 用途: 优化INSERT...SELECT UNION查询的性能
-- 预期提升: 10-30%
-- 注意: 使用ONLINE=ON避免阻塞

-- ============================================
-- 当前数据库: Statistics-CT-test
-- ============================================
USE [Statistics-CT-test];
GO

PRINT '开始创建索引...';
PRINT '';

-- 索引1: Stations - 生产系统站点ID
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.Stations')
    AND name = 'IX_Stations_ProductionSys_Optimized'
)
BEGIN
    PRINT '创建索引: IX_Stations_ProductionSys_Optimized';
    CREATE NONCLUSTERED INDEX IX_Stations_ProductionSys_Optimized
    ON dbo.Stations(StationID_ProductionSys, isDeleted)
    INCLUDE (ID, Type)
    WITH (ONLINE = ON, FILLFACTOR = 90);
    PRINT '✓ 完成';
END
ELSE
    PRINT '! 索引已存在: IX_Stations_ProductionSys_Optimized';
GO

-- 索引2: Stations - 称重系统站点ID
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.Stations')
    AND name = 'IX_Stations_WeighbridgeSys_Optimized'
)
BEGIN
    PRINT '创建索引: IX_Stations_WeighbridgeSys_Optimized';
    CREATE NONCLUSTERED INDEX IX_Stations_WeighbridgeSys_Optimized
    ON dbo.Stations(StationID_WeighbridgeSys, isDeleted)
    INCLUDE (ID, Type)
    WITH (ONLINE = ON, FILLFACTOR = 90);
    PRINT '✓ 完成';
END
ELSE
    PRINT '! 索引已存在: IX_Stations_WeighbridgeSys_Optimized';
GO

-- 索引3: ProductionDailyReports - 优化JOIN条件
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.ProductionDailyReports')
    AND name = 'IX_ProductionDailyReports_Station_Date_Optimized'
)
BEGIN
    PRINT '创建索引: IX_ProductionDailyReports_Station_Date_Optimized';
    CREATE NONCLUSTERED INDEX IX_ProductionDailyReports_Station_Date_Optimized
    ON dbo.ProductionDailyReports(StationID, ReportDate, isDeleted)
    INCLUDE (ID)
    WITH (ONLINE = ON, FILLFACTOR = 90);
    PRINT '✓ 完成';
END
ELSE
    PRINT '! 索引已存在: IX_ProductionDailyReports_Station_Date_Optimized';
GO

-- 索引4: ProductCategories - 分类名称查找
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.ProductCategories')
    AND name = 'IX_ProductCategories_CategoryName'
)
BEGIN
    PRINT '创建索引: IX_ProductCategories_CategoryName';
    CREATE NONCLUSTERED INDEX IX_ProductCategories_CategoryName
    ON dbo.ProductCategories(CategoryName)
    INCLUDE (Unit)
    WITH (ONLINE = ON, FILLFACTOR = 90);
    PRINT '✓ 完成';
END
ELSE
    PRINT '! 索引已存在: IX_ProductCategories_CategoryName';
GO

-- 索引5: Project - 项目信息查找
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.Project')
    AND name = 'IX_Project_ID_SalesInfo'
)
BEGIN
    PRINT '创建索引: IX_Project_ID_SalesInfo';
    CREATE NONCLUSTERED INDEX IX_Project_ID_SalesInfo
    ON dbo.Project(ID)
    INCLUDE (SalesDepartment, Salesman, SalesPaymentType)
    WITH (ONLINE = ON, FILLFACTOR = 90);
    PRINT '✓ 完成';
END
ELSE
    PRINT '! 索引已存在: IX_Project_ID_SalesInfo';
GO

PRINT '';
PRINT '=========================================================';
PRINT '当前数据库索引创建完成！';
PRINT '=========================================================';
PRINT '';

-- ============================================
-- 跨数据库索引建议
-- ============================================
PRINT '注意: 以下索引需要在对应的数据库中创建';
PRINT '';

PRINT '----------------------------------------';
PRINT '数据库: logistics-test';
PRINT '----------------------------------------';
PRINT 'USE [logistics-test];';
PRINT 'GO';
PRINT '';
PRINT '-- 索引: ProductDetailsDino-mt';
PRINT 'CREATE NONCLUSTERED INDEX IX_ProductDetails_TenantSiteDate';
PRINT 'ON dbo.[ProductDetailsDino-mt](TenantId, SiteDate, SiteId)';
PRINT 'INCLUDE (Id, ProjectId, PlanId, ActQuantity, ConcreteCategory, ...);';
PRINT '';
PRINT '-- 索引: UserPlans';
PRINT 'CREATE NONCLUSTERED INDEX IX_UserPlans_ID';
PRINT 'ON dbo.UserPlans(id)';
PRINT 'INCLUDE (Type, Creator, ConcreteCategory, EgcbOrderCreator, EgcbOrderCreatorPhone, EGCBOrderID);';
PRINT '';
PRINT '-- 索引: Plans';
PRINT 'CREATE NONCLUSTERED INDEX IX_Plans_ID';
PRINT 'ON dbo.Plans(id)';
PRINT 'INCLUDE (HaulDistance, Code);';
PRINT '';

PRINT '----------------------------------------';
PRINT '数据库: Weighbridge';
PRINT '----------------------------------------';
PRINT 'USE [Weighbridge];';
PRINT 'GO';
PRINT '';
PRINT '-- 索引: Shipping';
PRINT 'CREATE NONCLUSTERED INDEX IX_Shipping_StationDeleted';
PRINT 'ON dbo.Shipping(StationID, isDeleted)';
PRINT 'INCLUDE (DeliveringID, Number, ProjectName, Consignee, Position, ProjectID);';
PRINT '';
PRINT '-- 索引: Delivering';
PRINT 'CREATE NONCLUSTERED INDEX IX_Delivering_ID_Time';
PRINT 'ON dbo.Delivering(ID, GrossTime, isDeleted)';
PRINT 'INCLUDE (Vehicle, grade, Item, Specification, RealNet, Net, grade1, feature, UserPlanID);';
PRINT '';
PRINT '-- 索引: Delivering - 时间范围查询优化';
PRINT 'CREATE NONCLUSTERED INDEX IX_Delivering_GrossTime';
PRINT 'ON dbo.Delivering(GrossTime, isDeleted)';
PRINT 'INCLUDE (ID, Vehicle, RealNet, Net);';
PRINT '';

PRINT '=========================================================';
PRINT '索引建议生成完成！';
PRINT '=========================================================';
PRINT '';
PRINT '注意事项:';
PRINT '1. 跨数据库索引需要在各自数据库中手动创建';
PRINT '2. INCLUDE列可根据实际SELECT字段调整';
PRINT '3. 建议在业务低峰期创建索引';
PRINT '4. 监控索引碎片率，定期维护';
PRINT '';

-- ============================================
-- 索引维护脚本
-- ============================================
/*
-- 查看索引碎片率
SELECT
    OBJECT_NAME(ips.object_id) AS TableName,
    i.name AS IndexName,
    ips.avg_fragmentation_in_percent,
    ips.page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i
    ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.avg_fragmentation_in_percent > 10
  AND ips.page_count > 1000
  AND i.name IN (
      'IX_Stations_ProductionSys_Optimized',
      'IX_Stations_WeighbridgeSys_Optimized',
      'IX_ProductionDailyReports_Station_Date_Optimized',
      'IX_ProductCategories_CategoryName',
      'IX_Project_ID_SalesInfo'
  )
ORDER BY ips.avg_fragmentation_in_percent DESC;

-- 重建索引（如果碎片率>30%）
ALTER INDEX IX_Stations_ProductionSys_Optimized
ON dbo.Stations REBUILD WITH (ONLINE = ON);

ALTER INDEX IX_Stations_WeighbridgeSys_Optimized
ON dbo.Stations REBUILD WITH (ONLINE = ON);

ALTER INDEX IX_ProductionDailyReports_Station_Date_Optimized
ON dbo.ProductionDailyReports REBUILD WITH (ONLINE = ON);

ALTER INDEX IX_ProductCategories_CategoryName
ON dbo.ProductCategories REBUILD WITH (ONLINE = ON);

ALTER INDEX IX_Project_ID_SalesInfo
ON dbo.Project REBUILD WITH (ONLINE = ON);

-- 更新统计信息
UPDATE STATISTICS dbo.Stations WITH FULLSCAN;
UPDATE STATISTICS dbo.ProductionDailyReports WITH FULLSCAN;
UPDATE STATISTICS dbo.ProductCategories WITH FULLSCAN;
UPDATE STATISTICS dbo.Project WITH FULLSCAN;
*/

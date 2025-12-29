-- ============================================
-- 优化���本2: 临时表+批量处理
-- ============================================
-- 说明: 使用临时表缓存需要更新的ID，然后批量更新
-- 适用场景: 大数据量场景（影响行数 > 10,000）
-- 预期性能提升: 40-60%

-- Step 1: 创建临时表存储需要更新的ID
SELECT ins.Id
INTO #ToUpdate
FROM [logistics-test].dbo.WbMaterialIns ins
WHERE ins.TenantId = @TenantID
  AND ins.SiteDate >= DATEADD(MONTH, -2, CAST(@ReportDate AS DATE))
  AND NOT EXISTS (
    SELECT 1
    FROM dbo.ReceivingDailyReportDetails d
    INNER JOIN dbo.ReceivingDailyReports r
        ON r.ID = d.DailyReportID
       AND r.isDeleted = 0
    WHERE d.OriginalID = ins.Id
  );

-- 显示需要更新的行数
SELECT COUNT(*) AS ToBeUpdated FROM #ToUpdate;

-- Step 2: 在临时表上创建索引
CREATE CLUSTERED INDEX IX_ToUpdate ON #ToUpdate(Id);

-- Step 3: 批量更新
UPDATE ins
SET ReceivingDailyReportID = NULL
FROM [logistics-test].dbo.WbMaterialIns ins
INNER JOIN #ToUpdate t ON ins.Id = t.Id;

-- 查看影响行数
SELECT @@ROWCOUNT AS AffectedRows;

-- Step 4: 清理临时表
DROP TABLE #ToUpdate;

-- ============================================
-- 优化版本2 - 分批处理变体
-- ============================================
-- 说明: 在版本2基础上增加分批处理，避免长时间锁定
-- 适用场景: 超大数据量场景（影响行数 > 100,000）
-- 预期性能提升: 40-60%，并降低锁竞争

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
DECLARE @TotalRows INT = (SELECT COUNT(*) FROM #ToUpdate);
PRINT '需要更新的总行数: ' + CAST(@TotalRows AS VARCHAR(20));

-- Step 2: 在临时表上创建索引
CREATE CLUSTERED INDEX IX_ToUpdate ON #ToUpdate(Id);

-- Step 3: 分批更新
DECLARE @BatchSize INT = 5000;  -- 每批处理5000行
DECLARE @ProcessedRows INT = 0;
DECLARE @BatchCount INT = 0;

WHILE EXISTS (SELECT 1 FROM #ToUpdate)
BEGIN
    SET @BatchCount = @BatchCount + 1;

    -- 更新一批数据
    UPDATE TOP (@BatchSize) ins
    SET ReceivingDailyReportID = NULL
    FROM [logistics-test].dbo.WbMaterialIns ins
    INNER JOIN #ToUpdate t ON ins.Id = t.Id;

    SET @ProcessedRows = @ProcessedRows + @@ROWCOUNT;

    -- 删除已处理的ID
    DELETE TOP (@BatchSize) FROM #ToUpdate;

    -- 显示进度
    PRINT '批次 ' + CAST(@BatchCount AS VARCHAR(10))
        + ': 已处理 ' + CAST(@ProcessedRows AS VARCHAR(20))
        + ' / ' + CAST(@TotalRows AS VARCHAR(20))
        + ' (' + CAST(@ProcessedRows * 100 / @TotalRows AS VARCHAR(10)) + '%)';

    -- 短暂延迟，释放资源，避免长时间锁定
    WAITFOR DELAY '00:00:00.100';  -- 100毫秒
END

PRINT '✓ 更新完成！总共处理了 ' + CAST(@ProcessedRows AS VARCHAR(20)) + ' 行';

-- Step 4: 清理临时表
DROP TABLE #ToUpdate;

-- ============================================================
-- 性能测试脚本
-- 对比原始存储过程和优化后的存储过程性能
-- 测试日期: 2025-12-29
-- ============================================================

USE [Statistics-CT-test];
GO

SET NOCOUNT ON;

PRINT '============================================================';
PRINT '存储过程性能对比测试';
PRINT '测试时间: ' + CONVERT(VARCHAR(23), GETDATE(), 121);
PRINT '============================================================';

-- 创建测试结果表
IF OBJECT_ID('tempdb..#PerformanceTest') IS NOT NULL
    DROP TABLE #PerformanceTest;

CREATE TABLE #PerformanceTest
(
    TestID INT IDENTITY(1, 1),
    TestName NVARCHAR(100),
    TestRound INT,
    StartTime DATETIME2,
    EndTime DATETIME2,
    Duration_MS INT,
    CPU_Time_MS INT,
    Logical_Reads BIGINT,
    Physical_Reads BIGINT,
    ErrorMessage NVARCHAR(MAX)
);

-- ============================================================
-- 测试配置
-- ============================================================
DECLARE @TestRounds INT = 3;  -- 测试轮次
DECLARE @CurrentRound INT = 1;
DECLARE @StartTime DATETIME2;
DECLARE @EndTime DATETIME2;
DECLARE @CPU_Start INT;
DECLARE @CPU_End INT;

PRINT '';
PRINT CONCAT('测试轮次: ', @TestRounds);
PRINT '';

-- ============================================================
-- 测试1: 原始存储过程
-- ============================================================
PRINT '------------------------------------------------------------';
PRINT '[测试1] 原始存储过程: usp_UpdateProjectRiskRelationInfo';
PRINT '------------------------------------------------------------';

SET @CurrentRound = 1;
WHILE @CurrentRound <= @TestRounds
BEGIN
    PRINT CONCAT('  轮次 ', @CurrentRound, '/', @TestRounds, '...');

    -- 清空缓存(可选,用于冷启动测试)
    -- DBCC DROPCLEANBUFFERS;  -- 清空数据缓存
    -- DBCC FREEPROCCACHE;     -- 清空执行计划缓存

    -- 启用统计信息
    SET STATISTICS IO ON;
    SET STATISTICS TIME ON;

    SET @StartTime = SYSDATETIME();
    SET @CPU_Start = @@CPU_BUSY;

    BEGIN TRY
        -- 执行原始存储过程
        EXEC dbo.usp_UpdateProjectRiskRelationInfo;

        SET @EndTime = SYSDATETIME();
        SET @CPU_End = @@CPU_BUSY;

        -- 记录结果
        INSERT INTO #PerformanceTest
        (TestName, TestRound, StartTime, EndTime, Duration_MS, CPU_Time_MS)
        VALUES
        ('Original', @CurrentRound, @StartTime, @EndTime,
         DATEDIFF(MILLISECOND, @StartTime, @EndTime),
         (@CPU_End - @CPU_Start) * 31.25);  -- 转换为毫秒

        PRINT CONCAT('    完成 - 耗时: ', DATEDIFF(MILLISECOND, @StartTime, @EndTime), 'ms');

    END TRY
    BEGIN CATCH
        INSERT INTO #PerformanceTest
        (TestName, TestRound, StartTime, EndTime, Duration_MS, ErrorMessage)
        VALUES
        ('Original', @CurrentRound, @StartTime, SYSDATETIME(),
         DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()),
         ERROR_MESSAGE());

        PRINT CONCAT('    失败 - ', ERROR_MESSAGE());
    END CATCH;

    SET STATISTICS IO OFF;
    SET STATISTICS TIME OFF;

    SET @CurrentRound = @CurrentRound + 1;

    -- 等待几秒钟,让系统稳定
    WAITFOR DELAY '00:00:02';
END;

PRINT '';

-- ============================================================
-- 测试2: 优化后的存储过程
-- ============================================================
PRINT '------------------------------------------------------------';
PRINT '[测试2] 优化存储过程: usp_UpdateProjectRiskRelationInfo_Optimized';
PRINT '------------------------------------------------------------';

SET @CurrentRound = 1;
WHILE @CurrentRound <= @TestRounds
BEGIN
    PRINT CONCAT('  轮次 ', @CurrentRound, '/', @TestRounds, '...');

    -- 清空缓存(可选)
    -- DBCC DROPCLEANBUFFERS;
    -- DBCC FREEPROCCACHE;

    SET STATISTICS IO ON;
    SET STATISTICS TIME ON;

    SET @StartTime = SYSDATETIME();
    SET @CPU_Start = @@CPU_BUSY;

    BEGIN TRY
        -- 执行优化后的存储过程
        EXEC dbo.usp_UpdateProjectRiskRelationInfo_Optimized;

        SET @EndTime = SYSDATETIME();
        SET @CPU_End = @@CPU_BUSY;

        INSERT INTO #PerformanceTest
        (TestName, TestRound, StartTime, EndTime, Duration_MS, CPU_Time_MS)
        VALUES
        ('Optimized', @CurrentRound, @StartTime, @EndTime,
         DATEDIFF(MILLISECOND, @StartTime, @EndTime),
         (@CPU_End - @CPU_Start) * 31.25);

        PRINT CONCAT('    完成 - 耗时: ', DATEDIFF(MILLISECOND, @StartTime, @EndTime), 'ms');

    END TRY
    BEGIN CATCH
        INSERT INTO #PerformanceTest
        (TestName, TestRound, StartTime, EndTime, Duration_MS, ErrorMessage)
        VALUES
        ('Optimized', @CurrentRound, @StartTime, SYSDATETIME(),
         DATEDIFF(MILLISECOND, @StartTime, SYSDATETIME()),
         ERROR_MESSAGE());

        PRINT CONCAT('    失败 - ', ERROR_MESSAGE());
    END CATCH;

    SET STATISTICS IO OFF;
    SET STATISTICS TIME OFF;

    SET @CurrentRound = @CurrentRound + 1;

    WAITFOR DELAY '00:00:02';
END;

PRINT '';

-- ============================================================
-- 生成测试报告
-- ============================================================
PRINT '============================================================';
PRINT '测试结果汇总';
PRINT '============================================================';
PRINT '';

-- 每轮测试详细结果
PRINT '每轮测试详细数据:';
PRINT '------------------------------------------------------------';
SELECT
    TestName AS '版本',
    TestRound AS '轮次',
    Duration_MS AS '执行时间(ms)',
    CPU_Time_MS AS 'CPU时间(ms)',
    CONVERT(VARCHAR(23), StartTime, 121) AS '开始时间',
    CASE WHEN ErrorMessage IS NOT NULL THEN '失败: ' + ErrorMessage ELSE '成功' END AS '状态'
FROM #PerformanceTest
ORDER BY TestName, TestRound;

PRINT '';
PRINT '统计汇总:';
PRINT '------------------------------------------------------------';

-- 统计汇总
SELECT
    TestName AS '版本',
    COUNT(*) AS '测试次数',
    AVG(Duration_MS) AS '平均执行时间(ms)',
    MIN(Duration_MS) AS '最小执行时间(ms)',
    MAX(Duration_MS) AS '最大执行时间(ms)',
    STDEV(Duration_MS) AS '标准差(ms)',
    SUM(CASE WHEN ErrorMessage IS NOT NULL THEN 1 ELSE 0 END) AS '失败次数'
FROM #PerformanceTest
GROUP BY TestName
ORDER BY TestName;

PRINT '';
PRINT '性能提升对比:';
PRINT '------------------------------------------------------------';

-- 性能提升计算
DECLARE @OriginalAvg FLOAT = (SELECT AVG(Duration_MS) FROM #PerformanceTest WHERE TestName = 'Original' AND ErrorMessage IS NULL);
DECLARE @OptimizedAvg FLOAT = (SELECT AVG(Duration_MS) FROM #PerformanceTest WHERE TestName = 'Optimized' AND ErrorMessage IS NULL);
DECLARE @Improvement FLOAT = ((@OriginalAvg - @OptimizedAvg) / @OriginalAvg) * 100;
DECLARE @SpeedupFactor FLOAT = @OriginalAvg / NULLIF(@OptimizedAvg, 0);

PRINT CONCAT('原始版本平均执行时间:   ', FORMAT(@OriginalAvg, 'N2'), ' ms');
PRINT CONCAT('优化版本平均执行时间:   ', FORMAT(@OptimizedAvg, 'N2'), ' ms');
PRINT CONCAT('性能提升:              ', FORMAT(@Improvement, 'N2'), '%');
PRINT CONCAT('加速倍数:              ', FORMAT(@SpeedupFactor, 'N2'), 'x');
PRINT '';

IF @Improvement > 0
BEGIN
    PRINT CONCAT('✓ 优化成功! 性能提升了 ', FORMAT(@Improvement, 'N2'), '%');
    IF @Improvement > 50
        PRINT '  [优秀] 性能提升超过50%';
    ELSE IF @Improvement > 30
        PRINT '  [良好] 性能提升在30-50%之间';
    ELSE IF @Improvement > 10
        PRINT '  [一般] 性能提升在10-30%之间';
    ELSE
        PRINT '  [轻微] 性能提升小于10%';
END
ELSE
BEGIN
    PRINT CONCAT('✗ 警告! 优化版本性能反而下降了 ', FORMAT(ABS(@Improvement), 'N2'), '%');
    PRINT '  请检查优化策略和索引是否正确创建';
END

PRINT '';
PRINT '============================================================';
PRINT '测试完成!';
PRINT '完成时间: ' + CONVERT(VARCHAR(23), GETDATE(), 121);
PRINT '============================================================';

-- ============================================================
-- 保存测试结果到永久表(可选)
-- ============================================================
/*
IF OBJECT_ID('dbo.PerformanceTestHistory') IS NULL
BEGIN
    CREATE TABLE dbo.PerformanceTestHistory
    (
        TestID INT IDENTITY(1,1) PRIMARY KEY,
        TestDate DATETIME2 DEFAULT SYSDATETIME(),
        TestName NVARCHAR(100),
        TestRound INT,
        StartTime DATETIME2,
        EndTime DATETIME2,
        Duration_MS INT,
        CPU_Time_MS INT,
        Logical_Reads BIGINT,
        Physical_Reads BIGINT,
        ErrorMessage NVARCHAR(MAX)
    );
END;

-- 保存本次测试结果
INSERT INTO dbo.PerformanceTestHistory
(TestName, TestRound, StartTime, EndTime, Duration_MS, CPU_Time_MS, Logical_Reads, Physical_Reads, ErrorMessage)
SELECT
    TestName, TestRound, StartTime, EndTime, Duration_MS, CPU_Time_MS, Logical_Reads, Physical_Reads, ErrorMessage
FROM #PerformanceTest;

PRINT '测试结果已保存到 dbo.PerformanceTestHistory 表';
*/

-- 清理
DROP TABLE #PerformanceTest;

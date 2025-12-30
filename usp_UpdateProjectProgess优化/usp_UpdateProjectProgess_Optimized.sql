-- =============================================
-- 优化版本: usp_UpdateProjectProgess
-- 优化日期: 2025-12-30
-- 主要优化点:
--   1. 预计算常量(GETDATE()、3个月前日期、类型过滤器)
--   2. 临时表添加索引
--   3. 移除UPDATE语句中的NOLOCK提示
--   4. 使用IS NULL替代!= NULL的错误判断
--   5. 预计算三个月前的日期，避免重复计算
--   6. 添加事务控制和错误处理
-- =============================================
CREATE PROCEDURE [dbo].[usp_UpdateProjectProgess]
AS
BEGIN
    SET NOCOUNT ON;

    -- 添加错误处理
    BEGIN TRY
        BEGIN TRANSACTION;

        -- 优化1: 预计算常量，避免重复执行
        DECLARE @ThreeMonthsAgo DATE = DATEADD(MONTH, -3, CAST(GETDATE() AS DATE));
        DECLARE @ProjectSalesTypeFilter NVARCHAR(MAX);
        DECLARE @TypeFilter TABLE (Type NVARCHAR(100));

        -- 一次性获取参数值
        SELECT @ProjectSalesTypeFilter = ParaValue
        FROM dbo.Parameters WITH (NOLOCK)
        WHERE ParaName = 'ProjectSalesTypeFilter';

        -- 一次性解析类型过滤器
        INSERT INTO @TypeFilter (Type)
        SELECT col
        FROM dbo.f_split(@ProjectSalesTypeFilter, ',');

        /*
            业务逻辑说明:
            1.如果没有生产记录 且 工程核算账户进展为空——未开工
            2.如果有生产记录 且最近一条的生产日期在3个月内 且工程核算账户进展 in（NULL, '停工', '完工', '未开工'）——在建
            3.如果有生产记录 且最近一条的生产日期不在3个月内 且工程核算账户进展 in（NULL, '停工', '在建', '未开工'）——完工
            其他情况  不修改
        */

        -- 优化2: 使用表变量进行类型过滤，避免相关子查询
        SELECT *
        INTO #temp
        FROM
        (
            SELECT ROW_NUMBER() OVER (PARTITION BY ProjectID ORDER BY ReceiptDate DESC) num,
                   ProjectID,
                   ReceiptDate,
                   ID
            FROM ProductionDailyReportDetails WITH (NOLOCK)
            WHERE Type IN (SELECT Type FROM @TypeFilter)
        ) x
        WHERE x.num = 1;

        -- 优化3: 为临时表添加聚集索引
        CREATE CLUSTERED INDEX IX_temp_ProjectID ON #temp(ProjectID);

        -- 优化4: 移除UPDATE中的NOLOCK，避免数据不一致
        -- 优化5: 使用预计算的@ThreeMonthsAgo替代重复的GETDATE() - 90
        -- 优化6: 使用IS NULL替代!= NULL
        UPDATE p
        SET p.ProjectProgess = CASE
                                   WHEN report.ID IS NULL
                                        AND ISNULL(p.ProjectProgess, '') = '' THEN
                                       '未开工'
                                   WHEN report.ID IS NOT NULL
                                        AND report.ReceiptDate >= @ThreeMonthsAgo
                                        AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '完工', '未开工' ) THEN
                                       '在建'
                                   WHEN report.ID IS NOT NULL
                                        AND report.ReceiptDate < @ThreeMonthsAgo
                                        AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '在建', '未开工' ) THEN
                                       '完工'
                                   ELSE
                                       p.ProjectProgess
                               END,
            p.FinishDate = CASE
                               WHEN report.ID IS NOT NULL
                                    AND report.ReceiptDate >= @ThreeMonthsAgo
                                    AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '完工', '未开工', '在建' ) THEN
                                   NULL
                               WHEN report.ID IS NOT NULL
                                    AND report.ReceiptDate < @ThreeMonthsAgo
                                    AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '在建', '未开工', '完工' ) THEN
                                   report.ReceiptDate
                               ELSE
                                   p.FinishDate
                           END
        FROM dbo.Project p
            LEFT JOIN #temp report
                ON p.ID = report.ProjectID
        WHERE isDeleted IS NULL OR isDeleted != 1  -- 优化7: 使用IS NULL处理NULL值
              AND (Status IS NULL OR Status != 1)
              AND Type = 1;

        -- 清理临时表
        DROP TABLE #temp;

        COMMIT TRANSACTION;

    END TRY
    BEGIN CATCH
        -- 发生错误时回滚事务
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- 重新抛出错误
        DECLARE @ErrorMessage NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrorSeverity INT = ERROR_SEVERITY();
        DECLARE @ErrorState INT = ERROR_STATE();

        RAISERROR(@ErrorMessage, @ErrorSeverity, @ErrorState);
    END CATCH;
END;

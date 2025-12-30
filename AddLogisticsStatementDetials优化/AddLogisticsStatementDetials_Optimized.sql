-- =============================================
-- 优化版本: AddLogisticsStatementDetials
-- 优化日期: 2025-12-30
-- 主要优化点:
--   1. 添加事务控制和错误处理
--   2. 添加SET NOCOUNT ON减少网络流量
--   3. 优化UPDATE子查询，避免重复聚合计算
--   4. 添加参数验证
--   5. 使用更清晰的代码结构
-- =============================================
CREATE PROCEDURE [dbo].[AddLogisticsStatementDetials]
    @StatementID BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    -- 参数验证
    IF @StatementID IS NULL
    BEGIN
        RAISERROR('参数 @StatementID 不能为空', 16, 1);
        RETURN;
    END;

    -- 添加错误处理
    BEGIN TRY
        BEGIN TRANSACTION;

        -- 步骤1: 删除旧的明细记录
        DELETE FROM dbo.LogisticsStatementDetails
        WHERE StatementID = @StatementID;

        -- 步骤2: 插入新的明细记录
        INSERT INTO LogisticsStatementDetails
        (
            StatementID,
            ProjectName,
            ProductCategory,
            Distance,
            LogisticsUCost,
            ReturnUCost,
            OvertimeUCost,
            VehicleNum,
            VehicleCount,
            ShippingQty_M3,
            ReorderQty_M3,
            ReturnQty_M3,
            Overtime,
            TowerCraneAmt,
            VehicleBackAmt,
            OtherAmt,
            Subtotal
        )
        SELECT @StatementID,
               ProjectName,
               ProductCategory,
               Distance,
               LogisticsUCost,
               LogisticsReturnUCost,
               LogisticsOvertimeUCost,
               VehicleNum,
               COUNT(id) AS VehicleCount,
               SUM(LogisticsFinalQty_M3) AS ShippingQty_M3,
               SUM(LogisticsReorderQty) AS ReorderQty_M3,
               SUM(LogisticsReturnQty) AS ReturnQty_M3,
               SUM(LogisticsOvertime) AS Overtime,
               SUM(LogisticsTowerCraneAmt) AS LogisticsTowerCraneAmt,
               SUM(LogisticsVehicleBackAmt) AS LogisticsVehicleBackAmt,
               SUM(LogisticsOtherAmt) AS OtherAmt,
               -- 优化: 使用更清晰的小计计算逻辑
               ROUND(
                   (ISNULL(SUM(LogisticsFinalQty_M3), 0) + ISNULL(SUM(LogisticsReorderQty), 0))
                   * ISNULL(LogisticsUCost, 0) + ISNULL(SUM(LogisticsReturnQty), 0)
                   * ISNULL(LogisticsReturnUCost, 0) + ISNULL(SUM(LogisticsOvertime), 0)
                   * ISNULL(LogisticsOvertimeUCost, 0) + ISNULL(SUM(LogisticsTowerCraneAmt), 0)
                   + ISNULL(SUM(LogisticsVehicleBackAmt), 0) + ISNULL(SUM(LogisticsOtherAmt), 0),
                   2
               ) AS SubtotalAmt
        FROM dbo.ProductionDailyReportDetails WITH (NOLOCK)
        WHERE LogisticStatementID = @StatementID
        GROUP BY ProjectName,
                 ProductCategory,
                 Distance,
                 LogisticsUCost,
                 LogisticsReturnUCost,
                 LogisticsOvertimeUCost,
                 VehicleNum;

        -- 步骤3: 优化 - 使用变量存储聚合结果，避免重复计算
        DECLARE @TotalFreightAmt DECIMAL(18, 2);

        SELECT @TotalFreightAmt = ROUND(SUM(Subtotal), 2)
        FROM dbo.LogisticsStatementDetails WITH (NOLOCK)
        WHERE StatementID = @StatementID;

        -- 步骤4: 更新主表的运费金额
        UPDATE dbo.LogisticsStatements
        SET FreightAmt = @TotalFreightAmt
        WHERE ID = @StatementID;

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

-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE PROCEDURE [dbo].[AddLogisticsStatementDetials]
	@StatementID BIGINT
AS
BEGIN

DELETE dbo.LogisticsStatementDetails WHERE StatementID = @StatementID

INSERT LogisticsStatementDetails 
(StatementID, ProjectName, ProductCategory, Distance, LogisticsUCost, ReturnUCost, OvertimeUCost, VehicleNum, VehicleCount, ShippingQty_M3, ReorderQty_M3, ReturnQty_M3, 
Overtime,TowerCraneAmt,VehicleBackAmt,OtherAmt,Subtotal)

SELECT @StatementID,ProjectName,ProductCategory,Distance,LogisticsUCost,LogisticsReturnUCost,LogisticsOvertimeUCost,VehicleNum,
COUNT(id) AS VehicleCount,
SUM(LogisticsFinalQty_M3) AS ShippingQty_M3,SUM(LogisticsReorderQty) AS ReorderQty_M3,SUM(LogisticsReturnQty) AS ReturnQty_M3,
SUM(LogisticsOvertime) AS Overtime,
SUM(LogisticsTowerCraneAmt) AS LogisticsTowerCraneAmt,SUM(LogisticsVehicleBackAmt) AS LogisticsVehicleBackAmt,SUM(LogisticsOtherAmt) AS OtherAmt,
ROUND((ISNULL(SUM(LogisticsFinalQty_M3),0) + ISNULL(SUM(LogisticsReorderQty),0)) * ISNULL(LogisticsUCost,0) 
+  ISNULL(SUM(LogisticsReturnQty),0) * ISNULL(LogisticsReturnUCost,0) 
+ ISNULL(SUM(LogisticsOvertime),0) * ISNULL(LogisticsOvertimeUCost,0) 
+ ISNULL(SUM(LogisticsTowerCraneAmt),0) + ISNULL(SUM(LogisticsVehicleBackAmt),0) + ISNULL(SUM(LogisticsOtherAmt),0),2) AS SubtotalAmt

FROM dbo.ProductionDailyReportDetails
WHERE LogisticStatementID =@StatementID
GROUP BY ProjectName,ProductCategory,Distance,LogisticsUCost,LogisticsReturnUCost,LogisticsOvertimeUCost,VehicleNum

UPDATE dbo.LogisticsStatements 
SET FreightAmt = (SELECT Round(SUM(Subtotal),2) AS Total FROM dbo.LogisticsStatementDetails WHERE StatementID = @StatementID GROUP BY StatementID)  
WHERE ID = @StatementID

END

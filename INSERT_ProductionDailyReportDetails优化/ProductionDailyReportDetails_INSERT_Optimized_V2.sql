-- ============================================
-- 优化版本2: 使用临时表缓存跨库数据
-- ============================================
-- 适用场景: 定时批量任务
-- 优化要点:
-- 1. 将跨库数据缓存到临时表
-- 2. 在临时表上创建索引优化JOIN
-- 3. 减少跨库查询次数
-- 4. 预期性能提升: 30-50%

-- ============================================
-- Step 1: 缓存生产数据到临时表
-- ============================================
PRINT '正在缓存生产数据...';

SELECT
    mt.*,
    -- 预计算单位相关字段
    ISNULL(pc.Unit, @DefaultUnit) as UnitType,
    CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN @ProCoeff ELSE NULL END as Coefficient,
    ISNULL(mt.SignedQuantity, mt.FaceQuantity) as EffectiveSignedQty
INTO #ProductionDataCache
FROM [logistics-test].dbo.[ProductDetailsDino-mt] mt
LEFT JOIN [logistics-test].dbo.ProductCategories_Cache pc  -- 如果可能，也缓存这个表
    ON pc.CategoryName = ISNULL(mt.ConcreteCategory, @DefaultProductCategory)
WHERE mt.TenantId = @TenantID
  AND mt.SiteDate >= @ReportDate
  AND mt.SiteDate < DATEADD(DAY, 1, @ReportDate);

-- 创建索引优化后续JOIN
CREATE CLUSTERED INDEX IX_Temp_Production ON #ProductionDataCache(SiteId, SiteDate);
CREATE NONCLUSTERED INDEX IX_Temp_Production_TenantDate ON #ProductionDataCache(TenantId, SiteDate);

PRINT '✓ 生产数据缓存完成: ' + CAST(@@ROWCOUNT AS VARCHAR(20)) + ' 行';

-- ============================================
-- Step 2: 缓存称重数据到临时表
-- ============================================
PRINT '正在缓存称重数据...';

SELECT
    Shipping.*,
    Delivering.DeliveringID,
    Delivering.GrossTime,
    Delivering.Vehicle,
    Delivering.grade,
    Delivering.Item,
    Delivering.Specification,
    Delivering.RealNet,
    Delivering.Net,
    Delivering.grade1,
    Delivering.feature,
    Delivering.UserPlanID,
    up.Type as UserPlanType,
    up.Creator as UserPlanCreator,
    up.ConcreteCategory as UserPlanCategory,
    up.EgcbOrderCreator,
    up.EgcbOrderCreatorPhone,
    up.EGCBOrderID,
    p.HaulDistance,
    p.Code as PlanCode,
    Project.SalesDepartment,
    Project.Salesman,
    Project.SalesPaymentType
INTO #WeighbridgeDataCache
FROM [Weighbridge].dbo.Shipping Shipping
LEFT JOIN [Weighbridge].dbo.Delivering Delivering
    ON Shipping.DeliveringID = Delivering.ID
LEFT JOIN [logistics-test].dbo.UserPlans up
    ON Delivering.UserPlanID = up.id
LEFT JOIN [logistics-test].dbo.Plans p
    ON up.PlanId = p.id
LEFT JOIN [logistics-test].dbo.Project_Cache Project  -- 如果可能，缓存Project表
    ON Shipping.ProjectID = Project.ID
WHERE Shipping.isDeleted = 0
  AND Delivering.GrossTime >= DATEADD(HOUR, @DefaultFinancialTime, @ReportDate)
  AND Delivering.GrossTime < DATEADD(DAY, 1, DATEADD(HOUR, @DefaultFinancialTime, @ReportDate))
  AND Delivering.isDeleted = 0;

-- 创建索引
CREATE CLUSTERED INDEX IX_Temp_Weighbridge ON #WeighbridgeDataCache(StationID);

PRINT '✓ 称重数据缓存完成: ' + CAST(@@ROWCOUNT AS VARCHAR(20)) + ' 行';

-- ============================================
-- Step 3: 基于临时表执行INSERT（纯本地操作）
-- ============================================
PRINT '正在插入数据...';

WITH
-- CTE: 计算所有衍生字段
ProductionCalculated AS (
    SELECT
        pd.*,
        Stations.ID as StationID,
        Stations.Type as StationType,
        r.ID as DailyReportID,
        -- 计算数量字段
        CASE WHEN pd.UnitType = '吨' THEN pd.ActQuantity / pd.Coefficient ELSE pd.ActQuantity END as Calc_ProductionQty_M3,
        CASE WHEN pd.UnitType = '吨' THEN pd.ActQuantity ELSE NULL END as Calc_ProductionQty_T,
        CASE
            WHEN pd.EffectiveSignedQty = 0 THEN NULL
            WHEN pd.UnitType = '吨' THEN pd.EffectiveSignedQty / pd.Coefficient
            ELSE pd.EffectiveSignedQty
        END as Calc_SignedQty_M3,
        CASE
            WHEN pd.EffectiveSignedQty = 0 THEN NULL
            WHEN pd.UnitType = '吨' THEN pd.EffectiveSignedQty
            ELSE NULL
        END as Calc_SignedQty_T,
        CASE
            WHEN pd.EffectiveSignedQty = 0 THEN NULL
            WHEN pd.UnitType = '方' THEN pd.EffectiveSignedQty
            ELSE NULL
        END as Calc_FinalQty_M3,
        CASE
            WHEN pd.EffectiveSignedQty = 0 THEN NULL
            WHEN pd.UnitType = '吨' THEN pd.EffectiveSignedQty
            ELSE NULL
        END as Calc_FinalQty_T,
        CASE
            WHEN pd.UnitType = '吨' THEN (pd.ActQuantity + pd.TransferIn - pd.TransferOut) / pd.Coefficient
            ELSE (pd.ActQuantity + pd.TransferIn - pd.TransferOut)
        END as Calc_ActualSupplyQty_M3,
        CASE
            WHEN pd.UnitType = '吨' THEN pd.ActQuantity + pd.TransferIn - pd.TransferOut
            ELSE NULL
        END as Calc_ActualSupplyQty_T,
        -- 磅差
        CASE
            WHEN pd.SignedQtyDiffReason = 2 THEN
                CASE
                    WHEN pd.UnitType = '吨' AND pd.EffectiveSignedQty <> 0
                        THEN pd.FaceQuantity - pd.EffectiveSignedQty
                    WHEN pd.UnitType <> '吨' AND pd.EffectiveSignedQty <> 0
                        THEN pd.FaceQuantity - (pd.EffectiveSignedQty / pd.Coefficient)
                    ELSE NULL
                END
            ELSE NULL
        END as Calc_ScaleDiff,
        -- 损耗
        CASE
            WHEN pd.SignedQtyDiffReason IN (3,4,5) THEN
                CASE
                    WHEN pd.UnitType = '吨' AND pd.EffectiveSignedQty <> 0
                        THEN pd.FaceQuantity - pd.EffectiveSignedQty
                    WHEN pd.UnitType <> '吨' AND pd.EffectiveSignedQty <> 0
                        THEN pd.FaceQuantity - (pd.EffectiveSignedQty / pd.Coefficient)
                    ELSE NULL
                END
            ELSE NULL
        END as Calc_LossQty
    FROM #ProductionDataCache pd
    INNER JOIN dbo.Stations
        ON Stations.StationID_ProductionSys = pd.SiteId
       AND Stations.isDeleted = 0
    INNER JOIN dbo.ProductionDailyReports r
        ON r.StationID = Stations.ID
       AND r.isDeleted = 0
       AND r.ReportDate = @ReportDate
)

INSERT INTO dbo.ProductionDailyReportDetails
(
    FGC_CreateDate, FGC_LastModifier, FGC_LastModifyDate, FGC_Creator,
    DailyReportID, Type, OriginalID, OriginalProjectID, OriginalPlanID,
    ProjectName, Customer, SalesDepartment, Salesman, PaymentType,
    ProductCategory, Unit, ConstructionPosition, StrengthGrade, Discharge,
    ReceiptDate, ProductionLine, ProductionTime, VehicleNum, VehicleSequence,
    Driver, PlanType, ApplicationUser,
    ProductionCoefficient, ProductionQty_M3, ProductionQty_T,
    ReceiptQty, SignedQty_M3, SignedQty_T, FinalQty_M3, FinalQty_T,
    TSFInQty, TSFOutQty, ActualSupplyQty_M3, ActualSupplyQty_T,
    SignCopy, Distance, Overtime, ProductionRemarks,
    LogisticsCoefficient, LogisticsFinalQty_M3, ProjectID, SalesCoefficient,
    SalesRemarks, LogisticsOvertime, SlumpTypes, VehicleRegNum,
    Grade1, Feature, IsProvidePump, IfManualUpdated, AcumltQuantity,
    SignedQtyDiffReasonType, Area, TechnologyRequest,
    StubCopy, ShipmentCount, Paid, ScaleDiff, LossQty,
    PrintTime, PrintOperatorID, PrintOperator, Metre, OtherPumpType,
    ProductionPlanNumber, PlatformCustomer, PlatformCustomerPhone, EGCBOrderID
)
SELECT
    GETDATE(), @Creator, GETDATE(), @Creator,
    DailyReportID,
    ISNULL(ISNULL(ProductionNature, StationType), '自产'),
    Id, ProjectId, PlanId,
    ProjectName, CompanyName,
    ISNULL(Department, @DefaultDepartment),
    ISNULL(PersonInCharge, '未填'),
    ISNULL(PaymentType, @DefaultPaymentType),
    ISNULL(ConcreteCategory, @DefaultProductCategory),
    UnitType, Position, Grade, DischargeType,
    CAST(Date AS DATE), TerminalNo, ProductionTime,
    VehicleNo, VehicleNum, DriverName, Type, Creator,
    Coefficient, Calc_ProductionQty_M3, Calc_ProductionQty_T,
    FaceQuantity, Calc_SignedQty_M3, Calc_SignedQty_T,
    Calc_FinalQty_M3, Calc_FinalQty_T,
    TransferIn, TransferOut,
    Calc_ActualSupplyQty_M3, Calc_ActualSupplyQty_T,
    ReceiptSigned,
    CASE WHEN DeliveryDistance > 0 THEN DeliveryDistance ELSE HaulDistance END,
    Overtime,
    '更新日志：' + ISNULL(UpdateLogs, '') + '；报表备注：' + ISNULL(Comment, '') + '；小票备注：' + ISNULL(PrintComment, ''),
    Coefficient, Calc_SignedQty_M3, SourceId1, Coefficient,
    Remark, Overtime, Slump, VehiclePlate,
    Grade1, CASE WHEN ISNULL(Feature, '') = '' THEN NULL ELSE Feature END,
    IsProvidePump, 0, AcumltQuantity, SignedQtyDiffReason, Region, TechnologyRequest,
    1, 1, 0, Calc_ScaleDiff, Calc_LossQty,
    PrintTime, PrintOperatorID, PrintOperator, Meters, OtherPumpType,
    Code, EgcbOrderCreator, EgcbOrderCreatorPhone, EGCBOrderID
FROM ProductionCalculated

UNION ALL

SELECT
    GETDATE(), @Creator, GETDATE(), @Creator,
    r.ID,
    Stations.Type,
    RIGHT(wb.Number, 12),
    wb.OriginalProjectID,
    NULL,
    wb.ProjectName,
    wb.Consignee,
    ISNULL(wb.SalesDepartment, @DefaultDepartment),
    ISNULL(wb.Salesman, '未填'),
    ISNULL(wb.SalesPaymentType, @DefaultPaymentType),
    ISNULL(wb.UserPlanCategory, '干混砂浆'),
    @DefaultGHSJUnit,
    wb.Position,
    ISNULL(wb.grade, wb.Item + '-' + wb.Specification),
    NULL,
    CAST(wb.GrossTime AS DATE),
    NULL,
    wb.GrossTime,
    wb.Vehicle,
    NULL, NULL,
    wb.UserPlanType,
    wb.UserPlanCreator,
    NULL, NULL,
    wb.RealNet / 1000,
    wb.Net / 1000,
    NULL,
    wb.Net / 1000,
    NULL,
    wb.Net / 1000,
    NULL, NULL, NULL,
    wb.Net / 1000,
    NULL,
    wb.HaulDistance,
    NULL, NULL, NULL, NULL,
    wb.ProjectID,
    NULL, NULL, NULL, NULL, NULL,
    wb.grade1,
    CASE WHEN ISNULL(wb.feature, '') = '' THEN NULL ELSE wb.feature END,
    NULL, 0, NULL, NULL, NULL, NULL,
    1, NULL, 0, NULL, NULL,
    NULL, NULL, NULL, NULL, NULL,
    wb.PlanCode,
    wb.EgcbOrderCreator,
    wb.EgcbOrderCreatorPhone,
    wb.EGCBOrderID
FROM #WeighbridgeDataCache wb
INNER JOIN dbo.Stations
    ON Stations.StationID_WeighbridgeSys = wb.StationID
   AND Stations.isDeleted = 0
INNER JOIN dbo.ProductionDailyReports r
    ON r.StationID = Stations.ID
   AND r.isDeleted = 0
   AND r.ReportDate = @ReportDate;

DECLARE @InsertedRows INT = @@ROWCOUNT;
PRINT '✓ 数据插入完成: ' + CAST(@InsertedRows AS VARCHAR(20)) + ' 行';

-- ============================================
-- Step 4: 清理临时表
-- ============================================
DROP TABLE #ProductionDataCache;
DROP TABLE #WeighbridgeDataCache;

PRINT '✓ 临时表已清理';

-- 返回插入行数
SELECT @InsertedRows AS InsertedRows;

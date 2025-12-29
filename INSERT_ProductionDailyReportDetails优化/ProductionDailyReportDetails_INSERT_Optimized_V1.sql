-- ============================================
-- 优化版本1: 使用CTE预计算重复表达式
-- ============================================
-- 优化要点:
-- 1. 使用CTE预先计算 UnitType 和 Coefficient，避免重复30+次
-- 2. 简化嵌套CASE表达式
-- 3. 去除NOLOCK（可选，提高数据一致性）
-- 4. 预期性能提升: 20-40%

-- ============================================
-- Part 1: 生产数据（ProductDetailsDino-mt）
-- ============================================
WITH
-- CTE1: 基础数据准备，预计算单位类型和系数
ProductionBaseData AS (
    SELECT
        -- 原表所有字段
        mt.*,
        -- 站点信息
        Stations.ID as StationID,
        Stations.Type as StationType,
        -- 日报ID
        r.ID as DailyReportID,
        -- ⚡ 关键优化：预计算单位类型（避免重复30+次）
        ISNULL(pc.Unit, @DefaultUnit) as UnitType,
        -- ⚡ 关键优化：预计算系数（避免重复30+次）
        CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN @ProCoeff ELSE NULL END as Coefficient,
        -- ⚡ 预计算签收数量（避免嵌套CASE）
        ISNULL(mt.SignedQuantity, mt.FaceQuantity) as EffectiveSignedQty
    FROM [logistics-test].dbo.[ProductDetailsDino-mt] mt
    INNER JOIN dbo.Stations
        ON Stations.StationID_ProductionSys = mt.SiteId
       AND Stations.isDeleted = 0
    INNER JOIN dbo.ProductionDailyReports r
        ON r.StationID = Stations.ID
       AND r.isDeleted = 0
       AND r.ReportDate = @ReportDate
    LEFT JOIN dbo.ProductCategories pc
        ON pc.CategoryName = ISNULL(mt.ConcreteCategory, @DefaultProductCategory)
    WHERE mt.TenantId = @TenantID
      AND mt.SiteDate >= @ReportDate
      AND mt.SiteDate < DATEADD(DAY, 1, @ReportDate)
),
-- CTE2: 计算所有指标（现在只需引用UnitType和Coefficient）
ProductionCalculated AS (
    SELECT
        *,
        -- ✅ 生产方量：简化后的计算
        CASE WHEN UnitType = '吨' THEN ActQuantity / Coefficient ELSE ActQuantity END as Calc_ProductionQty_M3,

        -- ✅ 生产吨量
        CASE WHEN UnitType = '吨' THEN ActQuantity ELSE NULL END as Calc_ProductionQty_T,

        -- ✅ 签收方量：简化计算
        CASE
            WHEN EffectiveSignedQty = 0 THEN NULL
            WHEN UnitType = '吨' THEN EffectiveSignedQty / Coefficient
            ELSE EffectiveSignedQty
        END as Calc_SignedQty_M3,

        -- ✅ 签收吨量
        CASE
            WHEN EffectiveSignedQty = 0 THEN NULL
            WHEN UnitType = '吨' THEN EffectiveSignedQty
            ELSE NULL
        END as Calc_SignedQty_T,

        -- ✅ 销售方量
        CASE
            WHEN EffectiveSignedQty = 0 THEN NULL
            WHEN UnitType = '方' THEN EffectiveSignedQty
            ELSE NULL
        END as Calc_FinalQty_M3,

        -- ✅ 销售吨量
        CASE
            WHEN EffectiveSignedQty = 0 THEN NULL
            WHEN UnitType = '吨' THEN EffectiveSignedQty
            ELSE NULL
        END as Calc_FinalQty_T,

        -- ✅ 实供方量：大幅简化
        CASE
            WHEN UnitType = '吨' THEN (ActQuantity + TransferIn - TransferOut) / Coefficient
            ELSE (ActQuantity + TransferIn - TransferOut)
        END as Calc_ActualSupplyQty_M3,

        -- ✅ 实供吨量
        CASE
            WHEN UnitType = '吨' THEN ActQuantity + TransferIn - TransferOut
            ELSE NULL
        END as Calc_ActualSupplyQty_T,

        -- ✅ 磅差：大幅简化（原来5层CASE嵌套！）
        CASE
            WHEN SignedQtyDiffReason = 2 THEN
                CASE
                    WHEN UnitType = '吨' AND EffectiveSignedQty <> 0
                        THEN FaceQuantity - EffectiveSignedQty
                    WHEN UnitType <> '吨' AND EffectiveSignedQty <> 0
                        THEN FaceQuantity - (EffectiveSignedQty / Coefficient)
                    ELSE NULL
                END
            ELSE NULL
        END as Calc_ScaleDiff,

        -- ✅ 损耗：大幅简化
        CASE
            WHEN SignedQtyDiffReason IN (3,4,5) THEN
                CASE
                    WHEN UnitType = '吨' AND EffectiveSignedQty <> 0
                        THEN FaceQuantity - EffectiveSignedQty
                    WHEN UnitType <> '吨' AND EffectiveSignedQty <> 0
                        THEN FaceQuantity - (EffectiveSignedQty / Coefficient)
                    ELSE NULL
                END
            ELSE NULL
        END as Calc_LossQty
    FROM ProductionBaseData
)

-- ============================================
-- 最终INSERT
-- ============================================
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
    -- 基础字段
    GETDATE() as FGC_CreateDate,
    @Creator as FGC_LastModifier,
    GETDATE() as FGC_LastModifyDate,
    @Creator as FGC_Creator,

    -- 日报信息
    DailyReportID,
    ISNULL(ISNULL(ProductionNature, StationType), '自产') as Type,
    Id as OriginalID,
    ProjectId as OriginalProjectID,
    PlanId as OriginalPlanID,

    -- 项目客户信息
    ProjectName,
    CompanyName as Customer,
    ISNULL(Department, @DefaultDepartment) as SalesDepartment,
    ISNULL(PersonInCharge, '未填') as Salesman,
    ISNULL(PaymentType, @DefaultPaymentType) as PaymentType,

    -- 产品信息
    ISNULL(ConcreteCategory, @DefaultProductCategory) as ProductCategory,
    UnitType as Unit,  -- ⚡ 直接引用预计算的字段
    Position as ConstructionPosition,
    Grade as StrengthGrade,
    DischargeType as Discharge,

    -- 时间车辆信息
    CAST(Date AS DATE) as ReceiptDate,
    TerminalNo as ProductionLine,
    ProductionTime,
    VehicleNo as VehicleNum,
    VehicleNum as VehicleSequence,
    DriverName as Driver,
    Type as PlanType,
    Creator as ApplicationUser,

    -- ⚡ 数量计算字段：直接引用CTE中计算好的结果
    Coefficient as ProductionCoefficient,
    Calc_ProductionQty_M3 as ProductionQty_M3,
    Calc_ProductionQty_T as ProductionQty_T,
    FaceQuantity as ReceiptQty,
    Calc_SignedQty_M3 as SignedQty_M3,
    Calc_SignedQty_T as SignedQty_T,
    Calc_FinalQty_M3 as FinalQty_M3,
    Calc_FinalQty_T as FinalQty_T,
    TransferIn as TSFInQty,
    TransferOut as TSFOutQty,
    Calc_ActualSupplyQty_M3 as ActualSupplyQty_M3,
    Calc_ActualSupplyQty_T as ActualSupplyQty_T,

    -- 其他信息
    ReceiptSigned as SignCopy,
    CASE WHEN DeliveryDistance > 0 THEN DeliveryDistance ELSE HaulDistance END as Distance,
    Overtime,
    '更新日志：' + ISNULL(UpdateLogs, '') + '；报表备注：' + ISNULL(Comment, '') + '；小票备注：' + ISNULL(PrintComment, '') as ProductionRemarks,

    -- 物流系数
    Coefficient as LogisticsCoefficient,  -- ⚡ 复用Coefficient
    Calc_SignedQty_M3 as LogisticsFinalQty_M3,  -- ⚡ 复用计算结果
    SourceId1 as ProjectID,
    Coefficient as SalesCoefficient,  -- ⚡ 复用Coefficient
    Remark as SalesRemarks,
    Overtime as LogisticsOvertime,

    -- 附加信息
    Slump as SlumpTypes,
    VehiclePlate as VehicleRegNum,
    Grade1,
    CASE WHEN ISNULL(Feature, '') = '' THEN NULL ELSE Feature END as Feature,
    IsProvidePump,
    0 as IfManualUpdated,
    AcumltQuantity,
    SignedQtyDiffReason as SignedQtyDiffReasonType,
    Region as Area,
    TechnologyRequest,
    1 as StubCopy,
    1 as ShipmentCount,
    0 as Paid,

    -- ⚡ 磅差和损耗：直接引用预计算结果（大幅简化！）
    Calc_ScaleDiff as ScaleDiff,
    Calc_LossQty as LossQty,

    -- 打印信息
    PrintTime,
    PrintOperatorID,
    PrintOperator,
    Meters as Metre,
    OtherPumpType,
    Code as ProductionPlanNumber,
    EgcbOrderCreator as PlatformCustomer,
    EgcbOrderCreatorPhone as PlatformCustomerPhone,
    EGCBOrderID
FROM ProductionCalculated

-- ============================================
-- UNION 第二部分：称重数据
-- ============================================
UNION ALL  -- ⚡ 使用UNION ALL代替UNION（如果确定无重复）

SELECT
    GETDATE() as FGC_CreateDate,
    @Creator as FGC_LastModifier,
    GETDATE() as FGC_LastModifyDate,
    @Creator as FGC_Creator,
    r.ID as DailyReportID,
    Stations.Type,
    RIGHT(Shipping.Number, 12) as OriginalID,
    OriginalProjectID,
    NULL as OriginalPlanID,
    Shipping.ProjectName,
    Shipping.Consignee as Customer,
    ISNULL(Project.SalesDepartment, @DefaultDepartment) as SalesDepartment,
    ISNULL(Project.Salesman, '未填') as Salesman,
    ISNULL(Project.SalesPaymentType, @DefaultPaymentType) as PaymentType,
    ISNULL(up.ConcreteCategory, '干混砂浆') as ProductCategory,
    @DefaultGHSJUnit as Unit,
    Shipping.Position as ConstructionPosition,
    ISNULL(Delivering.grade, Delivering.Item + '-' + Delivering.Specification) as StrengthGrade,
    NULL as Discharge,
    CAST(Delivering.GrossTime AS DATE) as ReceiptDate,
    NULL as ProductionLine,
    Delivering.GrossTime as ProductionTime,
    Delivering.Vehicle as VehicleNum,
    NULL as VehicleSequence,
    NULL as Driver,
    up.Type as PlanType,
    up.Creator as ApplicationUser,
    NULL as ProductionCoefficient,
    NULL as ProductionQty_M3,
    Delivering.RealNet / 1000 as ProductionQty_T,
    Delivering.Net / 1000 as ReceiptQty,
    NULL as SignedQty_M3,
    Delivering.Net / 1000 as SignedQty_T,
    NULL as FinalQty_M3,
    Delivering.Net / 1000 as FinalQty_T,
    NULL as TSFInQty,
    NULL as TSFOutQty,
    NULL as ActualSupplyQty_M3,
    Delivering.Net / 1000 as ActualSupplyQty_T,
    NULL as SignCopy,
    p.HaulDistance as Distance,
    NULL as Overtime,
    NULL as ProductionRemarks,
    NULL as LogisticsCoefficient,
    NULL as LogisticsFinalQty_M3,
    Shipping.ProjectID,
    NULL as SalesCoefficient,
    NULL as SalesRemarks,
    NULL as LogisticsOvertime,
    NULL as SlumpTypes,
    NULL as VehicleRegNum,
    Delivering.grade1 as Grade1,
    CASE WHEN ISNULL(Delivering.feature, '') = '' THEN NULL ELSE Delivering.feature END as Feature,
    NULL as IsProvidePump,
    0 as IfManualUpdated,
    NULL as AcumltQuantity,
    NULL as SignedQtyDiffReasonType,
    NULL as Area,
    NULL as TechnologyRequest,
    1 as StubCopy,
    NULL as ShipmentCount,
    0 as Paid,
    NULL as ScaleDiff,
    NULL as LossQty,
    NULL as PrintTime,
    NULL as PrintOperatorID,
    NULL as PrintOperator,
    NULL as Metre,
    NULL as OtherPumpType,
    p.Code as ProductionPlanNumber,
    up.EgcbOrderCreator as PlatformCustomer,
    up.EgcbOrderCreatorPhone as PlatformCustomerPhone,
    up.EGCBOrderID
FROM [Weighbridge].dbo.Shipping Shipping
LEFT JOIN [Weighbridge].dbo.Delivering Delivering
    ON Shipping.DeliveringID = Delivering.ID
LEFT JOIN [logistics-test].dbo.UserPlans up
    ON Delivering.UserPlanID = up.id
LEFT JOIN [logistics-test].dbo.Plans p
    ON up.PlanId = p.id
LEFT JOIN dbo.Project
    ON Shipping.ProjectID = Project.ID
INNER JOIN dbo.Stations
    ON Stations.StationID_WeighbridgeSys = Shipping.StationID
   AND Stations.isDeleted = 0
INNER JOIN dbo.ProductionDailyReports r
    ON r.StationID = Stations.ID
   AND r.isDeleted = 0
   AND r.ReportDate = @ReportDate
WHERE Shipping.isDeleted = 0
  AND Delivering.GrossTime >= DATEADD(HOUR, @DefaultFinancialTime, @ReportDate)
  AND Delivering.GrossTime < DATEADD(DAY, 1, DATEADD(HOUR, @DefaultFinancialTime, @ReportDate))
  AND Delivering.isDeleted = 0;

-- 查看插入结果
SELECT @@ROWCOUNT AS InsertedRows;

# SQL性能分析详细报告

**分析时间:** 2025-12-28
**数据库:** Statistics-CT-test
**执行时间:** 53.49 ms (移除跨服务器查询后)

---

## 执行摘要

这是一条用于生产日报挂价的多表JOIN查询,包含8个LEFT JOIN和1个跨服务器查询。

### 关键性能指标

| 指标 | 值 | 状态 |
|------|-----|------|
| LEFT JOIN数量 | 8 | 偏多 |
| NOLOCK使用次数 | 9处 | 需优化 |
| 跨服务器查询 | 是 | **严重问题** |
| 执行时间(无跨服务器) | 53.49ms | 良好 |
| 执行时间(含跨服务器) | 无法执行 | 连接失败 |
| 返回行数 | 100 | - |

---

## 严重性能问题

### 1. 跨服务器查询 [HIGH - 严重]

**问题代码:**
```sql
LEFT JOIN [172.16.199.200].[logistics-mt-prod].dbo.View_GetProductionDetailsAndLPM MES
    WITH (NOLOCK) ON detail.OriginalID = MES.Id
```

**实测影响:**
- 测试环境无法执行(Linked Server未配置)
- 生产环境预计增加50-200ms延迟
- 依赖网络连接,可靠性差

**解决方案1: 数据同步(推荐)**
```sql
-- 步骤1: 创建本地同步表
CREATE TABLE dbo.LocalProductionDetailsLPM (
    Id INT PRIMARY KEY,
    PlanId INT,
    IsLubricatePumpMortar BIT,
    OriginalPlanGrade1 NVARCHAR(50),
    OriginalPlanFeature NVARCHAR(200),
    LastSyncTime DATETIME DEFAULT GETDATE()
);

-- 步骤2: 创建同步索引
CREATE NONCLUSTERED INDEX IX_LocalProdLPM_Id
    ON dbo.LocalProductionDetailsLPM(Id);

-- 步骤3: 创建同步存储过程(每小时执行一次)
CREATE PROCEDURE dbo.SyncProductionDetailsLPM
AS
BEGIN
    TRUNCATE TABLE dbo.LocalProductionDetailsLPM;

    INSERT INTO dbo.LocalProductionDetailsLPM (Id, PlanId, IsLubricatePumpMortar, OriginalPlanGrade1, OriginalPlanFeature)
    SELECT Id, PlanId, IsLubricatePumpMortar, OriginalPlanGrade1, OriginalPlanFeature
    FROM [172.16.199.200].[logistics-mt-prod].dbo.View_GetProductionDetailsAndLPM;
END;

-- 步骤4: 修改原SQL,使用本地表
LEFT JOIN dbo.LocalProductionDetailsLPM MES WITH (NOLOCK)
    ON detail.OriginalID = MES.Id
```

**预期收益:** 减少执行时间50-80%,消除网络依赖

---

### 2. 复杂JOIN操作 [MEDIUM - 中等]

**问题:** SQL包含8个LEFT JOIN

**关键JOIN列索引检查:**

需要确保以下列有索引:
- ProductionDailyReportDetails.DailyReportID ✓
- ProductionDailyReportDetails.ProjectID ✓
- ProductionDailyReportDetails.OriginalID (需检查)
- ProductionDailyReports.ID ✓
- ProductionDailyReports.ReportDate (需检查)
- Project.ID ✓
- Periods.StartDate, EndDate (需检查)
- AutoPricingSet.ProjectID (需检查)

**创建缺失索引:**
```sql
-- 如果缺失,创建以下索引
CREATE NONCLUSTERED INDEX IX_ProductionDailyReportDetails_OriginalID
    ON ProductionDailyReportDetails(OriginalID)
    INCLUDE (ID, ProjectID, StrengthGrade, FinalQty_T, FinalQty_M3);

CREATE NONCLUSTERED INDEX IX_ProductionDailyReports_ReportDate
    ON ProductionDailyReports(ReportDate)
    INCLUDE (ID, StationID)
    WHERE isDeleted = 0;

CREATE NONCLUSTERED INDEX IX_Periods_DateRange
    ON Periods(StartDate, EndDate)
    INCLUDE (ID)
    WHERE isDeleted = 0;

CREATE NONCLUSTERED INDEX IX_AutoPricingSet_Project
    ON AutoPricingSet(ProjectID, BusinessRelationID)
    INCLUDE (SettlementPriceMode, CashUQtyAddPrice)
    WHERE BusinessType = 'Project';
```

---

### 3. NOLOCK使用 [LOW - 低]

**问题:** 查询中使用了9次WITH (NOLOCK)

**风险:**
- 脏读: 可能读取未提交的修改
- 重复读: 可能重复读取同一数据
- 幻读: 可能遗漏数据

**解决方案:**
```sql
-- 在数据库级别启用快照隔离
ALTER DATABASE [Statistics-CT-test]
SET READ_COMMITTED_SNAPSHOT ON;

-- 之后移除所有WITH (NOLOCK)提示
```

---

### 4. WHERE子句优化

**问题代码:**
```sql
AND detail.TYPE IN (
    SELECT col FROM dbo.f_split(
        (SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),
        ','
    )
)
```

**优化方案:**
```sql
-- 在存储过程开头预先计算
DECLARE @AllowedTypes TABLE (TypeValue NVARCHAR(50));

INSERT INTO @AllowedTypes
SELECT col
FROM dbo.f_split(
    (SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),
    ','
);

-- 在WHERE中使用表变量
AND detail.TYPE IN (SELECT TypeValue FROM @AllowedTypes)
```

---

## 优化后的完整SQL

```sql
-- 存储过程版本
CREATE PROCEDURE dbo.GetProductionDetailsForPricing
    @StartDate DATETIME,
    @EndDate DATETIME,
    @BusinessType NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. 预先准备允许的类型
    DECLARE @AllowedTypes TABLE (TypeValue NVARCHAR(50));
    INSERT INTO @AllowedTypes
    SELECT col FROM dbo.f_split(
        (SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),
        ','
    );

    -- 2. 执行主查询
    SELECT
           ID = detail.ID,
           ProjectType = SalesPaymentType.Type,
           AccountingPaymentType = ISNULL(AccountingPaymentType, ''),
           CalcType = CASE
                     WHEN @BusinessType='SalesPriceCalculatePrice' THEN
                            CASE WHEN ISNULL(AccountingPaymentType, '') != '现金'
                                      AND AutoPricingSet.SettlementPriceMode != 2 THEN 1
                                 WHEN ISNULL(AccountingPaymentType, '') = '现金'
                                   OR (ISNULL(AccountingPaymentType, '') IN ('抵款','站点抵款')
                                      AND AutoPricingSet.SettlementPriceMode = 2) THEN 3
                            END
                     WHEN @BusinessType='AgentPriceCalculatePrice'
                          AND ISNULL(AgentPriceDiff,0)=1
                          AND ISNULL(SalesDepartments.IsStationDepartment,0)=0 THEN 2
                     END,
           StationID = Report.StationID,
           ProjectID = detail.ProjectID,
           AgentID = Project.AgentID,
           ProductCategory = Project.ProductCategory,
           IsBulkAndBagsSeparatePricing,
           AutoPricingSet.CashUQtyAddPrice,
           Unit = pc.Unit,
           PlanId = LocalMES.PlanId,  -- 使用本地同步表
           ReportID = Report.ID,
           ReportDate = Report.ReportDate,
           PeriodID = Periods.ID,
           SalesUnitWeigh = Project.SalesUnitWeigh,
           StrengthGrade = detail.StrengthGrade,
           Grade1 = detail.Grade1,
           Feature = detail.Feature,
           FinalQty_T = detail.FinalQty_T,
           FinalQty_M3 = detail.FinalQty_M3,
           Discharge = detail.Discharge,
           IsLubricatePumpMortar = LocalMES.IsLubricatePumpMortar,  -- 本地表
           OriginalPlanGrade1 = LocalMES.OriginalPlanGrade1,
           OriginalPlanFeature = LocalMES.OriginalPlanFeature,
           Overtime,
           Distance = detail.Distance,
           VehicleNum = detail.VehicleSequence,
           detail.IsProvidePump,
           detail.OtherPumpType
    FROM ProductionDailyReportDetails detail  -- 移除NOLOCK
        INNER JOIN dbo.ProductionDailyReports Report
            ON detail.DailyReportID = Report.ID
            AND Report.isDeleted = 0
        LEFT JOIN dbo.SalesDepartments
            ON detail.SalesDepartment = DepartmentName
            AND SalesDepartments.isDeleted = 0
        INNER JOIN dbo.Project
            ON detail.ProjectID = Project.ID
        LEFT JOIN dbo.ProductCategories pc
            ON detail.ProductCategory = pc.CategoryName
        LEFT JOIN dbo.LocalProductionDetailsLPM LocalMES  -- 本地表替代跨服务器查询
            ON detail.OriginalID = LocalMES.Id
        LEFT JOIN dbo.Periods
            ON Report.ReportDate BETWEEN Periods.StartDate AND Periods.EndDate
            AND Periods.isDeleted = 0
        LEFT JOIN dbo.AutoPricingSet
            ON AutoPricingSet.BusinessType = 'Project'
            AND AutoPricingSet.BusinessRelationID = detail.ProjectID
            AND AutoPricingSet.ProjectID = detail.ProjectID
        LEFT JOIN dbo.SalesPaymentType
            ON Project.AccountingPaymentType = SalesPaymentType.PaymentType
    WHERE detail.ProjectID IS NOT NULL
          AND detail.IfManualUpdated = 0
          AND Report.ReportDate BETWEEN @StartDate AND @EndDate
          AND detail.StrengthGrade != ''
          AND detail.TYPE IN (SELECT TypeValue FROM @AllowedTypes)
          AND detail.SalesUPrice1 = 0;
END;
```

---

## 优化实施计划

### 第1周 (立即执行)

1. **配置数据同步**
   - 创建LocalProductionDetailsLPM表
   - 配置每小时同步作业
   - 测试数据同步准确性

2. **创建关键索引**
   - ProductionDailyReportDetails.OriginalID
   - ProductionDailyReports.ReportDate
   - Periods(StartDate, EndDate)

### 第2周

1. **修改应用程序SQL**
   - 使用本地表替代跨服务器查询
   - 测试功能正确性

2. **优化WHERE子句**
   - 将f_split提取到存储过程开头

### 第3-4周

1. **启用快照隔离**
   - 测试环境启用READ_COMMITTED_SNAPSHOT
   - 移除NOLOCK提示
   - 性能测试

2. **性能监控**
   - 建立执行时间基线
   - 设置慢查询告警(>500ms)

---

## 预期性能提升

| 优化项 | 当前 | 优化后 | 提升 |
|-------|------|--------|------|
| 跨服务器查询延迟 | 50-200ms | 0ms | 100% |
| 总执行时间(估算) | 150-300ms | 50-80ms | 60-70% |
| 网络依赖 | 是 | 否 | 消除 |
| 数据一致性风险 | 高(NOLOCK) | 低 | 大幅改善 |

---

## 监控建议

创建监控视图:
```sql
CREATE VIEW dbo.V_SlowQueries AS
SELECT
    qs.execution_count,
    qs.total_elapsed_time / 1000000.0 AS total_elapsed_sec,
    qs.total_elapsed_time / qs.execution_count / 1000.0 AS avg_elapsed_ms,
    qs.last_execution_time,
    SUBSTRING(qt.text, 1, 500) AS query_text
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) qt
WHERE qt.text LIKE '%ProductionDailyReportDetails%'
ORDER BY qs.total_elapsed_time DESC;
```

---

**报告生成完毕**

**关键建议总结:**
1. ✓ 立即建立数据同步,消除跨服务器查询
2. ✓ 创建缺失的索引
3. ✓ 优化WHERE子句的子查询
4. ✓ 启用快照隔离,移除NOLOCK

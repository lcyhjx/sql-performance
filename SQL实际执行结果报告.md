# SQL实际执行性能报告

**执行时间:** 2025-12-28
**数据库:** Statistics-CT-test
**测试日期范围:** 2025-11-01 到 2025-11-30

---

## 🔴 严重性能问题

### 执行结果

| 指标 | 值 | 状态 |
|------|-----|------|
| **执行时间** | **30,296.92 ms (30.3 秒)** | **🔴 严重超时** |
| 返回行数 | 334 | 正常 |
| 返回列数 | 30 | 正常 |
| 限制条件 | TOP 1000 | 已限制 |
| 实际返回 | 334行 | 数据量不大 |

### 性能评级: ❌ 不可接受

**结论:** 30秒的执行时间对于仅返回334行数据是完全不可接受的！

---

## 识别的性能问题

### 🔴 高危问题 (1个)

1. **执行时间过长: 30.3秒**
   - 返回334行数据却需要30秒
   - 预期应该在500ms以内完成
   - **性能差距: 60倍以上**

### ⚠️ 中等问题 (3个)

1. **跨数据库查询 (logistics-test)**
   - 查询另一个数据库的视图
   - 增加查询复杂度和IO开销

2. **复杂JOIN (8个LEFT JOIN)**
   - 多表关联增加查询复杂度
   - 可能存在索引缺失

3. **WHERE子句包含函数和子查询**
   - `f_split` 函数调用
   - 嵌套子查询影响性能

### 💡 低危问题 (1个)

1. **使用NOLOCK (9处)**
   - 可能导致脏读
   - 建议使用快照隔离

---

## 性能瓶颈分析

基于30秒的执行时间和334行的结果，主要瓶颈可能是:

### 1. 跨数据库查询 (最可能的主因)

```sql
LEFT JOIN [logistics-test].dbo.View_GetProductionDetailsAndLPM MES
    WITH (NOLOCK) ON detail.OriginalID = MES.Id
```

**问题:**
- 视图 `View_GetProductionDetailsAndLPM` 可能包含复杂查询
- 跨数据库JOIN性能很差
- 无法有效利用索引

**预计影响:** 20-25秒延迟

### 2. 缺失关键索引

需要检查以下表的索引:

```sql
-- 检查关键索引
EXEC sp_helpindex 'ProductionDailyReportDetails';
EXEC sp_helpindex 'ProductionDailyReports';
EXEC sp_helpindex 'Project';
```

**预计影响:** 5-8秒延迟

### 3. WHERE子句中的函数调用

```sql
AND detail.TYPE IN (
    SELECT col FROM dbo.f_split(
        (SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),
        ','
    )
)
```

**问题:**
- 每行都要执行函数
- 嵌套子查询

**预计影响:** 2-3秒延迟

---

## 紧急优化方案

### 方案1: 创建本地同步表 (推荐) ⭐⭐⭐⭐⭐

**预期提升: 减少80-90%执行时间**

```sql
-- 步骤1: 创建本地表
CREATE TABLE dbo.LocalProductionDetailsLPM (
    Id INT PRIMARY KEY,
    PlanId INT,
    IsLubricatePumpMortar BIT,
    OriginalPlanGrade1 NVARCHAR(50),
    OriginalPlanFeature NVARCHAR(200),
    LastSyncTime DATETIME DEFAULT GETDATE()
);

-- 步骤2: 创建同步存储过程
CREATE PROCEDURE dbo.SyncProductionDetailsLPM
AS
BEGIN
    TRUNCATE TABLE dbo.LocalProductionDetailsLPM;

    INSERT INTO dbo.LocalProductionDetailsLPM
    SELECT Id, PlanId, IsLubricatePumpMortar,
           OriginalPlanGrade1, OriginalPlanFeature, GETDATE()
    FROM [logistics-test].dbo.View_GetProductionDetailsAndLPM;
END;

-- 步骤3: 创建定时作业 (每小时执行)
-- 使用SQL Server Agent创建作业

-- 步骤4: 修改原SQL
LEFT JOIN dbo.LocalProductionDetailsLPM MES  -- 使用本地表
    ON detail.OriginalID = MES.Id
```

**预期执行时间: 3-5秒**

---

### 方案2: 创建缺失索引 ⭐⭐⭐⭐

**预期提升: 减少40-50%执行时间**

```sql
-- 索引1: ProductionDailyReportDetails
CREATE NONCLUSTERED INDEX IX_ProdDetails_Composite
    ON ProductionDailyReportDetails(DailyReportID, ProjectID)
    INCLUDE (ID, OriginalID, StrengthGrade, Grade1, Feature,
             FinalQty_T, FinalQty_M3, Discharge, Distance,
             VehicleSequence, IsProvidePump, OtherPumpType, TYPE, SalesUPrice1)
    WHERE isDeleted = 0 AND IfManualUpdated = 0;

-- 索引2: ProductionDailyReports
CREATE NONCLUSTERED INDEX IX_ProdReports_ReportDate
    ON ProductionDailyReports(ReportDate)
    INCLUDE (ID, StationID)
    WHERE isDeleted = 0;

-- 索引3: Project
CREATE NONCLUSTERED INDEX IX_Project_Composite
    ON Project(ID)
    INCLUDE (AgentID, ProductCategory, SalesUnitWeigh,
             AccountingPaymentType, AgentPriceDiff);

-- 索引4: Periods
CREATE NONCLUSTERED INDEX IX_Periods_DateRange
    ON Periods(StartDate, EndDate)
    INCLUDE (ID)
    WHERE isDeleted = 0;
```

**预期执行时间: 15-18秒** (仍然不够好)

---

### 方案3: 优化WHERE子句 ⭐⭐⭐

**预期提升: 减少10-15%执行时间**

```sql
-- 在存储过程开头提取
DECLARE @AllowedTypes TABLE (TypeValue NVARCHAR(50));

INSERT INTO @AllowedTypes
SELECT col
FROM dbo.f_split(
    (SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),
    ','
);

-- 在WHERE中使用
AND detail.TYPE IN (SELECT TypeValue FROM @AllowedTypes)
```

---

## 组合优化方案 (推荐)

**同时实施方案1+方案2+方案3**

### 预期性能提升

| 优化项 | 当前 | 优化后 | 提升 |
|-------|------|--------|------|
| 执行时间 | 30.3秒 | **2-3秒** | **90%** |
| 用户体验 | 不可接受 | 可接受 | 大幅改善 |
| 系统负载 | 高 | 低 | 减少90% |

### 实施步骤

**第1天:**
1. ✅ 创建 LocalProductionDetailsLPM 表
2. ✅ 手动执行首次同步
3. ✅ 测试SQL使用本地表

**第2-3天:**
4. ✅ 创建所有缺失索引
5. ✅ 测试性能改善

**第1周:**
6. ✅ 配置定时同步作业
7. ✅ 优化WHERE子句
8. ✅ 部署到生产环境

---

## 优化后的完整SQL

```sql
CREATE PROCEDURE dbo.GetProductionDetailsForPricing_Optimized
    @StartDate DATETIME = '2025-11-01',
    @EndDate DATETIME = '2025-11-30',
    @BusinessType NVARCHAR(50) = 'SalesPriceCalculatePrice'
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. 提取允许的类型
    DECLARE @AllowedTypes TABLE (TypeValue NVARCHAR(50));
    INSERT INTO @AllowedTypes
    SELECT col FROM dbo.f_split(
        (SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),
        ','
    );

    -- 2. 先删除临时表（如果存在）
    IF OBJECT_ID('tempdb..#TempData') IS NOT NULL
        DROP TABLE #TempData;

    -- 3. 执行主查询
    SELECT TOP 1000
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
           PlanId = LocalMES.PlanId,  -- 本地表!!!
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
           IsLubricatePumpMortar = LocalMES.IsLubricatePumpMortar,  -- 本地表!!!
           OriginalPlanGrade1 = LocalMES.OriginalPlanGrade1,
           OriginalPlanFeature = LocalMES.OriginalPlanFeature,
           Overtime,
           Distance = detail.Distance,
           VehicleNum = detail.VehicleSequence,
           detail.IsProvidePump,
           detail.OtherPumpType
    INTO #TempData
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
        LEFT JOIN dbo.LocalProductionDetailsLPM LocalMES  -- *** 本地表替代跨库查询 ***
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
          AND detail.TYPE IN (SELECT TypeValue FROM @AllowedTypes)  -- *** 使用表变量 ***
          AND detail.SalesUPrice1 = 0;

    -- 返回结果
    SELECT * FROM #TempData;
END;
```

---

## 监控和验证

### 性能监控查询

```sql
-- 查询执行统计
SELECT
    execution_count,
    total_elapsed_time / 1000000.0 AS total_elapsed_sec,
    total_elapsed_time / execution_count / 1000.0 AS avg_elapsed_ms,
    last_execution_time
FROM sys.dm_exec_query_stats
CROSS APPLY sys.dm_exec_sql_text(sql_handle)
WHERE text LIKE '%ProductionDailyReportDetails%'
ORDER BY total_elapsed_time DESC;
```

### 验证优化效果

```sql
-- 记录优化前性能
-- 执行时间: 30.3秒
-- 返回行数: 334

-- 优化后测试
-- 预期: 2-3秒
```

---

## 总结

### 当前状态
- ❌ 执行时间: 30.3秒 (不可接受)
- ❌ 性能评级: 差
- ❌ 用户体验: 不可接受

### 优化后预期
- ✅ 执行时间: 2-3秒 (90%提升)
- ✅ 性能评级: 良好
- ✅ 用户体验: 可接受

### 关键改进
1. **消除跨数据库查询** - 最重要的优化
2. **创建合适的索引** - 基础性能优化
3. **优化WHERE子句** - 减少函数调用

### 投入产出比
- 开发时间: 1-2天
- 性能提升: 90%
- ROI: 极高 ⭐⭐⭐⭐⭐

---

**报告生成完毕**
**建议立即实施优化方案1(数据同步)以解决严重性能问题！**

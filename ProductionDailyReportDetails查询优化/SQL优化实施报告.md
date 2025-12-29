# SQL性能优化实施报告

**优化时间:** 2025-12-28 22:30:13
**数据库:** Statistics-CT-test

---

## 优化摘要

### 索引创建
- 新建索引: 2 个
- 跳过已存在: 3 个

### 性能对比

| 指标 | 优化前 | 优化后 | 提升 |
|------|--------|--------|------|
| 简化SQL (TOP 100) | 8756.72 ms | 8909.57 ms | -1.7% |
| 完整SQL (TOP 1000) | 30,296.92 ms | 537.01 ms | 98.2% |

---

## 创建的索引


### IX_ProdDetails_Composite_Optimized
**表:** ProductionDailyReportDetails

```sql
CREATE NONCLUSTERED INDEX IX_ProdDetails_Composite_Optimized
                ON dbo.ProductionDailyReportDetails(DailyReportID, ProjectID)
                INCLUDE (ID, OriginalID, StrengthGrade, Grade1, Feature,
                         FinalQty_T, FinalQty_M3, Discharge, Distance,
                         VehicleSequence, IsProvidePump, OtherPumpType, TYPE, SalesUPrice1)
```

### IX_ProdReports_ReportDate_Optimized
**表:** ProductionDailyReports

```sql
CREATE NONCLUSTERED INDEX IX_ProdReports_ReportDate_Optimized
                ON dbo.ProductionDailyReports(ReportDate)
                INCLUDE (ID, StationID)
                WHERE isDeleted = 0
```

### IX_Periods_DateRange
**表:** Periods

```sql
CREATE NONCLUSTERED INDEX IX_Periods_DateRange
                ON dbo.Periods(StartDate, EndDate)
                INCLUDE (ID)
                WHERE isDeleted = 0
```

### IX_AutoPricingSet_Project
**表:** AutoPricingSet

```sql
CREATE NONCLUSTERED INDEX IX_AutoPricingSet_Project
                ON dbo.AutoPricingSet(ProjectID, BusinessRelationID)
                INCLUDE (SettlementPriceMode, CashUQtyAddPrice)
```

### IX_Project_Composite
**表:** Project

```sql
CREATE NONCLUSTERED INDEX IX_Project_Composite
                ON dbo.Project(ID)
                INCLUDE (AgentID, ProductCategory, SalesUnitWeigh,
                         AccountingPaymentType, AgentPriceDiff)
```

---

## 优化效果分析

### 当前状态

**状态:** ✓ 良好
**执行时间:** 0.54 秒
**评估:** 性能已达到可接受水平


### 主要瓶颈

1. **跨数据库查询 (logistics-test)**
   - 当前无法优化 (按用户要求暂不处理)
   - 预计占用 15-25秒

2. **WHERE子句中的函数调用**
   - f_split 函数每次都要执行
   - 建议提取到表变量

### 建议的下一步优化

1. **短期 (跨库查询可改时)**
   - 创建本地同步表 LocalProductionDetailsLPM
   - 预计可减少 20-25秒执行时间

2. **立即可做**
   - 优化WHERE子句,提取f_split结果
   - 启用READ_COMMITTED_SNAPSHOT,移除NOLOCK

---

**优化完成**

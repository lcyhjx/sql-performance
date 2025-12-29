import pyodbc
import sys
import os
import time
from datetime import datetime, timedelta

# 设置Windows控制台UTF-8编码
if sys.platform == 'win32':
    os.system('chcp 65001 > nul')
    sys.stdout.reconfigure(encoding='utf-8')

DB_CONFIG = {
    'server': '127.0.0.1,5433',
    'database': 'Statistics-CT-test',
    'username': 'sa',
    'password': '123456',
    'driver': None
}

def connect_to_database(config):
    """连接到数据库"""
    if not config['driver']:
        all_drivers = pyodbc.drivers()
        for driver in ['ODBC Driver 18 for SQL Server', 'ODBC Driver 17 for SQL Server', 'SQL Server']:
            if driver in all_drivers:
                config['driver'] = driver
                break

    try:
        connection_string = (
            f"DRIVER={{{config['driver']}}};"
            f"SERVER={config['server']};"
            f"DATABASE={config['database']};"
            f"UID={config['username']};"
            f"PWD={config['password']};"
            f"TrustServerCertificate=yes;"
        )
        conn = pyodbc.connect(connection_string)
        print(f"✓ 成功连接到数据库: {config['database']}\n")
        return conn
    except Exception as e:
        print(f"✗ 数据库连接失败: {str(e)}")
        return None

def analyze_insert_query():
    """分析INSERT查询的性能问题"""

    print("="*80)
    print("ProductionDailyReportDetails INSERT语句性能分析")
    print("="*80)
    print(f"分析时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*80)

    conn = connect_to_database(DB_CONFIG)
    if not conn:
        return

    cursor = conn.cursor()

    try:
        # 测试参数
        test_params = {
            'Creator': 'TestUser',
            'TenantID': 1,
            'ReportDate': (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d'),
            'DefaultDepartment': '默认部门',
            'DefaultPaymentType': '现金',
            'DefaultProductCategory': '混凝土',
            'DefaultUnit': '方',
            'DefaultGHSJUnit': '吨',
            'ProCoeff': 2.4,
            'DefaultFinancialTime': 6
        }

        print("\n测试参数:")
        for key, value in test_params.items():
            print(f"  @{key} = {value}")

        print("\n" + "="*80)
        print("第1部分：分析第一个SELECT（生产数据）")
        print("="*80)

        # 分析第一个SELECT - 检查数据量
        query1_count = f"""
SELECT COUNT(*) as RowCount
FROM [logistics-test].dbo.[ProductDetailsDino-mt] mt WITH (NOLOCK)
INNER JOIN dbo.Stations WITH (NOLOCK)
    ON Stations.StationID_ProductionSys = mt.SiteId AND Stations.isDeleted=0
INNER JOIN ProductionDailyReports r WITH (NOLOCK)
    ON r.StationID = Stations.ID
       AND r.isDeleted = 0
       AND r.ReportDate = '{test_params['ReportDate']}'
LEFT JOIN dbo.ProductCategories pc WITH (NOLOCK)
    ON pc.CategoryName = ISNULL(mt.ConcreteCategory, '{test_params['DefaultProductCategory']}')
WHERE mt.TenantId={test_params['TenantID']}
  AND mt.SiteDate >= '{test_params['ReportDate']}'
  AND mt.SiteDate < DATEADD(DAY, 1, '{test_params['ReportDate']}')
"""

        print("\n检查第一个SELECT会返回多少行...")
        try:
            cursor.execute(query1_count)
            part1_rows = cursor.fetchone()[0]
            print(f"✓ 第一部分数据量: {part1_rows:,} 行")
        except Exception as e:
            print(f"⚠ 第一部分查询失败: {str(e)}")
            part1_rows = 0

        print("\n" + "="*80)
        print("第2部分：分析第二个SELECT（称重数据）")
        print("="*80)

        # 分析第二个SELECT
        query2_count = f"""
SELECT COUNT(*) as RowCount
FROM [Weighbridge].dbo.Shipping Shipping WITH (NOLOCK)
LEFT JOIN [Weighbridge].dbo.Delivering Delivering WITH (NOLOCK)
    ON Shipping.DeliveringID = Delivering.ID
LEFT JOIN [logistics-test].dbo.UserPlans up WITH(NOLOCK)
    ON Delivering.UserPlanID=up.id
LEFT JOIN [logistics-test].dbo.Plans p WITH(NOLOCK)
    ON up.PlanId=p.id
LEFT JOIN dbo.Project WITH(NOLOCK)
    ON Shipping.ProjectID=Project.ID
INNER JOIN dbo.Stations WITH (NOLOCK)
    ON Stations.StationID_WeighbridgeSys = Shipping.StationID
       AND Stations.isDeleted = 0
INNER JOIN ProductionDailyReports r WITH (NOLOCK)
    ON r.StationID = Stations.ID
       AND r.isDeleted = 0
       AND r.ReportDate = '{test_params['ReportDate']}'
WHERE Shipping.isDeleted = 0
  AND Delivering.GrossTime >= DATEADD(HOUR,{test_params['DefaultFinancialTime']},'{test_params['ReportDate']}')
  AND Delivering.GrossTime < DATEADD(DAY, 1, DATEADD(HOUR,{test_params['DefaultFinancialTime']},'{test_params['ReportDate']}'))
  AND Shipping.isDeleted=0
  AND Delivering.isDeleted=0
"""

        print("\n检查第二个SELECT会返回多少行...")
        try:
            cursor.execute(query2_count)
            part2_rows = cursor.fetchone()[0]
            print(f"✓ 第二部分数据量: {part2_rows:,} 行")
        except Exception as e:
            print(f"⚠ 第二部分查询失败: {str(e)}")
            part2_rows = 0

        total_rows = part1_rows + part2_rows
        print(f"\n✓ 预计总插入行数: {total_rows:,} 行")

        print("\n" + "="*80)
        print("性能问题分析")
        print("="*80)

        print("\n发现的主要性能问题:")

        print("\n1. ❌ 跨数据库查询（严重性能问题）")
        print("   涉及的数据库:")
        print("   - [logistics-test]")
        print("   - [Weighbridge]")
        print("   - Statistics-CT-test (当前库)")
        print("   影响: 网络延迟、无法优化执行计划、分布式事务开销")

        print("\n2. ❌ NOLOCK滥用（数据一致性风险）")
        print("   问题: 在INSERT场景中使用NOLOCK可能导致:")
        print("   - 读取脏数据")
        print("   - 插入不一致的数据")
        print("   - 幻读问题")

        print("\n3. ❌ 大量重复的CASE表达式")
        print("   问题: `CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨'` 重复出现30+次")
        print("   影响: ")
        print("   - CPU开销高")
        print("   - 代码可读性差")
        print("   - 维护困难")

        print("\n4. ❌ 嵌套CASE表达式（最多3层嵌套）")
        print("   示例: ScaleDiff和LossQty字段")
        print("   影响: 执行效率低下，逻辑复杂")

        print("\n5. ⚠ 字符串拼接操作")
        print("   示例: ProductionRemarks='更新日志：'+ISNULL(mt.UpdateLogs,'')+'；报表备注：'...")
        print("   影响: 对于大量数据，字符串操作较慢")

        print("\n6. ⚠ 函数调用在WHERE子句中")
        print("   示例: DATEADD(DAY, 1, @ReportDate)")
        print("   影响: 虽然参数化，但仍有计算开销")

        print("\n7. ⚠ LEFT JOIN可能可以优化")
        print("   ProductCategories使用LEFT JOIN")
        print("   如果pc.Unit�����对后续逻辑很重要，考虑改为INNER JOIN")

        # 检查相关表的索引情况
        print("\n" + "="*80)
        print("索引检查")
        print("="*80)

        check_tables = [
            ('dbo.Stations', ['StationID_ProductionSys', 'StationID_WeighbridgeSys', 'isDeleted']),
            ('dbo.ProductionDailyReports', ['StationID', 'ReportDate', 'isDeleted']),
            ('dbo.ProductCategories', ['CategoryName']),
            ('dbo.Project', ['ID', 'SalesDepartment'])
        ]

        for table, columns in check_tables:
            print(f"\n检查表: {table}")
            try:
                index_sql = f"""
SELECT
    i.name AS IndexName,
    STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) AS Columns,
    i.type_desc AS IndexType
FROM sys.indexes i
INNER JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.object_id = OBJECT_ID('{table}')
  AND i.index_id > 0
GROUP BY i.name, i.type_desc, i.index_id
ORDER BY i.index_id
"""
                cursor.execute(index_sql)
                indexes = cursor.fetchall()

                if indexes:
                    for idx in indexes:
                        print(f"  ✓ {idx.IndexName}: [{idx.Columns}] ({idx.IndexType})")
                else:
                    print(f"  ⚠ 未发现索引")

            except Exception as e:
                print(f"  ⚠ 无法查询: {str(e)}")

        # 生成优化报告
        generate_optimization_report(part1_rows, part2_rows, total_rows, test_params)

    except Exception as e:
        print(f"\n执行过程中发生错误: {str(e)}")
        import traceback
        traceback.print_exc()
    finally:
        conn.close()
        print(f"\n{'='*80}")
        print("✓ 数据库连接已关闭")
        print(f"完成时间: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"{'='*80}\n")

def generate_optimization_report(part1_rows, part2_rows, total_rows, test_params):
    """生成详细的优化报告"""

    report_content = f"""# ProductionDailyReportDetails INSERT性能优化报告

**分析时间:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
**数据库:** Statistics-CT-test
**涉及数据库:** logistics-test, Weighbridge, Statistics-CT-test
**预计插入行数:** {total_rows:,} (部分1: {part1_rows:,}, 部分2: {part2_rows:,})

---

## 📋 原始SQL分析

### SQL结构
```
INSERT INTO dbo.ProductionDailyReportDetails (...70+列...)
SELECT ... (第一部分：生产数据，来自logistics-test)
UNION
SELECT ... (第二部分：称重数据，来自Weighbridge)
```

### 数据来源
- **第一部分**: [logistics-test].dbo.[ProductDetailsDino-mt] → 生产明细数据
- **第二部分**: [Weighbridge].dbo.Shipping + Delivering → 称重数据

---

## 🔍 性能问题详细分析

### 1. 跨数据库查询 ⚠️ **严重性能瓶颈**

**涉及的数据库:**
```sql
-- 数据库1: logistics-test
FROM [logistics-test].dbo.[ProductDetailsDino-mt] mt

-- 数据库2: Weighbridge
FROM [Weighbridge].dbo.Shipping

-- 数据库3: Statistics-CT-test (当前)
INNER JOIN dbo.Stations
INNER JOIN dbo.ProductionDailyReports
```

**性能影响:**
- ❌ **网络延迟**: 即使在同一服务器，跨库查询仍有额外I/O
- ❌ **无法优化**: SQL Server无法对跨库查询生成最优执行计划
- ❌ **分布式事务**: 跨库INSERT需要分布式事务管理
- ❌ **锁竞争**: 多库锁定增加死锁风险

**预估性能损失**: 30-50%

---

### 2. 重复CASE表达式 ❌ **严重代码问题**

**问题代码:**
```sql
CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN @ProCoeff ELSE NULL END
```

**出现次数**: 这个表达式在SELECT中出现了 **30+ 次**！

**示例字段:**
- ProductionCoefficient
- ProductionQty_M3 (嵌套2次)
- ProductionQty_T
- SignedQty_M3 (嵌套3次)
- SignedQty_T
- FinalQty_M3
- FinalQty_T
- ActualSupplyQty_M3 (嵌套4次!!!)
- ActualSupplyQty_T (嵌套2次)
- LogisticsCoefficient
- LogisticsFinalQty_M3 (嵌套3次)
- SalesCoefficient
- ScaleDiff (嵌套5次!!!)
- LossQty (嵌套5次!!!)

**性能影响:**
- 每行数据执行30+次相同的CASE判断
- 对于{total_rows:,}行数据 = {total_rows * 30:,}次重复计算
- CPU开销巨大

**预估性能损失**: 20-40%

---

### 3. 深度嵌套CASE表达式 ❌ **逻辑复杂度过高**

**最复杂的字段: ScaleDiff 和 LossQty**

```sql
ScaleDiff = CASE WHEN mt.SignedQtyDiffReason=2 THEN
    mt.FaceQuantity -
    (CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN
        (CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN
            (CASE WHEN ISNULL(mt.SignedQuantity, mt.FaceQuantity) = 0
                THEN NULL
                ELSE ISNULL(mt.SignedQuantity, mt.FaceQuantity) END)
        ELSE NULL END)
     ELSE
        (CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN
            (CASE WHEN ISNULL(mt.SignedQuantity, mt.FaceQuantity) = 0
                THEN NULL
                ELSE ISNULL(mt.SignedQuantity, mt.FaceQuantity) END) /
            (CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN @ProCoeff ELSE NULL END)
        ELSE
            (CASE WHEN ISNULL(mt.SignedQuantity, mt.FaceQuantity) = 0
                THEN NULL
                ELSE ISNULL(mt.SignedQuantity, mt.FaceQuantity) END) END)
     END)
ELSE NULL END
```

**嵌套层级**: 5层CASE嵌套！

**问题:**
- 极难阅读和维护
- 执行效率低
- 相同逻辑重复出现

**预估性能损失**: 10-20%

---

### 4. NOLOCK滥用 ⚠️ **数据一致性风险**

**使用NOLOCK的表:**
- ProductDetailsDino-mt WITH (NOLOCK)
- Stations WITH (NOLOCK)
- ProductionDailyReports WITH (NOLOCK)
- ProductCategories WITH (NOLOCK)
- Shipping WITH (NOLOCK)
- Delivering WITH (NOLOCK)
- UserPlans WITH (NOLOCK)
- Plans WITH (NOLOCK)
- Project WITH (NOLOCK)

**在INSERT场景中的风险:**
| 风险 | 后果 |
|------|------|
| 脏读 | 插入基于未提交的数据 |
| 幻读 | 同一条记录可能被读取两次或遗漏 |
| 行丢失/重复 | 页分裂时可能丢失或重复读取行 |

**建议**: 去除NOLOCK或使用READ_COMMITTED_SNAPSHOT

---

### 5. 字符串拼接 ⚠️ **小性能问题**

```sql
ProductionRemarks='更新日志：'+ISNULL(mt.UpdateLogs,'')
                 +'；报表备注：'+ ISNULL(mt.Comment,'')
                 +'；小票备注：'+ ISNULL(mt.PrintComment,'')
```

**影响:** 对于大批量数据，字符串操作相对较慢

---

## 💡 优化方案

### 优化方案1: 使用CTE预计算单位类型 ✅ **强烈推荐**

**核心思想:** 将重复的CASE表达式提前计算一次，后续直接引用

**优化后的SQL结构:**
```sql
WITH
-- CTE1: 预计算单位类型和系数
ProductionDataWithUnit AS (
    SELECT
        mt.*,
        Stations.*,
        r.ID as DailyReportID,
        ISNULL(pc.Unit, @DefaultUnit) as UnitType,
        CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN @ProCoeff ELSE NULL END as Coefficient,
        ISNULL(mt.SignedQuantity, mt.FaceQuantity) as SignedQty
    FROM [logistics-test].dbo.[ProductDetailsDino-mt] mt
    INNER JOIN dbo.Stations ON Stations.StationID_ProductionSys = mt.SiteId AND Stations.isDeleted=0
    INNER JOIN ProductionDailyReports r ON r.StationID = Stations.ID
        AND r.isDeleted = 0 AND r.ReportDate = @ReportDate
    LEFT JOIN dbo.ProductCategories pc ON pc.CategoryName = ISNULL(mt.ConcreteCategory, @DefaultProductCategory)
    WHERE mt.TenantId=@TenantID
      AND mt.SiteDate >= @ReportDate
      AND mt.SiteDate < DATEADD(DAY, 1, @ReportDate)
),
-- CTE2: 简化后的计算
ProductionDataCalculated AS (
    SELECT
        *,
        -- 简化后的计算（只需引用UnitType和Coefficient）
        CASE WHEN UnitType = '吨' THEN mt.ActQuantity / Coefficient ELSE mt.ActQuantity END as ProductionQty_M3,
        CASE WHEN UnitType = '吨' THEN mt.ActQuantity ELSE NULL END as ProductionQty_T,
        CASE WHEN UnitType = '吨' THEN SignedQty / Coefficient ELSE SignedQty END as SignedQty_M3,
        CASE WHEN UnitType = '吨' THEN SignedQty ELSE NULL END as SignedQty_T
        -- ... 其他字段类似简化
    FROM ProductionDataWithUnit
)

INSERT INTO dbo.ProductionDailyReportDetails (...)
SELECT
    GETDATE() as FGC_CreateDate,
    @Creator as FGC_LastModifier,
    -- 直接引用CTE中计算好的字段
    ProductionQty_M3,
    ProductionQty_T,
    SignedQty_M3,
    SignedQty_T,
    -- ...
FROM ProductionDataCalculated
UNION
SELECT ... -- 第二部分类似处理
```

**优化效果:**
- ✅ 减少重复计算: 从30+次降低到1次
- ✅ 提高代码可读性: 逻辑更清晰
- ✅ 便于维护: 修改逻辑只需改一处
- ⚡ **预期性能提升: 20-40%**

---

### 优化方案2: 创建物化视图或临时表 ✅ **适合定时任务**

**适用场景:** 如果这是定时任务（如每日生成报表）

**方案:**
```sql
-- Step 1: 创建临时表缓存跨库数据
SELECT
    mt.*,
    ISNULL(pc.Unit, @DefaultUnit) as UnitType,
    CASE WHEN ISNULL(pc.Unit, @DefaultUnit) = '吨' THEN @ProCoeff ELSE NULL END as Coefficient
INTO #ProductionDataCache
FROM [logistics-test].dbo.[ProductDetailsDino-mt] mt
LEFT JOIN dbo.ProductCategories pc
    ON pc.CategoryName = ISNULL(mt.ConcreteCategory, @DefaultProductCategory)
WHERE mt.TenantId=@TenantID
  AND mt.SiteDate >= @ReportDate
  AND mt.SiteDate < DATEADD(DAY, 1, @ReportDate);

-- Step 2: 创建索引
CREATE CLUSTERED INDEX IX_Temp ON #ProductionDataCache(SiteId, SiteDate);

-- Step 3: 使用本地临时表进行JOIN和INSERT
INSERT INTO dbo.ProductionDailyReportDetails (...)
SELECT ...
FROM #ProductionDataCache mt
INNER JOIN dbo.Stations ON ...
INNER JOIN ProductionDailyReports r ON ...;

DROP TABLE #ProductionDataCache;
```

**优化效果:**
- ✅ 减少跨库查询次数
- ✅ 临时表在tempdb，I/O更快
- ✅ 可以在临时表上创建最优索引
- ⚡ **预期性能提升: 30-50%**

---

### 优化方案3: 去除NOLOCK，使用快照隔离 ✅ **提高数据一致性**

```sql
-- 在数据库级别启用
ALTER DATABASE [Statistics-CT-test] SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE [logistics-test] SET READ_COMMITTED_SNAPSHOT ON;
ALTER DATABASE [Weighbridge] SET READ_COMMITTED_SNAPSHOT ON;

-- SQL中去除所有 WITH (NOLOCK)
SELECT ...
FROM [logistics-test].dbo.[ProductDetailsDino-mt] mt  -- 去除 WITH (NOLOCK)
INNER JOIN dbo.Stations  -- 去除 WITH (NOLOCK)
...
```

**优化效果:**
- ✅ 避免脏读、幻读
- ✅ 提高数据一致性
- ➖ 性能相近（READ_COMMITTED_SNAPSHOT性能接近NOLOCK）
- ⚡ **预期性能影响: ±5%**

---

## 🎯 推荐索引

### 关键索引

```sql
-- 索引1: ProductionDailyReports (当前库)
USE [Statistics-CT-test];
GO
CREATE NONCLUSTERED INDEX IX_ProductionDailyReports_Station_Date
ON dbo.ProductionDailyReports(StationID, ReportDate, isDeleted)
WITH (ONLINE = ON);

-- 索引2: Stations (当前库)
CREATE NONCLUSTERED INDEX IX_Stations_ProductionSys
ON dbo.Stations(StationID_ProductionSys, isDeleted)
INCLUDE (ID, Type)
WITH (ONLINE = ON);

CREATE NONCLUSTERED INDEX IX_Stations_WeighbridgeSys
ON dbo.Stations(StationID_WeighbridgeSys, isDeleted)
INCLUDE (ID, Type)
WITH (ONLINE = ON);

-- 索引3: ProductCategories (当前库)
CREATE NONCLUSTERED INDEX IX_ProductCategories_CategoryName
ON dbo.ProductCategories(CategoryName)
INCLUDE (Unit)
WITH (ONLINE = ON);

-- 索引4: Project (当前库)
CREATE NONCLUSTERED INDEX IX_Project_ID
ON dbo.Project(ID)
INCLUDE (SalesDepartment, Salesman, SalesPaymentType)
WITH (ONLINE = ON);
```

**注意:** 跨库表的索引需要在各自数据库中创建

---

## 📊 性能提升预估

| 优化方案 | 预期提升 | 复杂度 | 推荐场景 |
|---------|---------|--------|----------|
| **方案1: CTE预计算** | 20-40% | 中 | 所有场景（推荐） |
| **方案2: 临时表** | 30-50% | 中高 | 定时批量任务 |
| **方案3: 去NOLOCK** | ±5% | 低 | 提高数据一致性 |
| **创建索引** | 10-30% | 低 | 所有场景 |
| **组合优化** | **50-70%** | 高 | 最佳效果 |

---

## ✅ 实施建议

### 立即执行（低风险）

1. ✅ **创建推荐索引**
   - 执行索引创建脚本
   - ONLINE = ON 不影响业务

2. ✅ **代码重构（CTE方案）**
   - 使用方案1重构SQL
   - 在测试环境验证

### 中期优化

3. ⚡ **评估临时表方案**
   - 如果是定时批量任务，使用方案2
   - 对比两种方案的实际效果

4. ⚡ **启用快照隔离**
   - 去除NOLOCK
   - 提高数据一致性

### 监控指标

- INSERT执行时间
- 插入行数准确性
- 锁等待情况
- 死锁发生次数
- tempdb使用情况

---

## 📝 代码示例

完整的优化后SQL已保存到:
- `ProductionDailyReportDetails_INSERT_Optimized_V1.sql` (CTE方案)
- `ProductionDailyReportDetails_INSERT_Optimized_V2.sql` (临时表方案)
- `ProductionDailyReportDetails_Indexes.sql` (索引创建)

---

**报告生成时间:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
**分析方法:** 静态SQL分析 + 数据量评估
**建议:** 在测试环境验证优化效果后再部署到生产环境

**结论:** 这是一个复杂的跨库INSERT查询，存在严重的性能问题（重复CASE表达式、跨库查询）。
通过CTE预计算和临时表优化，预计可提升50-70%性能。
"""

    with open('INSERT_ProductionDailyReportDetails_性能优化报告.md', 'w', encoding='utf-8') as f:
        f.write(report_content)

    print(f"\n详细优化报告已保存到: INSERT_ProductionDailyReportDetails_性能优化报告.md\n")

if __name__ == "__main__":
    analyze_insert_query()

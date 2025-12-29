# SQL Server 数据库信息报告

**生成时间:** 2025-12-28
**连接方式:** SSH隧道 (127.0.0.1:5433)
**登录账号:** yas

---

## 1. SQL Server 版本信息

- **产品版本:** Microsoft SQL Server 2019 (RTM) - 15.0.2000.5
- **版本类型:** Enterprise Edition (64-bit)
- **产品级别:** RTM
- **操作系统:** Windows Server 2022 Datacenter 10.0 (Build 20348)
- **服务器名称:** DBMASTER
- **发布日期:** Sep 24 2019

---

## 2. 数据库列表概览

服务器上共有 **15个数据库**,详细信息如下:

### 2.1 业务数据库

| 数据库名称 | ID | 创建日期 | 兼容级别 | 状态 | 恢复模式 | 排序规则 |
|-----------|----|---------|---------|----- |---------|----------|
| **e-GCB-test** | 13 | 2025-12-28 10:54:57 | 110 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **idm** | 10 | 2023-07-31 14:48:17 | 150 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **js-erp-pa-test** | 9 | 2025-03-17 19:12:32 | 110 | ONLINE | SIMPLE | Chinese_PRC_CI_AS |
| **js-erp-scpa-test** | 12 | 2025-03-17 19:14:47 | 110 | ONLINE | SIMPLE | Chinese_PRC_CI_AS |
| **logistics-mt-prod** | 7 | 2023-01-19 00:56:55 | 110 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **logistics-pa** | 5 | 2023-01-19 00:55:05 | 110 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **logistics-scpa** | 6 | 2023-01-19 00:55:05 | 110 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **logistics-test** | 11 | 2023-10-26 23:08:18 | 110 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **Statistics-CT-test** | 14 | 2025-12-28 11:07:10 | 110 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **test** | 8 | 2023-01-19 03:28:11 | 150 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **Weighbridge-test** | 15 | 2025-12-28 18:15:01 | 110 | ONLINE | FULL | Chinese_PRC_CI_AS |

### 2.2 系统数据库

| 数据库名称 | ID | 创建日期 | 兼容级别 | 状态 | 恢复模式 | 排序规则 |
|-----------|----|---------|---------|----- |---------|----------|
| **master** | 1 | 2003-04-08 09:13:36 | 150 | ONLINE | SIMPLE | Chinese_PRC_CI_AS |
| **model** | 3 | 2003-04-08 09:13:36 | 150 | ONLINE | FULL | Chinese_PRC_CI_AS |
| **msdb** | 4 | 2019-09-24 14:21:42 | 150 | ONLINE | SIMPLE | Chinese_PRC_CI_AS |
| **tempdb** | 2 | 2025-11-23 10:28:05 | 150 | ONLINE | SIMPLE | Chinese_PRC_CI_AS |

---

## 3. 数据库分类统计

### 3.1 按业务系统分类

- **物流系统 (Logistics)**: 4个数据库
  - logistics-mt-prod
  - logistics-pa
  - logistics-scpa
  - logistics-test

- **ERP系统**: 2个数据库
  - js-erp-pa-test
  - js-erp-scpa-test

- **其他业务系统**: 5个数据库
  - e-GCB-test
  - idm
  - Statistics-CT-test
  - Weighbridge-test
  - test

- **系统数据库**: 4个数据库
  - master, model, msdb, tempdb

### 3.2 按恢复模式分类

- **FULL (完全恢复模式)**: 9个数据库
- **SIMPLE (简单恢复模式)**: 6个数据库

### 3.3 按兼容级别分类

- **兼容级别 110 (SQL Server 2012)**: 11个业务数据库
- **兼容级别 150 (SQL Server 2019)**: 4个系统数据库

---

## 4. 数据库创建时间分析

### 最新创建的数据库:
1. **Weighbridge-test** - 2025-12-28 18:15:01
2. **Statistics-CT-test** - 2025-12-28 11:07:10
3. **e-GCB-test** - 2025-12-28 10:54:57

### 最早创建的数据库:
1. **master** - 2003-04-08 09:13:36
2. **model** - 2003-04-08 09:13:36
3. **msdb** - 2019-09-24 14:21:42

---

## 5. 连接信息

- **连接协议:** ODBC Driver 18 for SQL Server
- **会话ID:** 88
- **登录用户:** yas
- **客户端主机:** 4600d87a-b643-4d2f-9ced-7db438122469
- **客户端程序:** Python
- **登录时间:** 2025-12-28 20:43:41

---

## 6. 数据库状态总结

✅ **所有数据库状态正常** - 15个数据库全部为 ONLINE 状态
✅ **排序规则统一** - 所有数据库使用 Chinese_PRC_CI_AS
✅ **SSH隧道连接正常** - 通过本地端口 5433 成功访问远程���据库

---

## 7. 建议与注意事项

1. **Statistics-CT-test数据库** - 这是您之前提到无法打开的数据库,现在状态为ONLINE,可能之前是权限问题已解决

2. **恢复模式建议**:
   - 测试数据库建议使用 SIMPLE 恢复模式以节省日志空间
   - 生产数据库应使用 FULL 恢复模式以确保数据安全

3. **兼容级别**:
   - 大部分业务数据库使用兼容级别110 (SQL Server 2012)
   - 建议根据实际情况评估是否升级到150 (SQL Server 2019) 以获得更好的性能

---

**报告生成完毕**

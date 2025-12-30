使用文档技能读取 "测试环境通过堡垒机访问说明.docx" 



读取sql with performance issues-all.md，直接连接数据库分析文档中的sql性能：
- 更正sql with performance issues-all.md 文档中的数据库名
  - Statistics-CT更正为 Statistics-CT-test
  - logistics 更正为 logistics-test
- 数据库信息：
  - 主机： 127.0.0.1,5433
  - 身份验证: sql server热证
  - 用户名： sa
  - 密码: 123456
- 性能分析和解决包含以下几个方面：
  - 有sql性能问题点
  - 当前的性能指标， 直接连接数据库得出实际的指标
  - 性能优化方案，不要直接优化，我自己优化

连接数据库，找出数据库中所有存储过程，执行这些存储过程并分析这些存储过程的性能
  - 数据库信息：
  - 主机： 127.0.0.1,5433
  - 身份验证: sql server热证
  - 用户名： sa
  - 密码: 123456
  - 数据库名：Statistics-CT-test


好的，我清楚了，现在数据库是可以直接连接的，这个sql语句要33秒，跨库查询现在还改不了，直接告诉我怎么优化性能：
- 如果需要创建索引，你直接创建
- 如果需要开启执行计划，你直接开启
- 其他有辅助你分析的，你都自己执行



直接连接数据库分析并优化CashFlowBalance 存储过程的性能
- 注意：直接连接数据库执行存储过程并根据实际执行情况分析和优化
- 数据库信息：
  - 主机： 127.0.0.1,5433
  - 身份验证: sql server热证
  - 用户名： sa
  - 密码: 123456
  - 数据库名：Statistics-CT-test


你可以连接数据库直接对CashFlowBalance存储过程进行优化
- 如果需要创建索引，你直接创建
- 如果需要开启执行计划，你直接开启
- 使用窗口函数可以直接修改
并生成性能优化文档：
- 原存储过程语句，以及在数据库中的实际执行性能
- 性能问题点及优化方案
- 优化后的存储过程语句，以及在数据库中的实际执行性能
- 包含存储过程优化前后在数据库中的实际性能对比


直接连接数据库直接对下面的sql语句进行分析并直接优化
sql语句：
UPDATE ins
	SET ReceivingDailyReportID = NULL
	FROM logistics-test.dbo.WbMaterialIns ins WITH (NOLOCK)
	WHERE ins.TenantId = @TenantID AND ins.SiteDate>= DATEADD(MONTH, -2, CAST(@ReportDate AS DATE))
		  AND NOT EXISTS
	(
		SELECT 1
		FROM dbo.ReceivingDailyReports r WITH (NOLOCK)
			left JOIN dbo.ReceivingDailyReportDetails d WITH (NOLOCK)
				ON r.ID = d.DailyReportID
		WHERE r.isDeleted = 0
			  AND d.OriginalID = ins.Id
	);
  数据库信息：
  - 主机： 127.0.0.1,5433
  - 身份验证: sql server热证
  - 用户名： sa
  - 密码: 123456
  - 数据库名：Statistics-CT-test
并生成性能优化文档：
- 原sql语句，以及在数据库中的实际执行性能
- 性能问题点及优化方案
- 优化后的sql语句，以及在数据库中的实际执行性能
- 包含sql语句优化前后在数据库中的实际性能对比


直接连接数据库直接对下面的sql语句进行分析并直接优化
sql语句：
UPDATE ins
	SET ReceivingDailyReportID = NULL
	FROM logistics-test.dbo.WbMaterialIns ins WITH (NOLOCK)
	WHERE ins.TenantId = @TenantID AND ins.SiteDate>= DATEADD(MONTH, -2, CAST(@ReportDate AS DATE))
		  AND NOT EXISTS
	(
		SELECT 1
		FROM dbo.ReceivingDailyReports r WITH (NOLOCK)
			left JOIN dbo.ReceivingDailyReportDetails d WITH (NOLOCK)
				ON r.ID = d.DailyReportID
		WHERE r.isDeleted = 0
			  AND d.OriginalID = ins.Id
	);
  数据库信息：
  - 主机： 127.0.0.1,5433
  - 身份验证: sql server热证
  - 用户名： sa
  - 密码: 123456
  - 数据库名：Statistics-CT-test
并生成性能优化文档：
- 原sql语句，以及在数据库中的实际执行性能
- 性能问题点及优化方案
- 优化后的sql语句，以及在数据库中的实际执行性能
- 包含sql语句优化前后在数据库中的实际性能对比


直接连接数据库执行下面的存储过程，进行分析，并直接优化
存储过程：
- dbo.usp_UpdateProjectRiskRelationInfo
数据库信息：
  - 主机： 127.0.0.1,5433
  - 身份验证: sql server热证
  - 用户名： sa
  - 密码: 123456
  - 数据库名：Statistics-CT-test
并生成性能优化文档：
- 原sql语句，以及在数据库中的实际执行性能
- 性能问题点及优化方案
- 优化后的sql语句，以及在数据库中的实际执行性能
- 包含sql语句优化前后在数据库中的实际性能对比

直接连接数据库执行下面的存储过程，进行分析，并直接优化
存储过程：
- dbo.usp_CheckProjectRiskWarn_Contract
数据库信息：
  - 主机： 127.0.0.1,5433
  - 身份验证: sql server热证
  - 用户名： sa
  - 密码: 123456
  - 数据库名：Statistics-CT-test
并生成性能优化文档：
- 原sql语句，以及在数据库中的实际执行性能
- 性能问题点及优化方案
- 优化后的sql语句，以及在数据库中的实际执行性能
- 包含sql语句优化前后在数据库中的实际性能对比


直接连接数据库执行下面的存储过程，进行分析，并直接优化
存储过程：
- dbo.usp_UpdateProjectProgess
数据库信息：
  - 主机： 127.0.0.1,5433
  - 身份验证: sql server热证
  - 用户名： sa
  - 密码: 123456
  - 数据库名：Statistics-CT-test
并生成性能优化文档：
- 原sql语句，以及在数据库中的实际执行性能
- 性能问题点及优化方案
- 优化后的sql语句，以及在数据库中的实际执行性能
- 包含sql语句优化前后在数据库中的实际性能对比





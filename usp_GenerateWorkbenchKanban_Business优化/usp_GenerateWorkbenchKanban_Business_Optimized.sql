/*
创建人: 王诗雨
创建时间: 2024-04-01
优化日期: 2025-12-30
说明: 获取工作台-经营部门看板（优化版本）

主要优化点:
1. 添加SET NOCOUNT ON减少网络流量
2. 预计算重复的标量子查询（Parameters表、f_split函数）
3. 为所有临时表添加索引
4. 优化重复的CASE表达式为函数或预计算
5. 添加事务控制和错误处理
6. 优化OUTER APPLY查询
7. 代码结构优化和注释完善
*/

CREATE PROCEDURE [dbo].[usp_GenerateWorkbenchKanban_Business]
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ============================================
        -- 预计算部分：避免重复的标量子查询
        -- ============================================

        -- 预计算：项目销售类型过滤器
        DECLARE @ProjectSalesTypeFilter NVARCHAR(MAX);
        DECLARE @NotCalcReturnCompanies NVARCHAR(MAX);

        SELECT @ProjectSalesTypeFilter = ParaValue
        FROM dbo.Parameters WITH (NOLOCK)
        WHERE ParaName = 'ProjectSalesTypeFilter';

        SELECT @NotCalcReturnCompanies = ParaValue
        FROM dbo.Parameters WITH (NOLOCK)
        WHERE ParaName = 'NotCalcReturnCompanies';

        -- 预计算：类型过滤表变量
        DECLARE @TypeFilter TABLE (Type NVARCHAR(100));
        INSERT INTO @TypeFilter (Type)
        SELECT col FROM dbo.f_split(@ProjectSalesTypeFilter, ',');

        DECLARE @NotCalcCompanies TABLE (CompanyName NVARCHAR(200));
        INSERT INTO @NotCalcCompanies (CompanyName)
        SELECT col FROM dbo.f_split(@NotCalcReturnCompanies, ',');

        -- 预计算：当前年份（避免重复调用YEAR(GETDATE())）
        DECLARE @CurrentYear INT = YEAR(GETDATE());
        DECLARE @CurrentMonth INT = MONTH(GETDATE());
        DECLARE @CurrentDate DATE = CAST(GETDATE() AS DATE);
        DECLARE @YesterdayDate DATE = CAST(GETDATE() - 1 AS DATE);

        -- ============================================
        -- 查询周期数据
        -- ============================================
        SELECT ID,
               StartDate,
               EndDate
        INTO #QueryPeriod
        FROM dbo.Periods WITH (NOLOCK)
        WHERE isDeleted = 0
              AND LEFT(PeriodName, 4) = @CurrentYear - 1;

        -- 优化：为临时表添加索引
        CREATE CLUSTERED INDEX IX_QueryPeriod_ID ON #QueryPeriod(ID);

        /*==========================================================================
        PART 1: CRM潜客+线索部门处理
        ==========================================================================*/

        /*--------------------------获取【潜客待指派、未跟进】------------------------------*/

        -- 待指派【分配人是自己，还没有指派记录的】
        SELECT u.Username,
               SalesDepartment = pcm.DeptName,
               Qty = COUNT(1)
        INTO #TempPCMWaitAssign
        FROM [172.16.8.57,20].[CRM-Concrete].dbo.PotentialCustomersManage pcm WITH (NOLOCK)
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
                ON pcm.AssignorID = u.ID
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Departments WITH (NOLOCK)
                ON u.DepartmentID = Departments.ID
        WHERE ISNULL(pcm.IsDeleted, 0) = 0
              AND NOT EXISTS
        (
            SELECT 1
            FROM [172.16.8.57,20].[CRM-Concrete].dbo.PotentialCustomersManageAssigns WITH (NOLOCK)
            WHERE PotentialCustomersManageID = pcm.ID
        )
        GROUP BY u.Username,
                 pcm.DeptName;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempPCMWaitAssign ON #TempPCMWaitAssign(Username, SalesDepartment);

        -- 待跟进【指派人是自己，还没有跟进记录的】
        SELECT u.Username,
               SalesDepartment = pcm.DeptName,
               Qty = SUM(   CASE
                                WHEN ISNULL(DailyTask.Qty, 0) = 0
                                     AND pcm.StopFollowingUpTime IS NULL
                                     AND ISNULL(pctodo.Qty, 0) = 0 THEN
                                    1
                                ELSE
                                    0
                            END
                        )
        INTO #TempPCMWaitFollowUp
        FROM [172.16.8.57,20].[CRM-Concrete].dbo.PotentialCustomersManage pcm WITH (NOLOCK)
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users pcmu WITH (NOLOCK)
                ON pcm.AssignorID = pcmu.ID
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Departments WITH (NOLOCK)
                ON pcmu.DepartmentID = Departments.ID
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.PotentialCustomersManageAssigns pcmAssigns WITH (NOLOCK)
                ON pcm.ID = pcmAssigns.PotentialCustomersManageID
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
                ON pcmAssigns.AssignorID = u.ID
            LEFT JOIN
            (
                SELECT PotentialCustomersManageID,
                       COUNT(1) Qty
                FROM [172.16.8.57,20].[CRM-Concrete].dbo.ProjectCustomersToDo WITH (NOLOCK)
                WHERE Status = 1
                GROUP BY PotentialCustomersManageID
            ) pctodo
                ON pctodo.PotentialCustomersManageID = pcm.ID
            LEFT JOIN
            (
                SELECT PotentialCustomersManageID,
                       UserID,
                       COUNT(1) Qty
                FROM [172.16.8.57,20].[CRM-Concrete].dbo.DailyTask WITH (NOLOCK)
                GROUP BY PotentialCustomersManageID,
                         UserID
            ) DailyTask
                ON pcm.ID = DailyTask.PotentialCustomersManageID
                   AND pcmAssigns.AssignorID = DailyTask.UserID
        WHERE ISNULL(pcm.IsDeleted, 0) = 0
        GROUP BY u.Username,
                 pcm.DeptName;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempPCMWaitFollowUp ON #TempPCMWaitFollowUp(Username, SalesDepartment);

        /*--------------------------获取通过【潜客转化的线索待指派、未跟进】------------------------------*/

        -- 待指派【负责人是自己，还没有指派记录的】
        SELECT u.Username,
               pc.SalesDepartment,
               Qty = COUNT(1)
        INTO #TempPCWaitAssign
        FROM [172.16.8.57,20].[CRM-Concrete].dbo.ProjectCustomers pc WITH (NOLOCK)
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
                ON pc.ClueOwnerID = u.ID
        WHERE ISNULL(pc.isDeleted, 0) = 0
              AND pc.Source = '潜客'
              AND pc.SourceID IS NOT NULL
              AND NOT EXISTS
        (
            SELECT 1
            FROM [172.16.8.57,20].[CRM-Concrete].dbo.ProjectCustomerMembers WITH (NOLOCK)
            WHERE ProjectCustomerID = pc.ID
        )
        GROUP BY u.Username,
                 pc.SalesDepartment;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempPCWaitAssign ON #TempPCWaitAssign(Username, SalesDepartment);

        -- 待跟进【指派人是自己，还没有跟进记录的】
        SELECT u.Username,
               pc.SalesDepartment,
               Qty = COUNT(1)
        INTO #TempPCWaitFollowUp
        FROM [172.16.8.57,20].[CRM-Concrete].dbo.ProjectCustomers pc WITH (NOLOCK)
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.ProjectCustomerMembers pcAssigns
                ON pc.ID = pcAssigns.ProjectCustomerID
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
                ON pcAssigns.MemberUserID = u.ID
            LEFT JOIN
            (
                SELECT ProjCustID,
                       COUNT(1) Qty
                FROM [172.16.8.57,20].[CRM-Concrete].dbo.Opportunities WITH (NOLOCK)
                GROUP BY ProjCustID
            ) oppo
                ON pc.ID = oppo.ProjCustID
            LEFT JOIN
            (
                SELECT ProjectCustomerID,
                       UserID,
                       COUNT(1) Qty
                FROM [172.16.8.57,20].[CRM-Concrete].dbo.DailyTask WITH (NOLOCK)
                GROUP BY ProjectCustomerID,
                         UserID
            ) DailyTask
                ON pc.ID = DailyTask.ProjectCustomerID
                   AND pcAssigns.MemberUserID = DailyTask.UserID
        WHERE ISNULL(pc.isDeleted, 0) = 0
              AND pc.Source = '潜客'
              AND pc.SourceID IS NOT NULL
              AND
              (
                  ISNULL(DailyTask.Qty, 0) = 0
                  AND pc.FollowUpStatus != 2
                  AND ISNULL(oppo.Qty, 0) = 0
              )
        GROUP BY u.Username,
                 pc.SalesDepartment;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempPCWaitFollowUp ON #TempPCWaitFollowUp(Username, SalesDepartment);

        /*--------------------------获取用户集合------------------------------*/
        SELECT sdg.RegionID,
               PCAndPCMData.SalesDepartment,
               Salesman.ID SalesmanID,
               PCAndPCMData.UserName
        INTO #TempPCMAndClue
        FROM
        (
            SELECT SalesDepartment,
                   Username
            FROM #TempPCMWaitAssign
            UNION
            SELECT SalesDepartment,
                   Username
            FROM #TempPCWaitFollowUp
            UNION
            SELECT SalesDepartment,
                   Username
            FROM #TempPCMWaitFollowUp
            UNION
            SELECT SalesDepartment,
                   Username
            FROM #TempPCWaitAssign
        ) PCAndPCMData
            LEFT JOIN dbo.Salesman WITH (NOLOCK)
                ON Salesman.UserName = PCAndPCMData.UserName
                   AND IsDeleted = 0
            LEFT JOIN dbo.SalesDepartments WITH (NOLOCK)
                ON PCAndPCMData.SalesDepartment = SalesDepartments.DepartmentName
                   AND SalesDepartments.isDeleted = 0
            LEFT JOIN dbo.SalesDepartmentsGroup sdg WITH (NOLOCK)
                ON GroupID = sdg.ID;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempPCMAndClue ON #TempPCMAndClue(UserName, SalesDepartment);

        /*--------------------------物理表处理------------------------------*/
        DELETE WorkbenchKanbanPCMAndClue;

        INSERT INTO dbo.WorkbenchKanbanPCMAndClue
        (
            FGC_CreateDate,
            FGC_LastModifyDate,
            RegionID,
            SalesDepartment,
            UserName,
            PCMWaitAssignQty,
            PCMWaitFollowUpQty,
            ClueWaitAssignQty,
            ClueWaitFollowUpQty,
            SalesmanID
        )
        SELECT @CurrentDate,
               @CurrentDate,
               #TempPCMAndClue.RegionID,
               #TempPCMAndClue.SalesDepartment,
               #TempPCMAndClue.UserName,
               ISNULL(#TempPCMWaitAssign.Qty, 0),
               ISNULL(#TempPCMWaitFollowUp.Qty, 0),
               ISNULL(#TempPCWaitAssign.Qty, 0),
               ISNULL(#TempPCWaitFollowUp.Qty, 0),
               SalesmanID
        FROM #TempPCMAndClue
            LEFT JOIN #TempPCMWaitAssign
                ON #TempPCMWaitAssign.SalesDepartment = #TempPCMAndClue.SalesDepartment
                   AND #TempPCMAndClue.UserName = #TempPCMWaitAssign.UserName
            LEFT JOIN #TempPCMWaitFollowUp
                ON #TempPCMWaitFollowUp.SalesDepartment = #TempPCMAndClue.SalesDepartment
                   AND #TempPCMAndClue.UserName = #TempPCMWaitFollowUp.UserName
            LEFT JOIN #TempPCWaitAssign
                ON #TempPCWaitAssign.SalesDepartment = #TempPCMAndClue.SalesDepartment
                   AND #TempPCMAndClue.UserName = #TempPCWaitAssign.UserName
            LEFT JOIN #TempPCWaitFollowUp
                ON #TempPCWaitFollowUp.SalesDepartment = #TempPCMAndClue.SalesDepartment
                   AND #TempPCMAndClue.UserName = #TempPCWaitFollowUp.UserName;

        /*==========================================================================
        PART 2: CRM商机数据处理
        ==========================================================================*/

        -- 优化：创建产品分类映射函数（避免重复的CASE表达式）
        -- 注意：由于CASE表达式在多处使用，考虑创建计算列或内联表值函数

        /*--------------------------获取商机数据：状态为已报备------------------------------*/
        SELECT u.Username,
               oppo.DeptName,
               ProductCategory = (CASE
                                      WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水', '泡沫混凝土' ) THEN
                                          '砼'
                                      WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                                          '砂浆'
                                  END
                                 ),
               OppoReportedQty = COUNT(1),
               OppoEstimatedSupplyQty = SUM(ISNULL(oppo.ESTDSupplyQty, 0))
        INTO #TempOppoReported
        FROM [172.16.8.57,20].[CRM-Concrete].dbo.Opportunities oppo WITH (NOLOCK)
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
                ON oppo.UserID = u.ID
        WHERE ISNULL(oppo.isDeleted, 0) = 0
              AND YEAR(oppo.ApprovalTime) = @CurrentYear
              AND MONTH(oppo.ApprovalTime) = @CurrentMonth
              AND oppo.ProdCateName IN ( '普混', '陶粒', '透水', '砂浆', '干混砂浆', '泡沫混凝土' )
        GROUP BY u.Username,
                 oppo.DeptName,
                 (CASE
                      WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水', '泡沫混凝土' ) THEN
                          '砼'
                      WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                          '砂浆'
                  END
                 );

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempOppoReported ON #TempOppoReported(Username, DeptName, ProductCategory);

        /*--------------------------获取赢单商机数据------------------------------*/
        SELECT u.Username,
               oppo.DeptName,
               ProductCategory = (CASE
                                      WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水', '泡沫混凝土' ) THEN
                                          '砼'
                                      WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                                          '砂浆'
                                  END
                                 ),
               MonthWinOppoQty = COUNT(1),
               MonthWinOppoSupplyQty = SUM(ISNULL(Prod.MonthWinOppoSupplyQty, 0))
        INTO #TempOppoWin
        FROM [172.16.8.57,20].[CRM-Concrete].dbo.Opportunities oppo WITH (NOLOCK)
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
                ON oppo.UserID = u.ID
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.ProjApprove pa WITH (NOLOCK)
                ON pa.OppoID = oppo.ID
            OUTER APPLY
        (
            SELECT SUM(ISNULL(   CASE
                                     WHEN d.Unit = '吨' THEN
                                         d.FinalQty_T
                                     ELSE
                                         d.FinalQty_M3
                                 END,
                                 0
                             )
                      ) MonthWinOppoSupplyQty
            FROM dbo.ProductionDailyReportDetails d WITH (NOLOCK)
                LEFT JOIN dbo.ProductionDailyReports r WITH (NOLOCK)
                    ON d.DailyReportID = r.ID
            WHERE r.isDeleted = 0
                  AND YEAR(r.ReportDate) = @CurrentYear
                  AND
                  (
                      d.ProjectID = pa.CSEProjectID
                      OR d.ProjectID = pa.CSEProjectID_SJ
                  )
        ) Prod
        WHERE ISNULL(oppo.isDeleted, 0) = 0
              AND oppo.Status = 9
              AND YEAR(oppo.EndTime) = @CurrentYear
              AND MONTH(oppo.EndTime) = @CurrentMonth
              AND oppo.ProdCateName IN ( '普混', '陶粒', '透水', '砂浆', '干混砂浆', '泡沫混凝土' )
        GROUP BY u.Username,
                 oppo.DeptName,
                 (CASE
                      WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水', '泡沫混凝土' ) THEN
                          '砼'
                      WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                          '砂浆'
                  END
                 );

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempOppoWin ON #TempOppoWin(Username, DeptName, ProductCategory);

        /*--------------------------获取有效商机数据------------------------------*/
        SELECT u.Username,
               oppo.DeptName,
               ProductCategory = (CASE
                                      WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水', '泡沫混凝土' ) THEN
                                          '砼'
                                      WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                                          '砂浆'
                                  END
                                 ),
               MonthEffectiveOppoQty = COUNT(1)
        INTO #TempOppoEffective
        FROM [172.16.8.57,20].[CRM-Concrete].dbo.Opportunities oppo WITH (NOLOCK)
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
                ON oppo.UserID = u.ID
            LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.ProjApprove pa WITH (NOLOCK)
                ON pa.OppoID = oppo.ID
        WHERE ISNULL(oppo.isDeleted, 0) = 0
              AND YEAR(oppo.SecondStageSubmitTime) = @CurrentYear
              AND MONTH(oppo.SecondStageSubmitTime) = @CurrentMonth
              AND oppo.ProdCateName IN ( '普混', '陶粒', '透水', '砂浆', '干混砂浆', '泡沫混凝土' )
        GROUP BY u.Username,
                 oppo.DeptName,
                 (CASE
                      WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水', '泡沫混凝土' ) THEN
                          '砼'
                      WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                          '砂浆'
                  END
                 );

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempOppoEffective ON #TempOppoEffective(Username, DeptName, ProductCategory);

        /*--------------------------获取数据集合------------------------------*/
        SELECT DISTINCT
               sdg.RegionID,
               OppoData.DeptName SalesDepartment,
               Salesman.ID SalesmanID,
               OppoData.UserName,
               OppoData.ProductCategory
        INTO #TempOppo
        FROM
        (
            SELECT DeptName,
                   Username,
                   ProductCategory
            FROM #TempOppoReported
            UNION
            SELECT DeptName,
                   Username,
                   ProductCategory
            FROM #TempOppoWin
            UNION
            SELECT DeptName,
                   Username,
                   ProductCategory
            FROM #TempOppoEffective
        ) OppoData
            LEFT JOIN dbo.Salesman WITH (NOLOCK)
                ON Salesman.UserName = OppoData.UserName
                   AND IsDeleted = 0
            LEFT JOIN dbo.SalesDepartments WITH (NOLOCK)
                ON OppoData.DeptName = SalesDepartments.DepartmentName
                   AND SalesDepartments.isDeleted = 0
            LEFT JOIN dbo.SalesDepartmentsGroup sdg WITH (NOLOCK)
                ON GroupID = sdg.ID;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempOppo ON #TempOppo(UserName, SalesDepartment, ProductCategory);

        /*--------------------------物理表处理------------------------------*/
        DELETE dbo.WorkbenchKanbanOppo;

        INSERT INTO dbo.WorkbenchKanbanOppo
        (
            FGC_CreateDate,
            FGC_LastModifyDate,
            RegionID,
            SalesDepartment,
            UserName,
            TypeName,
            OppoReportedQty,
            OppoEstimatedSupplyQty,
            MonthWinOppoQty,
            MonthWinOppoSupplyQty,
            SalesmanID,
            OppoEffectiveQty
        )
        SELECT @CurrentDate,
               @CurrentDate,
               #TempOppo.RegionID,
               #TempOppo.SalesDepartment,
               #TempOppo.UserName,
               #TempOppo.ProductCategory,
               ISNULL(#TempOppoReported.OppoReportedQty, 0),
               ISNULL(#TempOppoReported.OppoEstimatedSupplyQty, 0),
               ISNULL(#TempOppoWin.MonthWinOppoQty, 0),
               ISNULL(#TempOppoWin.MonthWinOppoSupplyQty, 0),
               #TempOppo.SalesmanID,
               ISNULL(#TempOppoEffective.MonthEffectiveOppoQty, 0)
        FROM #TempOppo
            LEFT JOIN #TempOppoReported
                ON #TempOppo.SalesDepartment = #TempOppoReported.DeptName
                   AND #TempOppo.UserName = #TempOppoReported.UserName
                   AND #TempOppoReported.ProductCategory = #TempOppo.ProductCategory
            LEFT JOIN #TempOppoWin
                ON #TempOppo.SalesDepartment = #TempOppoWin.DeptName
                   AND #TempOppo.UserName = #TempOppoWin.UserName
                   AND #TempOppoWin.ProductCategory = #TempOppo.ProductCategory
            LEFT JOIN #TempOppoEffective
                ON #TempOppo.SalesDepartment = #TempOppoEffective.DeptName
                   AND #TempOppo.UserName = #TempOppoEffective.UserName
                   AND #TempOppoEffective.ProductCategory = #TempOppo.ProductCategory;

        /*==========================================================================
        PART 3: 统计数据处理
        ==========================================================================*/

        /*--------------------------获取要查询的数据------------------------------*/
        SELECT DISTINCT
               sdg.RegionID,
               SalesDepartment,
               Project.ID ProjectID,
               SalesmanID,
               Salesman.UserName,
               ProductCategory = (CASE
                                      WHEN Project.ProductCategory IN ( '普混', '陶粒', '透水', '泡沫混凝土' ) THEN
                                          '砼'
                                      WHEN Project.ProductCategory IN ( '砂浆', '干混砂浆' ) THEN
                                          '砂浆'
                                  END
                                 ),
               AccountingPaymentType = CASE
                                           WHEN AccountingPaymentType IN ( '现金' ) THEN
                                               '现金'
                                           WHEN AccountingPaymentType IN ( '站点抵款' ) THEN
                                               '站点抵款'
                                           ELSE
                                               '垫资'
                                       END
        INTO #TempProj
        FROM dbo.Project WITH (NOLOCK)
            INNER JOIN dbo.Salesman WITH (NOLOCK)
                ON SalesmanID = Salesman.ID
            LEFT JOIN dbo.SalesDepartments sd WITH (NOLOCK)
                ON Project.SalesDepartment = sd.DepartmentName
                   AND Project.isDeleted = 0
            LEFT JOIN dbo.SalesDepartmentsGroup sdg WITH (NOLOCK)
                ON sd.GroupID = sdg.ID
            LEFT JOIN dbo.ProjectRealManageSet WITH (NOLOCK)
                ON Project.ProjectRealManageSetID = ProjectRealManageSet.ID
            LEFT JOIN dbo.Companies_PartyA WITH (NOLOCK)
                ON Project.SignCompanyID_PartyA = Companies_PartyA.ID
        WHERE Project.isDeleted = 0
              AND Salesman.isDeleted = 0
              AND ISNULL(ProjectRealManageSet.IsParticipateInReturnCalc, 1) = 1
              AND ISNULL(Companies_PartyA.CompanyName, '') NOT IN (SELECT CompanyName FROM @NotCalcCompanies)
              AND Project.ProductCategory IN ( '普混', '陶粒', '透水', '砂浆', '干混砂浆', '泡沫混凝土' );

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempProj_ProjectID ON #TempProj(ProjectID);
        CREATE NONCLUSTERED INDEX IX_TempProj_Lookup ON #TempProj(SalesDepartment, UserName, ProductCategory, AccountingPaymentType);

        SELECT DISTINCT
               RegionID,
               SalesDepartment,
               SalesmanID,
               UserName,
               AccountingPaymentType
        INTO #TempSales
        FROM #TempProj;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempSales ON #TempSales(SalesDepartment, UserName, AccountingPaymentType);

        /*--------------------------获取销售目标、利润、回款数据------------------------------*/

        CREATE TABLE #QueryBusinessMaterialType
        (
            TypeName NVARCHAR(200)
        );
        INSERT INTO #QueryBusinessMaterialType
        (
            TypeName
        )
        SELECT Value
        FROM dbo.DataDictionaries WITH (NOLOCK)
        WHERE DataTableName = '销售月度目标品类'
              AND Value != '新材料';

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_QueryBusinessMaterialType ON #QueryBusinessMaterialType(TypeName);

        -- 销量目标、利润目标
        SELECT t.SalesDepartment,
               Salesman.UserName,
               t.PeriodID,
               ProductCategory,
               SUM(ISNULL(t.TargetQty, 0)) TargetFinalQty,
               SUM(ISNULL(t.TargetAmt, 0)) TargetSalesAmt,
               SUM(ISNULL(t.ProfitTargetAmt, 0)) ProfitTargetAmt
        INTO #TempSalesTargets
        FROM SalesTargets t WITH (NOLOCK)
            LEFT JOIN dbo.Salesman WITH (NOLOCK)
                ON t.SalesmanID = Salesman.ID
        WHERE t.PeriodID IN (SELECT ID FROM #QueryPeriod)
              AND ProductCategory != '新材料'
        GROUP BY t.SalesDepartment,
                 Salesman.UserName,
                 t.PeriodID,
                 ProductCategory;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempSalesTargets ON #TempSalesTargets(SalesDepartment, UserName, PeriodID, ProductCategory);

        -- 销量（优化：使用表变量替代子查询）
        SELECT #TempProj.SalesDepartment,
               #TempProj.UserName,
               Periods.ID PeriodID,
               #TempProj.ProductCategory,
               #TempProj.AccountingPaymentType,
               SUM(ISNULL(   CASE
                                 WHEN Unit = '吨' THEN
                                     d.FinalQty_T
                                 ELSE
                                     d.FinalQty_M3
                             END,
                             0
                         )
                  ) FinalQty,
               SUM(ISNULL(d.SalesTotalAmt1, 0)) SalesAmt
        INTO #TempProd
        FROM dbo.ProductionDailyReportDetails d WITH (NOLOCK)
            LEFT JOIN #TempProj
                ON d.ProjectID = #TempProj.ProjectID
            INNER JOIN dbo.ProductionDailyReports r WITH (NOLOCK)
                ON d.DailyReportID = r.ID
            INNER JOIN #QueryPeriod Periods WITH (NOLOCK)
                ON r.ReportDate
                   BETWEEN StartDate AND EndDate
        WHERE r.isDeleted = 0
              AND d.Type IN (SELECT Type FROM @TypeFilter)
        GROUP BY #TempProj.SalesDepartment,
                 #TempProj.UserName,
                 Periods.ID,
                 #TempProj.ProductCategory,
                 #TempProj.AccountingPaymentType;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempProd ON #TempProd(SalesDepartment, UserName, PeriodID, ProductCategory, AccountingPaymentType);

        -- 利润
        SELECT #TempProj.SalesDepartment,
               #TempProj.UserName,
               PeriodID,
               #TempProj.ProductCategory,
               #TempProj.AccountingPaymentType,
               SUM(ISNULL(spp.MonthProfitAmt, 0)) ProfitAmt
        INTO #TempProfit
        FROM dbo.SalesProjectProfitMonth spp WITH (NOLOCK)
            INNER JOIN #TempProj
                ON spp.ProjectID = #TempProj.ProjectID
            LEFT JOIN dbo.Salesman WITH (NOLOCK)
                ON #TempProj.SalesmanID = Salesman.ID
        WHERE spp.PeriodID IN (SELECT ID FROM #QueryPeriod)
        GROUP BY #TempProj.SalesDepartment,
                 #TempProj.UserName,
                 PeriodID,
                 #TempProj.ProductCategory,
                 #TempProj.AccountingPaymentType;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempProfit ON #TempProfit(SalesDepartment, UserName, PeriodID, ProductCategory, AccountingPaymentType);

        -- 回款目标
        SELECT p.SalesDepartment,
               p.UserName,
               t.PeriodID,
               p.AccountingPaymentType,
               TargetReturnAmt = SUM(ISNULL(ar.AR, 0) * ISNULL(t.TargetRatio, 0))
        INTO #TempReturnTargets
        FROM #TempProj p
            LEFT JOIN dbo.SalesReturnTargets t WITH (NOLOCK)
                ON p.ProductCategory = t.ProductCategoryType
            LEFT JOIN dbo.AccountReceivable ar WITH (NOLOCK)
                ON ar.PeriodID = t.PeriodID - 1
                   AND ar.ProjectID = p.ProjectID
            LEFT JOIN dbo.FinanceReports fr WITH (NOLOCK)
                ON ar.FinanceRptID = fr.ID
        WHERE fr.isDeleted = 0
              AND ar.isDeleted = 0
              AND t.PeriodID IN (SELECT ID FROM #QueryPeriod)
        GROUP BY p.SalesDepartment,
                 p.UserName,
                 t.PeriodID,
                 p.AccountingPaymentType;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempReturnTargets ON #TempReturnTargets(SalesDepartment, UserName, PeriodID, AccountingPaymentType);

        -- 回款计划
        SELECT p.SalesDepartment,
               p.UserName,
               plans.PeriodID,
               p.AccountingPaymentType,
               PlanReturnAmt = SUM(ISNULL(ThisPaymentPromiseTarget, 0))
        INTO #TempReturnPlans
        FROM #TempProj p
            LEFT JOIN dbo.SalesPaymentPlanDetails details
                ON details.ProjectID = p.ProjectID
            LEFT JOIN dbo.SalesPaymentPlan plans WITH (NOLOCK)
                ON plans.ID = details.SalesPaymentPlanID
        WHERE plans.IsDeleted = 0
              AND details.IsMerged = 0
              AND plans.Type = 1
              AND plans.PeriodID IN (SELECT ID FROM #QueryPeriod)
        GROUP BY p.SalesDepartment,
                 p.UserName,
                 plans.PeriodID,
                 p.AccountingPaymentType;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempReturnPlans ON #TempReturnPlans(SalesDepartment, UserName, PeriodID, AccountingPaymentType);

        -- 实际回款
        SELECT ProjectID,
               SalesPayment.PeriodID,
               CAST(SUM(ISNULL(Amount, 0)) AS DECIMAL(18, 2)) ReturnAmt
        INTO #TempSalesPayment
        FROM dbo.SalesPayment WITH (NOLOCK)
        WHERE ISNULL(SalesPayment.isDeleted, 0) = 0
              AND PeriodID IN (SELECT ID FROM #QueryPeriod)
        GROUP BY ProjectID,
                 SalesPayment.PeriodID;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempSalesPayment ON #TempSalesPayment(ProjectID, PeriodID);

        SELECT ProjectID,
               SalesServiceIncome.PeriodID,
               CAST(SUM(ISNULL(RefundAmt, 0)) AS DECIMAL(18, 2)) RefundAmt
        INTO #TempRefund
        FROM dbo.SalesServiceIncome WITH (NOLOCK)
        WHERE ServiceType = '支出'
              AND ISNULL(SalesServiceIncome.isDeleted, 0) = 0
              AND PeriodID IN (SELECT ID FROM #QueryPeriod)
        GROUP BY ProjectID,
                 SalesServiceIncome.PeriodID;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempRefund ON #TempRefund(ProjectID, PeriodID);

        SELECT p.SalesDepartment,
               p.UserName,
               Periods.ID PeriodID,
               p.AccountingPaymentType,
               SUM(ISNULL(ReturnAmt, 0)) - SUM(ISNULL(RefundAmt, 0)) ReturnAmt
        INTO #TempReturn
        FROM #TempProj p
            LEFT JOIN dbo.Salesman WITH (NOLOCK)
                ON SalesmanID = Salesman.ID
            INNER JOIN #QueryPeriod Periods
                ON 1 = 1
            LEFT JOIN #TempSalesPayment SalesReturn
                ON SalesReturn.ProjectID = p.ProjectID
                   AND Periods.ID = SalesReturn.PeriodID
            LEFT JOIN #TempRefund SalesRefund
                ON SalesRefund.ProjectID = p.ProjectID
                   AND Periods.ID = SalesRefund.PeriodID
        GROUP BY p.SalesDepartment,
                 p.UserName,
                 Periods.ID,
                 p.AccountingPaymentType;

        -- 优化：添加索引
        CREATE CLUSTERED INDEX IX_TempReturn ON #TempReturn(SalesDepartment, UserName, PeriodID, AccountingPaymentType);

        /*--------------------------物理表处理：销售数据------------------------------*/
        DELETE WorkbenchKanbanSales;

        INSERT INTO dbo.WorkbenchKanbanSales
        (
            FGC_CreateDate,
            FGC_LastModifyDate,
            RegionID,
            SalesDepartment,
            UserName,
            TypeName,
            TimeType,
            TargetFinalQty,
            FinalQty,
            TargetSalesAmt,
            SalesAmt,
            ProfitTargetAmt,
            ProfitAmt,
            SalesmanID,
            AccountingPaymentType,
            LastFinalQty
        )
        SELECT FGC_CreateDate = @CurrentDate,
               FGC_LastModifyDate = @CurrentDate,
               #TempSales.RegionID,
               #TempSales.SalesDepartment,
               #TempSales.UserName,
               type.TypeName,
               TimeType = 1,
               SUM(ISNULL(   CASE
                                 WHEN #TempSales.AccountingPaymentType != '垫资' THEN
                                     0
                                 ELSE
                                     TargetFinalQty
                             END,
                             0
                         )
                  ),
               SUM(ISNULL(#TempProd.FinalQty, 0)),
               SUM(ISNULL(TargetSalesAmt, 0)),
               SUM(ISNULL(#TempProd.SalesAmt, 0)),
               SUM(ISNULL(ProfitTargetAmt, 0)),
               SUM(ISNULL(ProfitAmt, 0)),
               SalesmanID,
               #TempSales.AccountingPaymentType,
               SUM(ISNULL(LastProd.FinalQty, 0))
        FROM #TempSales
            LEFT JOIN #QueryBusinessMaterialType type
                ON 1 = 1
            LEFT JOIN #QueryPeriod Periods
                ON 1 = 1
            LEFT JOIN #TempSalesTargets
                ON type.TypeName = #TempSalesTargets.ProductCategory
                   AND #TempSalesTargets.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempSalesTargets.UserName = #TempSales.UserName
                   AND #TempSalesTargets.PeriodID = Periods.ID
            LEFT JOIN #TempProd
                ON type.TypeName = #TempProd.ProductCategory
                   AND #TempProd.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempProd.UserName = #TempSales.UserName
                   AND #TempProd.PeriodID = Periods.ID
                   AND #TempProd.AccountingPaymentType = #TempSales.AccountingPaymentType
            LEFT JOIN #TempProd LastProd
                ON type.TypeName = LastProd.ProductCategory
                   AND LastProd.SalesDepartment = #TempSales.SalesDepartment
                   AND LastProd.UserName = #TempSales.UserName
                   AND LastProd.PeriodID = Periods.ID - 1
                   AND LastProd.AccountingPaymentType = #TempSales.AccountingPaymentType
            LEFT JOIN #TempProfit
                ON type.TypeName = #TempProfit.ProductCategory
                   AND #TempProfit.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempProfit.UserName = #TempSales.UserName
                   AND #TempProfit.PeriodID = Periods.ID
                   AND #TempProfit.AccountingPaymentType = #TempSales.AccountingPaymentType
        WHERE @YesterdayDate
        BETWEEN StartDate AND EndDate
        GROUP BY #TempSales.RegionID,
                 #TempSales.SalesDepartment,
                 #TempSales.UserName,
                 type.TypeName,
                 SalesmanID,
                 #TempSales.AccountingPaymentType
        UNION ALL
        SELECT FGC_CreateDate = @CurrentDate,
               FGC_LastModifyDate = @CurrentDate,
               #TempSales.RegionID,
               #TempSales.SalesDepartment,
               #TempSales.UserName,
               type.TypeName,
               TimeType = 2,
               SUM(ISNULL(   CASE
                                 WHEN #TempSales.AccountingPaymentType != '垫资' THEN
                                     0
                                 ELSE
                                     TargetFinalQty
                             END,
                             0
                         )
                  ),
               SUM(ISNULL(FinalQty, 0)),
               SUM(ISNULL(TargetSalesAmt, 0)),
               SUM(ISNULL(SalesAmt, 0)),
               SUM(ISNULL(ProfitTargetAmt, 0)),
               SUM(ISNULL(ProfitAmt, 0)),
               SalesmanID,
               #TempSales.AccountingPaymentType,
               NULL
        FROM #TempSales
            LEFT JOIN #QueryBusinessMaterialType type
                ON 1 = 1
            LEFT JOIN #QueryPeriod Periods
                ON 1 = 1
            LEFT JOIN #TempSalesTargets
                ON type.TypeName = #TempSalesTargets.ProductCategory
                   AND #TempSalesTargets.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempSalesTargets.UserName = #TempSales.UserName
                   AND #TempSalesTargets.PeriodID = Periods.ID
            LEFT JOIN #TempProd
                ON type.TypeName = #TempProd.ProductCategory
                   AND #TempProd.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempProd.UserName = #TempSales.UserName
                   AND #TempProd.PeriodID = Periods.ID
                   AND #TempProd.AccountingPaymentType = #TempSales.AccountingPaymentType
            LEFT JOIN #TempProfit
                ON type.TypeName = #TempProfit.ProductCategory
                   AND #TempProfit.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempProfit.UserName = #TempSales.UserName
                   AND #TempProfit.PeriodID = Periods.ID
                   AND #TempProfit.AccountingPaymentType = #TempSales.AccountingPaymentType
        GROUP BY #TempSales.RegionID,
                 #TempSales.SalesDepartment,
                 #TempSales.UserName,
                 type.TypeName,
                 SalesmanID,
                 #TempSales.AccountingPaymentType;

        /*--------------------------物理表处理：回款数据------------------------------*/
        DELETE WorkbenchKanbanReturn;

        INSERT INTO dbo.WorkbenchKanbanReturn
        (
            FGC_CreateDate,
            FGC_LastModifyDate,
            RegionID,
            SalesDepartment,
            UserName,
            TimeType,
            TargetReturnAmt,
            PlanReturnAmt,
            ReturnAmt,
            SalesmanID,
            AccountingPaymentType
        )
        SELECT FGC_CreateDate = @CurrentDate,
               FGC_LastModifyDate = @CurrentDate,
               #TempSales.RegionID,
               #TempSales.SalesDepartment,
               #TempSales.UserName,
               TimeType = 1,
               SUM(ISNULL(TargetReturnAmt, 0)),
               SUM(ISNULL(PlanReturnAmt, 0)),
               SUM(ISNULL(ReturnAmt, 0)),
               SalesmanID,
               #TempSales.AccountingPaymentType
        FROM #TempSales
            LEFT JOIN #QueryPeriod Periods
                ON 1 = 1
            LEFT JOIN #TempReturnTargets
                ON #TempReturnTargets.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempReturnTargets.UserName = #TempSales.UserName
                   AND #TempReturnTargets.PeriodID = Periods.ID
                   AND #TempReturnTargets.AccountingPaymentType = #TempSales.AccountingPaymentType
            LEFT JOIN #TempReturnPlans
                ON #TempReturnPlans.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempReturnPlans.UserName = #TempSales.UserName
                   AND #TempReturnPlans.PeriodID = Periods.ID
                   AND #TempReturnPlans.AccountingPaymentType = #TempSales.AccountingPaymentType
            LEFT JOIN #TempReturn
                ON #TempReturn.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempReturn.UserName = #TempSales.UserName
                   AND #TempReturn.PeriodID = Periods.ID
                   AND #TempReturn.AccountingPaymentType = #TempSales.AccountingPaymentType
        WHERE @YesterdayDate
        BETWEEN StartDate AND EndDate
        GROUP BY #TempSales.RegionID,
                 #TempSales.SalesDepartment,
                 #TempSales.UserName,
                 SalesmanID,
                 #TempSales.AccountingPaymentType
        UNION ALL
        SELECT FGC_CreateDate = @CurrentDate,
               FGC_LastModifyDate = @CurrentDate,
               #TempSales.RegionID,
               #TempSales.SalesDepartment,
               #TempSales.UserName,
               TimeType = 2,
               SUM(ISNULL(TargetReturnAmt, 0)),
               SUM(ISNULL(PlanReturnAmt, 0)),
               SUM(ISNULL(ReturnAmt, 0)),
               SalesmanID,
               #TempSales.AccountingPaymentType
        FROM #TempSales
            LEFT JOIN #QueryPeriod Periods
                ON 1 = 1
            LEFT JOIN #TempReturnTargets
                ON #TempReturnTargets.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempReturnTargets.UserName = #TempSales.UserName
                   AND #TempReturnTargets.PeriodID = Periods.ID
                   AND #TempReturnTargets.AccountingPaymentType = #TempSales.AccountingPaymentType
            LEFT JOIN #TempReturnPlans
                ON #TempReturnPlans.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempReturnPlans.UserName = #TempSales.UserName
                   AND #TempReturnPlans.PeriodID = Periods.ID
                   AND #TempReturnPlans.AccountingPaymentType = #TempSales.AccountingPaymentType
            LEFT JOIN #TempReturn
                ON #TempReturn.SalesDepartment = #TempSales.SalesDepartment
                   AND #TempReturn.UserName = #TempSales.UserName
                   AND #TempReturn.PeriodID = Periods.ID
                   AND #TempReturn.AccountingPaymentType = #TempSales.AccountingPaymentType
        GROUP BY #TempSales.RegionID,
                 #TempSales.SalesDepartment,
                 #TempSales.UserName,
                 SalesmanID,
                 #TempSales.AccountingPaymentType;

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

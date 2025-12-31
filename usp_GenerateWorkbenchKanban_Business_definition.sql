
/*
创建人: 王诗雨
创建时间: 2024-04-01
说明: 获取工作台-经营部门看板
*/

CREATE PROCEDURE [dbo].[usp_GenerateWorkbenchKanban_Business]
AS
BEGIN



    SELECT ID,
           StartDate,
           EndDate
    INTO #QueryPeriod
    FROM dbo.Periods
    WHERE isDeleted = 0
          AND LEFT(PeriodName, 4) = YEAR(GETDATE() - 1);

    /*CRM潜客+线索部门处理*/

    /*--------------------------PART1：获取【潜客待指派、未跟进】------------------------------*/
    --待指派【分配人是自己，还没有指派记录的】
    SELECT u.Username,
           SalesDepartment = pcm.DeptName,
           Qty = COUNT(1)
    INTO #TempPCMWaitAssign
    FROM [172.16.8.57,20].[CRM-Concrete].dbo.PotentialCustomersManage pcm WITH (NOLOCK)
        LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
            ON pcm.AssignorID = u.ID
        LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Departments WITH (NOLOCK)
            ON u.DepartmentID = Departments.ID
    WHERE ISNULL(pcm.IsDeleted,0) = 0
          AND NOT EXISTS
    (
        SELECT 1
        FROM [172.16.8.57,20].[CRM-Concrete].dbo.PotentialCustomersManageAssigns WITH (NOLOCK)
        WHERE PotentialCustomersManageID = pcm.ID
    )
    GROUP BY u.Username,
             pcm.DeptName;
    --待跟进【指派人是自己，还没有跟进记录的】
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
        --最新指派人
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
    WHERE ISNULL(pcm.IsDeleted,0) = 0
    GROUP BY u.Username,
             pcm.DeptName;

    /*--------------------------PART2：获取通过【潜客转化的线索待指派、未跟进】------------------------------*/
    --待指派【负责人是自己，还没有指派记录的】
    SELECT u.Username,
           pc.SalesDepartment,
           Qty = COUNT(1)
    INTO #TempPCWaitAssign
    FROM [172.16.8.57,20].[CRM-Concrete].dbo.ProjectCustomers pc WITH (NOLOCK)
        LEFT JOIN [172.16.8.57,20].[CRM-Concrete].dbo.Users u WITH (NOLOCK)
            ON pc.ClueOwnerID = u.ID
    WHERE ISNULL(pc.isDeleted,0) = 0
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
    --待跟进【指派人是自己，还没有跟进记录的】
    SELECT u.Username,
           pc.SalesDepartment,
           Qty = COUNT(1)
    INTO #TempPCWaitFollowUp
    FROM [172.16.8.57,20].[CRM-Concrete].dbo.ProjectCustomers pc WITH (NOLOCK)
        --指派记录
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
    WHERE ISNULL(pc.isDeleted,0) = 0
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

    /*--------------------------PART3：获取用户集合------------------------------*/
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

    /*--------------------------PART4：物理表处理------------------------------*/
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
    SELECT GETDATE(),
           GETDATE(),
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


    /*CRM商机数据处理*/

    /*--------------------------PART1：获取商机数据：状态为已报备、不含公海的已报备商机数+预计供应量------------------------------*/
    SELECT u.Username,
           oppo.DeptName,
           ProductCategory = (CASE
                                  WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水','泡沫混凝土') THEN
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
    WHERE ISNULL(oppo.isDeleted,0) = 0
          AND YEAR(oppo.ApprovalTime)=YEAR(GETDATE()) AND MONTH(oppo.ApprovalTime)=MONTH(GETDATE())
          AND oppo.ProdCateName IN ( '普混', '陶粒', '透水', '砂浆', '干混砂浆' ,'泡沫混凝土')
    GROUP BY u.Username,
             oppo.DeptName,
             (CASE
                  WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水','泡沫混凝土' ) THEN
                      '砼'
                  WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                      '砂浆'
              END
             );

    /*--------------------------PART2：获取赢单商机数据------------------------------*/
    SELECT u.Username,
           oppo.DeptName,
           ProductCategory = (CASE
                                  WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水' ,'泡沫混凝土') THEN
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
              AND YEAR(r.ReportDate) = YEAR(GETDATE())
              AND
              (
                  d.ProjectID = pa.CSEProjectID
                  OR d.ProjectID = pa.CSEProjectID_SJ
              )
    ) Prod
    WHERE ISNULL(oppo.isDeleted,0) = 0
          AND oppo.Status = 9
          AND YEAR(oppo.EndTime) = YEAR(GETDATE())
          AND MONTH(oppo.EndTime) = MONTH(GETDATE())
		  AND oppo.ProdCateName IN ( '普混', '陶粒', '透水', '砂浆', '干混砂浆','泡沫混凝土' )
    GROUP BY u.Username,
             oppo.DeptName,
             (CASE
                  WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水','泡沫混凝土') THEN
                      '砼'
                  WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                      '砂浆'
              END
             );

	/*--------------------------PART2：获取有效商机数据------------------------------*/
    SELECT u.Username,
           oppo.DeptName,
           ProductCategory = (CASE
                                  WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水' ,'泡沫混凝土') THEN
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
    WHERE ISNULL(oppo.isDeleted,0) = 0
          AND YEAR(oppo.SecondStageSubmitTime) = YEAR(GETDATE())
          AND MONTH(oppo.SecondStageSubmitTime) = MONTH(GETDATE())
		  AND oppo.ProdCateName IN ( '普混', '陶粒', '透水', '砂浆', '干混砂浆','泡沫混凝土' )
    GROUP BY u.Username,
             oppo.DeptName,
             (CASE
                  WHEN oppo.ProdCateName IN ( '普混', '陶粒', '透水','泡沫混凝土') THEN
                      '砼'
                  WHEN oppo.ProdCateName IN ( '砂浆', '干混砂浆' ) THEN
                      '砂浆'
              END
             );
    /*--------------------------PART3：获取数据集合------------------------------*/
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
            ON GroupID = sdg.ID
		--WHERE OppoData.ProductCategory IS NOT NULL;

    /*--------------------------PART4：物理表处理------------------------------*/
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
    SELECT GETDATE(),
           GETDATE(),
           #TempOppo.RegionID,
           #TempOppo.SalesDepartment,
           #TempOppo.UserName,
           #TempOppo.ProductCategory,
           ISNULL(#TempOppoReported.OppoReportedQty, 0),
           ISNULL(#TempOppoReported.OppoEstimatedSupplyQty, 0),
           ISNULL(#TempOppoWin.MonthWinOppoQty, 0),
           ISNULL(#TempOppoWin.MonthWinOppoSupplyQty, 0),
           #TempOppo.SalesmanID,
		   ISNULL(#TempOppoEffective.MonthEffectiveOppoQty,0)
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
               AND #TempOppoEffective.ProductCategory = #TempOppo.ProductCategory



    /*统计数据处理*/
    /*--------------------------PART0：获取要查询的数据------------------------------*/
    SELECT DISTINCT
           sdg.RegionID,
           SalesDepartment,
           Project.ID ProjectID,
           SalesmanID,
           Salesman.UserName,
           ProductCategory = (CASE
                                  WHEN Project.ProductCategory IN ( '普混', '陶粒', '透水' ,'泡沫混凝土') THEN
                                      '砼'
                                  WHEN Project.ProductCategory IN ( '砂浆', '干混砂浆' ) THEN
                                      '砂浆'
                              END
                             ),
           --垫资：代理商ID是空，核算付款方式！=‘现金’
           --现金：核算付款方式是现金
           --站点抵款：核算抵款方式=‘站点抵款’
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
          AND ISNULL(Companies_PartyA.CompanyName, '') NOT IN
              (
                  SELECT col
                  FROM dbo.f_split(
                       (
                           SELECT ParaValue
                           FROM dbo.Parameters
                           WHERE ParaName = 'NotCalcReturnCompanies'
                       ),
                       ','
                                  )
              )
          AND Project.ProductCategory IN ( '普混', '陶粒', '透水', '砂浆', '干混砂浆','泡沫混凝土' );

    SELECT DISTINCT
           RegionID,
           SalesDepartment,
           SalesmanID,
           UserName,
           AccountingPaymentType
    INTO #TempSales
    FROM #TempProj;

    /*--------------------------PART3：获取混凝土的本月销售目标量、本月销售量、本月销量达成率、本月利润目标、本月利润目标达成、本月利润目标达成、本月回款目标------------------------------*/

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

    --销量目标、利润目标
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
    WHERE t.PeriodID IN
          (
              SELECT ID FROM #QueryPeriod
          )
          AND ProductCategory != '新材料'
    GROUP BY t.SalesDepartment,
             Salesman.UserName,
             t.PeriodID,
             ProductCategory;

    --销量
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
        LEFT JOIN dbo.#TempProj WITH (NOLOCK)
            ON d.ProjectID = #TempProj.ProjectID
        INNER JOIN dbo.ProductionDailyReports r WITH (NOLOCK)
            ON d.DailyReportID = r.ID
        INNER JOIN #QueryPeriod Periods WITH (NOLOCK)
            ON r.ReportDate
               BETWEEN StartDate AND EndDate
    WHERE r.isDeleted = 0
          AND d.Type IN
              (
                  SELECT col
                  FROM dbo.f_split(
                       (
                           SELECT ParaValue
                           FROM dbo.Parameters
                           WHERE ParaName = 'ProjectSalesTypeFilter'
                       ),
                       ','
                                  )
              )
    GROUP BY #TempProj.SalesDepartment,
             #TempProj.UserName,
             Periods.ID,
             #TempProj.ProductCategory,
             #TempProj.AccountingPaymentType;


    --利润
    SELECT #TempProj.SalesDepartment,
           #TempProj.UserName,
           PeriodID,
           #TempProj.ProductCategory,
           #TempProj.AccountingPaymentType,
           SUM(ISNULL(spp.MonthProfitAmt, 0)) ProfitAmt
    INTO #TempProfit
    FROM dbo.SalesProjectProfitMonth spp WITH (NOLOCK)
        INNER JOIN dbo.#TempProj WITH (NOLOCK)
            ON spp.ProjectID = #TempProj.ProjectID
        LEFT JOIN dbo.Salesman WITH (NOLOCK)
            ON #TempProj.SalesmanID = Salesman.ID
    WHERE spp.PeriodID IN
          (
              SELECT ID FROM #QueryPeriod
          )
    GROUP BY #TempProj.SalesDepartment,
             #TempProj.UserName,
             PeriodID,
             #TempProj.ProductCategory,
             #TempProj.AccountingPaymentType;

    --回款目标
    SELECT p.SalesDepartment,
           p.UserName,
           t.PeriodID,
           p.AccountingPaymentType,
           TargetReturnAmt = SUM(ISNULL(ar.AR, 0) * ISNULL(t.TargetRatio, 0))
    INTO #TempReturnTargets
    FROM #TempProj p WITH (NOLOCK)
        LEFT JOIN dbo.SalesReturnTargets t WITH (NOLOCK)
            ON p.ProductCategory = t.ProductCategoryType
        LEFT JOIN dbo.AccountReceivable ar WITH (NOLOCK)
            ON ar.PeriodID = t.PeriodID - 1
               AND ar.ProjectID = p.ProjectID
        LEFT JOIN dbo.FinanceReports fr WITH (NOLOCK)
            ON ar.FinanceRptID = fr.ID
    WHERE fr.isDeleted = 0
          AND ar.isDeleted = 0
          AND t.PeriodID IN
              (
                  SELECT ID FROM #QueryPeriod
              )
    GROUP BY p.SalesDepartment,
             p.UserName,
             t.PeriodID,
             p.AccountingPaymentType;


    --回款计划
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
          AND plans.PeriodID IN
              (
                  SELECT ID FROM #QueryPeriod
              )
    GROUP BY p.SalesDepartment,
             p.UserName,
             plans.PeriodID,
             p.AccountingPaymentType;

    --实际回款

    SELECT ProjectID,
           SalesPayment.PeriodID,
           CAST(SUM(ISNULL(Amount, 0)) AS DECIMAL(18, 2)) ReturnAmt
    INTO #TempSalesPayment
    FROM dbo.SalesPayment WITH (NOLOCK)
    WHERE ISNULL(SalesPayment.isDeleted, 0) = 0
          AND PeriodID IN
              (
                  SELECT ID FROM #QueryPeriod
              )
    GROUP BY ProjectID,
             SalesPayment.PeriodID;

    SELECT ProjectID,
           SalesServiceIncome.PeriodID,
           CAST(SUM(ISNULL(RefundAmt, 0)) AS DECIMAL(18, 2)) RefundAmt
    INTO #TempRefund
    FROM dbo.SalesServiceIncome WITH (NOLOCK)
    WHERE ServiceType = '支出'
          AND ISNULL(SalesServiceIncome.isDeleted, 0) = 0
          AND PeriodID IN
              (
                  SELECT ID FROM #QueryPeriod
              )
    GROUP BY ProjectID,
             SalesServiceIncome.PeriodID;




    SELECT p.SalesDepartment,
           p.UserName,
           Periods.ID PeriodID,
           p.AccountingPaymentType,
           SUM(ISNULL(ReturnAmt, 0)) - SUM(ISNULL(RefundAmt, 0)) ReturnAmt
    INTO #TempReturn
    FROM #TempProj p WITH (NOLOCK)
        LEFT JOIN dbo.Salesman WITH (NOLOCK)
            ON SalesmanID = Salesman.ID
        INNER JOIN #QueryPeriod Periods WITH (NOLOCK)
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



    /*--------------------------END：物理表处理------------------------------*/




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
    SELECT FGC_CreateDate = GETDATE(),
           FGC_LastModifyDate = GETDATE(),
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
    WHERE CAST(GETDATE() - 1 AS DATE)
    BETWEEN StartDate AND EndDate
    GROUP BY #TempSales.RegionID,
             #TempSales.SalesDepartment,
             #TempSales.UserName,
             type.TypeName,
             SalesmanID,
             #TempSales.AccountingPaymentType
    UNION ALL
    SELECT FGC_CreateDate = GETDATE(),
           FGC_LastModifyDate = GETDATE(),
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
    SELECT FGC_CreateDate = GETDATE(),
           FGC_LastModifyDate = GETDATE(),
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
    WHERE CAST(GETDATE() - 1 AS DATE)
    BETWEEN StartDate AND EndDate
    GROUP BY #TempSales.RegionID,
             #TempSales.SalesDepartment,
             #TempSales.UserName,
             SalesmanID,
             #TempSales.AccountingPaymentType
    UNION ALL
    SELECT FGC_CreateDate = GETDATE(),
           FGC_LastModifyDate = GETDATE(),
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



END;

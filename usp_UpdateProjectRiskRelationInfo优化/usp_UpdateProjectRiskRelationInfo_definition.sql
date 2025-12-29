--SET QUOTED_IDENTIFIER ON|OFF
--SET ANSI_NULLS ON|OFF
--GO
/*
desc:每天0点定时刷新合同风险需要使用的相关信息
*/
CREATE PROCEDURE [dbo].[usp_UpdateProjectRiskRelationInfo]
AS
BEGIN
    /*
	合同状态；第一次打土日期；项目累计供应数量；项目累计产值；项目累计回款；项目回款率；未办理结算金额；项目结算金额
	*/

    /*Step1：获取需要更新的核算账户*/
    --合同状态
    SELECT p.ID ProjectID,
           p.SalesContractID,
           sc.SignStatus ContractSignStatus,
           p.ProductCategory,
           pc.Unit
    INTO #TempProj
    FROM dbo.Project p WITH (NOLOCK)
        LEFT JOIN dbo.SalesContracts sc WITH (NOLOCK)
            ON p.SalesContractID = sc.ID
        LEFT JOIN dbo.ProductCategories pc WITH (NOLOCK)
            ON sc.ProductCategory = pc.CategoryName
    --WHERE EXISTS
    --(
    --    SELECT 1 FROM dbo.ProjectRisk pr WITH (NOLOCK) WHERE pr.ProjectID = p.ID
    --);

    /*Step2：获取销售相关信息*/

    --获取【核算账户开工日期】【核算账户最后打土日期】【核算账户累计供应数量】；
    SELECT details.ProjectID,
           --SUM(ISNULL(details.FinalQty_M3, 0)) TotalFinalQty_M3,
           --SUM(ISNULL(details.FinalQty_T, 0)) TotalFinalQty_T,
           MIN(details.ReceiptDate) ProductionOpenningDate,
           MAX(details.ReceiptDate) ProductionEndDate
    INTO #TempProduct
    FROM ProductionDailyReportDetails details WITH (NOLOCK)
        LEFT JOIN dbo.ProductionDailyReports reports WITH (NOLOCK)
            ON details.DailyReportID = reports.ID
    WHERE reports.isDeleted = 0
          AND EXISTS
    (
        SELECT 1 FROM #TempProj WHERE ProjectID = details.ProjectID
    )
	AND details.Type IN (SELECT col FROM dbo.f_split((SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),','))
    GROUP BY details.ProjectID
    --HAVING SUM(   CASE
    --                  WHEN details.Unit = '吨' THEN
    --                      ISNULL(details.FinalQty_T, 0)
    --                  ELSE
    --                      ISNULL(details.FinalQty_M3, 0)
    --              END
    --          ) > 0;

    /*Step3：获取两月前的项目回款比例、实时项目回款比例*/

	/*
	以6月为例：项目回款率（截止今日回款/两月前产值）=（【3月应收回款表的回款】+【4.1-今日的回款】-【4.1-今日的退款】）/【3月应收回款表的产值】
	           项目回款率（截止今日回款/今日产值）=（【3月应收回款表的回款】+【4.1-今日的回款】-【4.1-今日的退款】）/(【3月应收回款表的产值】+【4.1-今日的销售产值】+【4.1-今日的调整金额】）
	*/
    DECLARE @PeriodID BIGINT =
            (
                SELECT ID
                FROM dbo.Periods
                WHERE isDeleted = 0
                      AND CAST(GETDATE() AS DATE)
                      BETWEEN StartDate AND EndDate
            );

    --核算账户【两月前产值】【两月前回款】
    SELECT details.ProjectID,
           p.ProductCategory,
           p.SalesContractID,
           details.CurrentACCUSalesIncomeTotalAmt ProjSalesTotalAmt, --3月份累计的产值
		   ( CASE WHEN p.Unit = '吨'
                                       THEN ISNULL(CurrentACCUFinalQty_T, 0)+ISNULL(details.CurrentACCUSalesIncomeAdjAdjustQty_T,0)
                                       ELSE ISNULL(CurrentACCUFinalQty_M3, 0)+ISNULL(details.CurrentACCUSalesIncomeAdjAdjustQty_M3,0)
                                  END ) ProjSalesTotalQty,--3月份累计的销量
           CurrentACCUSalesPayTotalAmt ProjReturnAmt      --3月累计回款
    INTO #TempBLastNR
    FROM AccountReceivable details WITH ( NOLOCK )
        INNER JOIN dbo.FinanceReports WITH ( NOLOCK ) ON details.FinanceRptID = FinanceReports.ID
        LEFT JOIN #TempProj p WITH (NOLOCK) ON p.ProjectID = details.ProjectID
    WHERE FinanceReports.isDeleted = 0 AND details.isDeleted=0
          AND FinanceReports.PeriodID = @PeriodID - 3;

    --核算账户【截止到当前产值】
    SELECT Project.ID ProjectID,
           ProductCategory,
           SalesContractID,
           ISNULL(nr.YearSalesIncomeTotalAmt, 0) + ISNULL(report.SalesTotalAmt, 0) + ISNULL(Adj.AdjustAmt, 0) CurrentProjSalesTotalAmt,
		   ISNULL(nr.SalesTotalQty, 0) + ISNULL(report.SalesTotalQty, 0) + ISNULL(CASE WHEN Unit='吨' THEN  Adj.AdjustQty_T ELSE Adj.AdjustQty_M3 END, 0) CurrentProjSalesTotalQty
    INTO #TempCurrentSales
    FROM dbo.Project
	 LEFT JOIN dbo.ProductCategories ON ProductCategories.CategoryName=Project.ProductCategory 
        LEFT JOIN
        (
            SELECT details.ProjectID,
                   details.CurrentACCUSalesIncomeTotalAmt YearSalesIncomeTotalAmt,
				      ( CASE WHEN p.Unit = '吨'
                                       THEN ISNULL(CurrentACCUFinalQty_T, 0)+ISNULL(details.CurrentACCUSalesIncomeAdjAdjustQty_T,0)
                                       ELSE ISNULL(CurrentACCUFinalQty_M3, 0)+ISNULL(details.CurrentACCUSalesIncomeAdjAdjustQty_M3,0)
                                  END ) SalesTotalQty
            FROM dbo.AccountReceivable details WITH ( NOLOCK )
            INNER JOIN dbo.FinanceReports WITH ( NOLOCK ) ON details.FinanceRptID = FinanceReports.ID
			LEFT JOIN #TempProj p WITH (NOLOCK) ON p.ProjectID = details.ProjectID
           WHERE FinanceReports.isDeleted = 0 AND details.isDeleted=0
                  AND FinanceReports.PeriodID = @PeriodID - 2
        ) nr
            ON Project.ID = nr.ProjectID --截止到4月底产值、销量
        LEFT JOIN
        (
            SELECT d.ProjectID,
                   SUM(d.SalesTotalAmt1) SalesTotalAmt,
				   SUM(ISNULL(CASE WHEN d.Unit='吨' THEN d.FinalQty_T ELSE d.FinalQty_M3 END,0)) SalesTotalQty
            FROM dbo.ProductionDailyReportDetails d
                INNER JOIN dbo.ProductionDailyReports r
                    ON d.DailyReportID = r.ID
            WHERE r.isDeleted = 0
                  AND r.ReportDate
                  BETWEEN DATEADD(MM, DATEDIFF(MM, 0, DATEADD(MM, -1, GETDATE())), 0) AND GETDATE()
				  AND d.Type IN (SELECT col FROM dbo.f_split((SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),','))
            GROUP BY d.ProjectID
        ) report
            ON Project.ID = report.ProjectID --5.1到当前产值
        LEFT JOIN
        (
            SELECT ProjectID,
                   SUM(ISNULL(AdjustAmt, 0)) AdjustAmt,
				   SUM(ISNULL(AdjustQty_T, 0)) AdjustQty_T,
				   SUM(ISNULL(AdjustQty_M3, 0)) AdjustQty_M3
            FROM SalesIncomeAdjustment
            WHERE [CurrentPeriodID] > @PeriodID - 2
                  AND ISNULL([isDeleted], 0) = 0
            GROUP BY ProjectID
        ) Adj
            ON Project.ID = Adj.ProjectID
    WHERE Project.isDeleted = 0;

    --核算账户【4.1截止到当前回款】；
    SELECT P.ID ProjectID,
           P.ProductCategory,
           P.SalesContractID,
           ISNULL(CurrentReturnAmt, 0) - ISNULL(CurrentRefundAmt, 0) ReturnTotalAmt
    INTO #TempCurrentReturn
    FROM dbo.Project P WITH (NOLOCK)
        LEFT JOIN
        (
            SELECT ProjectID,
                   CAST(SUM(ISNULL(Amount, 0)) AS DECIMAL(18, 2)) CurrentReturnAmt
            FROM dbo.SalesPayment WITH (NOLOCK)
            WHERE PaymentDate
                  BETWEEN DATEADD(MM, DATEDIFF(MM, 0, DATEADD(MM, -2, GETDATE())), 0) AND GETDATE() --3.1截止此刻
                  AND ISNULL(isDeleted, 0) = 0
            GROUP BY ProjectID
        ) SalesReturn
            ON SalesReturn.ProjectID = P.ID
        LEFT JOIN
        (
            SELECT ProjectID,
                   CAST(SUM(ISNULL(RefundAmt, 0)) AS DECIMAL(18, 2)) CurrentRefundAmt
            FROM dbo.SalesServiceIncome WITH (NOLOCK)
            WHERE PaymentDate
                  BETWEEN DATEADD(MM, DATEDIFF(MM, 0, DATEADD(MM, -2, GETDATE())), 0) AND GETDATE() --3.1截止此刻
                  AND ServiceType = '支出'
                  AND ISNULL(isDeleted, 0) = 0
            GROUP BY ProjectID
        ) SalesRefund
            ON SalesRefund.ProjectID = P.ID;

    /*拼接【项目回款（截止今日）】【项目产值（截止两月前）】【项目产值（截止今日）】【核算账户产值（截止今日）】【项目回款率（今日）】【项目回款率（两月前）】数据*/
    SELECT p.ID ProjectID,
           p.ProductCategory,
           ProductCategoryType=CASE
               WHEN p.ProductCategory IN ( '砂浆', '干混砂浆' ) THEN
                   1
               WHEN p.ProductCategory IN ( '普混', '陶粒', '透水' ) THEN
                   2
           END ,
           p.SalesContractID,
		   ProjFinalTotalQty=ISNULL(#TempCurrentSales.CurrentProjSalesTotalQty,0), --核算账户销量(截止今日)
		   ProjSalesTotalAmt=ISNULL(#TempBLastNR.ProjSalesTotalAmt,0),--核算账户产值（截止两月前）
		   ContractSalesTotalAmt=CAST(0 AS DECIMAL(18,2)),--项目产值（截止两月前）
		   CurrentProjSalesTotalAmt=ISNULL(#TempCurrentSales.CurrentProjSalesTotalAmt,0), --核算账户产值(截止今日)
		   CurrentContractSalesTotalAmt=CAST(0 AS DECIMAL(18,2)),--项目产值（截止今日）

		   CurrentProjReturnTotalAmt=ISNULL(#TempBLastNR.ProjReturnAmt,0)+ISNULL(#TempCurrentReturn.ReturnTotalAmt,0),--核算账户回款（截止今日）
		   CurrentContractReturnTotalAmt=CAST(0 AS DECIMAL(18,2)),--项目回款（截止今日）
		   ContractReturnRate=CAST(0 AS DECIMAL(18,4)),--项目回款率（截止今日回款/两月前产值）
		   CurrentContractReturnRate=CAST(0 AS DECIMAL(18,4))--项目回款率实时（截止今日回款/今日产值）
    INTO #TempReturnRate
    FROM dbo.Project p
	LEFT JOIN  #TempBLastNR
         ON p.ID=#TempBLastNR.ProjectID
		 LEFT JOIN #TempCurrentSales
            ON p.ID = #TempCurrentSales.ProjectID
        LEFT JOIN #TempCurrentReturn
            ON p.ID = #TempCurrentReturn.ProjectID
 
        

    /*品类为干混砂浆、湿拌砂浆/陶粒、透水的核算账户，查询该账户所属合同下所有核算账户的产值、回款*/
    UPDATE #TempReturnRate
    SET ContractSalesTotalAmt = ISNULL(cr.ContractSalesTotalAmt, 0),
        CurrentContractSalesTotalAmt = ISNULL(cr.CurrentContractSalesTotalAmt, 0),
        CurrentContractReturnTotalAmt = ISNULL(cr.CurrentContractReturnTotalAmt, 0),
        ContractReturnRate = CASE WHEN ISNULL(cr.ContractSalesTotalAmt, 0) = 0 THEN 1 ELSE CAST((ISNULL(cr.CurrentContractReturnTotalAmt, 0) / ISNULL(cr.ContractSalesTotalAmt, 0)) AS DECIMAL(18, 4)) END,
        CurrentContractReturnRate = CASE WHEN ISNULL(cr.CurrentContractSalesTotalAmt, 0) = 0 THEN 1 ELSE CAST((ISNULL(cr.CurrentContractReturnTotalAmt, 0) / ISNULL(cr.CurrentContractSalesTotalAmt, 0) ) AS DECIMAL(18, 4)) END
    FROM #TempReturnRate
        LEFT JOIN
        (
            SELECT SalesContractID,
                   ProductCategoryType,
                   SUM(ISNULL(ProjSalesTotalAmt, 0)) ContractSalesTotalAmt,
                   SUM(ISNULL(CurrentProjSalesTotalAmt, 0)) CurrentContractSalesTotalAmt,
                   SUM(ISNULL(CurrentProjReturnTotalAmt, 0)) CurrentContractReturnTotalAmt
            FROM #TempReturnRate
            GROUP BY SalesContractID,
                     ProductCategoryType
        ) cr
            ON cr.SalesContractID = #TempReturnRate.SalesContractID
               AND cr.ProductCategoryType = #TempReturnRate.ProductCategoryType;

    /*Step4：已办出结算单产值*/
    SELECT p.ID ProjectID,
           CASE
               WHEN p.ProductCategory IN ( '砂浆', '干混砂浆' ) THEN
                   1
               WHEN p.ProductCategory IN ( '普混', '陶粒', '透水' ) THEN
                   2
           END ProductCategoryType,
           p.SalesContractID,
           ROUND(SUM(ISNULL(SalesAmt, 0)), 2) AS CurrentProjSettleTotalAmt, --核算账户结算金额
		   CAST(0 AS DECIMAL(18,2)) CurrentContractSettleTotalAmt --项目结算金额
    INTO #TempStatement
    FROM Project p WITH (NOLOCK)
	LEFT JOIN SalesStatements  WITH (NOLOCK) ON ProjectID = p.ID AND SalesStatements.isDeleted = 0 AND ISNULL(IsVoid, 0) = 0 AND ISNULL(SalesStatements.ifCalculate, 0) = 1 AND SignDate IS NOT NULL
    WHERE p.isDeleted=0
    GROUP BY p.ID,
           CASE
               WHEN p.ProductCategory IN ( '砂浆', '干混砂浆' ) THEN
                   1
               WHEN p.ProductCategory IN ( '普混', '陶粒', '透水' ) THEN
                   2
           END,
           SalesContractID
	
	UPDATE #TempStatement
    SET CurrentContractSettleTotalAmt = ISNULL(cr.CurrentContractSettleTotalAmt, 0)
    FROM #TempStatement
        LEFT JOIN
        (
            SELECT SalesContractID,
                   ProductCategoryType,
                   SUM(ISNULL(CurrentProjSettleTotalAmt, 0)) CurrentContractSettleTotalAmt
            FROM #TempStatement
            GROUP BY SalesContractID,
                     ProductCategoryType
        ) cr
            ON cr.SalesContractID = #TempStatement.SalesContractID
               AND cr.ProductCategoryType = #TempStatement.ProductCategoryType;

    /*Step3：添加/更新风险相关信息表的字段*/
	SELECT #TempProj.ProjectID ProjectID,
		   ContractSignStatus,
		   #TempProduct.ProductionOpenningDate,
		   #TempProduct.ProductionEndDate,
		   ProjFinalTotalQty = ISNULL(#TempReturnRate.ProjFinalTotalQty,0),--核算账户销量（截止今日）
		   ContractSalesTotalAmt = ISNULL(#TempReturnRate.ContractSalesTotalAmt, 0),                    --项目产值（截止两月前）
		   CurrentContractSalesTotalAmt = ISNULL(#TempReturnRate.CurrentContractSalesTotalAmt, 0),      --项目产值（截止今日）
		   CurrentProjSalesTotalAmt = ISNULL(#TempReturnRate.CurrentProjSalesTotalAmt, 0),              --核算账户产值（截止今日）
		   CurrentProjReturnTotalAmt=ISNULL(#TempReturnRate.CurrentProjReturnTotalAmt, 0),--核算账户回款（截止今日）

		   CurrentContractReturnTotalAmt = ISNULL(#TempReturnRate.CurrentContractReturnTotalAmt, 0),    --项目回款（截止今日）
		   ContractReturnRate = ISNULL(#TempReturnRate.ContractReturnRate, 0),                          --项目回款率（截止今日回款/两月前产值）
		   CurrentContractReturnRate = ISNULL(#TempReturnRate.CurrentContractReturnRate, 0),            --项目回款率实时（截止今日回款/今日产值）

		   CurrentContractSettleTotalAmt = ISNULL(#TempStatement.CurrentContractSettleTotalAmt, 0),     --项目结算金额
		   CurrentContractUnSettleTotalAmt = ISNULL(#TempReturnRate.CurrentContractSalesTotalAmt, 0)
											 - ISNULL(#TempStatement.CurrentContractSettleTotalAmt, 0), --项目未结算金额

		   CurrentProjSettleTotalAmt = ISNULL(#TempStatement.CurrentProjSettleTotalAmt, 0),             --核算账户结算金额
		   CurrentProjUnSettleTotalAmt = ISNULL(#TempReturnRate.CurrentProjSalesTotalAmt, 0)
										 - ISNULL(#TempStatement.CurrentProjSettleTotalAmt, 0),         --核算账户未结算金额
		   @PeriodID ReturnNewPeriodID
	INTO #TempData
	FROM #TempProj
		LEFT JOIN #TempProduct
			ON #TempProduct.ProjectID = #TempProj.ProjectID
		LEFT JOIN #TempReturnRate
			ON #TempReturnRate.ProjectID = #TempProj.ProjectID
		LEFT JOIN #TempStatement
			ON #TempStatement.ProjectID = #TempProj.ProjectID;

	/*物理表更新*/
	UPDATE prri
	SET FGC_LastModifyDate = GETDATE(),
		ContractSignStatus = #TempData.ContractSignStatus,
		ProductionOpenningDate = #TempData.ProductionOpenningDate,
		ProductionEndDate = #TempData.ProductionEndDate,
		ProjFinalTotalQty = #TempData.ProjFinalTotalQty,               --核算账户销量
		ContractSalesTotalAmt = #TempData.ContractSalesTotalAmt,           --项目产值（截止两月前）
		CurrentContractSalesTotalAmt = #TempData.CurrentContractSalesTotalAmt,    --项目产值（截止今日）
		CurrentProjSalesTotalAmt = #TempData.CurrentProjSalesTotalAmt,        --核算账户产值（截止今日）
		CurrentProjReturnTotalAmt=#TempData.CurrentProjReturnTotalAmt,--核算账户回款（截止今日）

		CurrentContractReturnTotalAmt = #TempData.CurrentContractReturnTotalAmt,   --项目回款（截止今日）
		ContractReturnRate = #TempData.ContractReturnRate,              --项目回款率（截止今日回款/两月前产值）
		CurrentContractReturnRate = #TempData.CurrentContractReturnRate,       --项目回款率实时（截止今日回款/今日产值）

		CurrentContractSettleTotalAmt = #TempData.CurrentContractSettleTotalAmt,   --项目结算金额
		CurrentContractUnSettleTotalAmt = #TempData.CurrentContractUnSettleTotalAmt, --项目未结算金额

		CurrentProjSettleTotalAmt = #TempData.CurrentProjSettleTotalAmt,       --核算账户结算金额
		CurrentProjUnSettleTotalAmt = #TempData.CurrentProjUnSettleTotalAmt,     --核算账户未结算金额
		ReturnNewPeriodID = #TempData.ReturnNewPeriodID
	FROM ProjectRiskRelationInfo prri WITH (NOLOCK)
		LEFT JOIN #TempData
			ON #TempData.ProjectID = prri.ProjectID;

	INSERT INTO dbo.ProjectRiskRelationInfo
	(
		FGC_CreateDate,
		FGC_LastModifyDate,
		ProjectID,
		ContractSignStatus,
		ProductionOpenningDate,
		ProductionEndDate,
		ProjFinalTotalQty,               --核算账户销量
		ContractSalesTotalAmt,           --项目产值（截止两月前）
		CurrentContractSalesTotalAmt,    --项目产值（截止今日）
		CurrentProjSalesTotalAmt,        --核算账户产值（截止今日）
		CurrentProjReturnTotalAmt,	--核算账户回款（截止今日）

		CurrentContractReturnTotalAmt,   --项目回款（截止今日）
		ContractReturnRate,              --项目回款率（截止今日回款/两月前产值）
		CurrentContractReturnRate,       --项目回款率实时（截止今日回款/今日产值）

		CurrentContractSettleTotalAmt,   --项目结算金额
		CurrentContractUnSettleTotalAmt, --项目未结算金额

		CurrentProjSettleTotalAmt,       --核算账户结算金额
		CurrentProjUnSettleTotalAmt,     --核算账户未结算金额
		ReturnNewPeriodID
	)
	SELECT GETDATE(),
		   GETDATE(),
		   ProjectID,
		   ContractSignStatus,
		   ProductionOpenningDate,
		   ProductionEndDate,
		   ProjFinalTotalQty,
		   ContractSalesTotalAmt,           --项目产值（截止两月前）
		   CurrentContractSalesTotalAmt,    --项目产值（截止今日）
		   CurrentProjSalesTotalAmt,        --核算账户产值（截止今日）
		   CurrentProjReturnTotalAmt,    --核算账户回款（截止今日）

		   CurrentContractReturnTotalAmt,   --项目回款（截止今日）
		   ContractReturnRate,              --项目回款率（截止今日回款/两月前产值）
		   CurrentContractReturnRate,       --项目回款率实时（截止今日回款/今日产值）

		   CurrentContractSettleTotalAmt,   --项目结算金额
		   CurrentContractUnSettleTotalAmt, --项目未结算金额

		   CurrentProjSettleTotalAmt,       --核算账户结算金额
		   CurrentProjUnSettleTotalAmt,     --核算账户未结算金额
		   ReturnNewPeriodID
	FROM #TempData
	WHERE NOT EXISTS
	(
		SELECT 1
		FROM ProjectRiskRelationInfo prri WITH (NOLOCK)
		WHERE prri.ProjectID = #TempData.ProjectID
	);

END;

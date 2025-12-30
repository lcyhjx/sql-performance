--SET QUOTED_IDENTIFIER ON|OFF
--SET ANSI_NULLS ON|OFF
--GO
/*
Creator:wangshiyu
Createdate:20221228
desc：每月15，巡检在建项目未办理结算；每月1号停供前再次巡检
*/
CREATE PROCEDURE [dbo].[usp_CheckProjectRiskWarn_Settlement] 
@Type INT=1, --1巡检 2停供 3发起审批前巡检风险是否存在
@ProjectID BIGINT=NULL
AS
BEGIN
    /*1.15号检索  11月（含11月）之前所有有打土记录 且截止到1.15号无签回结算单的核算账户，在2.1停供*/
    /*每月1号停供检索  2.1检索11月（含11月）之前所有有打土记录，3.1检索12月（含12月）之前所有有打土记录*/

    DECLARE @EndDate DATETIME;
    IF (@Type = 1)
        SET @EndDate = DATEADD(s, -1, DATEADD(MM, DATEDIFF(M, 0, GETDATE()) - 1, 0)); --上上个月底（上上月底打土的 上月结算）
    ELSE
        SET @EndDate = DATEADD(s, -1, DATEADD(MM, DATEDIFF(M, 0, GETDATE()) - 2, 0)); --停供巡检上上上月底（因为停供时间在巡检时间的次月1号）

    /*Step1:检索11月之前所有有打土记录的核算账户*/
    SELECT details.ProjectID,
           MAX(details.ReceiptDate) ENDDate,
           DATEADD(MONTH, +1, DATEADD(DAY, 1 - DAY(MIN(GETDATE())), GETDATE())) StopDate --当前时间的下月1号停供（1.15巡检，2.1停供）
    INTO #TempProduct
    FROM ProductionDailyReportDetails details WITH (NOLOCK)
        LEFT JOIN dbo.ProductionDailyReports reports WITH (NOLOCK)
            ON details.DailyReportID = reports.ID
        --LEFT JOIN dbo.Periods WITH (NOLOCK)
        --    ON details.ReceiptDate
        --       BETWEEN Periods.StartDate AND EndDate
    WHERE reports.isDeleted = 0
		  AND reports.ReportDate>='2022-06-01'
          AND details.ProjectID IS NOT NULL
          AND details.ReceiptDate <= @EndDate
		  AND details.Type IN (SELECT col FROM dbo.f_split((SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),','))
    GROUP BY details.ProjectID
             --,Periods.ID
    HAVING SUM(   CASE
                      WHEN details.Unit = '吨' THEN
                          ISNULL(details.FinalQty_T, 0)
                      ELSE
                          ISNULL(details.FinalQty_M3, 0)
                  END
              ) > 0;

    --单核算账户发起审批前巡检一次
	IF (@ProjectID != NULL)
	BEGIN
	 DELETE FROM #TempProduct WHERE ProjectID!=@ProjectID
	END

    /*Step2:检索存在风险的核算账户*/
    SELECT DISTINCT
           #TempProduct.ProjectID,
		   ISNULL(Project.EnableUserPlan, 1)EnableUserPlan,
           StopDate
    INTO #TempData
    FROM #TempProduct
        --LEFT JOIN dbo.Periods WITH (NOLOCK)
        --    ON #TempProduct.PeriodID = Periods.ID
        LEFT JOIN dbo.Project WITH (NOLOCK)
            ON #TempProduct.ProjectID = Project.ID
        OUTER APPLY
        (
            SELECT TOP 1
                   Receivedby
            FROM SalesStatements WITH (NOLOCK)
            WHERE isDeleted = 0
			AND SalesStatements.ProjectID = #TempProduct.ProjectID  AND #TempProduct.ENDDate BETWEEN SalesStatements.FromDate AND SalesStatements.ToDate
			ORDER BY ID DESC
        ) SalesStatements
    WHERE  ISNULL(SalesStatements.Receivedby,'')=''
          --AND Periods.ID >= 30
          --AND Project.AgentID IS NULL
          AND Project.Type = 1
          --AND ISNULL(Project.EnableUserPlan, 1) = 1
          AND Project.AccountingPaymentType <> '现金'
		  AND ISNULL(Project.isPartnerProjFinished,0)=0;

    --DELETE FROM #TempData
    --WHERE ProjectID NOT IN ( 137770, 137771,137787 );

    /*Step3：巡检增加警告*/
    IF @Type = 1
    BEGIN
        UPDATE ProjectRiskWarn
        SET IsDeleted = 1
        WHERE RiskType = 2
              AND IsDeleted = 0;
        INSERT INTO dbo.ProjectRiskWarn
        (
            FGC_CreateDate,
            FGC_LastModifyDate,
            ProjectID,
            RiskType,
            WarnTime,
            IsDeleted,
            WarnType
        )
        SELECT GETDATE() FGC_CreateDate,
               GETDATE() FGC_LastModifyDate,
               ProjectID,
               2 RiskType,
               GETDATE() WarnTime,
               0 IsDeleted,
               1 WarnType
        FROM #TempData WHERE ISNULL(EnableUserPlan, 1) = 1;

        INSERT INTO dbo.ProjectRisk
        (
            FGC_CreateDate,
            FGC_LastModifyDate,
            ProjectID,
            RiskType,
            IsWarn,
            WarnDate,
            FirstStopDate,
            FirstStopQty,
            ApplyDelayDays,
            ApplySupplyTotalQty,
            NewStopDate,
            NewStopQty,
            IsStop,
            IsDeleted,
            WarnType
        )
        SELECT GETDATE() FGC_CreateDate,
               GETDATE() FGC_LastModifyDate,
               ProjectID,
               2 RiskType,
               0 IsWarn,
               NULL WarnDate,
               StopDate FirstStopDate,
               NULL FirstStopQty,
               NULL ApplyDelayDays,
               NULL ApplySupplyTotalQty,
               StopDate NewStopDate,
               NULL NewStopQty,
               0 IsStop,
               0 IsDeleted,
               1 WarnType
        FROM #TempData
        WHERE ISNULL(EnableUserPlan, 1) = 1 AND NOT EXISTS
        (
            SELECT 1
            FROM dbo.ProjectRisk
            WHERE ProjectID = #TempData.ProjectID
                  AND IsDeleted = 0
                  AND RiskType = 2
                  AND WarnType = 1
        );

    END;
    ELSE IF(@Type=2) --1号巡检依旧异常就停供，不异常就删除之前的停供风险数据
	BEGIN
        UPDATE pr
        SET IsStop = 1
        FROM ProjectRisk pr WITH (NOLOCK)
            INNER JOIN #TempData
                ON #TempData.ProjectID = pr.ProjectID
                   AND pr.RiskType = 2
                   AND WarnType = 1
                   AND pr.IsStop = 0
                   AND IsDeleted = 0
                   AND DATEDIFF(DAY, pr.NewStopDate, GETDATE()) >= 0;
        UPDATE pr
        SET pr.IsDeleted = 1
        FROM ProjectRisk pr WITH (NOLOCK)
        WHERE pr.RiskType = 2
              AND IsDeleted = 0
              AND DATEDIFF(DAY, pr.NewStopDate, GETDATE()) >= 0
              AND NOT EXISTS
        (
            SELECT 1 FROM #TempData WHERE #TempData.ProjectID = pr.ProjectID
        );
    END
	ELSE --单核算账户发起审批前再巡检一次是否存在风险  不存在就把风险删除
	BEGIN
		UPDATE pr
        SET pr.IsDeleted = 1
        FROM ProjectRisk pr WITH (NOLOCK)
        WHERE pr.RiskType = 2
              AND IsDeleted = 0
             -- AND DATEDIFF(DAY, pr.NewStopDate, GETDATE()) >= 0
              AND NOT EXISTS
        (
            SELECT 1 FROM #TempData WHERE #TempData.ProjectID = pr.ProjectID
        );
	END
END;

--SET QUOTED_IDENTIFIER ON|OFF
--SET ANSI_NULLS ON|OFF
--GO
/*
Creator:wangshiyu
Createdate:20221228
desc：每天巡检在建项目未签合同风险的数据
*/
CREATE PROCEDURE [dbo].[usp_CheckProjectRiskWarn_Contract]
    @Type INT = 1, --1巡检 2停供 3发起审批前巡检风险是否存在
    @ProjectID BIGINT = NULL
AS
BEGIN
    /*Step1：查询所有核算账户的第一次打土时间*/
    SELECT prod.*,
           ISNULL(ProjFinalTotalQty, 0) FinalQty
    INTO #TempProduct
    FROM
    (
        SELECT details.ProjectID,
               MIN(details.ReceiptDate) OpenningDate,
               SUM(ISNULL(details.Unpaid, 0)) unpaid
        FROM ProductionDailyReportDetails details WITH (NOLOCK)
            LEFT JOIN dbo.ProductionDailyReports reports WITH (NOLOCK)
                ON details.DailyReportID = reports.ID
        WHERE reports.isDeleted = 0
              AND details.ProjectID IS NOT NULL
			  AND details.Type IN (SELECT col FROM dbo.f_split((SELECT ParaValue FROM dbo.Parameters WHERE ParaName='ProjectSalesTypeFilter'),','))
        GROUP BY details.ProjectID
        HAVING SUM(   CASE
                          WHEN details.Unit = '吨' THEN
                              ISNULL(details.FinalQty_T, 0)
                          ELSE
                              ISNULL(details.FinalQty_M3, 0)
                      END
                  ) > 0
    ) prod
        LEFT JOIN dbo.ProjectRiskRelationInfo WITH (NOLOCK)
            ON prod.ProjectID = ProjectRiskRelationInfo.ProjectID;

    --单核算账户发起审批前巡检一次
    IF (@ProjectID != NULL)
    BEGIN
        DELETE FROM #TempProduct
        WHERE ProjectID != @ProjectID;
    END;

    /*Step2：查询存在风险的核算账户*/
    SELECT *
    INTO #TempProjdata
    FROM
    (
        SELECT p.*,
               c.CorpType
        FROM dbo.Project p WITH (NOLOCK)
            INNER JOIN dbo.SalesContracts c WITH (NOLOCK)
                ON p.SalesContractID = c.ID
        WHERE p.Type = 1
              AND p.AccountingPaymentType <> '现金'
              AND ISNULL(p.isPartnerProjFinished, 0) = 0
              AND p.AgentID IS NULL
              AND LTRIM(RTRIM(ISNULL(c.SignStatus, ''))) NOT IN ( '已签', '付清', '此合同号作废' )
        UNION
        SELECT p.*,
               c.CorpType
        FROM dbo.Project p WITH (NOLOCK)
            INNER JOIN dbo.SalesContracts c WITH (NOLOCK)
                ON p.SalesContractID = c.ID
        WHERE p.Type = 1
              AND p.AccountingPaymentType <> '现金'
              AND ISNULL(p.isPartnerProjFinished, 0) = 0
              AND p.AgentID IS NOT NULL
              AND LTRIM(RTRIM(ISNULL(p.AgentAgreementSignStatus, ''))) NOT IN ( '已签' )
    ) projdata;



    --国企在打土开始的第90-15或90-3天触发警告，第90天停供 (如果已经有最新的延期时间就用延期时间来比较)
    --私企在打土开始的第60-15或60-3天触发警告，第60天停供 (如果已经有最新的延期时间就用延期时间来比较)
    SELECT p.CorpType,
           p.ID ProjectID,
           ISNULL(p.EnableUserPlan, 1) EnableUserPlan,
           p.Number,
           p.ProjectName,
           p.SalesDepartment,
           p.Salesman,
           p.AccountingPaymentType,
           p.ProductCategory CategoryName,
           #TempProduct.OpenningDate,
           ISNULL(   ProjectRisk.NewStopDate,
                     #TempProduct.OpenningDate + (CASE
                                                      WHEN p.CorpType = '国企' THEN
                                                          90
                                                      ELSE
                                                          60
                                                  END
                                                 )
                 ) StopDate
    INTO #Temp1
    FROM #TempProjdata p WITH (NOLOCK)
        INNER JOIN #TempProduct
            ON #TempProduct.ProjectID = p.ID
        LEFT JOIN
        (
            SELECT ProjectID,
                   MAX(NewStopDate) NewStopDate
            FROM dbo.ProjectRisk
            WHERE RiskType = 1
                  AND WarnType = 1
                  AND IsDeleted = 0
                  AND IsStop = 0
            GROUP BY ProjectID
        ) ProjectRisk
            ON ProjectRisk.ProjectID = p.ID;
    /*Step3：查询按量风险的核算账户*/

    --砂浆（包含特种砼）供应量>=【1000(有最新的供应量就用最新的)-500】吨
    --混凝土达到>=【2000(有最新的供应量就用最新的)-100】方
    SELECT p.CorpType,
           p.ID ProjectID,
           ISNULL(p.EnableUserPlan, 1) EnableUserPlan,
           p.Number,
           p.ProjectName,
           p.SalesDepartment,
           p.Salesman,
           p.AccountingPaymentType,
           p.ProductCategory CategoryName,
           FinalQty,
           ISNULL(   NewStopQty,
                     CASE
                         WHEN p.ProductCategory IN ( '砂浆', '干混砂浆', '陶粒', '透水' ) THEN
                             1000
                         WHEN p.ProductCategory IN ( '普混' ) THEN
                             2000
                         ELSE
                             0
                     END
                 ) StopQty
    INTO #Temp2
    FROM #TempProjdata p WITH (NOLOCK)
        INNER JOIN #TempProduct
            ON #TempProduct.ProjectID = p.ID
        LEFT JOIN
        (
            SELECT ProjectID,
                   MAX(NewStopQty) NewStopQty
            FROM dbo.ProjectRisk
            WHERE RiskType = 1
                  AND WarnType = 2
                  AND IsDeleted = 0
                  AND IsStop = 0
            GROUP BY ProjectID
        ) ProjectRisk
            ON ProjectRisk.ProjectID = p.ID;

    /*Step5：添加数据到警告表*/
    IF @Type = 1
    BEGIN
        /*今天需要发警告的数据*/
        SELECT *
        INTO #Temp1Warn
        FROM #Temp1
        WHERE ISNULL(EnableUserPlan, 1) = 1
              AND
              (
                  DATEDIFF(DAY, (StopDate - 15), GETDATE()) = 0
                  OR DATEDIFF(DAY, (StopDate - 3), GETDATE()) = 0
              );

        SELECT *
        INTO #Temp2Warn
        FROM #Temp2
        WHERE ISNULL(EnableUserPlan, 1) = 1
              AND (StopQty - FinalQty) <= (CASE
                                               WHEN CategoryName IN ( '砂浆', '干混砂浆', '陶粒', '透水' ) THEN
                                                   500
                                               WHEN CategoryName IN ( '普混' ) THEN
                                                   1000
                                               ELSE
                                                   0
                                           END
                                          );

        UPDATE ProjectRiskWarn
        SET IsDeleted = 1
        WHERE RiskType = 1
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
        SELECT FGC_CreateDate = GETDATE(),
               FGC_LastModifyDate = GETDATE(),
               ProjectID,
               1 RiskType,
               GETDATE() WarnTime,
               0 IsDeleted,
               1 WarnType
        FROM #Temp1Warn
        UNION ALL
        SELECT FGC_CreateDate = GETDATE(),
               FGC_LastModifyDate = GETDATE(),
               ProjectID,
               1 RiskType,
               GETDATE() WarnTime,
               0 IsDeleted,
               2 WarnType
        FROM #Temp2Warn;

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
               1 RiskType,
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
        FROM #Temp1Warn
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.ProjectRisk
            WHERE ProjectID = #Temp1Warn.ProjectID
                  AND IsDeleted = 0
                  AND RiskType = 1
                  AND WarnType = 1
        )
        UNION ALL
        SELECT GETDATE() FGC_CreateDate,
               GETDATE() FGC_LastModifyDate,
               ProjectID,
               1 RiskType,
               0 IsWarn,
               NULL WarnDate,
               NULL FirstStopDate,
               StopQty FirstStopQty,
               NULL ApplyDelayDays,
               NULL ApplySupplyTotalQty,
               NULL NewStopDate,
               StopQty NewStopQty,
               0 IsStop,
               0 IsDeleted,
               2 WarnType
        FROM #Temp2Warn
        WHERE NOT EXISTS
        (
            SELECT 1
            FROM dbo.ProjectRisk
            WHERE ProjectID = #Temp2Warn.ProjectID
                  AND IsDeleted = 0
                  AND RiskType = 1
                  AND WarnType = 2
        );
    END;
    ELSE IF (@Type = 2) --巡检依旧异常就停供，不异常就删除之前的停供风险数据
    BEGIN
        UPDATE pr
        SET IsStop = 1
        FROM ProjectRisk pr WITH (NOLOCK)
            INNER JOIN #Temp1
                ON #Temp1.ProjectID = pr.ProjectID
                   AND pr.RiskType = 1
                   AND WarnType = 1
                   AND pr.IsStop = 0
                   AND IsDeleted = 0
                   AND DATEDIFF(DAY, pr.NewStopDate, GETDATE()) >= 0;

        UPDATE pr
        SET IsStop = 1
        FROM ProjectRisk pr WITH (NOLOCK)
            INNER JOIN #Temp2
                ON #Temp2.ProjectID = pr.ProjectID
                   AND pr.RiskType = 1
                   AND WarnType = 2
                   AND pr.IsStop = 0
                   AND IsDeleted = 0
                   AND FinalQty >= pr.NewStopQty;


        UPDATE pr
        SET pr.IsDeleted = 1
        FROM ProjectRisk pr WITH (NOLOCK)
        WHERE pr.RiskType = 1
              AND IsDeleted = 0
              AND EXISTS
        (
            SELECT 1
            FROM dbo.Project p WITH (NOLOCK)
                LEFT JOIN dbo.SalesContracts sc WITH (NOLOCK)
                    ON p.SalesContractID = sc.ID
            WHERE p.AgentID IS NULL
                  AND p.isDeleted = 0
                  AND sc.isDeleted = 0
                  AND p.ID = pr.ProjectID
                  AND LTRIM(RTRIM(ISNULL(sc.SignStatus, ''))) IN ( '已签', '付清', '此合同号作废' )
        );
        UPDATE pr
        SET pr.IsDeleted = 1
        FROM ProjectRisk pr WITH (NOLOCK)
        WHERE pr.RiskType = 1
              AND IsDeleted = 0
              AND EXISTS
        (
            SELECT 1
            FROM dbo.Project p WITH (NOLOCK)
            WHERE p.AgentID IS NOT NULL
                  AND p.isDeleted = 0
                  AND p.ID = pr.ProjectID
                  AND LTRIM(RTRIM(ISNULL(p.AgentAgreementSignStatus, ''))) IN ( '已签' )
        );

    END;
    ELSE --单核算账户发起审批前再巡检一次是否存在风险  不存在就把风险删除
    BEGIN
        UPDATE pr
        SET pr.IsDeleted = 1
        FROM ProjectRisk pr WITH (NOLOCK)
        WHERE pr.RiskType = 1
              AND IsDeleted = 0
              AND EXISTS
        (
            SELECT 1
            FROM dbo.Project p WITH (NOLOCK)
                LEFT JOIN dbo.SalesContracts sc WITH (NOLOCK)
                    ON p.SalesContractID = sc.ID
            WHERE p.AgentID IS NULL
                  AND p.isDeleted = 0
                  AND sc.isDeleted = 0
                  AND p.ID = pr.ProjectID
                  AND LTRIM(RTRIM(sc.SignStatus)) IN ( '已签', '付清', '此合同号作废' )
        );
        UPDATE pr
        SET pr.IsDeleted = 1
        FROM ProjectRisk pr WITH (NOLOCK)
        WHERE pr.RiskType = 1
              AND IsDeleted = 0
              AND EXISTS
        (
            SELECT 1
            FROM dbo.Project p WITH (NOLOCK)
            WHERE p.AgentID IS NOT NULL
                  AND p.isDeleted = 0
                  AND p.ID = pr.ProjectID
                  AND LTRIM(RTRIM(p.AgentAgreementSignStatus)) IN ( '已签' )
        );

    END;
END;


-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE PROCEDURE [dbo].[usp_UpdateProjectProgess]
AS
BEGIN

    /*
		1.如果没有生产记录 且 工程核算账户进展为空——未开工
		2.如果有生产记录 且最近一条的生产日期在3个月内 且工程核算账户进展 in（NULL, '停工', '完工', '未开工'）——在建
		3.如果有生产记录 且最近一条的生产日期不在3个月内 且工程核算账户进展 in（NULL, '停工', '在建', '未开工'）——完工
		其他情况  不修改
		*/
    SELECT *
    INTO #temp
    FROM
    (
        SELECT ROW_NUMBER() OVER (PARTITION BY ProjectID ORDER BY ReceiptDate DESC) num,
               ProjectID,
               ReceiptDate,
               ID
        FROM ProductionDailyReportDetails WITH (NOLOCK)
        WHERE Type IN
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
    ) x
    WHERE x.num = 1;

    /*
        SELECT  p.ID ,
                p.ProjectProgess ,
                report.ID ,
                report.ReceiptDate ,
                CASE WHEN report.ID IS NULL
                          AND ISNULL(p.ProjectProgess, '') = '' THEN '未开工'
                     WHEN report.ID IS NOT NULL
                          AND report.ReceiptDate >= GETDATE() - 90
                          AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '完工',
                                                              '未开工' )
                     THEN '在建'
                     WHEN report.ID IS NOT NULL
                          AND report.ReceiptDate <= GETDATE() - 90
                          AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '在建',
                                                              '未开工' )
                     THEN '完工'
                     ELSE p.ProjectProgess
                END
        FROM    dbo.Project p WITH ( NOLOCK )
                LEFT JOIN #temp report ON p.ID = report.ProjectID
        WHERE   isDeleted != 1
                AND Status != 1; 
		*/
    UPDATE p
    SET p.ProjectProgess = CASE
                               WHEN report.ID IS NULL
                                    AND ISNULL(p.ProjectProgess, '') = '' THEN
                                   '未开工'
                               WHEN report.ID IS NOT NULL
                                    AND report.ReceiptDate >= GETDATE() - 90
                                    AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '完工', '未开工' ) THEN
                                   '在建'
                               WHEN report.ID IS NOT NULL
                                    AND report.ReceiptDate <= GETDATE() - 90
                                    AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '在建', '未开工' ) THEN
                                   '完工'
                               ELSE
                                   p.ProjectProgess
                           END,
        p.FinishDate = CASE
                           WHEN report.ID IS NOT NULL
                                AND report.ReceiptDate >= GETDATE() - 90
                                AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '完工', '未开工', '在建' ) THEN
                               NULL
                           WHEN report.ID IS NOT NULL
                                AND report.ReceiptDate <= GETDATE() - 90
                                AND ISNULL(p.ProjectProgess, '') IN ( '', '停工', '在建', '未开工', '完工' ) THEN
                               report.ReceiptDate
                           ELSE
                               p.FinishDate
                       END
    FROM dbo.Project p WITH (NOLOCK)
        LEFT JOIN #temp report
            ON p.ID = report.ProjectID
    WHERE isDeleted != 1
          AND Status != 1
          AND Type = 1;
END;

-- =============================================
-- 优化版本：CashFlowBalance 存储过程
-- 优化方式：使用窗口函数替代游标
-- 预期性能提升：90-95% (从44秒降至2-3秒)
-- 创建日期：2025-12-29
-- =============================================

CREATE PROCEDURE [dbo].[CashFlowBalance_Optimized]
    @beginDate datetime,
    @endDate datetime
AS
BEGIN
    SET NOCOUNT ON;

    -- 选项1：使用 TRUNCATE (如果没有外键约束)
    -- TRUNCATE TABLE BankCashBalance;

    -- 选项2：使用 DELETE WITH TABLOCK (如果有外键约束)
    DELETE FROM BankCashBalance WITH (TABLOCK);

    -- 使用 CTE 和窗口函数替代游标
    WITH InitialBalance AS (
        -- 计算每个账户的期初余额
        -- 这个查询只执行一次，获取所有账户的期初余额
        SELECT
            BankAccountID,
            ISNULL(SUM(ISNULL(IncomeAmt, 0)) - SUM(ISNULL(ExpenditureAmt, 0)), 0) AS IniBalance
        FROM BankCashFlow WITH (NOLOCK)
        WHERE TxnDate < @beginDate
          AND isDeleted = 0
          AND (ifSplited IS NULL OR ifSplited = 1)
        GROUP BY BankAccountID
    ),
    CurrentPeriod AS (
        -- 获取查询期间的所有流水
        -- 只扫描一���表，获取所有相关数据
        SELECT
            BankAccountID,
            id,
            IncomeAmt,
            ExpenditureAmt,
            TxnDate,
            ROW_NUMBER() OVER (PARTITION BY BankAccountID ORDER BY TxnDate, id) AS idd
        FROM BankCashFlow WITH (NOLOCK)
        WHERE TxnDate >= @beginDate
          AND TxnDate <= @endDate
          AND isDeleted = 0
          AND (ifSplited IS NULL OR ifSplited = 1)
    ),
    CumulativeFlow AS (
        -- 使用窗口函数计算累计余额
        -- 这是核心优化：用窗口函数替代循环中的子查询
        SELECT
            cp.id,
            cp.BankAccountID,
            cp.idd,
            cp.IncomeAmt,
            cp.ExpenditureAmt,
            -- 计算累计余额：期初余额 + 累计流水
            ISNULL(ib.IniBalance, 0) +
            SUM(ISNULL(cp.IncomeAmt, 0) - ISNULL(cp.ExpenditureAmt, 0))
                OVER (PARTITION BY cp.BankAccountID ORDER BY cp.idd
                      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS Balance
        FROM CurrentPeriod cp
        LEFT JOIN InitialBalance ib ON cp.BankAccountID = ib.BankAccountID
    )
    -- 一次性插入所有结果
    INSERT INTO BankCashBalance (CashFlowID, idd, BankAccountID, IncomeAmt, ExpenditureAmt, Balance)
    SELECT
        id AS CashFlowID,
        idd,
        BankAccountID,
        IncomeAmt,
        ExpenditureAmt,
        Balance
    FROM CumulativeFlow
    OPTION (MAXDOP 4); -- 限制并行度，根据服务器配置调整

END
GO

-- =============================================
-- 性能测试脚本
-- =============================================

/*
-- 测试原版本
SET STATISTICS TIME ON;
SET STATISTICS IO ON;

EXEC CashFlowBalance '2025-01-01', '2025-12-31';

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;

-- 保存原结果用于对比
SELECT * INTO #OriginalResult FROM BankCashBalance;

-- 测试优化版本
DELETE FROM BankCashBalance;

SET STATISTICS TIME ON;
SET STATISTICS IO ON;

EXEC CashFlowBalance_Optimized '2025-01-01', '2025-12-31';

SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;

-- 验证结果一致性
SELECT
    CASE
        WHEN NOT EXISTS (
            SELECT CashFlowID, Balance FROM #OriginalResult
            EXCEPT
            SELECT CashFlowID, Balance FROM BankCashBalance
        ) AND NOT EXISTS (
            SELECT CashFlowID, Balance FROM BankCashBalance
            EXCEPT
            SELECT CashFlowID, Balance FROM #OriginalResult
        )
        THEN '结果一致 ✓'
        ELSE '结果不一致 ✗ - 需要检查'
    END AS ValidationResult;

-- 详细对比
SELECT
    o.CashFlowID,
    o.Balance AS OriginalBalance,
    n.Balance AS OptimizedBalance,
    CASE
        WHEN ABS(o.Balance - n.Balance) > 0.01 THEN '差异'
        ELSE '一致'
    END AS Status
FROM #OriginalResult o
FULL OUTER JOIN BankCashBalance n ON o.CashFlowID = n.CashFlowID
WHERE o.CashFlowID IS NULL OR n.CashFlowID IS NULL OR ABS(o.Balance - n.Balance) > 0.01;

DROP TABLE #OriginalResult;
*/

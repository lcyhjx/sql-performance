-- =============================================
-- Author:		<Author,,Name>
-- Create date: <Create Date,,>
-- Description:	<Description,,>
-- =============================================
CREATE PROCEDURE [dbo].[CashFlowBalance]
	-- Add the parameters for the stored procedure here
	@beginDate datetime ,@endDate datetime
AS
BEGIN
	-- SET NOCOUNT ON added to prevent extra result sets from
	-- interfering with SELECT statements.
	SET NOCOUNT ON;

--DECLARE @beginDate datetime,@endDate datetime
DECLARE @BankAccountID bigint
DECLARE @IniBalance FLOAT
declare @in float,@exp FLOAT

--DECLARE @beginDate DATETIME
--DECLARE @endDate DATETIME
 
--SET @IniBalance = 0
--SET @beginDate = '2020-11-26'
--SET @endDate = '2021-11-26'

--select @beginDate = isnull(@beginDate,CONVERT(varchar(100), GETDATE(), 23))
--select @endDate = isnull(@endDate,CONVERT(varchar(100), GETDATE(), 23))

/*
if OBJECT_ID('tempdb..#bal') is not null 
begin
  drop table #bal
end
create table #bal(id bigint,idd int,IncomeAmt float,ExpenditureAmt float,Balance float,BankAccountID bigint)
*/

DELETE FROM BankCashBalance
declare @currentCashFlow table (id bigint,idd int,IncomeAmt float,ExpenditureAmt float,BankAccountID bigint)
-----------------------------------

DECLARE bank_cursor CURSOR FOR
 select BankAccountID from BankCashFlow group by BankAccountID
OPEN bank_cursor
 -- 首先提取第一行数据，并将结果保存到局部变量中
FETCH NEXT FROM bank_cursor 
INTO @BankAccountID
WHILE @@FETCH_STATUS = 0
BEGIN
  --获取查询期间前的现金余额
  select @IniBalance = isnull(sum(isnull(IncomeAmt,0)) - sum(isnull(ExpenditureAmt,0)),0)
  from BankCashFlow
  where BankAccountID = @BankAccountID and TxnDate < @beginDate  and isDeleted = 0 and (ifSplited is null or ifSplited = 1)


  --select @in = IncomeAmt,@exp = ExpenditureAmt
  --from BankCashFlow
  --where  id = (select min(id) from BankCashFlow where BankAccountID = @BankAccountID  and TxnDate <= @endDate) and isDeleted = 0

  --set @IniBalance = @IniBalance +ISNULL(@in,0) - ISNULL(@exp,0)
  delete from @currentCashFlow
  
  --获取查询区间的现金流水记录
  insert into @currentCashFlow (idd,IncomeAmt,ExpenditureAmt,id,BankAccountID)
  select  ROW_NUMBER() over (order by TxnDate,id) idd ,IncomeAmt,ExpenditureAmt,id,BankAccountID
  from BankCashFlow 
  where BankAccountID = @BankAccountID and (TxnDate >= @beginDate and TxnDate <= @endDate) and isDeleted = 0 and (ifSplited is null or ifSplited = 1)

  --获取第一条记录的收入和支出金额
   SELECT @in = IncomeAmt,@exp = ExpenditureAmt
   FROM @currentCashFlow 
   where idd = 1
   
   --计算查询期第一条记录的余额
   set @IniBalance = @IniBalance +ISNULL(@in,0) - ISNULL(@exp,0)

  --;with cte as( select  ROW_NUMBER() over (order by TxnDate,id) idd ,IncomeAmt,ExpenditureAmt,id,BankAccountID
  --from BankCashFlow 
  --where BankAccountID = @BankAccountID and (TxnDate >= @beginDate and TxnDate <= @endDate) and isDeleted = 0)

  --计算查询期间的余额
  insert into BankCashBalance (CashFlowID,idd,BankAccountID,IncomeAmt,ExpenditureAmt,Balance)
  select id,idd,BankAccountID,
  IncomeAmt,ExpenditureAmt,
  b = case idd when  1 then @IniBalance else (select @IniBalance + sum(isnull(IncomeAmt,0))-sum(isnull(ExpenditureAmt,0)) from @currentCashFlow where idd between 2 and t.idd) end
  from @currentCashFlow t

  /*
  insert into #bal(id,idd,BankAccountID,IncomeAmt,ExpenditureAmt,Balance)
  select id,idd,BankAccountID,
  IncomeAmt,ExpenditureAmt,
  b = case idd when  1 then @IniBalance else (select @IniBalance + sum(isnull(IncomeAmt,0))-sum(isnull(ExpenditureAmt,0)) from cte where idd between 2 and t.idd) end
  from cte t
  */

   --提取下一行数据
   FETCH NEXT FROM bank_cursor 
   INTO  @BankAccountID
END
CLOSE bank_cursor 
DEALLOCATE bank_cursor

END

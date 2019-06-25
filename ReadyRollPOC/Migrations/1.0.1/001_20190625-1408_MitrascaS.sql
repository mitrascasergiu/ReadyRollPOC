-- <Migration ID="746588d5-ce31-46cd-80f7-fecd70c76eb4" />
GO


GO
PRINT N'Altering [dbo].[ib_EquityCash_Select]...';


GO
/*
Programmer:  Bruce McQuien	
Description:  Selects cash records from ib_equitycash.
Date:  28/11/2006
*/

--test sergiu

ALTER PROC dbo.ib_EquityCash_Select
@EquityHeaderId int,
@InternalExternalCode char(1)

AS
SET NOCOUNT ON


SELECT [Description]
      ,[Amount]
	  ,[InternalExternalCode] 
FROM [dbo].[ib_EquityCash]
WHERE EquityHeaderId = @EquityHeaderId
AND InternalExternalCode = @InternalExternalCode
GO


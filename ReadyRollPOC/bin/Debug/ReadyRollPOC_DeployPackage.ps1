$SqlCmdVariables = @{
}
$TargetDatabase = 'i-Balancer'
$OctoOptionDeployToLocalInstance = ''
$SkipVariableValidation = ''
$__isAzurePlatformTarget = 'False'
$CreateScriptFileName = 'ReadyRollPOC_Package.sql'
$SnapshotPackageFileName = 'ReadyRollPOC_Snapshot.nupkg.bin'
$MigrationLogSchemaName = 'dbo'
function Get-SqlScalarValue($variableName, $ConnectionString, $scalarQuery) {
  try {
    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString
    $SqlConnection.Open()
    $SqlCmd = New-Object System.Data.SqlClient.SqlCommand
    $SqlCmd.CommandText = $scalarQuery
    $SqlCmd.Connection = $sqlConnection
    $scalarValue = [string]$SqlCmd.ExecuteScalar()
    if ($scalarValue -eq '') {
      Write-Warning "Could not determine a value for $variableName variable. An empty string will be supplied to the deployment."
    }
    $SqlConnection.Close()
    return $scalarValue
  }
  catch {
    Write-Warning "Could not retrieve a value for ${variableName}: $_ "
    return ""
  }
}
function Get-ScriptDirectory {
  $Invocation = (Get-Variable MyInvocation -Scope 1).Value
  Split-Path $Invocation.MyCommand.Path
}

try {
  if ($ReleaseVersion -eq $null) {
    $ReleaseVersion = '';
    if ($OctopusEnvironmentName -eq $null) {
      Write-Warning 'As the ReleaseVersion variable is not set, the [__MigrationLog].[release_version] column will be set to NULL for any pending migrations.'
    }
  }
  if ($OctopusReleaseNumber -ne $null) { $ReleaseVersion = $OctopusReleaseNumber }
  if ($DeployPath -eq $null) { $DeployPath = (Get-ScriptDirectory).TrimEnd('\') + '\' }
  if ($SkipOctopusVariableValidation -ne $null) { $SkipVariableValidation = $SkipOctopusVariableValidation }
  if ($UseSqlCmdVariableDefaults -eq $null) { $UseSqlCmdVariableDefaults = "true" }
  if ($UseSqlCmdVariableDefaults -eq "true") {
    Write-Output 'If you require that all SqlCmd variable values be passed in explicitly, specify UseSqlCmdVariableDefaults=False.'
    foreach ($kvp in $SqlCmdVariables.GetEnumerator()) {
      $identity = $kvp.Name
      $default = $kvp.Value
      $currentValue = Get-Variable $identity -ValueOnly -ErrorAction SilentlyContinue
      if ($identity -ne '') {
        if ($currentValue -eq $null) {
          Write-Output "Using default value for $identity variable: $default"
          New-Variable $identity $default
        }
      }
    }
    if ($TargetDatabase -ne '') {
      if ($DatabaseName -eq $null) {
      Write-Output "Using default value for DatabaseName variable: $TargetDatabase"
      $DatabaseName=$TargetDatabase.Replace("'", "''")
      }
    }
    if ($ForceDeployWithoutBaseline -eq $null) {
      Write-Output 'Using default value for ForceDeployWithoutBaseline variable: False'
      $ForceDeployWithoutBaseline = 'False'
    }
    if ($OctoOptionDeployToLocalInstance) {
      if ($DatabaseServer -eq $null -and $OctoOptionDeployToLocalInstance -ne "false") {
        Write-Output '**Deploying to (local) because OctoOptionDeployToLocalInstance=True'
        $DatabaseServer='(local)'
      }
    }
  }

  if ($SkipVariableValidation -ne $true) {
    if ($DatabaseServer -eq $null) {
      Throw 'DatabaseServer variable was not provided.'
    }
    if ($DatabaseName -eq $null) {
      Throw 'DatabaseName variable was not provided.'
    }
    if ($ForceDeployWithoutBaseline -eq $null) {
      Throw 'ForceDeployWithoutBaseline variable was not provided.'
    }
    foreach ($kvp in $SqlCmdVariables.GetEnumerator()) {
      $identity = $kvp.Name
      $currentValue = Get-Variable $identity -ValueOnly -ErrorAction SilentlyContinue
      if ($currentValue -eq $null) {
        Throw "$identity variable was not provided"
      }
    }
  }

  if ($__isAzurePlatformTarget -eq $false) {
    if ($UseWindowsAuth -eq $null) {
      $UseWindowsAuth = $true
    }
  }
  if ($UseWindowsAuth -eq $true) {
      Write-Output 'Using Windows Authentication'
    $SqlCmdAuth = '-E'
    $ConnectionString = 'Data Source=' + $DatabaseServer + ';Integrated Security=SSPI';
  }
  else {
    if ($DatabaseUserName -eq $null) {
      Throw 'As SQL Server Authentication is to be used, please specify values for the DatabaseUserName and DatabasePassword variables. Alternately, specify UseWindowsAuth=True to use Windows Authentication instead.'
    }
    if ($DatabasePassword -eq $null) {
      Throw 'If a DatabaseUserName is specified, the DatabasePassword variable must also be provided.'
    }
    Write-Output 'Using SQL Server Authentication'
    $SqlCmdAuth = '-U "' + $DatabaseUserName.Replace('"', '""') + '" '; $env:SQLCMDPASSWORD=$DatabasePassword; $ConnectionString = 'Data Source=' + $DatabaseServer + ';User Id=' + $DatabaseUserName + ';Password=' + $DatabasePassword;
  }

  $__isAzureDatabaseServer = $false
  if ((Get-SqlScalarValue "isAzureDatabaseServer" $ConnectionString ("select SERVERPROPERTY('EngineEdition')")) -eq 5) {
    $__isAzureDatabaseServer = $true
    if ($__isAzurePlatformTarget -eq $false) {
      Write-Warning "The server is Microsoft Azure SQL Database but the project is set to target SQL Server. This mismatch may result in deployment failure. To resolve, open the project in Visual Studio and adjust the Target Platform setting in the project designer to Microsoft Azure SQL Database."
    }
  }

  $__databaseExists = $false
  $__autoCreateDatabase = $false
  if ((Get-SqlScalarValue "databaseExists" $ConnectionString ("select count(*) from sys.databases where name = '" + $DatabaseName.Replace("'", "''") + "'")) -ne 0) {
    $__databaseExists = $true
  }
  elseif ($__isAzurePlatformTarget -eq $true) {
    $__autoCreateDatabase = $true
  }

  if ($__isAzureDatabaseServer -eq $true) {
    $DefaultFilePrefix = ""
    $DefaultDataPath = ""
    $DefaultLogPath = ""
    $DefaultBackupPath = ""
  }
  else {
    if ($DefaultFilePrefix -eq $null) {
      Write-Output "Using default value for DefaultFilePrefix variable: $TargetDatabase"
      $DefaultFilePrefix = $TargetDatabase.Replace("'", "''")
    }
    if ($DefaultDataPath -eq $null) {
      $DefaultDataPath = Get-SqlScalarValue "DefaultDataPath" $ConnectionString "declare @DefaultPath nvarchar(512);  exec master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultData', @DefaultPath output;    if (@DefaultPath is null)  begin    set @DefaultPath = (select F.physical_name from sys.master_files F where F.database_id=db_id('master') and F.type = 0);    select @DefaultPath=substring(@DefaultPath, 1, len(@DefaultPath) - charindex('\', reverse(@DefaultPath)));  end    select isnull(@DefaultPath + '\', '') DefaultData"
      Write-Output "Using default value for DefaultDataPath variable: $DefaultDataPath"
    }
    if ($DefaultLogPath -eq $null) {
      $DefaultLogPath = Get-SqlScalarValue "DefaultLogPath" $ConnectionString "declare @DefaultPath nvarchar(512);  exec     master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultLog', @DefaultPath output;    if (@DefaultPath is null)  begin    set @DefaultPath = (select F.physical_name from sys.master_files F where F.database_id=db_id('master') and F.type = 1);    select @DefaultPath=substring(@DefaultPath, 1, len(@DefaultPath) - charindex('\', reverse(@DefaultPath)));  end    select isnull(@DefaultPath + '\', '') DefaultData"
      Write-Output "Using default value for DefaultLogPath variable: $DefaultLogPath"
    }
    if ($DefaultBackupPath -eq $null) {
      $DefaultBackupPath = Get-SqlScalarValue "DefaultBackupPath" $ConnectionString "declare @DefaultBackup nvarchar(512);  exec master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @DefaultBackup output;  select isnull(@DefaultBackup + '\', '') DefaultBackup;"
      Write-Output "Using default value for DefaultBackupPath variable: $DefaultBackupPath"
    }
  }

  Write-Output "Starting '$DatabaseName' Database Deployment to '$DatabaseServer'"
  $SqlCmdVarArguments = 'DatabaseName="' + $DatabaseName.Replace('"', '""') + '"'
  $SqlCmdVarArguments += ' ReleaseVersion="' + $ReleaseVersion.Replace('"', '""') + '"'
  $SqlCmdVarArguments += ' DeployPath="' + $DeployPath.Replace('"', '""') + '"'
  $SqlCmdVarArguments += ' ForceDeployWithoutBaseline="' + $ForceDeployWithoutBaseline.Replace('"', '""') + '"'
  $SqlCmdVarArguments += ' DefaultFilePrefix="' + $DefaultFilePrefix.Replace('"', '""') + '"'
  $SqlCmdVarArguments += ' DefaultDataPath="' + $DefaultDataPath.Replace('"', '""') + '"'
  $SqlCmdVarArguments += ' DefaultLogPath="' + $DefaultLogPath.Replace('"', '""') + '"'
  $SqlCmdVarArguments += ' DefaultBackupPath="' + $DefaultBackupPath.Replace('"', '""') + '"'
  foreach ($kvp in $SqlCmdVariables.GetEnumerator()) {
    $identity = $kvp.Name
    $currentValue = Get-Variable $identity -ValueOnly -ErrorAction SilentlyContinue

    $SqlCmdVarArguments += " $Identity=""" + $currentValue.Replace('"', '""') + '"'
  }

  $SqlCmdBase = 'sqlcmd.exe -b -S "' + $DatabaseServer + '" -v ' + $SqlCmdVarArguments

  if ($__databaseExists -eq $false -and $__autoCreateDatabase -eq $false) {
    $SqlCmd = $SqlCmdBase
  }
  else {
    $SqlCmd = $SqlCmdBase + ' -d "' + $DatabaseName.Replace('"', '""') + '"'
  }
  $SqlCmd = $SqlCmd + ' -i "' + (Get-ScriptDirectory) + "\$CreateScriptFileName" + '"'
  $SqlCmdWithAuth = $SqlCmd + ' ' + $SqlCmdAuth
  Write-Output $SqlCmdWithAuth
}
catch {
  Write-Error "A validation error occurred: $_ "
  if ($SkipVariableValidation) {
    Write-Error 'To bypass variable validation, pass this property value to MSBuild: SkipVariableValidation=True'
  }
  if ($OctopusEnvironmentName -ne $null) {
    [Environment]::Exit(1)
  }
  throw
}

# SQLCMD package deployment
if ($__databaseExists -eq $false) {
  if ($__autoCreateDatabase -eq $true) {
    $SqlCmdCreateDatabase = $SqlCmdBase + ' ' + $SqlCmdAuth + ' -Q "CREATE DATABASE [' + $DatabaseName.Replace('"', '""') + ']"'
    try {
      Write-Output "Automatically creating database $DatabaseName..."
      cmd /Q /C $SqlCmdCreateDatabase
      if ($lastexitcode) {
        throw 'sqlcmd.exe exited with a non-zero exit code.'
      }
    }
    catch {
      Write-Error "A deployment error occurred: $_ "
      if ($OctopusEnvironmentName -ne $null) {
        [Environment]::Exit(1)
      }
      throw
    }
  }
  else {
    Write-Output "The database does not exist. It will be created by your project Pre-Deployment script(s)."
  }
}
else {
  Write-Output "The database already exists. An incremental deployment will be performed."
}

try {
  cmd /Q /C $SqlCmdWithAuth
  if ($lastexitcode) {
    throw 'sqlcmd.exe exited with a non-zero exit code.'
  }
}
catch {
  Write-Error "A deployment error occurred: $_ "
  if ($OctopusEnvironmentName -ne $null) 	{
    [Environment]::Exit(1)
  }
  throw
}

function Read-Snapshot($ScriptDirectory) {
  try{
    $SnapshotName = (Get-Item "$ScriptDirectory\$SnapshotPackageFileName" -ErrorAction Stop)[0].Name
    $SnapshotPath = Join-Path $ScriptDirectory $SnapshotName
    $HexString = [System.BitConverter]::ToString([System.IO.File]::ReadAllBytes($SnapshotPath)).Replace('-', '')
    if ([string]::IsNullOrEmpty($HexString)) {
      Throw "File [$SnapshotPackageFileName] contained no data."
    }
    return $HexString
  }
  catch{
    Write-Warning "Failed to read schema snapshot from file. As a result, preview/drift reports will be unavailable for the next deployment: $_"
    return $null
  }
}
function Write-Snapshot($HexString) {
  $WriteFailedMessage = "No schema snapshot will be written to the target database. As a result, preview/drift reports will be unavailable for the next deployment."

  if ([string]::IsNullOrEmpty($HexString)) {
    Write-Warning $WriteFailedMessage
    return
  }

  $SchemaSnapshotTableName = "__SchemaSnapshot"

  $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
  $SqlConnection.ConnectionString = "$ConnectionString;Database=$DatabaseName"
  $SnapshotSqlCmd = New-Object System.Data.SqlClient.SqlCommand
  $SnapshotSqlCmd.Connection = $SqlConnection

  $InsertQuery = "INSERT INTO [$MigrationLogSchemaName].[$SchemaSnapshotTableName] (Snapshot) VALUES (0x$HexString)"
  $SnapshotSqlCmd.CommandText = "$InsertQuery"

  try {
    $SqlConnection.Open()
    $SnapshotSqlCmd.ExecuteScalar()
  }
  catch {
    Write-Warning "Failed to write schema snapshot to database: $_"
    Write-Warning $WriteFailedMessage
  }
  finally{
    $SqlConnection.Close()
    $SnapshotSqlCmd.Dispose()
  }
}

$ScriptDirectory = Get-ScriptDirectory
if (Test-Path "$ScriptDirectory\$SnapshotPackageFileName") {
  Write-Output "Reading schema snapshot"
  $HexString = Read-Snapshot(Get-ScriptDirectory)

  if ($HexString -ne $null) {
    Write-Output "Writing schema snapshot to target database"
    Write-Snapshot($HexString)
  }
}
else
{
  Write-Output 'Skipping schema snapshot deployment as a snapshot file could not be found. As a result, preview/drift reports will be unavailable for the next deployment. To enable schema snapshot creation, specify the ShadowServer property in your build configuration https://www.red-gate.com/sca/dev/continuous-integration-msbuild'
}

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]
    $NetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]
    $SQLServiceAccount,

    [Parameter(Mandatory=$true)]
    [string]
    $SQLServiceAccountPasswordKey,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminPasswordKey,

    [Parameter(Mandatory=$true)]
    [string[]]
    $DriveLetters,

    [Parameter(Mandatory=$true)]
    [string[]]
    $DriveTypes,

    [Parameter(Mandatory=$true)]
    [string[]]
    $TempDBonInstanceStore

)

try {
    Start-Transcript -Path C:\cfn\log\Reconfigure-SQL.ps1.txt -Append
    $ErrorActionPreference = "Stop"
    $DomainNetBIOSName = $env:USERDOMAIN

    $dataPath = ""
    $logPath = ""
    $backupPath = ""
    $tempPath=""
    for ($i = 0; $i -lt $DriveTypes.count; $i++) {
            switch ($DriveTypes[$i]) {
                "logs"{$logPath = $DriveLetters[$i] + ':\MSSQL\LOG'}
                "data"{$dataPath = $DriveLetters[$i] + ':\MSSQL\DATA'}
                "backup"{$backupPath = $DriveLetters[$i] + ':\MSSQL\Backup'
                         $tempPath = $DriveLetters[$i] + ':\MSSQL\TempDB'}
        }
    }
    [array]$paths = $dataPath,$logPath,$backupPath,$tempPath

    Write-Host $paths
    $sqlpath = (Resolve-Path 'C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\').Path
    $params = "-d$dataPath\master.mdf;-e$sqlpath\MSSQL\Log\ERRORLOG;-l$logPath\mastlog.ldf"
    $DomainAdminFullUser = $DomainNetBIOSName + '\' + $DomainAdminUser
    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))
    $SQLServiceAccountPassword = (ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $SQLServiceAccountPasswordKey).SecretString).password

    $SQLFullUser = $DomainNetBIOSName + '\' + $SQLServiceAccount

    $ConfigureSqlPs={
        $ErrorActionPreference = "Stop"

        ForEach ($path in $Using:paths) {
            New-Item -ItemType directory -Path $path
            $rule = new-object System.Security.AccessControl.FileSystemAccessRule($Using:SQLFullUser,"FullControl","ContainerInherit, ObjectInherit","InheritOnly","Allow")
            $acl = Get-Acl $path
            $acl.SetAccessRule($rule)
            Set-ACL -Path $path -AclObject $acl
        }

        # Set Default Paths
        Import-Module SQLPS
        Set-Location "SQLSERVER:\SQL\$env:COMPUTERNAME\DEFAULT"
        $Server = (Get-Item .)
        $Server.DefaultFile = $dataPath
        $Server.DefaultLog = $logPath
        $Server.BackupDirectory = $backupPath
        $Server.Alter()

        # Update Startup settings with new master db path
        [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SqlWmiManagement')| Out-Null
        $smowmi = New-Object Microsoft.SqlServer.Management.Smo.Wmi.ManagedComputer localhost
        $SQLService = $smowmi.Services | where {$_.name -eq 'MSSQLSERVER'}
        $SQLService.StartupParameters = $Using:params
        $SQLService.Alter()

        # Create account for SQL AD user
        $SQLUser = "[" + $Using:DomainNetBIOSName + "\" + $Using:SQLServiceAccount + "]"
        $AdminUser = "[" + $Using:DomainNetBIOSName + "\" + $Using:DomainAdminUser + "]"
        Invoke-Sqlcmd -Query "CREATE LOGIN $SQLUser FROM WINDOWS ;"
        Invoke-Sqlcmd -Query "CREATE LOGIN $AdminUser FROM WINDOWS ;"
        Invoke-Sqlcmd -Query "ALTER SERVER ROLE [sysadmin] ADD MEMBER $SQLUser ;"
        Invoke-Sqlcmd -Query "ALTER SERVER ROLE [sysadmin] ADD MEMBER $AdminUser ;"

        # Update paths for tempdb,model and MSDB
        $tempDevFile = "'$Using:tempPath\tempdb.mdf'"
        $modelDevFile = "'$Using:dataPath\model.mdf'"
        $msdbDataFile = "'$Using:dataPath\MSDBData.mdf'"
        $tempLogFile = "'$Using:tempPath\templog.ldf'"
        $modelLogFile = "'$Using:logPath\modellog.ldf'"
        $msdbLogFile = "'$Using:logPath\MSDBLog.ldf'"
        Invoke-Sqlcmd -Query "USE master; ALTER DATABASE tempdb MODIFY FILE (NAME = tempdev, FILENAME = $tempDevFile); ALTER DATABASE tempdb MODIFY FILE (NAME = templog, FILENAME = $tempLogFile);"
        Invoke-Sqlcmd -Query "USE master; ALTER DATABASE model MODIFY FILE (NAME = modeldev, FILENAME = $modelDevFile); ALTER DATABASE model MODIFY FILE (NAME = modellog, FILENAME = $modelLogFile);"
        Invoke-Sqlcmd -Query "USE master; ALTER DATABASE MSDB MODIFY FILE (NAME = MSDBData, FILENAME = $msdbDataFile); ALTER DATABASE MSDB MODIFY FILE (NAME = MSDBLog, FILENAME = $msdbLogFile);"

        # Stop SQL Service
        $SQLService = Get-Service -Name 'MSSQLSERVER'
        if ($SQLService.status -eq 'Running') {$SQLService.Stop()}
        $SQLService.WaitForStatus('Stopped','00:01:00')

        # Move files to new locations
        $tempDevFile = "$Using:tempPath\tempdb.mdf"
        $modelDevFile = "$Using:dataPath\model.mdf"
        $msdbDataFile = "$Using:dataPath\MSDBData.mdf"
        $tempLogFile = "$Using:tempPath\templog.ldf"
        $modelLogFile = "$Using:logPath\modellog.ldf"
        $msdbLogFile = "$Using:logPath\MSDBLog.ldf"
        Move-Item-Safely "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\tempdb.mdf" $tempDevFile
        Move-Item-Safely "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\templog.ldf" $tempLogFile
        Move-Item-Safely "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\model.mdf" $modelDevFile
        Move-Item-Safely "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\modellog.ldf" $modelLogFile
        Move-Item-Safely "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\MSDBData.mdf" $msdbDataFile
        Move-Item-Safely "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\MSDBLog.ldf" $msdbLogFile
        Move-Item-Safely "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\master.mdf" "$Using:dataPath\master.mdf"
        Move-Item-Safely "C:\Program Files\Microsoft SQL Server\MSSQL*.MSSQLSERVER\MSSQL\DATA\mastlog.ldf" "$Using:logPath\mastlog.ldf"

        # Set SQL Server and Agent services user to SQL AD user
        $Services = Get-WmiObject -Class Win32_Service -Filter "Name='SQLSERVERAGENT' OR Name='MSSQLSERVER'"
        $Services.change($null,$null,$null,$null,$null,$null, $Using:SQLFullUser,$Using:SQLServiceAccountPassword,$null,$null,$null)

        # Start service
        $SQLService.Start()
        $SQLService.WaitForStatus('Running','00:01:00')
    }

    Invoke-Command -Authentication Credssp -Scriptblock $ConfigureSqlPs -ComputerName $NetBIOSName -Credential $DomainAdminCreds

}
catch {
    $_ | Write-AWSLaunchWizardException
}

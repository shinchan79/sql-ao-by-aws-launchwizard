<#
.SYNOPSIS
Executes SQL setup action 'CompleteFailoverCluster' on primary node.

.DESCRIPTION
Finalizes SQL FCI setup by executing CompleteFailoverCluster install action.

.LINK
https://docs.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver15
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$Node1FciIp,

    [Parameter(Mandatory=$true)]
    [string]$Node1SubnetId,

    [Parameter(Mandatory=$true)]
    [string]$Node2FciIp,

    [Parameter(Mandatory=$true)]
    [string]$Node2SubnetId,

    [Parameter(Mandatory=$true)]
    [string]$FCIName,

    [Parameter(Mandatory=$true)]
    [string]$SQLAdminAccounts,

    [Parameter(Mandatory=$true)]
    [string]$StackName,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory=$false)]
    [string]$DomainNetBIOSName=$env:USERDOMAIN
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    ## Retrieve secure credentials using provided secret name
    $AdminSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser

    ## Run cluster validation prior to completing FCI setup.
    Invoke-Command -scriptblock { Test-Cluster } -Credential $AdminSecureCredObject.Credential -ComputerName $env:COMPUTERNAME -Authentication credssp

    ## Creating SQLSYSADMINACCOUNTS variables
    $AdminGroup = 'BUILTIN\Administrators'

    ## Preparing relevant cluster settings
    $DataVolumeLabel = 'SQL-DATA'
    $LogVolumeLabel = 'SQL-LOG'

    $datavol = (Get-Volume -FileSystemLabel $DataVolumeLabel).DriveLetter
    $logvol = (Get-Volume -FileSystemLabel $LogVolumeLabel).DriveLetter

    $sqlRootPath = "$($datavol):\mssql\system"
    $sqlDataPath = "$($datavol):\mssql\data"
    $sqlLogPath = "$($logvol):\mssql\log"

    $Node1SubnetMask = Get-SubnetMask -SubnetId $Node1SubnetId
    $Node2SubnetMask = Get-SubnetMask -SubnetId $Node2SubnetId

    ## Setting arguments to pass for SQL setup
    $SetupArguments = '/ACTION="CompleteFailoverCluster" /QUIET="True" /INDICATEPROGRESS="False" /INSTANCENAME="MSSQLSERVER" /FAILOVERCLUSTERDISKS="{0}" "{1}" /FAILOVERCLUSTERGROUP="SQL Server (MSSQLSERVER)" /CONFIRMIPDEPENDENCYCHANGE="True" /FAILOVERCLUSTERIPADDRESSES="IPv4;{2};Cluster Network 1;{3}" "IPv4;{4};Cluster Network 2;{5}" /FAILOVERCLUSTERNETWORKNAME="{6}" /SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS" /SQLSYSADMINACCOUNTS="{7}" "{8}" /INSTALLSQLDATADIR="{9}" /SQLUSERDBDIR="{10}" /SQLUSERDBLOGDIR="{11}"' -f $DataVolumeLabel, $LogVolumeLabel, $Node1FciIp, $Node1SubnetMask, $Node2FciIp, $Node2SubnetMask, $FCIName, $AdminGroup, $AdminSecureCredObject.DomainDlln, $sqlRootPath, $sqlDataPath, $sqlLogPath

    ## Configuring administrative PS session to capture exit code
    $LocalPSSession = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication credssp -Credential $AdminSecureCredObject.Credential

    ## Execute SQL setup and return exit code in existing session
    $SQLPrepProcExitCode = Invoke-Command -Session $LocalPSSession -ScriptBlock {
        $SQLPrepProc = Start-Process -FilePath C:\SQLServerSetup\setup.exe -ArgumentList $Using:SetupArguments -Wait -PassThru -WindowStyle Hidden
        return $SQLPrepProc.ExitCode
    }

    Remove-Variable -Name SetupArguments -ErrorAction SilentlyContinue
    [System.GC]::Collect()

    ## Destroy session if not already ended
    if ($null -ne $LocalPSSession) {
        Remove-PSSession -Session $LocalPSSession
    }

    ## For any exit code besides 0, stop the deployment
    if ($SQLPrepProcExitCode -ne 0) {
        throw "PrepareFailoverCluster action failed; Exit code: $SQLPrepProcExitCode"
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}
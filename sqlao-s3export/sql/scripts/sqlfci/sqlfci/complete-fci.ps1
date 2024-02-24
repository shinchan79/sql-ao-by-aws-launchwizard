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

# https://docs.microsoft.com/en-us/sql/database-engine/install-windows/install-sql-server-from-the-command-prompt?view=sql-server-ver15

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    ## Retrieve secure credentials using provided secret name
    $AdminSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser

    #Need to run cluster validation first
    Invoke-Command -scriptblock { Test-Cluster } -Credential $AdminSecureCredObject.Credential -ComputerName $env:COMPUTERNAME -Authentication credssp

    # Creating SQLSYSADMINACCOUNTS variables
    $AdminGroup = 'BUILTIN\Administrators'
    $AdminUserDomainAccount = $AdminSecureCredObject.NetBIOSDlln

    # File share DNS name
    $fsList = Get-FSXFileSystem | Where-Object { $_.Tags.Key -eq 'aws:cloudformation:stack-name' -and $_.Tags.Value -eq $Stackname }
    $fileshare = $fsList.DNSName

    $sqlRootPath = "\\$($fileshare)\SqlShare\mssql"
    $sqlDataPath = "\\$($fileshare)\SqlShare\mssql\data"
    $sqlLogPath = "\\$($fileshare)\SqlShare\mssql\log"

    $Node1SubnetMask = Get-SubnetMask -SubnetId $Node1SubnetId
    $Node2SubnetMask = Get-SubnetMask -SubnetId $Node2SubnetId

    ## Setting arguments to pass for SQL setup
    $SetupArguments = '/ACTION="CompleteFailoverCluster" /QUIET="True" /INDICATEPROGRESS="False" /INSTANCENAME="MSSQLSERVER" /FAILOVERCLUSTERGROUP="SQL Server (MSSQLSERVER)" /CONFIRMIPDEPENDENCYCHANGE="True" /FAILOVERCLUSTERIPADDRESSES="IPv4;{0};Cluster Network 1;{1}" "IPv4;{2};Cluster Network 2;{3}" /FAILOVERCLUSTERNETWORKNAME="{4}" /SQLCOLLATION="SQL_Latin1_General_CP1_CI_AS" /SQLSYSADMINACCOUNTS="{5}" "{6}" /INSTALLSQLDATADIR="{7}" /SQLUSERDBDIR="{8}" /SQLUSERDBLOGDIR="{9}"' -f $Node1FciIp, $Node1SubnetMask, $Node2FciIp, $Node2SubnetMask, $FCIName, $AdminGroup, $AdminUserDomainAccount, $sqlRootPath, $sqlDataPath, $sqlLogPath

    ## If node is not owner of all cluster resources, attempt to migrate.
    Invoke-ClusterResourceMigration

    ## Configuring administrative PS session to capture exit code
    $LocalPSSession = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication credssp -Credential $AdminSecureCredObject.Credential

    ## Execute SQL setup and return exit code in existing session
    $SQLCompleteProcExitCode = Invoke-Command -Session $LocalPSSession -ScriptBlock {
        $SQLCompleteProc = Start-Process -FilePath C:\SQLServerSetup\setup.exe -ArgumentList $Using:SetupArguments -Wait -PassThru -WindowStyle Hidden
        return $SQLCompleteProc.ExitCode
    }

    Remove-Variable -Name SetupArguments -ErrorAction SilentlyContinue
    [System.GC]::Collect()

    ## Destroy session if not already ended
    if ($null -ne $LocalPSSession) {
        Remove-PSSession -Session $LocalPSSession
    }

    ## For any exit code besides 0, stop the deployment
    if (-not (Confirm-SafeExitCode -ExitCode $SQLCompleteProcExitCode)) {
        throw "CompleteFailoverCluster action failed; Exit code: $SQLCompleteProcExitCode"
    }
} catch {
        $_ | Write-AWSLaunchWizardException
}
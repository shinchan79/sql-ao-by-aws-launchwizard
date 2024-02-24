[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]
    $numberOfNodes,

    [Parameter(Mandatory=$true)]
    [string]
    $agName,

    [Parameter(Mandatory=$true)]
    [string]
    $agListenerName,

    [Parameter(Mandatory=$true)]
    [string]
    $domaindnsname,

    [Parameter(Mandatory=$true)]
    [string]
    $ipAgListeners,

    [Parameter(Mandatory=$true)]
    [string]
    $NodeNetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]
    $SQLServiceAccount,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminPasswordKey,

    [Parameter(Mandatory=$true)]
    [string]
    $DatabaseName,

    [Parameter(Mandatory=$true)]
    [string[]]
    $DriveLetters,

    [Parameter(Mandatory=$true)]
    [string[]]
    $DriveTypes,

   [Parameter(Mandatory=$true)]
    [string[]]
    $nodeAccessTypes,

    [Parameter(Mandatory=$true)]
    [string]
    $PrivateSubnetAssignment,

    [Parameter(Mandatory=$true)]
    [string]
    $subnetMasks,

    [Parameter(Mandatory=$true)]
    [string]$Region,

    [Parameter(Mandatory=$true)]
    [string]$DDBTableName
)
$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\cfn\log\setupsqlha.ps1.txt -Append
Add-Type -Path (${env:ProgramFiles(x86)}+"\AWS SDK for .NET\bin\Net45\AWSSDK.DynamoDBv2.dll")

$nodes = $NodeNetBIOSName.split(',')
$domainNetbios  = $env:USERDOMAIN
$domainCred     = $domainNetbios+"\" +$DomainAdminUser
$driveLetters  = $DriveLetters.split(',')
$driveTypes  = $DriveTypes.split(',')
$sqlDataPath = "\"
$sqlLogPath = "\"
$sqlBackupPath = "\"
$shareName = 'SQLBackup'
for ($i = 0; $i -lt $driveTypes.count; $i++) {
switch ($driveTypes[$i]) {
"logs"{$sqlLogPath = $driveLetters[$i] + ':\MSSQL\LOG'}
"data"{$sqlDataPath = $driveLetters[$i] + ':\MSSQL\DATA'}
"backup"{$sqlBackupPath = $driveLetters[$i] + ':\MSSQL\Backup'}
 }
}
$SQLDataSize = '1024'
$SQLDataGrowth = '256'
$SQLLogSize = '1024'
$SQLLogGrowth = '256'

$backupLog = "\\$($nodes[0])\$($shareName)\$($DatabaseName)_log.bak"
# log file path
Write-LogInfo "SQL-HA Setup Starts"
# Create a credential object for the domain admin account.
#$domainPwd = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
#$Pwd = ConvertTo-SecureString $domainPwd -AsPlainText -Force
#$cred = New-Object System.Management.Automation.PSCredential $domainCred, $Pwd
$AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
$cred = (New-Object PSCredential($domainCred ,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))

$nodes = $nodes[0..($numberOfNodes - 1)]
$listenerips = $ipAgListeners.Split(",")
# We will refer to node1 and node2 with their full domain name
$nodesFqdn = @()
ForEach ($node in $nodes) {
$nodesFqdn += $node+"."+$domaindnsname
}

# NodeName and FQDN Map, only for secondaryNodes
$secondaryNodeFqdnMap = @{}
For ($i = 1; $i -lt $numberOfNodes; $i++) {
    $secondaryNodeFqdnMap.Add($nodes[$i], $nodesFqdn[$i])
}
Write-Output "AG Listerner IPS are"+ $ipAgListeners
try
{
    #1. Start SQLServer
    Start-SQLServer $nodesFqdn[0] $nodes $secondaryNodeFqdnMap $cred
    #2. Create test DB on Primary Node
    Write-Log (New-DataBase $nodesFqdn[0] $cred $DatabaseName $sqlDataPath $SQLDataSize $SQLDataGrowth $sqlLogPath $SQLLogSize $SQLLogGrowth)
    #3. Create a shared folder for initial backup used by Availability Groups
    Write-Log (New-SharedFolder $nodesFqdn[0] $cred $DomainAdminUser $SQLServiceAccount $sqlBackupPath $shareName $nodes $numberOfNodes)
    Enable-CredSSp $nodesFqdn $cred
    #4. Create the SQL Server endpoints for the Availability Groups
    Write-LogInfo 'Creating SQLServer Endpoint'
    [hashtable]$ex = @{ }
    $ex.IsError = $false
    $ex.Message = "\"
    ForEach ($nodeFqdn in $nodesFqdn[0..($numberOfNodes - 1)])
    {
        $ex = (New-SQLServerEndpoint $nodeFqdn $cred $nodes $domainNetbios)
        if ($ex.IsError)
        {
            Write-Log $ex
        }
    }
    #5. Create the Availability Group
    Write-Log (New-AG $nodesFqdn[0] $cred $nodeAccessTypes $nodes $numberOfNodes $shareName $DatabaseName $domaindnsname $agName $backupLog)
    #6. Join secondary DBs to AG
    Write-Log (Join-secondaryDBs $DatabaseName $nodes[0] $nodesFqdn[0] $secondaryNodeFqdnMap $cred $agName $backupLog)
    #7. Create AG Listener
    Write-Output "Listerner Ips are "+$listenerips
    Write-Log (New-AGListener $listenerips $subnetMasks.split(',') $PrivateSubnetAssignment $agName $agListenerName)
    #8. Remove DDB Table
    Get-DDBTable -TableName $DDBTableName | Remove-DDBTable -Force
}
catch {
    $_ | Write-AWSLaunchWizardException
}

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminPasswordKey,

    [Parameter(Mandatory=$true)]
    [string]
    $NetBIOSName
)

try
{
    Start-Transcript -Path C:\cfn\log\setsqlinstancename.ps1.txt -Append
    $ErrorActionPreference = "Stop"
    $DomainNetBIOSName = $env:USERDOMAIN

    $DomainAdminFullUser = $DomainNetBIOSName + '\' + $DomainAdminUser
    #$DomainAdminPassword = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
    #$DomainAdminSecurePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    #$DomainAdminCreds = New-Object System.Management.Automation.PSCredential($DomainAdminFullUser, $DomainAdminSecurePassword)
    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $DomainAdminFullUser = $DomainNetBIOSName + '\' + $DomainAdminUser
    $pass = ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force
    $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,$pass))
    $renameinstance = {
        $query = "
DECLARE @InternalInstanceName sysname;
DECLARE @MachineInstanceName sysname;
SELECT @InternalInstanceName = @@SERVERNAME,
@MachineInstanceName = CAST(SERVERPROPERTY('MACHINENAME') AS VARCHAR(128)) + COALESCE('\' + CAST(SERVERPROPERTY('INSTANCENAME') AS VARCHAR(128)), '');
IF @InternalInstanceName <> @MachineInstanceName
BEGIN EXEC sp_dropserver @InternalInstanceName;
EXEC sp_addserver @MachineInstanceName,
'LOCAL';
END"
        Invoke-Sqlcmd -Query $query
    }
    Invoke-Command -Authentication Credssp -Scriptblock $renameinstance -ComputerName $NetBIOSName -Credential $DomainAdminCreds

    Stop-Service SQLSERVERAGENT -Force
    Stop-Service MSSQLSERVER -Force
    Start-Service MSSQLSERVER
    Start-Service SQLSERVERAGENT
}
Catch
    {
        $_ | Write-AWSLaunchWizardException
    }

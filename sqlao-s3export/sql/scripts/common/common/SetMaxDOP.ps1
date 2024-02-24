[CmdletBinding()]
param(

    [Parameter(Mandatory=$true)]
    [string]
    $NetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminPasswordKey,

    [Parameter(Mandatory=$false)]
    [string]
    $dop="4"

)

try {
    Start-Transcript -Path C:\cfn\log\SetMaxDOP.ps1.txt -Append
    $ErrorActionPreference = "Stop"
    $DomainNetBIOSName = $env:USERDOMAIN
    #$DomainAdminPassword = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
    #$DomainAdminSecurePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    #$DomainAdminCreds = New-Object System.Management.Automation.PSCredential($DomainAdminFullUser, $DomainAdminSecurePassword)
    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $DomainAdminFullUser = $DomainNetBIOSName + '\' + $DomainAdminUser
    $pass = ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force
    $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,$pass))
    $SetupMaxDOPPs={
        $sql = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE WITH OVERRIDE; EXEC sp_configure 'max degree of parallelism', " + $Using:dop + "; RECONFIGURE WITH OVERRIDE; "
        Import-Module SQLPS
        Invoke-Sqlcmd -AbortOnError -ErrorAction Stop -Query $sql
    }

    Invoke-Command -Authentication Credssp -Scriptblock $SetupMaxDOPPs -ComputerName $NetBIOSName -Credential $DomainAdminCreds

}
catch {
    $_ | Write-AWSLaunchWizardException
}

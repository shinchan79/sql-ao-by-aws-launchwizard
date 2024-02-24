[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory=$true)]
    [string]$ADServer1NetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]$ADServer1PrivateIP,

    [Parameter(Mandatory=$true)]
    [string]$ADServer2PrivateIP,

    [Parameter(Mandatory=$true)]
    [string]$SSMParamName
)
try {
    $ErrorActionPreference = "Stop"
    Start-Transcript -Path C:\cfn\log\$($MyInvocation.MyCommand.Name).log -Append
    #$DomainAdminPassword = (Get-SSMParameterValue -Names $SSMParamName -WithDecryption $True).Parameters[0].Value
    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $SSMParamName).SecretString
    $DomainAdmin = $DomainDNSName + "\" + $DomainAdminUser
    $FQDN = $ADServer1NetBIOSName+"."+$DomainDNSName
    Invoke-Command -ComputerName $FQDN -Credential (New-Object PSCredential($DomainAdmin,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force))) -Scriptblock {
                    Get-NetAdapter | Set-DnsClientServerAddress -ServerAddresses $ADServer2PrivateIP, $ADServer1PrivateIP 
    }
}

catch {
    $_ | Write-AWSLaunchWizardException
}
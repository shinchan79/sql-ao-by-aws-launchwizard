[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ADServerPrivateIP,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    Get-NetAdapter | Set-DnsClientServerAddress -ServerAddresses $ADServerPrivateIP
} catch {
    $_ | Write-AWSLaunchWizardException
}
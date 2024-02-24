[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$ADServersPrivateIP
)

try {
    $ErrorActionPreference = "Stop"

    Start-Transcript -Path C:\cfn\log\$($MyInvocation.MyCommand.Name).log -Append

    $ADServersPrivateIPs = $ADServersPrivateIP.split(",")
    $netIPConfiguration = Get-NetIPConfiguration
    Set-DnsClientServerAddress -InterfaceIndex $netIPConfiguration.InterfaceIndex -ServerAddresses $ADServersPrivateIP
}
catch {
    $_ | Write-AWSLaunchWizardException
}
[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$ADServersPrivateIP
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    $ADServersPrivateIPs = $ADServersPrivateIP.split(",")
    $netIPConfiguration = Get-NetIPConfiguration

    Set-DnsClientServerAddress -InterfaceIndex $netIPConfiguration.InterfaceIndex -ServerAddresses $ADServersPrivateIPs
}
catch {
    $_ | Write-AWSLaunchWizardException
}
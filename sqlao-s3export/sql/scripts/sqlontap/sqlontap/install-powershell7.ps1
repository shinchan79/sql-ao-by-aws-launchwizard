<#
.SYNOPSIS
Installs Powershell 7

.DESCRIPTION
Installs Powershell 7 alongside existing version (does not force update v5)

.LINK
https://www.thomasmaurer.ch/2019/07/how-to-install-and-update-powershell-7/

.NOTES
Approach to obtaining PS7 can be updated to something more granular/safe - pending
#>
[CmdletBinding()]
param()

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Invoke-Expression "& { $(Invoke-RestMethod -Uri https://aka.ms/install-powershell.ps1) } -UseMSI"
} catch {
    $_ | Write-AWSLaunchWizardException
}

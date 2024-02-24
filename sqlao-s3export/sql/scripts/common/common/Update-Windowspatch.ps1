<#
.SYNOPSIS
Retrieves list of available Windows updates and installs each

.DESCRIPTION
Utilizes module PSWindowsUpdate to execute Get-WindowsUpdate and retrieve
a list of available updates, then executes Install-WindowsUpdate.

.LINK
https://www.powershellgallery.com/packages/PSWindowsUpdate

.NOTES
Manually forces a system reboot upon completion in case any updates require it.
#>
[CmdletBinding()]

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\cfn\log\Update-WindowsPatch.ps1.txt -Append

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

if ($null -eq (Get-Module -Name 'PSWindowsUpdate' -ListAvailable)) {
    Install-Module -Name PSWindowsUpdate -Force -Confirm:$false
}

try {
    Get-WindowsUpdate -Verbose -ErrorAction Continue | Out-File C:\cfn\log\availablewindowsupdates.txt

    Install-WindowsUpdate -WindowsUpdate -AcceptAll -IgnoreReboot -ErrorAction SilentlyContinue
} catch {
    throw "Encountered an issue while attempting to perform Windows updates. Exception message: $($_.Message.Exception)"
}

#restart computer for patching
C:\cfn\scripts\common\Restart-Computer.ps1
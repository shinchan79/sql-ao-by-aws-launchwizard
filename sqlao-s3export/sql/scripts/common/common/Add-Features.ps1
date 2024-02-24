[CmdletBinding()]
param()

Start-Transcript -Path C:\cfn\log\Add-Features.ps1.txt -Append
$ErrorActionPreference = "Stop"

try {
    if (-not ( (Get-WindowsFeature | Where-Object { $_.Name -eq 'RSAT-ADDS-Tools' }).Installed )) {
        Install-WindowsFeature -Name 'RSAT-ADDS-Tools' -IncludeAllSubFeature
    }

    if (-not ( (Get-WindowsFeature | Where-Object { $_.Name -eq 'RSAT-AD-PowerShell' }).Installed )) {
        Install-WindowsFeature -Name 'RSAT-AD-PowerShell' -IncludeAllSubFeature
    }
}
catch {
    $_ | Write-AWSLaunchWizardException
}
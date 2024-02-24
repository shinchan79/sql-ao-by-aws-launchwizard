[CmdletBinding()]

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\cfn\log\Install-RDSGateway.ps1.txt -Append
try
    {
        Write-Host "Installing RDS Gateway and RSAT-RDS-Gateway"
        Install-WindowsFeature RDS-Gateway,RSAT-RDS-Gateway
    }
catch
    {
        Write-Host " Error Occured during WMF installation "+ $_.Exception.Message
    }
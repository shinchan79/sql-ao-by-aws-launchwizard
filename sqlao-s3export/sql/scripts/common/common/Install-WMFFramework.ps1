[CmdletBinding()]

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\cfn\log\Install-WMFFramework.ps1.txt -Append
if ([Environment]::OSVersion.Version.Major -eq 6)
{

    try
    {
        Write-Host "Installing WMF 5.1"
        Start-Process -FilePath C:\cfn\Installer\WMF51\WMF51.msu -ArgumentList "/quiet" -Wait
    }
    catch
    {
        Write-Host " Error Occured during WMF installation "+ $_.Exception.Message
    }

}
else
{
    Write-Host " OS is not 2012. Skipping WMF install"
    #Rebooting server to compliment wait for completion signal in CFN
    C:\cfn\scripts\common\Restart-Computer.ps1
}


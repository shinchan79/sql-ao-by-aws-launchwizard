[CmdletBinding()]
param()

Start-Transcript -Path C:\cfn\log\Restart-Computer.ps1.txt -Append
$ErrorActionPreference = "SilentlyContinue"

Start-Process -FilePath "shutdown.exe" -ArgumentList @("/r", "/t 10") -Wait -NoNewWindow
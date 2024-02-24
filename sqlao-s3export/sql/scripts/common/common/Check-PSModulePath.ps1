[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$PathToCheck
)
Start-Transcript -Path C:\cfn\log\Check-PSModulePath.ps1.txt -Append
$ErrorActionPreference = "Stop"
$Pattern = "^" + $PathToCheck.Replace("\","\\") + "$"
$CurrentPath = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
$SplitPath = $CurrentPath.Split(";")
$exists = $false
foreach($Path in $SplitPath)
{
    if($Path -match $Pattern)
    {
        $exists = $true
        Write-Host "Path Exists. Skipping adding PSModulePath"
        break
    }
}

If(!($exists))
{
    try
    {
        [Environment]::SetEnvironmentVariable("PSModulePath", $CurrentPath + [System.IO.Path]::PathSeparator + $PathToCheck , "Machine")
        Write-Host " $PathToCheck added to PSModulePath"
    }
    Catch
    {
        Write-Host " Unable to add Path to PSModulePath"
    }
}


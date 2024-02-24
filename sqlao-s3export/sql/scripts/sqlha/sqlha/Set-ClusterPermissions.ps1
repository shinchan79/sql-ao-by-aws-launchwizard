[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]
    $WSFClusterName,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminPasswordKey
)
    Start-Transcript -Path C:\cfn\log\Set-Cluster-Permissions.ps1.txt -Append
    $ErrorActionPreference = "Stop"
try
{
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        Install-WindowsFeature RSAT-AD-PowerShell
    }
$count = 0
$cluster = $false
    do {
        try{
        get-adcomputer $WSFClusterName
        $cluster = $true
        Write-Output "$WSFClusterName found"
        Start-Sleep 60
        }
        catch{
            $count++
            Start-Sleep 60
        }
        if ($cluster -eq $true)
        {
            break
        }
    }while ($count -lt 10)

Set-ClusterPermission $WSFClusterName $DomainAdminPasswordKey $DomainAdminUser
}
Catch
    {
        $_ | Write-AWSLaunchWizardException
    }

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ClusterNodeName=$env:COMPUTERNAME
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    $SystemServiceName = 'ClusSvc'
    $ClusterSystemService = Get-Service -Name $SystemServiceName

    if ($ClusterSystemService.Status -ne 'Running') {
        Start-Sleep -Seconds 60
    }

    $ClusterNodeState = (Get-ClusterNode -Name $ClusterNodeName -ErrorAction SilentlyContinue).State

    if ($ClusterNodeState -ne "Up" -and $ClusterNodeState -ne "Joining") {
        Write-Host "Resuming cluster node $ClusterNodeName"
        Resume-ClusterNode -Name $ClusterNodeName -Failback NoFailback
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}
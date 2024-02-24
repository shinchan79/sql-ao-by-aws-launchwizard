[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$false)]
    [string]$ClusterNodeName=$env:COMPUTERNAME
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

$OwnerNodeList = (Get-ClusterGroup).OwnerNode.Name

# Ensure all nodes are joined to the cluster and in a state available for failover.
if ($OwnerNodeList -contains $ClusterNodeName) {
    $RetryCount = 0

    while ($RetryCount -lt 15) {
        $ListOfAvailableNodes = Get-ClusterNode | Where-Object { $_.Name -ne $ClusterNodeName -and $_.State -eq "Up" }

        if ($null -eq $ListOfAvailableNodes) {
            Write-Host "No cluster nodes are available for failover at this time."
            Write-Host "Waiting 60 seconds before checking node status. Attempts remaining: $((14 - $RetryCount))"

            Start-Sleep -Seconds 60
            $RetryCount = $RetryCount + 1
        } else {
            Write-Host "Target failover cluster node identified, initiating suspend."
            break
        }
    }

    if ($RetryCount -eq 15) {
        throw "Unable to identify any available cluster nodes to target for failover."
    }
}

try {
    # Addressing scenario where target node is unable to bring its IP Address up during role drain.
    Write-Host "Attempt to initialize target IP Address resource."
    $TargetIPResource = Get-ClusterResource | Where-Object { ($_.ResourceType -eq 'IP Address') -and ($_.State -eq 'Offline') }
    $TargetIPResource | Start-ClusterResource -ErrorAction SilentlyContinue

    Write-Host "Attempting to gracefully suspend cluster node $ClusterNodeName"
    Suspend-ClusterNode -Name $ClusterNodeName -Drain -Wait

    Write-Host "Initiating reboot for cluster node."
    Start-Process -FilePath "shutdown.exe" -ArgumentList @("/r", "/t 60") -NoNewWindow -Wait
} catch {
    $_ | Write-AWSLaunchWizardException
}
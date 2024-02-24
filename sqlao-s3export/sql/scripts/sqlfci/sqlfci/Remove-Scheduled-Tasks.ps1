[CmdletBinding()]
param()

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

$Task_ResumeClusterNode = "Resume_Cluster_Node"

try {
    if (Get-ScheduledTask | Where-Object { $_.TaskName -eq $Task_ResumeClusterNode }) {
        Unregister-ScheduledTask -TaskName $Task_ResumeClusterNode -Confirm:$false -ErrorAction SilentlyContinue
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}
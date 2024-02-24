
try{
    Start-Transcript -Path C:\cfn\log\createtempdbtask.ps1.txt -Append
    If (!(Test-Path C:\cfn\tempdb -ErrorAction SilentlyContinue))
    {    New-Item -ItemType Directory -Path c:\cfn\tempdb}
    Copy-Item "C:\cfn\scripts\sqlha\InstanceStoremapping.ps1" -Destination C:\cfn\tempdb -Force
# Create a scheduled task on startup to run script if required (if T: is lost)
    if (!(Get-ScheduledTask -TaskName "Rebuild TempDBPool" -ErrorAction SilentlyContinue))
    {
 $action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument 'c:\cfn\tempdb\InstanceStoreMapping.ps1'
 $trigger =  New-ScheduledTaskTrigger -AtStartup
 Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "Rebuild TempDBPool" -Description "Rebuild TempDBPool if required" -RunLevel Highest -User System
 }
}catch{
    $_ | Write-AWSLaunchWizardException
}
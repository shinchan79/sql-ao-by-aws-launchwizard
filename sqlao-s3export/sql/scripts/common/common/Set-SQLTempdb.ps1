[CmdletBinding()]

$ErrorActionPreference = "Stop"
try {
        Start-Transcript -Path C:\cfn\log\settempdb.ps1.txt -Append
        # Script to handle NVMe refresh on start/stop instance
        If (!(Get-ScheduledTask -TaskName "Rebuild TempDBPool"))
        {    $InstanceStoreMapping = {
            if (!(Get-Volume -DriveLetter T)) {
                #Create pool and virtual disk for TempDB using mirroring with NVMe
                $NVMe = Get-PhysicalDisk | ? { $_.CanPool -eq $True -and $_.FriendlyName -eq "NVMe Amazon EC2 NVMe"}
                New-StoragePool -FriendlyName TempDBPool -StorageSubsystemFriendlyName "Windows Storage*" -PhysicalDisks $NVMe
                New-VirtualDisk -StoragePoolFriendlyName TempDBPool -FriendlyName TempDBDisk -ResiliencySettingName simple -ProvisioningType Fixed -UseMaximumSize
                Get-VirtualDisk -FriendlyName TempDBDisk | Get-Disk | Initialize-Disk -Passthru | New-Partition -DriveLetter T -UseMaximumSize | Format-Volume -FileSystem ReFS -AllocationUnitSize 65536 -NewFileSystemLabel TempDBfiles -Confirm:$false
                #grant SQL Server Startup account full access to the new drive
                $item = gi -literalpath "T:\"
                $acl = $item.GetAccessControl()
                $permission="NT SERVICE\MSSQLSERVER","FullControl","Allow"
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
                $acl.SetAccessRule($rule)
                $item.SetAccessControl($acl)
                #Restart SQL so it can create tempdb on new drive
                Stop-Service SQLSERVERAGENT
                Stop-Service MSSQLSERVER
                Start-Service MSSQLSERVER
                Start-Service SQLSERVERAGENT
                }
            }
            New-Item -ItemType Directory -Path c:\Scripts    
            $InstanceStoreMapping | set-content c:\Scripts\InstanceStoreMapping.ps1
        # Create a scheduled task on startup to run script if required (if T: is lost)
            $action = New-ScheduledTaskAction -Execute 'Powershell.exe' -Argument 'c:\cfn\scripts\common\InstanceStoreMapping.ps1'
            $trigger =  New-ScheduledTaskTrigger -AtStartup
            Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "Rebuild TempDBPool" -Description "Rebuild TempDBPool if required" -RunLevel Highest -User System
        }
    }catch{
        $_ | Write-AWSLaunchWizardException
    }
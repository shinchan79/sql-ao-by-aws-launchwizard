Start-Transcript -Path C:\cfn\log\instancestoremapping.ps1.txt -Append
# Script to handle nvme refresh on start/stop instance
if (!(Get-Volume -DriveLetter T -ErrorAction SilentlyContinue)) {
    #Create pool and virtual disk for TempDB using mirroring with nvme
    $nvme = Get-PhysicalDisk|?{ $_.FriendlyName -eq "nvme Amazon EC2 nvme"}
    New-StoragePool -FriendlyName TempDBPool -StorageSubsystemFriendlyName "Windows Storage*" -PhysicalDisks $nvme
    New-VirtualDisk -StoragePoolFriendlyName TempDBPool -FriendlyName TempDBDisk -ResiliencySettingName simple -ProvisioningType Fixed -UseMaximumSize
    Get-VirtualDisk -FriendlyName TempDBDisk | Get-Disk | Initialize-Disk -Passthru | New-Partition -DriveLetter T -UseMaximumSize | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel TempDBfiles -Confirm:$false -Force
    #grant SQL Server Startup account full access to the new drive
    $SQLUserAccount = (Get-WmiObject Win32_Service -Filter "Name='MSSQLSERVER'").StartName
    $item = Get-Item -literalpath "T:\"
    $acl = $item.GetAccessControl()
    $permission= $($SQLUserAccount),"FullControl","Allow"
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission
    $acl.SetAccessRule($rule)
    $item.SetAccessControl($acl)
    If (!(Test-Path -path 'T:\MSSQL\TempDB'))
    {
        New-Item 'T:\MSSQL\TempDB' -ItemType Directory
    }
    #Restart SQL so it can create tempdb on new drive
    Stop-Service SQLSERVERAGENT -Force
    Stop-Service MSSQLSERVER -Force
    Start-Service MSSQLSERVER
    Start-Service SQLSERVERAGENT
    }


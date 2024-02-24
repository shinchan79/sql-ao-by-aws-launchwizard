[CmdletBinding()]
param()

$SQLUserAccount = (Get-WmiObject Win32_Service -Filter "Name='MSSQLSERVER'").StartName

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\cfn\log\settempdb.ps1.txt -Append

# Script to handle nvme refresh on start/stop instance
# Create pool and virtual disk for TempDB using mirroring with nvme

$InstanceStoreVols = Get-Disk | Where-Object { $_.FriendlyName -eq "NVMe Amazon EC2 NVMe" }

if ($null -ne $InstanceStoreVols) {
    foreach ($vol in $InstanceStoreVols) {
        Clear-Disk -Number $vol.DiskNumber -RemoveData -Confirm:$false -ErrorAction SilentlyContinue

        try {
            Reset-PhysicalDisk -UniqueId $vol.UniqueId
        } catch {
            throw "Unable to reset disk with unique ID: $($vol.UniqueId)"
        }

        "rescan" | diskpart
    }
}

try {
    $nvme = Get-PhysicalDisk | Where-Object { $_.FriendlyName -eq "NVMe Amazon EC2 NVMe" -and $_.CanPool -eq $true}

    if ($null -eq $nvme) {
        Write-Output "No instance store volumes identifed for Temp DB setup. Proceeding with deployment."
        return
    }

    New-StoragePool -FriendlyName TempDBPool -StorageSubsystemFriendlyName "Windows Storage*" -PhysicalDisks $nvme
    New-VirtualDisk -StoragePoolFriendlyName TempDBPool -FriendlyName TempDBDisk -ResiliencySettingName simple -ProvisioningType Fixed -UseMaximumSize

    $TempDBPoolDisk = Get-VirtualDisk -FriendlyName TempDBDisk | Get-Disk
    $TempDBPoolDisk | Initialize-Disk -Passthru | New-Partition -DriveLetter T -UseMaximumSize | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel TempDBfiles -Confirm:$false -Force

    #grant SQL Server Startup account full access to the new drive
    $item = Get-Item -LiteralPath "T:\"
    $acl = $item.GetAccessControl()

    $permission= $($SQLUserAccount),"FullControl","Allow"
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule $permission

    $acl.SetAccessRule($rule)
    $item.SetAccessControl($acl)

    if (!(Test-Path -path 'T:\MSSQL\TempDB')) {
        New-Item 'T:\MSSQL\TempDB' -ItemType Directory
    }

    #Restart SQL so it can create tempdb on new drive
    Stop-Service SQLSERVERAGENT -Force
    Stop-Service MSSQLSERVER -Force

    Start-Sleep -Seconds 5

    Start-Service MSSQLSERVER
    Start-Service SQLSERVERAGENT
} catch {
    $_ | Write-AWSLaunchWizardException
}
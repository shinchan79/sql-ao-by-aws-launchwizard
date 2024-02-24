<#
.SYNOPSIS
Initializes disks that were created for ONTAP

.DESCRIPTION
    - Enumerates disks where the friendly name contains 'NETAPP'
    - Executes basic initialization tasks (set to Online, GPT partition style, and initializes disk)
    - If one or more drives are of equal size, iterate through them by order of disk number; otherwise, match by disk size
    - Stops the ShellHWDetection service.
    - Creates a new partition that spans the maximum size the disk and partition type will support.
    - Assigns specified drive letter.
    - Formats the file system as NTFS with the specified file system label.
    - Starts the ShellHWDetection service again.

.LINK
https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ebs-using-volumes.html

.NOTES
Performing basic disk initialization tasks for NETAPP volumes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DataDriveSize,

    [Parameter(Mandatory=$true)]
    [string]$LogDriveSize,

    [Parameter(Mandatory=$false)]
    [int]$QuorumDriveSize=1
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    # Convert string drive sizes to integer
    [int]$DataDriveSize = [convert]::ToInt32($DataDriveSize)
    [int]$LogDriveSize = [convert]::ToInt32($LogDriveSize)

    # Create a set containing drive size (in GB) for all NetApp disks
    $NetAppDiskSet = New-Object System.Collections.Generic.HashSet[int]

    $NetAppDiskSet.Add($DataDriveSize) > $null
    $NetAppDiskSet.Add($LogDriveSize) > $null
    $NetAppDiskSet.Add($QuorumDriveSize) > $null

    # Create hash table to store OS disk size mapped to disk number
    $DriveSizeToNumberMap = New-Object System.Collections.HashTable

    # Retrieve a list of FSx for ONTAP disks, sorted by disk number
    [PSObject[]]$diskList = Get-Disk | Where-Object { $_.FriendlyName -eq 'NETAPP LUN C-MODE' } | Sort-Object -Property Number

    # Run through basic disk initialization tasks for each disk
    foreach ($disk in $diskList) {
        if ($disk.IsOffline -eq $True) {
            Set-Disk -Number $disk.Number -IsOffline $False
        }

        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction SilentlyContinue
        }

        if ($disk.IsReadOnly -eq $True) {
            Set-Disk -Number $disk.Number -IsReadOnly $False
        }

        # Converting disk size to GB and adding Size/Number to map
        # See more for conversion: https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-powershell-1.0/ee692684(v=technet.10)
        [int]$DiskSizeInGB = [math]::truncate($disk.Size / 1GB)
        $DriveSizeToNumberMap.Add($DiskSizeInGB, $disk.Number)
    }

    #Initiate, create and format volumes from the list of available FSx for ONTAP disks
    #Stopping Service to prevent format dialogs
    Stop-Service -Name ShellHWDetection

    # Build a list of drive letters by order of LUN creation
    $driveletters = @("S","L","Q")

    try {
        # In the case where there are non-unique disk sizes, set by order of creation.
        if ($NetAppDiskSet.Count -ne 3) {
            New-Partition -DiskNumber ($diskList[0]).Number -UseMaximumSize -DriveLetter $driveletters[0] | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -Force -NewFileSystemLabel SQL-Data
            New-Partition -DiskNumber ($diskList[1]).Number -UseMaximumSize -DriveLetter $driveletters[1] | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -Force -NewFileSystemLabel SQL-Log
            New-Partition -DiskNumber ($diskList[2]).Number -UseMaximumSize -DriveLetter $driveletters[2] | Format-Volume -FileSystem NTFS -Force -NewFileSystemLabel Quorum
        } else {
            New-Partition -DiskNumber $DriveSizeToNumberMap[$DataDriveSize] -UseMaximumSize -DriveLetter $driveletters[0] | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -Force -NewFileSystemLabel SQL-Data
            New-Partition -DiskNumber $DriveSizeToNumberMap[$LogDriveSize] -UseMaximumSize -DriveLetter $driveletters[1] | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -Force -NewFileSystemLabel SQL-Log
            New-Partition -DiskNumber $DriveSizeToNumberMap[$QuorumDriveSize] -UseMaximumSize -DriveLetter $driveletters[2] | Format-Volume -FileSystem NTFS -Force -NewFileSystemLabel Quorum
        }
    } catch {
        throw "Unable to successfully create disk partition(s). $($_.Exception.Message)"
    }

    Start-Service -Name ShellHWDetection
} catch {
    Write-Output "Error initializing drives"
    $_ | Write-AWSLaunchWizardException
}
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$UniqueID
)

try{
    Start-Transcript -Path C:\cfn\log\Tag-RootVolume.ps1.txt -Append
    $ErrorActionPreference = "Stop"
    
    $disks = Get-disk | ForEach-Object {
        $DriveLetter = $null
        $VolumeName = $null
        
        $DiskDrive = $_
        $Disk = $_.Number
        $Partitions = $_.NumberOfPartitions
        $EbsVolumeID = $_.SerialNumber -replace "_[^ ]*$" -replace "vol", "vol-"
        Get-Partition -DiskId $_.Path | ForEach-Object {
            if ($_.DriveLetter -ne "") {
                $DriveLetter = $_.DriveLetter
                $VolumeName = (Get-PSDrive | Where-Object {$_.Name -eq $DriveLetter}).Description
            }
        }
        
        New-Object PSObject -Property @{
            DriveLetter   = If ($DriveLetter -eq $null) { "N/A" } Else { $DriveLetter };
            EbsVolumeId   = If ($EbsVolumeID -eq $null) { "N/A" } Else { $EbsVolumeID };
           
        }
    }

    $RootVolumeID = ""
    foreach ($disk in $disks) {
        if ($disk.DriveLetter -eq "C") {
            $RootVolumeID = $disk.EbsVolumeId
        }
    }

    $tags = @()
    $ResourceGroupTag = @{Key="";Value=""}
    $ResourceGroupTag.Key = "LaunchWizardResourceGroupID"
    $ResourceGroupTag.Value = $UniqueID
    $ApplicationTypeTag = @{Key="";Value=""}
    $ApplicationTypeTag.Key = "LaunchWizardApplicationType"
    $ApplicationTypeTag.Value = "SQL_SERVER"
    $tags += $ApplicationTypeTag
    $tags += $ResourceGroupTag
    
    New-EC2Tag -Resource $RootVolumeID -Tags $tags
} catch {
    $_ | Write-AWSLaunchWizardException
}

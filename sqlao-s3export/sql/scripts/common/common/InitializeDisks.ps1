[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)]
	[string[]]$DeviceNames
)

function Invoke-InitializeDisks {
	[CmdletBinding()]
	param()

	$DiskList = Get-OSDiskDetails -ExcludeEphemeralDisks -SortedAscDeviceNumber

	foreach ($disk in $DiskList) {
		if ($disk.IsOffline -eq $True) {
			Set-Disk -Number $disk.Number -IsOffline $False
		}

		if ($disk.PartitionStyle -eq 'RAW') {
			Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction SilentlyContinue
		}

		if ($disk.IsReadOnly -eq $True) {
			Set-Disk -Number $disk.Number -IsReadOnly $False
		}
	}
}

function Invoke-FormatDisks {
	[CmdletBinding()]
	param()

	$DiskList = Get-OSDiskDetails -SortedAscDeviceNumber

	Stop-Service -Name ShellHWDetection

	foreach ($disk in $DiskList) {
		if ($DeviceNames -contains $disk.Device -and $disk.DriveLetter -eq [char]"`0") {
			New-Partition -DiskNumber $disk.Number -AssignDriveLetter -UseMaximumSize | Format-Volume -FileSystem NTFS -AllocationUnitSize 65536 -Force -Confirm:$false
		}
	}

	Start-Service -Name ShellHWDetection
}

function Test-VolumeAttachmentStatus {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)]
		[PSObject[]]$VolumeList
	)

	$attached = $false
	$countSleep = 0;

	while (-Not ($attached)) {
		$count = 0

		foreach ($volume in $VolumeList) {
			if ($volume.State -eq "attached") {
				$count = $count + 1
			}
		}

		if ($count -eq $VolumeList.length) {
			$attached = $true
			Write-Host 'All volumes are successfully attached to the instance.'
		} else {
			$countSleep = $countSleep + 1
			Start-Sleep -Seconds 1
		}

		if ($countSleep -gt 15) {
			throw "It is taking unusually longer for volumes to get attached. Aborting the program."
		}
	}
}

$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\cfn\log\InitializeDisks.ps1.txt -Append

try {
	# Path to InitializeDisks script from EC2 Launch V1
	$Path = 'C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeDisks.ps1'

	if (Test-Path -Path $Path){
		C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeDisks.ps1
	} else {
		$sessionToken = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri "http://169.254.169.254/latest/api/token"
		Set-Variable -Name 'Token' -Value $sessionToken -Scope Global

		$instanceID = Get-InstanceMetadataFromPath -Path "meta-data/instance-id"

		$volumes = (Get-EC2Volume).Attachments | Where-Object { $_.InstanceId -eq $instanceId }

		Write-Host "Validating all EBS volumes are attached to the instance."
		Test-VolumeAttachmentStatus -VolumeList $volumes

		Write-Host "Initializing disks."
		Invoke-InitializeDisks

		Write-Host "Creating and formatting disk volumes."
		Invoke-FormatDisks
	}
} catch {
	$_ | Write-AWSLaunchWizardException
}
[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)]
	[Int[]]$VolumeSizes,

	[Parameter(Mandatory=$true)]
	[string[]]$DriveLetters,

	[Parameter(Mandatory=$true)]
	[string[]]$DeviceNames
)

function Get-InUseDriveLetters {
	$driveLetters = New-Object -TypeName 'System.Collections.Generic.List[Char]'
	# Ignore any empty values for a partition using [char]"`0"
	Get-Partition | Where-Object {$_.DriveLetter -ne [char]"`0"} | Select-Object DriveLetter | ForEach-Object { $driveLetters.Add($_.DriveLetter) }

	return $driveLetters.ToArray()
}

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
	$sessionToken = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri "http://169.254.169.254/latest/api/token"
	Set-Variable -Name 'Token' -Value $sessionToken -Scope Global

	$tempLetters = New-Object System.Collections.Queue
	$tempLetters.Enqueue('O')
	$tempLetters.Enqueue('U')
	$tempLetters.Enqueue('W')
	$tempLetters.Enqueue('V')
	$tempLetters.Enqueue('X')
	$tempLetters.Enqueue('Y')
	$tempLetters.Enqueue('Z')

	$BDtoDrLetter = @{}
	for ($i = 0; $i -lt $DeviceNames.Length; $i++) {
		if($DeviceNames[$i] -ne 'N/A') {
			$BDtoDrLetter.add([String]$DeviceNames[$i], [String]$DriveLetters[$i])
		}
	}

	$letterToSizeMap = @{}
	for ($i = 0; $i -lt $DriveLetters.Length; $i++) {
		$letter = $DriveLetters[$i]
		$size = $VolumeSizes[$i]
		$letterToSizeMap.add($letter, $size)
	}

	foreach ($deviceName in $DeviceNames) {
		$disks = Get-OSDiskDetails -ExcludeEphemeralDisks

		foreach ($disk in $disks) {
			if ($deviceName -eq $disk.Device) {
				$key = $disk.Device

				if ($disk.DriveLetter -ne $BDtoDrLetter.$key) {
					# check for collision
					$inUseDriveLetters = Get-InUseDriveLetters

					if ($inUseDriveLetters -match $BDtoDrLetter.$key) {
						$tempLetter = $tempLetters.Dequeue()

						while ($inUseDriveLetters -match $tempLetter) {
							$tempLetter = $tempLetters.Dequeue()
						}

						Get-Partition -DriveLetter $BDtoDrLetter.$key| Set-Partition -NewDriveLetter $tempLetter

						$inUseDriveLetters = Get-InUseDriveLetters
						if ($inUseDriveLetters -match $BDtoDrLetter.$key) {
							throw "Drive letter $($BDtoDrLetter.$key) is still in use."
						}
					}

					Get-Partition -DiskNumber $disk.Number | Where-Object {$_.Type -ne "Reserved"} | Set-Partition -NewDriveLetter $BDtoDrLetter.$key
				}
			}
			Start-Sleep -Seconds 2
		}
	}

	$disks = Get-OSDiskDetails -ExcludeEphemeralDisks

	# Resize volumes
	foreach ($disk in $disks) {
		if ($DriveLetters -contains $disk.DriveLetter) {
			$key = [String]$disk.DriveLetter
			$VolumeSize = $letterToSizeMap.$key
			$volume = get-ec2volume -VolumeId $disk.EbsVolumeId
			if ($volume.Size -lt $VolumeSize) {
				try {
					Edit-EC2Volume -VolumeId $disk.EbsVolumeId -Size $VolumeSize
				} catch {
					$_ | Write-AWSLaunchWizardException
				}
			}
		}
	}

	C:\cfn\scripts\common\Restart-Computer.ps1

} catch {
	Write-Host $_.Exception.Message
	$_ | Write-AWSLaunchWizardException
}

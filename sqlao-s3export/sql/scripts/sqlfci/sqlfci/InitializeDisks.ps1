try {
	$ErrorActionPreference = 'Stop'
	$Path = 'C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeDisks.ps1'

	if (Test-Path -Path $Path){
		C:\ProgramData\Amazon\EC2-Windows\Launch\Scripts\InitializeDisks.ps1
	} else{
		$token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri http://169.254.169.254/latest/api/token
		$instanceID = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Method GET -Uri http://169.254.169.254/latest/meta-data/instance-id

		$volumes = (Get-EC2Volume).Attachments | Where-Object { $_.InstanceId -eq $instanceId }
		$attached = $false
		$countSleep = 0;

		while (-Not ($attached)) {
			$count = 0
			foreach ($volume in $volumes) {
				if ($volume.State -eq "attached") {
					$count = $count + 1
				}
			}
			if ($count -eq $volumes.length) {
				$attached = $true
			} else {
				$countSleep = $countSleep + 1
				Start-Sleep -s 1
			}

			if ($countSleep -gt 15) {
				throw "It is taking unusually longer for volumes to get attached. Aborting the program."
			}
		}
	}
} catch {
	$_ | Write-AWSLaunchWizardException
}
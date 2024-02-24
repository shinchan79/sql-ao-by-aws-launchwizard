[CmdletBinding()]
param(
[Parameter(Mandatory=$true)]
[string[]]$DriveLetters
)

try {
	foreach ($letter in $DriveLetters) {
		$currentSize = (Get-Partition -DriveLetter $letter).size
		$size = Get-PartitionSupportedSize -DriveLetter $letter
		$sizeDiff = $size.SizeMax - $currentSize

		# Size differential must be equal or greater than 1 MB
		if ($sizeDiff -ge 1MB) {
			Resize-Partition -DriveLetter $letter -Size $size.SizeMax
	        Start-Sleep -s 1
	    }
	}
} catch {
    Write-Host $_.Exception.Message
    $_ | Write-AWSLaunchWizardException
}

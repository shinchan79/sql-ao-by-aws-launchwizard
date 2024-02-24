[CmdletBinding()]
param(
	[Parameter(Mandatory=$True)]
	[string]$GroupName,

	[Parameter(Mandatory=$True)]
	[string]$UserName,

	[Parameter(Mandatory=$True)]
	[string]$DomainDNSName
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\cfn\log\AddUserToGroup.ps1.txt -Append

try {
	$DomainAccountName = $DomainDNSName,$UserName -Join "\"
	Add-LocalGroupMember -Group $GroupName -Member $DomainAccountName
} catch {
	$_ | Write-AWSLaunchWizardException
}
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\cfn\log\Join-Domain.ps1.log -Append

try {
	$AdminDomainAccountName = $DomainDNSName,$DomainAdminUser -Join "\"

	# Getting Password from Secrets Manager for AD Admin User
	$AdminSecretObject = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $AdminSecret | Select-Object -ExpandProperty 'SecretString')

	# Creating Credential Object for Administrator
	$AdminSecureCredentials = New-Object PSCredential($AdminDomainAccountName,(ConvertTo-SecureString $AdminSecretObject.password -AsPlainText -Force))

	Add-Computer -DomainName $DomainDNSName -Credential $AdminSecureCredentials -ErrorAction Stop
}
catch {
	$_ | Write-AWSLaunchWizardException
}

# restart computer to make joining domain effective
C:\cfn\scripts\common\Restart-Computer.ps1
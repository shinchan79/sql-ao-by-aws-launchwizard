[CmdletBinding()]
param(
	[Parameter(Mandatory=$true)]
	[string]$AdminSecret,

	[Parameter(Mandatory=$true)]
	[string]$ClusterName,

	[Parameter(Mandatory=$true)]
	[string]$DomainDNSName
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

$DscRootDirectory = "C:\cfn\dsc"

$DscConfigName = "ClusterADPermissionEntryConfig"
$DscConfigDirectory = $DscRootDirectory,$DscConfigName -Join "\"

## Retrieve the DSC Cert Encryption Thumbprint used to secure the MOF File
$DscCertThumbprint = (Get-ChildItem -Path cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=AWSLWDscEncryptCert" }).Thumbprint

$ConfigurationData = Get-CommonConfigurationData -CertificateThumbprint $DscCertThumbprint

try {
	## Retrieve secure credentials using provided secret name
	$ClusterSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -RetrieveCredentialOnly

	### Preparing requisite parameters

	# Set wait timer of 15 minutes for CNO to be created before executing.
	$RetryCount = 0

	while ($RetryCount -lt 15) {
		$ClusterComputerObject = Get-ADComputer -Filter { Name -like $ClusterName }

		if ($null -eq $ClusterComputerObject) {
			Write-Host "Cluster object $ClusterName does not exist at this time."
			Write-Host "Waiting 60 seconds before checking node status. Attempts remaining: $((14 - $RetryCount))"

			Start-Sleep -Seconds 60
			$RetryCount = $RetryCount + 1
		} else {
			Write-Host "Cluster object found - resuming setup."
			break
		}
	}

	if ($RetryCount -eq 15) {
		throw "Primary node did not complete initial setup in expected time period."
	}

	$DomainNetBIOS = $env:USERDOMAIN

	# Must reflect "DomainNetBIOS\Username"
	$IdentityRef = $DomainNetBIOS, $ClusterComputerObject.SamAccountName -Join "\"

	$ComputerCN,$OU = $ClusterComputerObject -split ',',2

	# Schema-Id-Guid | Class representing a computer account in the domain.
	$ObjectTypeGUID = "bf967a86-0de6-11d0-a285-00aa003049e2"

	# Schema-Id-Guid | A container for storing users, computers, and other account objects.
	$InheritedObjectTypeGUID = "bf967aa5-0de6-11d0-a285-00aa003049e2"

	Configuration $DscConfigName {
		param(
			[PSCredential] $Credentials
		)

		Import-DscResource -ModuleName ActiveDirectoryDsc
		Import-DscResource -ModuleName FailoverClusterDsc
	
		Node localhost
		{
			WaitForCluster WaitForCluster
			{
				Name             = $ClusterName
				RetryIntervalSec = 30
				RetryCount       = 20
			}

			ADObjectPermissionEntry 'GrantClusterCreateChildPermission'
			{
				Ensure                             = 'Present'
				Path                               = $OU
				IdentityReference                  = $IdentityRef
				ActiveDirectoryRights              = 'CreateChild'
				AccessControlType                  = 'Allow'
				ActiveDirectorySecurityInheritance = 'All'
				ObjectType                         = $ObjectTypeGUID
				InheritedObjectType                = $InheritedObjectTypeGUID
				PsDscRunAsCredential               = $Credentials
				DependsOn                          = '[WaitForCluster]WaitForCluster'
			}

			ADObjectPermissionEntry 'GrantClusterReadPropertyPermission'
			{
				Ensure                             = 'Present'
				Path                               = $OU
				IdentityReference                  = $IdentityRef
				ActiveDirectoryRights              = 'ReadProperty'
				AccessControlType                  = 'Allow'
				ActiveDirectorySecurityInheritance = 'All'
				ObjectType                         = '00000000-0000-0000-0000-000000000000'
				InheritedObjectType                = '00000000-0000-0000-0000-000000000000'
				PsDscRunAsCredential               = $Credentials
				DependsOn                          = '[WaitForCluster]WaitForCluster'
			}
		}
	}

    ClusterADPermissionEntryConfig -OutputPath $DscConfigDirectory -ConfigurationData $ConfigurationData -Credentials $ClusterSecureCredObject.Credential

    Start-DscConfiguration $DscConfigDirectory -Wait -Verbose -Force
} catch {
	$_ | Write-AWSLaunchWizardException
}
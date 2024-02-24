[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DomainDnsName,

    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$StackName
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

$DscRootDirectory = "C:\cfn\dsc"

$DscConfigName = "Node1AddCluster"
$DscConfigDirectory = $DscRootDirectory,$DscConfigName -Join "\"

## Retrieve the DSC Cert Encryption Thumbprint used to secure the MOF File
$DscCertThumbprint = (Get-ChildItem -Path cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=AWSLWDscEncryptCert" }).Thumbprint

$ConfigurationData = Get-CommonConfigurationData -CertificateThumbprint $DscCertThumbprint

try {
    ## Retrieve secure credentials using provided secret name
    $ClusterSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -RetrieveCredentialOnly

    Configuration $DscConfigName {
        param(
            [PSCredential] $Credentials
        )

        Import-DscResource -ModuleName PSDscResources

        Node 'localhost' {
            WindowsFeature RSAT-AD-PowerShell {
                Name = 'RSAT-AD-PowerShell'
                Ensure = 'Present'
            }

            WindowsFeature AddFailoverFeature {
                Ensure = 'Present'
                Name   = 'Failover-clustering'
                DependsOn = '[WindowsFeature]RSAT-AD-PowerShell'
            }
        }
    }

    Node1AddCluster -OutputPath $DscConfigDirectory -ConfigurationData $ConfigurationData -Credentials $ClusterSecureCredObject.Credential

    Start-DscConfiguration $DscConfigDirectory -Wait -Verbose -Force
} catch{
    $_ | Write-AWSLaunchWizardException
}
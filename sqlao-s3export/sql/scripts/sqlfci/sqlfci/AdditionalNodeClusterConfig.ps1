[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$WSFCNode2PrivateIP2,

    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

$DscRootDirectory = "C:\cfn\dsc"

$DscConfigName = "AdditionalNodeClusterConfig"
$DscConfigDirectory = $DscRootDirectory,$DscConfigName -Join "\"

## Retrieve the DSC Cert Encryption Thumbprint used to secure the MOF File
$DscCertThumbprint = (Get-ChildItem -Path cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=AWSLWDscEncryptCert" }).Thumbprint

$ConfigurationData = Get-CommonConfigurationData -CertificateThumbprint $DscCertThumbprint

try {
    ## Retrieve secure credentials using provided secret name
    $ClusterSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser

    Configuration $DscConfigName {
        param(
            [PSCredential] $Credentials
        )

        Import-DscResource -ModuleName PSDscResources

        Node 'localhost' {

            WindowsFeature AddRemoteServerAdministrationToolsClusteringFeature {
                Ensure    = 'Present'
                Name      = 'RSAT-Clustering-Mgmt'
            }

            WindowsFeature AddRemoteServerAdministrationToolsClusteringPowerShellFeature {
                Ensure    = 'Present'
                Name      = 'RSAT-Clustering-PowerShell'
                DependsOn = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringFeature'
            }

            WindowsFeature AddRemoteServerAdministrationToolsClusteringCmdInterfaceFeature {
                Ensure    = 'Present'
                Name      = 'RSAT-Clustering-CmdInterface'
                DependsOn = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringPowerShellFeature'
            }
        }
    }

    AdditionalNodeClusterConfig -OutputPath $DscConfigDirectory -ConfigurationData $ConfigurationData -Credentials $ClusterSecureCredObject.Credential

    Start-DscConfiguration $DscConfigDirectory -Wait -Verbose -Force
} catch {
    $_ | Write-AWSLaunchWizardException
}
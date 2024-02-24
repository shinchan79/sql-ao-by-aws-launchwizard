[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DomainDnsName,

    [Parameter(Mandatory=$true)]
    [string]$WSFCNode1PrivateIP2,

    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$StackName
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

$DscRootDirectory = "C:\cfn\dsc"

$DscConfigName = "Node1ClusterConfig"
$DscConfigDirectory = $DscRootDirectory,$DscConfigName -Join "\"

## Retrieve the DSC Cert Encryption Thumbprint used to secure the MOF File
$DscCertThumbprint = (Get-ChildItem -Path cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=AWSLWDscEncryptCert" }).Thumbprint

$ConfigurationData = Get-CommonConfigurationData -CertificateThumbprint $DscCertThumbprint

try {
    ## Retrieve secure credentials using provided secret name
    $ClusterSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -RetrieveCredentialOnly

    $fsList = Get-FSXFileSystem | Where-Object { $_.Tags.Key -eq 'aws:cloudformation:stack-name' -and $_.Tags.Value -eq $Stackname }

    if ($fsList.DNSName) {
        $ShareName = "\\" + $fsList.DNSName + "\SqlWitnessShare"
    }

    Configuration $DscConfigName {
        param(
            [PSCredential] $Credentials
        )

        Import-DscResource -ModuleName FailoverClusterDsc
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

            Cluster CreateCluster {
                Name                          =  $ClusterName
                StaticIPAddress               =  $WSFCNode1PrivateIP2
                DomainAdministratorCredential =  $Credentials
                DependsOn                     = '[WindowsFeature]AddRemoteServerAdministrationToolsClusteringCmdInterfaceFeature'
            }

            if ($fsList.DNSName) {
                ClusterQuorum 'SetQuorumToNodeAndFileShareMajority' {
                    IsSingleInstance = 'Yes'
                    Type             = 'NodeAndFileShareMajority'
                    Resource         = $ShareName
                    DependsOn        = '[Cluster]CreateCluster'
                }
            } else {
                ClusterQuorum 'SetQuorumToNodeMajority' {
                    IsSingleInstance = 'Yes'
                    Type             = 'NodeMajority'
                    DependsOn        = '[Cluster]CreateCluster'
                }
            }
        }
    }

    Node1ClusterConfig -OutputPath $DscConfigDirectory -ConfigurationData $ConfigurationData -Credentials $ClusterSecureCredObject.Credential

    Start-DscConfiguration $DscConfigDirectory -Wait -Verbose -Force
} catch {
    $_ | Write-AWSLaunchWizardException
}

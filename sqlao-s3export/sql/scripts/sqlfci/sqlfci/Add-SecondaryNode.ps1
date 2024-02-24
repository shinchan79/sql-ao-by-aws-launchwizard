[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$WSFCNode2PrivateIP2,

    [Parameter(Mandatory=$true)]
    [string]$Node2SubnetId,

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

$DscConfigName = "AddSecondaryNode"
$DscConfigDirectory = $DscRootDirectory,$DscConfigName -Join "\"

## Retrieve the DSC Cert Encryption Thumbprint used to secure the MOF File
$DscCertThumbprint = (Get-ChildItem -Path cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=AWSLWDscEncryptCert" }).Thumbprint

$ConfigurationData = Get-CommonConfigurationData -CertificateThumbprint $DscCertThumbprint

try {
    ## Retrieve secure credentials using provided secret name
    $ClusterSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser

    # Obtain subnet mask from secondary subnet ID
    $SubnetMaskDotDecimal = Get-SubnetMask -SubnetId $Node2SubnetId

    Configuration $DscConfigName {
        param(
            [PSCredential] $Credentials
        )

        Import-DscResource -ModuleName FailoverClusterDsc

        Node 'localhost'{

            WaitForCluster WaitForCluster {
                Name             = $ClusterName
                RetryIntervalSec = 60
                RetryCount       = 15
            }

            Cluster JoinNodeToCluster {
                Name                          = $ClusterName
                StaticIPAddress               = $WSFCNode2PrivateIP2
                DomainAdministratorCredential = $Credentials
                DependsOn                     = '[WaitForCluster]WaitForCluster'
            }

            ClusterIPAddress IPaddress {
                IPAddress   = $WSFCNode2PrivateIP2
                Ensure      = 'Present'
                AddressMask = $SubnetMaskDotDecimal
                DependsOn   = '[Cluster]JoinNodeToCluster'
            }
        }
    }

    AddSecondaryNode -OutputPath $DscConfigDirectory -ConfigurationData $ConfigurationData -Credentials $ClusterSecureCredObject.Credential

    Start-DscConfiguration $DscConfigDirectory -Wait -Verbose -Force
} catch {
    $_ | Write-AWSLaunchWizardException
}
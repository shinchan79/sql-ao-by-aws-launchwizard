<#
.SYNOPSIS
Completes the initial setup of the Windows cluster.

.DESCRIPTION
Installs required Windows Features for clustering, creates the cluster,
and sets up appropriate cluster disks

.LINK
https://github.com/dsccommunity/FailoverClusterDsc
#>
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
    [string]$StackName,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

$DscRootDirectory = "C:\cfn\dsc"

$DscConfigName = "Node1ClusterConfig"
$DscConfigDirectory = $DscRootDirectory,$DscConfigName -Join "\"

## Retrieve the DSC Cert Encryption Thumbprint used to secure the MOF File
$DscCertThumbprint = (Get-ChildItem -Path cert:\LocalMachine\My | Where-Object { $_.subject -eq "CN=AWSLWDscEncryptCert" }).Thumbprint

$ConfigurationData = Get-CommonConfigurationData -CertificateThumbprint $DscCertThumbprint

try {
    ## Retrieve secure credentials using provided secret name
    $ClusterSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser

    # Create list of ONTAP disks similar to Initialize-Iscsidisk.ps1
    [PSObject[]]$NetappDiskList = Get-Disk | Where-Object { $_.FriendlyName -eq 'NETAPP LUN C-MODE' } | Sort-Object -Property Number
    [PSObject[]]$OntapDiskLabels = @("SQL-DATA", "SQL-LOG", "Quorum")

    if ($OntapDiskLabels.Length -ne $NetappDiskList.Length) {
        throw "Mismatched count for available NetApp disks and disk labels."
    }

    $DiskLabelToDiskNumber = New-Object System.Collections.Hashtable
    foreach ($label in $OntapDiskLabels) {
        $DiskNum = (Get-Volume -FileSystemLabel $label | Get-Partition).DiskNumber
        $DiskLabelToDiskNumber.Add($label, $DiskNum)
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

            ClusterDisk AddDataClusterDisk {
                Number    = $DiskLabelToDiskNumber['SQL-DATA']
                Ensure    = 'Present'
                Label     = 'SQL-DATA'
                DependsOn = '[Cluster]CreateCluster'
            }

            ClusterDisk AddLogClusterDisk {
                Number    = $DiskLabelToDiskNumber['SQL-LOG']
                Ensure    = 'Present'
                Label     = 'SQL-LOG'
                DependsOn = '[Cluster]CreateCluster'
            }

            ClusterDisk AddQuorumClusterDisk {
                Number    = $DiskLabelToDiskNumber['Quorum']
                Ensure    = 'Present'
                Label     = 'Quorum'
                DependsOn = '[Cluster]CreateCluster'
            }

            ClusterQuorum SetQuorumToNodeMajority {
                IsSingleInstance = 'Yes'
                Type             = 'NodeAndDiskMajority'
                Resource         = 'Quorum'
                DependsOn        = '[ClusterDisk]AddQuorumClusterDisk'
            }
        }
    }

    Node1ClusterConfig -OutputPath $DscConfigDirectory -ConfigurationData $ConfigurationData -Credentials $ClusterSecureCredObject.Credential

    Start-DscConfiguration $DscConfigDirectory -Wait -Verbose -Force

} catch{
    $_ | Write-AWSLaunchWizardException
}
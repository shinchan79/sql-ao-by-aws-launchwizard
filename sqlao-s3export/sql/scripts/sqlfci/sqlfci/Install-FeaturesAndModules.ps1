<#
.SYNOPSIS
Installs required Powershell and DSC modules for FCI deployments

.DESCRIPTION
Installs required Windows Features (if missing): RSAT-AD-PowerShell
Installs required Powershell module(s): SqlServer
Installs required DSC module(s):
    - ActiveDirectoryDsc
    - ComputerManagementDsc
    - DnsServerDsc
    - FailoverClusterDsc
    - NetworkingDsc
    - PSDscResources
    - SqlServer
    - SqlServerDsc

.NOTES
This script does not need to perform a reboot at completion.
#>
[CmdletBinding()]
param()

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name -SecurityProtocol -InstallNuget -TrustPSGallery

$FciDscModules = @(
    'ActiveDirectoryDsc',
    'ComputerManagementDsc',
    'DnsServerDsc',
    'FailoverClusterDsc',
    'NetworkingDsc',
    'PSDscResources',
    'SqlServerDsc'
)

try {
    $AvailableModules = (Get-Module -ListAvailable).Name

    ## Installing required DSC modules if not present
    Write-Host "Installing DSC modules"

    foreach ($ModuleName in $FciDscModules) {
        if (-not ($AvailableModules -match $ModuleName)) {
            Install-Module -Name $ModuleName -AllowClobber -Scope AllUsers
        }
    }

    if ($null -eq (Get-Module -Name "SqlServer" -ListAvailable)) {
        # Ignore existing SQLPS module and install current SqlServer module
        Install-Module -Name "SqlServer" -AllowClobber -Force
    }

    if ($null -eq (Get-Module -Name "ActiveDirectory" -ListAvailable)) {
        Install-WindowsFeature RSAT-AD-PowerShell -IncludeAllSubFeature
    }

    ## Disable Windows Firewall
    Write-Host "Disabling Windows Firewall"
    Get-NetFirewallProfile | Set-NetFirewallProfile -Enabled False

    ## Create directory to store DSC certificate
    Write-Host "Creating Directory for DSC Public Cert"
    New-Item -Path C:\cfn\dsc\publickeys -ItemType directory

    ## Create self-signed certificate for DSC
    Write-Host "Setting up DSC Certificate to Encrypt Credentials in MOF File"
    $cert = New-SelfSignedCertificate -Type DocumentEncryptionCertLegacyCsp -DnsName 'AWSLWDscEncryptCert' -HashAlgorithm SHA256

    ## Exporting the public key certificate
    $cert | Export-Certificate -FilePath "C:\cfn\dsc\publickeys\AWSLWDscPublicKey.cer" -Force
} catch {
    $_ | Write-AWSLaunchWizardException
}
<#
.SYNOPSIS
Installs required Windows Features and Powershell modules for FCI ONTAP deployments

.DESCRIPTION
Installs required Windows Features such as:
    - Multipath-IO
    - Failover-Clustering
    - RSAT-DNS-Server
Installs required Powershell module(s):
    - Netapp.Ontap

.LINK
https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/mount-iscsi-windows.html

.NOTES
The installed Windows Features do require the instance to be rebooted at script completion
#>
[CmdletBinding()]
param()

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

## Install Windows Features required for ONTAP
try {
    # Requires reboot
    Install-WindowsFeature Multipath-IO,Failover-Clustering,RSAT-DNS-Server -IncludeManagementTools
} catch {
    $_ | Write-AWSLaunchWizardException
}

## Start iSCSI initiator
try {
    $ServiceMSiSCSI = Get-Service | Where-Object { $_.Name -eq "MSiSCSI" }

    if ($null -eq $ServiceMSiSCSI) {
        throw "MSiSCSI service not found, stopping deployment."
    }

    if ($ServiceMSiSCSI.StartType -ne "Automatic") {
        if ($ServiceMSiSCSI.Status -ne "Stopped") {
            $ServiceMSiSCSI | Stop-Service
        }

        $ServiceMSiSCSI | Set-Service -StartupType "Automatic"
    }

    $ServiceMSiSCSI | Start-Service -ErrorAction SilentlyContinue

    if ($ServiceMSiSCSI.Status -ne "Running") {
        throw "Unable to start the MSiSCSI service, stopping deployment."
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}

## Install latest modules for required services
$OntapModules = @(
    'NetApp.ONTAP'
)

Invoke-SimpleModuleInstaller -ModuleNames $OntapModules

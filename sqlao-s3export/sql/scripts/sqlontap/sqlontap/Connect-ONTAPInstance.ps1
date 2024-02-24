<#
.SYNOPSIS
Mounts an iSCSI LUN on the Windows client.

.DESCRIPTION
    - Connects to each of your file system’s iSCSI interfaces.
    - Adds and configures MPIO for iSCSI.
    - Establishes 8 sessions for each iSCSI connection, which enables the client
        to drive up to 40 Gb/s (5,000 MB/s) of aggregate throughput to the iSCSI LUN.

.LINK
https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/mount-iscsi-windows.html#configure-iscsi-on-fsx
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Stackname
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    $sessionToken = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri "http://169.254.169.254/latest/api/token"
    Set-Variable -Name 'Token' -Value $sessionToken -Scope Global

    $fslist = Get-FSXFileSystem | Where-Object { $_.Tags.Key -eq 'aws:cloudformation:stack-name' -and $_.Tags.Value -eq $Stackname }
    $TargetPortalAddresses = (Get-FSXStorageVirtualMachine | Where-Object { $_.FileSystemId -eq $fslist.FileSystemId }).Endpoints.Iscsi.IpAddresses

    $LocaliSCSIAddress = Get-InstanceMetadataFromPath -Path "meta-data/local-ipv4"

    Foreach ($TargetPortalAddress in $TargetPortalAddresses) {
        New-IscsiTargetPortal -TargetPortalAddress $TargetPortalAddress -TargetPortalPortNumber 3260 -InitiatorPortalAddress $LocaliSCSIAddress
    }

    #Add MPIO support for iSCSI
    New-MSDSMSupportedHW -VendorId MSFT2005 -ProductId iSCSIBusType_0x9

    #Establish iSCSI connection
    1..3 | %{Foreach($TargetPortalAddress in $TargetPortalAddresses){Get-IscsiTarget | Connect-IscsiTarget -IsMultipathEnabled $true -TargetPortalAddress $TargetPortalAddress -InitiatorPortalAddress $LocaliSCSIAddress -IsPersistent $true} }

    #Set the MPIO Policy to Round Robin
    Set-MSDSMGlobalDefaultLoadBalancePolicy -Policy RR
} catch {
    Write-Output "Error connecting to Iscsi targets"
    $_ | Write-AWSLaunchWizardException
}
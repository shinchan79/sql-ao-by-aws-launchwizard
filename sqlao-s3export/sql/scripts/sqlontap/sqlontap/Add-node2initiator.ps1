<#
.SYNOPSIS
Adds initiator for secondary node to an existing initiator group.

.DESCRIPTION
Waits for initiator group to be created (via primary node),
then runs Add-NcIgroupInitiator which adds the initiator
to an existing initiator group.

.LINK
https://docs.aws.amazon.com/powershell/latest/reference/items/Get-FSXFileSystem.html
https://www.netapp.com/media/16861-tr-4475.pdf?v=93202073432AM
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$sqlvmname,

    [Parameter(Mandatory=$true)]
    [string]$igroup,

    [Parameter(Mandatory=$true)]
    [string]$Stackname
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    ## Retrieve secure credentials using provided secret name
    $FSxSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -RetrieveCredentialOnly

    $fslist = Get-FSXFileSystem | Where-Object { $_.Tags.Key -eq 'aws:cloudformation:stack-name' -and $_.Tags.Value -eq $Stackname }

    $MgmtDNS = $fslist.ontapconfiguration.Endpoints.Management.DNSName
    $nodeiqn = (Get-InitiatorPort).NodeAddress

    Connect-NcController -Name $MgmtDNS -Credential $FSxSecureCredObject.Credential -Vserver $sqlvmname

    do {
        $ig = Get-NcIgroup -Name $igroup -WarningAction SilentlyContinue
    } while ($null -eq $ig)

    Add-NcIgroupInitiator -Name $igroup -Initiator $nodeiqn
} catch {
    Write-Output "Adding Initiator failed"
    $_ | Write-AWSLaunchWizardException
}
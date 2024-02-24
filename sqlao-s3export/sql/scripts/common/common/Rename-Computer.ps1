[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$NewName,

    [Parameter(Mandatory=$false)]
    [switch]$Restart
)

try {
    $ErrorActionPreference = "Stop"

    $renameComputerParams = @{
        NewName = $NewName
    }
    $domainName = (Get-WmiObject Win32_ComputerSystem).Domain
    if ($domainName -eq "WORKGROUP") {

        Rename-Computer @renameComputerParams

        if ($Restart) {
            C:\cfn\scripts\common\Restart-Computer.ps1
        }
    } else {
        throw "[ERROR] The AMI was created without sysprep shut down. It already has domain joined and could not be joined again. "
    }
}
catch {
    $_ | Write-AWSLaunchWizardException
}
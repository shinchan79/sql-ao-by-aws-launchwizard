[CmdletBinding()]
param(

    [Parameter(Mandatory=$true)]
    [String]
    $VPCCIDR

)

try {
    $ErrorActionPreference = "SilentlyContinue"
    #Set Powershell connection encryption to TLS 1.2 for Installting NuGet
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Allow Powershell to download resources from PSGallery
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted | Out-Null

    # Install necessary PowerShell modules
    Install-Module -Name xPSDesiredStateConfiguration | Out-Null
    Install-Module -Name NetworkingDSC | Out-Null

    # Configure SQLHA
    $SQLHAPath = 'C:\cfn\DSC\SQLHA'
    C:\cfn\DSC\BuildCompositeResources.ps1 -ModuleName 'SQLHA' -InputPath $SQLHAPath\Scripts\
    . $SQLHAPath\SQLHA.ps1 ; SQLHA -Computername $env:COMPUTERNAME -SecurityGroup $VPCCIDR -OutputPath $SQLHAPath
    Start-DscConfiguration -Path $SQLHAPath -Computername $env:COMPUTERNAME -Wait -Force | Out-Null
    if (Test-Path 'C:\cfn\AWSDriver\install.ps1' -PathType Leaf) {
        C:\cfn\AWSDriver\install.ps1 -noreboot
    }

    # Configure LaunchWizard
    $LaunchWizardPath = 'C:\cfn\DSC\LaunchWizard'
    C:\cfn\DSC\BuildCompositeResources.ps1 -ModuleName 'LaunchWizard' -InputPath $LaunchWizardPath\Scripts\
    . $LaunchWizardPath\LaunchWizard.ps1 ; LaunchWizard -Computername $env:COMPUTERNAME -OutputPath $LaunchWizardPath
    Start-DscConfiguration -Path $LaunchWizardPath -Computername $env:COMPUTERNAME -Wait -Force | Out-Null
    if (Test-Path 'C:\cfn\AWSPVDriver\install.ps1' -PathType Leaf) {
        C:\cfn\AWSPVDriver\install.ps1 -quiet -noreboot -verboselogging
    }
    # Tell system not to restart the instance as we are explicitly restarting instance post the script
    $LASTEXITCODE = 0
    return 0

}
catch {
    # Write-AWSLaunchWizardException along with writing to log sends failure signal to cfn, remove call to Write-AWSLaunchWizardException
    # Log failures but do not fail on it
    return 0
}

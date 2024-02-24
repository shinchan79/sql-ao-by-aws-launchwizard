[CmdletBinding()]
param()

try {
    $ErrorActionPreference = "SilentlyContinue"
    #Set Powershell connection encryption to TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Allow Powershell to download resources from PSGallery
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted

    # Install necessary PowerShell modules
    Install-Module -Name SqlServerDsc

    # Configure SQLAddAdmins
    $AddAdminPath = 'C:\cfn\DSC\SQLAddAdmins'
    C:\cfn\DSC\BuildCompositeResources.ps1 -ModuleName SQLAddAdmins -InputPath "$AddAdminPath\Scripts\"
    . $AddAdminPath\SQLAddAdmins.ps1 ; SQLAddAdmins -Computername $env:COMPUTERNAME -OutputPath $AddAdminPath
    Start-DscConfiguration -Path $AddAdminPath -Computername $env:COMPUTERNAME -Wait -Force

}
catch {
    # Write-AWSLaunchWizardException along with writing to log sends failure signal to cfn, remove call to Write-AWSLaunchWizardException
    # Log failures but do not fail on it
    return 0
}
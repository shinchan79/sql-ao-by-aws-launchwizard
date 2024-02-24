[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$DomainNetBIOSName,

    [Parameter(Mandatory=$false)]
    [string]$DomainDNSName,

    [Parameter(Mandatory=$false)]
    [string]$ServerName='*'
)

function Add-RegistryEntry {
    param(
        [Parameter(Mandatory=$true)]
        [string]$KeyPath,

        [Parameter(Mandatory=$true)]
        [string]$KeyName
    )

    $PathToTest = $KeyPath,$KeyName -Join "\"

    if (-Not (Test-Path -Path $PathToTest)) {
        New-Item -Path $KeyPath -Name $KeyName -Force

        # Validate entry was created successfully
        Start-Sleep -Seconds 5

        if (-Not (Test-Path -Path $PathToTest)) {
            throw "Unable to validate creation of registry entry {0}\{1}" -f $KeyPath, $KeyName
        }
    }
}

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\cfn\log\EnableCredSsp.ps1.txt -Append

try {
    Enable-WSManCredSSP Client -DelegateComputer $ServerName -Force

    if ($DomainNetBIOSName) {
        Enable-WSManCredSSP Client -DelegateComputer *.$DomainNetBIOSName -Force
    }

    if ($DomainDNSName) {
        Enable-WSManCredSSP Client -DelegateComputer *.$DomainDNSName -Force
    }

    Enable-WSManCredSSP Server -Force

    # Sometimes Enable-WSManCredSSP doesn't get it right, so we set some registry entries by hand
    $ParentKey = "hklm:\SOFTWARE\Policies\Microsoft\Windows"
    $CredDelegationKey = "$ParentKey\CredentialsDelegation"
    $AllowFreshKey = "$CredDelegationKey\AllowFreshCredentials"
    $AllowFreshNTLMKey = "$CredDelegationKey\AllowFreshCredentialsWhenNTLMOnly"

    # Create root key
    Add-RegistryEntry -KeyPath $ParentKey -KeyName 'CredentialsDelegation'

    # Create root key properties
    New-ItemProperty -Path $CredDelegationKey -Name AllowFreshCredentials -Value 1 -PropertyType Dword -Force
    New-ItemProperty -Path $CredDelegationKey -Name ConcatenateDefaults_AllowFresh -Value 1 -PropertyType Dword -Force
    New-ItemProperty -Path $CredDelegationKey -Name AllowFreshCredentialsWhenNTLMOnly -Value 1 -PropertyType Dword -Force
    New-ItemProperty -Path $CredDelegationKey -Name ConcatenateDefaults_AllowFreshNTLMOnly -Value 1 -PropertyType Dword -Force

    # Create required credential sub-keys
    Add-RegistryEntry -KeyPath $CredDelegationKey -KeyName 'AllowFreshCredentials'
    Add-RegistryEntry -KeyPath $CredDelegationKey -KeyName 'AllowFreshCredentialsWhenNTLMOnly'

    # Create required credential sub-key properties
    New-ItemProperty -Path $AllowFreshKey -Name 1 -Value "WSMAN/$ServerName" -PropertyType String -Force
    New-ItemProperty -Path $AllowFreshNTLMKey -Name 1 -Value "WSMAN/$ServerName" -PropertyType String -Force

    if ($DomainNetBIOSName) {
        New-ItemProperty -Path $AllowFreshKey -Name 2 -Value "WSMAN/$ServerName.$DomainNetBIOSName" -PropertyType String -Force
        New-ItemProperty -Path $AllowFreshNTLMKey -Name 2 -Value "WSMAN/$ServerName.$DomainNetBIOSName" -PropertyType String -Force
    }

    if ($DomainDNSName) {
        New-ItemProperty -Path $AllowFreshKey -Name 2 -Value "WSMAN/$ServerName.$DomainDNSName" -PropertyType String -Force
        New-ItemProperty -Path $AllowFreshNTLMKey -Name 2 -Value "WSMAN/$ServerName.$DomainDNSName" -PropertyType String -Force
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}

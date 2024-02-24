[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminSecretKey,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory=$true)]
    [string]$ServiceAccountUser,

    [Parameter(Mandatory=$true)]
    [string]$ServiceAccountSecretKey,

    [Parameter(Mandatory=$false)]
    [string]$ADServerNetBIOSName=$env:COMPUTERNAME,

    [Parameter(Mandatory=$false)]
    [string]$DomainNetBIOSName=$env:USERDOMAIN
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

if ($null -eq (Get-Module -Name ActiveDirectory -ListAvailable)) {
    Install-WindowsFeature -Name RSAT-AD-PowerShell
}

$DscRootDirectory = "C:\cfn\dsc"

$DscConfigName = "ADUser_CreateUser_Config"
$DscConfigDirectory = $DscRootDirectory,$DscConfigName -Join "\"

## Retrieve the DSC Cert Encryption Thumbprint used to secure the MOF File
$DscCertThumbprint = (Get-ChildItem -Path cert:\LocalMachine\My | Where-Object { $_.Subject -eq "CN=AWSLWDscEncryptCert" }).Thumbprint

$ConfigurationData = Get-CommonConfigurationData -CertificateThumbprint $DscCertThumbprint

try {
    ## Retrieve secure credentials using provided secret name
    $AdminSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $DomainAdminSecretKey -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser
    $SQLServiceSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $ServiceAccountSecretKey -DomainDNSName $DomainDNSName -DomainUserName $ServiceAccountUser

    Configuration $DscConfigName
    {
        param
        (
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [System.Management.Automation.PSCredential]
            $AdminSecureCreds,

            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            [System.Management.Automation.PSCredential]
            $SQLServiceSecureCreds
        )

        Import-DscResource -ModuleName 'ActiveDirectoryDsc'
        Import-DscResource -ModuleName 'PSDscResources'

        $ServiceAccountADUser = Get-ADUser -Filter { sAMAccountName -eq $ServiceAccountUser } -Credential $AdminSecureCreds

        # If the user account is identified, test the provided password.
        if ($null -ne $ServiceAccountADUser) {
            Write-Host "User already exists."

            # Adding brief wait condition for edge case scenario - prevents potential race condition in FCI scenarios.
            Start-Sleep -Seconds 60

            # Ensure that password is correct for the user
            try {
                Get-ADUser -Identity $ServiceAccountUser -Credential $SQLServiceSecureCreds -ErrorAction SilentlyContinue | Out-Null

                Write-Output "Validated credentials for user $($SQLServiceSecureCreds.UserName), no MOF will be generated."
                return
            } catch {
                throw "The password for $($SQLServiceSecureCreds.UserName) is incorrect, unable to proceed."
            }
        } else {
            Node localhost
            {
                ADUser $($SQLServiceSecureCredObject.DomainDlln)
                {
                    Ensure               = 'Present'
                    UserName             = $ServiceAccountUser
                    Password             = $SQLServiceSecureCreds
                    DomainName           = $DomainDNSName
                    UserPrincipalName    = $($SQLServiceSecureCredObject.Upn)
                    PsDscRunAsCredential = $AdminSecureCreds
                }
            }
        }
    }

    ADUser_CreateUser_Config -OutputPath $DscConfigDirectory -ConfigurationData $ConfigurationData -AdminSecureCreds $AdminSecureCredObject.Credential -SQLServiceSecureCreds $SQLServiceSecureCredObject.Credential

    # Check whether any MOF files exist in directory by specifying path as:
    #   C:\cfn\dsc\ADUser_CreateUser_Config\*.mof

    if (Test-Path -Path ($DscConfigDirectory,"*" -Join "\") -Include *.mof) {
        Start-DscConfiguration $DscConfigDirectory -Wait -Force -Verbose
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}

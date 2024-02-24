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
    [string]$ADServerNetBIOSName=$env:COMPUTERNAME
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

if ($null -eq (Get-Module -Name ActiveDirectory -ListAvailable)) {
    Install-WindowsFeature -Name RSAT-AD-PowerShell
}

try {
    ## Retrieve secure credentials using provided secret name
    $AdminSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $DomainAdminSecretKey -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser -RetrieveCredentialOnly
    $SQLServiceSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $ServiceAccountSecretKey -DomainDNSName $DomainDNSName -DomainUserName $ServiceAccountUser

    $createUserSB = {
        $ErrorActionPreference = "Stop"

        Write-Host "Searching for user $Using:ServiceAccountUser"

        $ServiceAccountADUser = Get-ADUser -Filter { sAMAccountName -eq $Using:ServiceAccountUser } -Credential ($Using:AdminSecureCredObject).Credential

        if ($null -ne $ServiceAccountADUser) {
            Write-Host "User already exists."

            # Adding brief wait condition for edge case scenario - prevents potential race condition in FCI scenarios.
            Start-Sleep -Seconds 60

            # Ensure that password is correct for the user
            try {
                Get-ADUser -Identity $Using:ServiceAccountUser -Credential ($Using:SQLServiceSecureCredObject).Credential -ErrorAction SilentlyContinue | Out-Null

                Write-Output "Validated credentials for user ($Using:SQLServiceSecureCredObject).Username"
            } catch {
                throw "The password for $Using:ServiceAccountUser is incorrect"
            }
        } else {
            Write-Host "Creating user $Using:ServiceAccountUser"

            try {
                New-ADUser -Name $Using:ServiceAccountUser -UserPrincipalName ($Using:SQLServiceSecureCredObject).Upn -AccountPassword ($Using:SQLServiceSecureCredObject).Credential.Password -Enabled $true -PasswordNeverExpires $true -ErrorAction SilentlyContinue
            } catch {
                if (($_.Exception).GetType() -eq [Microsoft.ActiveDirectory.Management.ADIdentityAlreadyExistsException]) {
                    Write-Output "User $Using:ServiceAccountUser was created by another node since last check; no further action required."
                } else {
                    throw "Unhandled exception when attempting to create AD user $Using:ServiceAccountUser. Exception message: $($_.Exception.Message)"
                }
            }
        }
    }

    Write-Host "Invoking command on $ADServerNetBIOSName"
    Invoke-Command -ScriptBlock $createUserSB -ComputerName $ADServerNetBIOSName -Credential $AdminSecureCredObject.Credential -Authentication Credssp
}
catch {
    $_ | Write-AWSLaunchWizardException
}
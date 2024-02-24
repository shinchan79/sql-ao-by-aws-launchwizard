# sssandee@:
# This powershell script creates the required service principal names(SPN's) required for SQLServer Auth
# these SPN's are required for the KDC running on the AD instance to issue kerberos tokens. This script
# also sets the kerberos delegation.
#
# InputParameters: 
#   $Domain: Active Directory Domain to which SQLServer Instance is joined. [Eg:corp.sssandee.com]
#   $SQLServerClusterInstances : Array of SQLServerInstances of a Cluster created by LaunchWizard [Eg:'sssandee1-P','sssandee1-S1']
#   $SQLServerPort: Port used by SQLServer [Eg:1433]
#   $SQLServerServiceAccount: Service Account used to run SQLServer Process. [Eg:sssandeesqlsvc]
#   $DomainAdminUserName: An Existing Active Directory user with previleges to create SPN's ,usually a DomainAdministrator [Eg:Administrator]
#   $DomainAdminPasswordKey: key to retrieve encrypted password for the domain user($DomainAdminUserName) from SSM.  
#
#
#  Example Invocation:
# .\sandeep.ps1 -Domain 'corp.sandeep.com' -SQLServerClusterInstances 'sssandee1-P','sssandee1-S1' -SQLServerPort '1433' -SQLServerServiceAccount 'sssandeesqlsvc' -DomainAdminUserName 'Administrator' -DomainAdminPasswordKey "AWSDXUser"
#
#
# Note: Do not input NetBIOS along with $DomainAdminUserName.We don't want to use NETBIOS to maintain consistency between windows versions.
# Note: This script uses setspn.exe utility which is mostly available on all windows versions from 2008R2 which has AD Powershelltools installed.
#
# OnSuccessfull execution this script creates the following SPN's for the input mentioned in Eg.
# 
#
#
#   MSSQLSvc/sssandee1-S1.corp.sssandee.com:1433
#   MSSQLSvc/sssandee1-S1.corp.sssandee.com
#   MSSQLSvc/sssandee1-P.corp.sssandee.com:1433
#   MSSQLSvc/sssandee1-P.corp.sssandee.com
#   MSSQLSvc/sssandee1-P
#   MSSQLSvc/sssandee1-S1
#
#
[CmdletBinding()]
param(
    [string]
    $Domain,

    [array]
    $SQLServerClusterInstances,

    [string]
    $SQLServerPort,

    [string]
    $SQLServerServiceAccount,

    [string]
    $DomainAdminUserName,

    [string]
    $DomainAdminPasswordKey

)

try {
    $ErrorActionPreference = "Stop"

    if ([String]::IsNullOrWhiteSpace($Domain)) {    
        throw "Invalid input Domain:$Domain for CreateServicePrincipleNames.ps1"
    }
     
    if ([String]::IsNullOrWhiteSpace($SQLServerPort)) {
        throw "Invalid input SQLServerPort:$SQLServerPort for CreateServicePrincipleNames.ps1"
    }

    if ([String]::IsNullOrWhiteSpace($SQLServerServiceAccount)) {
        throw "Invalid input SQLServerServiceAccount:$SQLServerServiceAccount for CreateServicePrincipleNames.ps1"
    }

    if ([String]::IsNullOrWhiteSpace($DomainAdminUserName)) {
        throw "Invalid input DomainAdminUserName:$DomainAdminUserName for CreateServicePrincipleNames.ps1"
    }

    if ([String]::IsNullOrWhiteSpace($DomainAdminPasswordKey)) {
        throw "Invalid input DomainAdminPasswordKey:$DomainAdminPasswordKey for CreateServicePrincipleNames.ps1"
    }

    if ($SQLServerClusterInstances.Length -le 0) {
        throw "Invalid input $SQLServerClusterInstances for CreateServicePrincipleNames.ps1"
    }

    [String]$DomainUser = [String]::Format("{0}\{1}", $Domain, $DomainAdminUserName)

    #$secure = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
    #$pass = ConvertTo-SecureString $secure -AsPlainText -Force

    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $pass = ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force
    
    if ([String]::IsNullOrWhiteSpace($pass)) {
        throw "Invalid Password retrived from SSMParameterStore in CreateServicePrincipleNames.ps1"
    }

    $cred = New-Object System.Management.Automation.PSCredential -ArgumentList $DomainUser, $pass
    
    [String]$SQLServerServiceName = "MSSQLSvc"
    [String]$Deletespncmd = "setspn.exe -d"
    [String]$Setspncmd = "setspn.exe -s"
    
    foreach ($SQLServerInstance in $SQLServerClusterInstances) {     
         
        [String]$Spn1 = [String]::format("{0}/{1}.{2} {3}\{4}", $SQLServerServiceName, $SQLServerInstance, $Domain, $Domain, $SQLServerServiceAccount)
        [String]$Spn2 = [String]::format("{0}/{1}.{2}:{3} {4}\{5}", $SQLServerServiceName, $SQLServerInstance, $Domain, $SQLServerPort, $Domain, $SQLServerServiceAccount)
        [String]$Spn3 = [String]::format("{0}/{1} {2}\{3}", $SQLServerServiceName, $SQLServerInstance, $Domain, $SQLServerServiceAccount)
       
                
        #Delete if any existing Service Principle Names
        Start-Process powershell.exe -Credential ($cred) -NoNewWindow -ArgumentList "$Deletespncmd $Spn1"
        Start-Process powershell.exe -Credential ($cred) -NoNewWindow -ArgumentList "$Deletespncmd $Spn2"
        Start-Process powershell.exe -Credential ($cred) -NoNewWindow -ArgumentList "$Deletespncmd $Spn3"

        #Create new Service Principle Names
        Start-Process powershell.exe -Credential ($cred) -NoNewWindow -ArgumentList "$Setspncmd $Spn1"
        Start-Process powershell.exe -Credential ($cred) -NoNewWindow -ArgumentList "$Setspncmd $Spn2"
        Start-Process powershell.exe -Credential ($cred) -NoNewWindow -ArgumentList "$Setspncmd $Spn3"


        #Set the kerberos delegation
        Get-ADComputer -Identity $SQLServerInstance -Credential $cred|Set-ADAccountControl -TrustedForDelegation 1

    }
   
}
catch {
    $_ | Write-AWSLaunchWizardException
}

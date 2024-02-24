[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$WSFClusterName,

    [Parameter(Mandatory=$true)]
    [string]$DomainName,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminPasswordKey,

    [Parameter(Mandatory=$true)]
    [string]$FileServerNetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]$SQLServiceAccount

)

Try
{
    Start-Transcript -Path C:\cfn\log\Set-Folder-Permissions.ps1.txt -Append
    $ErrorActionPreference = "Stop"

    $DomainAdminFullUser = $DomainName + '\' + $DomainAdminUser
    #$DomainAdminPassword = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
    #$DomainAdminSecurePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    #$DomainAdminCreds = New-Object System.Management.Automation.PSCredential($DomainAdminFullUser, $DomainAdminSecurePassword)
    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $DomainAdminFullUser = $DomainNetBIOSName + '\' + $DomainAdminUser
    $pass = ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force
    $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,$pass))

    $SetPermissions = {
        $ErrorActionPreference = "Stop"
        $acl = Get-Acl C:\witness
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule( $Using:obj, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl C:\witness $acl
        $stabilized = $true
    }


    New-PSSession -ComputerName $FileServerNetBIOSName -Name 'aclSession' -Credential $DomainAdminCreds -Authentication Credssp | Out-Null
    $Session = Get-PSSession -Name 'aclSession'

    $obj = $DomainNetBIOSName + '\' + $WSFClusterName + '$'
    Invoke-Command -Session $Session -ScriptBlock $SetPermissions
    Start-Sleep -s 20
    $obj = $DomainNetBIOSName + '\' + $SQLServiceAccount
    Invoke-Command -Session $Session -ScriptBlock $SetPermissions

    Remove-PSSession -Session $Session
}
Catch{
    $_ | Write-AWSLaunchWizardException
}

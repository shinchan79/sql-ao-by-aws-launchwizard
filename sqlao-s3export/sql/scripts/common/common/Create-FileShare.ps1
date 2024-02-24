[CmdletBinding()]
param(

    [Parameter(Mandatory=$true)]
    [string]$DomainName,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminPasswordKey,
  
    [Parameter(Mandatory=$true)]
    [string]$ShareName,

    [Parameter(Mandatory=$true)]
    [string]$Path,

    [Parameter(Mandatory=$false)]
    [string]$ServerName='localhost',

    [Parameter(Mandatory=$true)]
    [string]$FolderPath,

    [Parameter(Mandatory=$true)]
    [string]$FolderName,

    [Parameter(Mandatory=$false)]
    [string[]]$FullAccessUser='everyone'

)

try{
    Start-Transcript -Path C:\cfn\log\Create-FileShare.ps1.txt -Append
    $ErrorActionPreference = "Stop"

    $DomainAdminFullUser = $DomainName + '\' + $DomainAdminUser
    #$DomainAdminPassword = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
    #$DomainAdminSecurePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    #$DomainAdminCreds = New-Object System.Management.Automation.PSCredential($DomainAdminFullUser, $DomainAdminSecurePassword)
    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))
    $CreateShareFile = {
        Start-Transcript -Path C:\cfn\log\Create-FileShare.ps1.txt -Append
        $ErrorActionPreference = "Stop"
        New-Item -ItemType directory -Path $Using:FolderPath -Name $Using:FolderName
        Start-Sleep -Seconds 10
        New-SmbShare -Name $Using:ShareName -Path $Using:Path -FullAccess $Using:FullAccessUser
    }

    New-PSSession -ComputerName $env:COMPUTERNAME -Name 'aclSession' -Credential $DomainAdminCreds -Authentication Credssp | Out-Null
    $Session = Get-PSSession -Name 'aclSession'
    Invoke-Command -Session $Session -ScriptBlock $CreateShareFile
    Remove-PSSession -Session $Session

} catch {
    $_ + " | " + $exception | Write-AWSLaunchWizardException
}

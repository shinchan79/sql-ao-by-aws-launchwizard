[CmdletBinding()]
param(

    [Parameter(Mandatory=$true)]
    [string]$DomainName,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminPasswordKey,

    [Parameter(Mandatory=$false)]
    [string]$WSFCNodeNames,

    [Parameter(Mandatory=$true)]
    [string]$NodeAccessTypes,

    [Parameter(Mandatory=$false)]
    [string]$FileServerNetBIOSName,

    [Parameter(Mandatory=$false)]
    [bool]$Witness=$true

)
try {
    Start-Transcript -Path C:\cfn\log\Set-ClusterQuorum.ps1.txt -Append
    $ErrorActionPreference = "Stop"

        $DomainAdminFullUser = $DomainName + '\' + $DomainAdminUser
        #$DomainAdminPassword = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
        #$DomainAdminSecurePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
        #$DomainAdminCreds = New-Object System.Management.Automation.PSCredential($DomainAdminFullUser, $DomainAdminSecurePassword)
        $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
        $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))


    $SetClusterQuorum={
        $ErrorActionPreference = "Stop"
        if ($Using:Witness) {
            $ShareName = "\\" + $Using:FileServerNetBIOSName + "\witness"
            Set-ClusterQuorum -NodeAndFileShareMajority $ShareName
        } else {
            Set-ClusterQuorum -NodeMajority
        }
    }

    New-PSSession -ComputerName $env:COMPUTERNAME -Name 'quorumSession' -Credential $DomainAdminCreds -Authentication Credssp | Out-Null
    $Session = Get-PSSession -Name 'quorumSession'
    Invoke-Command -Scriptblock $SetClusterQuorum -ComputerName $env:COMPUTERNAME -Credential $DomainAdminCreds
    Remove-PSSession -Session $Session
}
catch {
    $_ | Write-AWSLaunchWizardException
}

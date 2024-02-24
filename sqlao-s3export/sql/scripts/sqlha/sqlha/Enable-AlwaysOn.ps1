[CmdletBinding()]
param(

    [Parameter(Mandatory=$true)]
    [int]$NumberOfNodes,

    [Parameter(Mandatory=$true)]
    [string]$DomainName,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminPasswordKey,

    [Parameter(Mandatory=$true)]
    [string[]]$NodeNetBIOSNames

)
$success = $false
For ($i=0; $i -le 4; $i++) {
    if ($success -eq $true) {
        Break
    }

    try {
        Start-Transcript -Path C:\cfn\log\Enable-SqlAlwaysOn.ps1.txt -Append
        $ErrorActionPreference = "Stop"

        $DomainAdminFullUser = $DomainName + '\' + $DomainAdminUser
        #$DomainAdminPassword = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
        #$DomainAdminSecurePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
        #$DomainAdminCreds = New-Object System.Management.Automation.PSCredential($DomainAdminFullUser, $DomainAdminSecurePassword)
        $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
        $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))

        $EnableAlwaysOnPs={
            $ErrorActionPreference = "Stop"
            Import-Module SQLPS
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
            Enable-SqlAlwaysOn -ServerInstance $Using:serverInstance -Force
        }

        ForEach ($serverInstance in $NodeNetBIOSNames[0..($NumberOfNodes - 1)]) {
            Invoke-Command -Scriptblock $EnableAlwaysOnPs -ComputerName $serverInstance -Credential $DomainAdminCreds
        }

        $success = $true

    }
    catch {
        if ($i -eq 3) {
            $_ | Write-AWSLaunchWizardException
        }
        else {
            $success = $false
        }
    }

    Start-Sleep -s 300
}



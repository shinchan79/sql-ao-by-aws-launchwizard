[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$UserName,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminPasswordKey

)
try {
    #$secure = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
    #$pass = ConvertTo-SecureString $secure -AsPlainText -Force
    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $pass = ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential -ArgumentList $UserName, $pass
    $pc = hostname
    Remove-Computer -ComputerName $pc -Credential $cred -PassThru -Verbose -Force
}
catch
{
    $_ | Write-AWSLaunchWizardException

}
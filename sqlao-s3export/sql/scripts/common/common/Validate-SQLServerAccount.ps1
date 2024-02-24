[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$SQLServerAccount,

    [Parameter(Mandatory=$true)]
    [string]$SQLServerAccountPasswordKey

)
try
{
    #$secure = (Get-SSMParameterValue -Names $SQLServerAccountPasswordKey -WithDecryption $True).Parameters[0].Value
    #$pass = ConvertTo-SecureString $secure -AsPlainText -Force
    $secure = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $pass = ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force

    [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null
    $srv = new-object ('Microsoft.SqlServer.Management.Smo.Server') "LOCALHOST"
    $names = $srv.Databases | Select name

    if($names.Count -gt 0) {
        Write-Output @{ status= "Completed"; reason= "Done." } | ConvertTo-Json -Compress
    }else {
        Write-Output @{ status= "Failed"; reason = "Was able to connect to SQLServer using credentials but no databases exist." } | ConvertTo-Json -Compress
    }
}
catch
{
    $exception = $_
    Write-Output @{ status= "Failed"; reason = "Unable to connect to SQL Server using credentials. Exception: $exception." } | ConvertTo-Json -Compress
}
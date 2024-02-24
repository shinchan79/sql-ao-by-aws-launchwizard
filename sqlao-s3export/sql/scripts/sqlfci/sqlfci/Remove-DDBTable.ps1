[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DDBTableName
)

#Remove DDB Table
try{
    Get-DDBTable -TableName $DDBTableName | Remove-DDBTable -Force
} catch{
    $_ | Write-AWSLaunchWizardException
}
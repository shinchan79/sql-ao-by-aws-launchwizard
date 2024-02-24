[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Region,

    [Parameter(Mandatory=$true)]
    [string]$DDBTableName,

    [Parameter(Mandatory=$true)]
    [string]$NodeName,

    [Parameter(Mandatory=$true)]
    [string]$IPAddress
)

function putDDBItem
{
    param (
        [string]$tableName,
        [string]$nodeName,
        [string]$ipAddress
    )
    $req = New-Object Amazon.DynamoDBv2.Model.PutItemRequest
    $req.TableName = $tableName
    $req.Item = New-Object 'system.collections.generic.dictionary[string,Amazon.DynamoDBv2.Model.AttributeValue]'

    $valObj = New-Object Amazon.DynamoDBv2.Model.AttributeValue
    $valObj.S = $nodeName
    $req.Item.Add('NodeName', $valObj)

    $val1Obj = New-Object Amazon.DynamoDBv2.Model.AttributeValue
    $val1Obj.S = $ipAddress
    $req.Item.Add('IPAddress', $val1Obj)

    $output = $dbClient.PutItem($req)
}

try {
    Add-Type -Path (${env:ProgramFiles(x86)}+"\AWS SDK for .NET\bin\Net45\AWSSDK.DynamoDBv2.dll")
    $regionEndpoint = [Amazon.RegionEndPoint]::GetBySystemName($Region)
    $dbClient = New-Object Amazon.DynamoDBv2.AmazonDynamoDBClient($regionEndpoint)

    putDDBItem -tableName $DDBTableName -nodeName $NodeName -ipAddress $IPAddress
}
catch {
    $_ | Write-AWSLaunchWizardException
}
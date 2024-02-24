
[CmdletBinding()]
param(

    [Parameter(Mandatory=$true)]
    [string]$Region,

    [Parameter(Mandatory=$true)]
    [string]$DDBTableName,

    [Parameter(Mandatory=$true)]
    [string]
    $numberOfNodes
)
    Start-Transcript -Path C:\cfn\log\Query-DDBTable.ps1.txt -Append
    $ErrorActionPreference = "Stop"

Add-Type -Path (${env:ProgramFiles(x86)}+"\AWS SDK for .NET\bin\Net45\AWSSDK.DynamoDBv2.dll")
    try
    {
        #Query DynamoDB for SQL nodes information
        $count = 0
        while ($count -le 15)
        {
        $regionEndpoint=[Amazon.RegionEndPoint]::GetBySystemName($Region)
        $client = New-Object Amazon.DynamoDBv2.AmazonDynamoDBClient($regionEndpoint)
        $req = New-Object Amazon.DynamoDBv2.Model.ScanRequest
        $req.TableName = $DDBTableName
        $result = $client.Scan($req)
        $nodenumber = [int]$numberOfNodes
        if ($result.count -lt $nodenumber)
            {
                $count++
                Write-OutPut " Count is $count"
                Write-Output " Number of Nodes is $($result.count)"
                sleep 180
            }
            else
            {
                Write-Output " Number of Nodes is $($result.count)"
                break
            }
        }
        If ($count -gt 15)
        {
            throw "Dynamo DB table count does not match Node count. Exiting"
        }
    }catch{
            $_ | Write-AWSLaunchWizardException
    }
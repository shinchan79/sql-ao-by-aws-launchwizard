[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$DDBTableName,

    [Parameter(Mandatory=$true)]
    [string]$NodeCount,

    [Parameter(Mandatory=$true)]
    [string]$Region
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

$DynamoDBv2Path = Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath "AWS SDK for .NET\bin\Net45\AWSSDK.DynamoDBv2.dll"
Add-Type -Path $DynamoDBv2Path

try {
    # Query DynamoDB to determine if primary node is finished initial setup.
    $RegionEndPoint = [Amazon.RegionEndPoint]::GetBySystemName($Region)
    $DDBClient = New-Object Amazon.DynamoDBv2.AmazonDynamoDBClient($RegionEndPoint)

    $ScanRequest = New-Object Amazon.DynamoDBv2.Model.ScanRequest
    $ScanRequest.TableName = $DDBTableName

    $RetryCount = 0

    while ($RetryCount -lt 45) {
        $Result = $DDBClient.Scan($ScanRequest)

        if ($Result.count -ne $NodeCount) {
            Write-Host "Number of nodes: $($Result.count)"
            Write-Host "Waiting 60 seconds. Attempts remaining: $((44 - $RetryCount))"

            Start-Sleep -Seconds 60
            $RetryCount = $RetryCount + 1
        } else {
            Write-Host "Number of nodes: $($Result.count)"
            Write-Host "Node count match - resuming setup."
            break
        }
    }

    if ($RetryCount -eq 45) {
        throw "Setup did not complete in the expected time period."
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}
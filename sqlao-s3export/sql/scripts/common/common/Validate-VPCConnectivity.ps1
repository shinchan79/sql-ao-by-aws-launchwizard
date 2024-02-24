[CmdletBinding()]

param(
    [Parameter(Mandatory=$true)]
    [string]
    $subnet,

    [Parameter(Mandatory=$true)]
    [string]
    $serviceURLMap
)

# Tries to enable TLS12
function enableTLS12 {
    try {
        if ([Net.ServicePointManager]::SecurityProtocol.ToString().Contains("Tls12") -eq $false) {
            [Net.ServicePointManager]::SecurityProtocol += [Net.SecurityProtocolType]::Tls12
        }
    } catch {
        # Ignore failure; there's nothing we can do about it anyway
    }
}

$failed = $false
$failedServices = @()
enableTLS12

# example for $serviceURLMap: {"Cloudformation": "cloudformation.us-east-2.amazonaws.com", "S3": "s3.us-east-2.amazonaws.com"}
# Convert input string to HashTable
# Keeping it compatible with older versions of Powershell. Powershell 6 onwards can use "ConvertFrom-Json -As hashtable"
$serviceURlMapJson = ConvertFrom-Json $serviceURLMap
$serviceURLHashTable = @{}
foreach ($property in $serviceURlMapJson.PSObject.Properties) {
    $serviceURLHashTable[$property.Name] = $property.Value
}

foreach ($service in $serviceURLHashTable.keys) {

    try{
        $out = (Invoke-WebRequest $serviceURLHashTable[$service] -UseBasicParsing).StatusCode

        if (($out -ge 200 -and $out -lt 299) -or ($out -ge 500 -and $out-lt 600)) {
            # Was able to connect to service, continue testing
        } else {
            $failedServices += $service
            $failed = $true
        }
    } catch {
        $failedServices += $service
        $failed = $true
    }
}

if ($failed -eq $true) {
    Write-Output @{status= "Failed"; reason= "Failed to connect to services $($failedServices -join ', ')"} | ConvertTo-Json -Compress
} else
{
    Write-Output @{ status = "Completed"; reason = "Done." } | ConvertTo-Json -Compress
}
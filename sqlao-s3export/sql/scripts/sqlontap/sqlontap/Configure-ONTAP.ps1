#Requires -Version 7.0
<#
.SYNOPSIS
Configures the ONTAP file system for Windows client.

.LINK
https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/mount-iscsi-windows.html#configure-iscsi-on-ontap-win
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$SQLVMName,

    [Parameter(Mandatory=$true)]
    [string]$datalunsize,

    [Parameter(Mandatory=$true)]
    [string]$loglunsize,

    [Parameter(Mandatory=$true)]
    [string]$Stackname,

    [Parameter(Mandatory=$true)]
    [string]$volume,

    [Parameter(Mandatory=$true)]
    [string]$IGROUP
)

function Get-FsxCertificateBundle {
    <#
    .SYNOPSIS
    Returns the output of the data obtained from metadata path provided
    .LINK
    https://docs.aws.amazon.com/fsx/latest/ONTAPGuide/managing-resources-ontap-apps.html#netapp-ontap-api
    .NOTES
    Only commercial, China, and GovCloud partitions are supported at the present time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$region,

        [ValidateSet("aws", "aws-cn", "aws-us-gov", IgnoreCase = $true)]
        [Parameter(Mandatory=$true)]
        [string]$partition
    )

    ## Setting ONTAP endpoints as per partition
    switch($partition) {
        "aws"           { $certuri = "https://fsx-aws-certificates.s3.amazonaws.com/bundle-$region.pem" }
        "aws-cn"        { $certuri = "https://fsx-aws-cn-certificates.s3.cn-north-1.amazonaws.com.cn/bundle-$region.pem" }
        "aws-us-gov"    { $certuri = "https://fsx-aws-us-gov-certificates.s3.us-gov-west-1.amazonaws.com/bundle-$region.pem" }
        default         { $certuri = "https://fsx-aws-certificates.s3.amazonaws.com/bundle-$region.pem" }
    }

    Invoke-WebRequest -Uri $certuri -OutFile C:\cfn\cert.pem
    $cert = Import-Certificate -FilePath C:\cfn\cert.pem -CertStoreLocation Cert:\LocalMachine\Root

    return Get-ChildItem -Path Cert:\LocalMachine\Root | Where-Object { $_.Subject -like $cert.Subject }
}

function Invoke-NetAppOntapRestApi {
    param(
        [Parameter(Mandatory=$true)]
        [string]$MgmtDNS,

        [Parameter(Mandatory=$true)]
        [string]$uri,

        [Parameter(Mandatory=$true)]
        [string]$region,

        [Parameter(Mandatory=$true)]
        [Hashtable]$parambody,

        [Parameter(Mandatory=$true)]
        [string]$EncryptedAuth
    )

    try {
        $restcert = Get-FsxCertificateBundle -region $region -partition $partition
        $resturi = "https://$MgmtDNS/api/$uri"
        $JsonBody = $Body | ConvertTo-Json

        $Params = @{
            "URI"     = "$resturi"
            "Method"  = "POST"
            "Headers" = @{"Authorization" = "Basic $EncryptedAuth"}
            "Body" =  "$JsonBody"
            "ContentType" = "application/json"
        }

        Invoke-RestMethod @Params -Certificate $restcert
    } catch {
        $_ | Write-AWSLaunchWizardException
    }
}

Import-Module AWSPowerShell
Import-Module AWSLaunchWizardSQLUtility

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

## Retrieve secure credentials using provided secret name
$SecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -RetrieveCredentialOnly

$sessionToken = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri "http://169.254.169.254/latest/api/token"
Set-Variable -Name 'Token' -Value $sessionToken -Scope Global

$region = Get-InstanceMetadataFromPath -Path "meta-data/placement/region"
$partition = Get-InstanceMetadataFromPath -Path "meta-data/services/partition"

## Create Volume with ONTAP RestAPI via PowerShell 7.0
$fslist = Get-FSXFileSystem | Where-Object { $_.Tags.Key -eq 'aws:cloudformation:stack-name' -and $_.Tags.Value -eq $Stackname }
$MgmtDNS = $fslist.ontapconfiguration.Endpoints.Management.DNSName

$volume="SQLCluster01"

$IGROUP='SQLigroup'

$pair = "$($SecureCredObject.Credential.GetNetworkCredential().UserName):$($SecureCredObject.Credential.GetNetworkCredential().Password)"
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)

## Safely remove any variables housing sensitive data in memory which are no longer needed
Remove-Variable -Name pair -ErrorAction SilentlyContinue
Remove-Variable -Name bytes -ErrorAction SilentlyContinue
[System.GC]::Collect()

#get management IP
$nodeiqn = (Get-InitiatorPort).NodeAddress

#Start ONTAP configuration
$VolUriDynamicPart='private/cli/volume'

$URI=@"
https://$($MgmtDNS)/api/$($VolUriDynamicPart)?vserver=$($SQLVMName)&volume=$($volume)
"@
$Body = @{
    "fractional-reserve" = "0"
     "space-mgmt-try-first"= "snap_delete"
}

$JsonBody = $Body | ConvertTo-Json
$Params = @{
    "URI"     = "$URI"
    "Method"  = "PATCH"
    "Headers" = @{"Authorization" = "Basic $base64"}
    "Body" =  "$JsonBody"
    "ContentType" = "application/json"
}

try {
    $restcert = Get-FsxCertificateBundle -region $region -partition $partition
    Invoke-RestMethod @Params -Certificate $restcert
} catch {
    Write-Output "Volume modification failed"
    $_ | Write-AWSLaunchWizardException
}
Start-Sleep 5

##create igroup
$IGUriDynamicPart='private/cli/igroup'
$URI = "https://$MgmtDNS/api/$IGUriDynamicPart"
$Body = @{
    "igroup"  = "$IGROUP"
    "vserver" = "$SQLVMName"
    "ostype" = "windows"
     "protocol" = "iscsi"
     "initiator"= @("$nodeiqn")
}
Invoke-NetAppOntapRestApi -MgmtDNS $MgmtDNS -uri $IGUriDynamicPart -region $region -parambody $Body -EncryptedAuth $base64
Start-Sleep 5

##create data lun
$lunUriDynamicPart='private/cli/lun'
$URI = "https://$MgmtDNS/api/$lunUriDynamicPart"
$DATALUN = 'sqldata'
$DSIZE = $datalunsize+"G"
$Body = @{
    "vserver" = "$SQLVMName"
    "volume" = "$volume"
    "ostype" = "windows_2008"
    "lun" = "$DATALUN"
    "size"= "$DSIZE"
}
Invoke-NetAppOntapRestApi -MgmtDNS $MgmtDNS -uri $lunUriDynamicPart -region $region -parambody $Body -EncryptedAuth $base64
Start-Sleep 5

##mapping data lun
$lunmapsUriDynamicPart = 'protocols/san/lun-maps'
$URI = "https://$MgmtDNS/api/$lunmapsUriDynamicPart"
$volume_PATH = "/vol/$volume/$DATALUN"
$Body = @{
    "svm" = @{"name" = "$SQLVMName"}
    "lun" = @{"name" = "$volume_PATH"}
    "igroup" = @{"name" = "$IGROUP"}
}
Invoke-NetAppOntapRestApi -MgmtDNS $MgmtDNS -uri $lunmapsUriDynamicPart -region $region -parambody $Body -EncryptedAuth $base64
Start-Sleep 5

##create log lun
$lunUriDynamicPart='private/cli/lun'
$URI = "https://$MgmtDNS/api/$lunUriDynamicPart"
$LOGLUN = 'sqllog'
$LSIZE = $loglunsize+"G"
$Body = @{
    "vserver" = "$SQLVMName"
    "volume" = "$volume"
    "ostype" = "windows_2008"
    "lun" = "$LOGLUN"
    "size"= "$LSIZE"
}
Invoke-NetAppOntapRestApi -MgmtDNS $MgmtDNS -uri $lunUriDynamicPart -region $region -parambody $Body -EncryptedAuth $base64
Start-Sleep 5

##mapping log lun
$lunmapsUriDynamicPart = 'protocols/san/lun-maps'
$volume_PATH = "/vol/$volume/$LOGLUN"
$Body = @{
    "svm" = @{"name" = "$SQLVMName"}
    "lun" = @{"name" = "$volume_PATH"}
    "igroup" = @{"name" = "$IGROUP"}
}
Invoke-NetAppOntapRestApi -MgmtDNS $MgmtDNS -uri $lunmapsUriDynamicPart -region $region -parambody $Body -EncryptedAuth $base64
Start-Sleep 5

##create quorum lun
$lunUriDynamicPart='private/cli/lun'
$URI = "https://$MgmtDNS/api/$lunUriDynamicPart"
$QLUN = 'quorum'
$Body = @{
    "vserver" = "$SQLVMName"
    "volume" = "$volume"
    "ostype" = "windows_2008"
    "lun" = "$QLUN"
    "size"= "1G"
}
Invoke-NetAppOntapRestApi -MgmtDNS $MgmtDNS -uri $lunUriDynamicPart -region $region -parambody $Body -EncryptedAuth $base64
Start-Sleep 5

##mapping quorum lun
$lunmapsUriDynamicPart = 'protocols/san/lun-maps'
$URI = "https://$MgmtDNS/api/$lunmapsUriDynamicPart"
$volume_PATH = "/vol/$volume/$QLUN"
$Body = @{
    "svm" = @{"name" = "$SQLVMName"}
    "lun" = @{"name" = "$volume_PATH"}
    "igroup" = @{"name" = "$IGROUP"}
}
Invoke-NetAppOntapRestApi -MgmtDNS $MgmtDNS -uri $lunmapsUriDynamicPart -region $region -parambody $Body -EncryptedAuth $base64
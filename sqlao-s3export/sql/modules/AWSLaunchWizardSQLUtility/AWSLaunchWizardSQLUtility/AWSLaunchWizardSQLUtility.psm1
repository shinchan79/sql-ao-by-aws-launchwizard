<#
.SYNOPSIS
Returns common DSC settings for generic usage.

.DESCRIPTION
Returns configuration settings which specify location of certificate file,
certificate thumbprint, and enables PSDscAllowDomainUser.

.PARAMETER CertificateThumbprint
Thumbprint of local certificate used for securing MOF files

.EXAMPLE
Get-CommonConfigurationData -CertificateThumbprint $DscCertThumbprint

.NOTES
Primarily utilized with FCI deployments.
#>
function Get-CommonConfigurationData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [string]$CertificateThumbprint
    )

    $CommonConfigurationData = @{
        AllNodes = @(
            @{
                NodeName = "*"
                CertificateFile = "C:\cfn\dsc\publickeys\AWSLWDscPublicKey.cer"
                Thumbprint = $CertificateThumbprint
                PSDscAllowDomainUser = $true
            },
            @{
                NodeName = 'localhost'
            }
        )
    }

    return $CommonConfigurationData
}

<#
.SYNOPSIS
Retrieves metadata content using the path specified

.DESCRIPTION
If session token doesn't exist in the global scope, create a new short-lived token. Retrieve
and return content, as specified by the Path parameter

.PARAMETER Path
Abbreviated path to specific IMDS property

.EXAMPLE
Get-InstanceMetadataFromPath -Path 'meta-data'

.NOTES
Does not require extracting data values from Content key
#>
function Get-InstanceMetadataFromPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [string]$Path
    )

    Write-Host "Attempting to retrieve metadata for path: $Path"

    ## If session token is not defined in global scope, create in local scope.
    if ($Token.Length -eq 0) {
        $Token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "60"} -Method PUT -Uri "http://169.254.169.254/latest/api/token"
    }

    $response = Invoke-RestMethod -Uri "http://169.254.169.254/latest/$Path/" -Headers @{"X-aws-ec2-metadata-token" = $Token} -Method GET -UseBasicParsing

    return $response
}

<#
.SYNOPSIS
Retrieves a list of local disk objects

.DESCRIPTION
Checks for all existing EBS and NVMe disks attached to the instance, and
generates a user-friendly list of custom disk objects.

.PARAMETER SortedAscDeviceNumber
When enabled, function returns disk object list sorted by disk number

.EXAMPLE
Get-OSDiskDetails -SortedAscDeviceNumber

.LINK
https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2-windows-volumes.html#list-nvme-powershell

.NOTES
This function is utilized in multiple scripts, with varying use cases. Be sure to consider
any dependent scripts when making updates.
#>
function Get-OSDiskDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [switch]$ExcludeEphemeralDisks,

        [Parameter(Mandatory=$false)]
        [switch]$SortedAscDeviceNumber
    )

    $disks = New-Object -TypeName 'System.Collections.Generic.List[PSObject]'

    foreach ($disk in (Get-Disk)) {
        ## Create initial set of variables directly from output
        $DiskIsOffline = $disk.IsOffline
        $DiskIsReadOnly = $disk.IsReadOnly
        $DiskNumber = $disk.Number
        $DiskPartitionStyle = $disk.PartitionStyle

        ## Manipulate string to produce friendly name for EBS volumes
        if ($disk.SerialNumber -like 'vol*') {
            $DiskEbsVolumeId = $disk.SerialNumber -replace "_[^ ]*$" -replace "vol", "vol-"
        } else {
            $DiskEbsVolumeId = $disk.SerialNumber -replace "_[^ ]*$" -replace "AWS", "AWS-"
        }

        $DiskDriveLetter = (Get-Partition | Where-Object { $_.DiskNumber -eq $disk.Number }).DriveLetter

        ## Attempt alternative method to obtain drive letter if above yields no result
        if ($null -eq $DiskDriveLetter) {
            $PartitionAccessPaths = (Get-Partition | Where-Object { $_.DiskId -eq $disk.Path }).AccessPaths

            if ($null -eq $PartitionAccessPaths) {
                $DiskDriveLetter = ""
            } else {
                try {
                    $DiskDriveLetter = $PartitionAccessPaths.Split(",")[0]
                } catch {
                    $DiskDriveLetter = ""
                }
            }
        }

        if ($DiskEbsVolumeId -match '^vol-') {
            $DiskDevice  = ((Get-EC2Volume -VolumeId $DiskEbsVolumeId).Attachment).Device
            $DiskVolumeName = ""
        } else {
            $DiskDevice = "Ephemeral"
            $DiskVolumeName = "Temporary Storage"
        }

        $DiskObject = New-Object PSObject -Property @{
            Device          = if ($null -eq $DiskDevice) { "N/A" } Else { $DiskDevice };
            DriveLetter     = $DiskDriveLetter;
            EbsVolumeId     = if ($null -eq $DiskEbsVolumeId) { "N/A" } Else { $DiskEbsVolumeId };
            IsOffline       = $DiskIsOffline;
            IsReadOnly      = $DiskIsReadOnly;
            Number          = $DiskNumber;
            PartitionStyle  = $DiskPartitionStyle;
            VolumeName      = $DiskVolumeName;
        }

        if ($ExcludeEphemeralDisks.IsPresent) {
            if ($DiskObject.Device -ne 'Ephemeral') {
                $disks.Add($DiskObject)
            }
        }
    }

    if ($SortedAscDeviceNumber.IsPresent) {
	    return $disks.ToArray() | Sort-Object -Property 'Device'
    } else {
        return $disks.ToArray()
    }
}

<#
.SYNOPSIS
Returns subnet mask using dot decimal notation.

.DESCRIPTION
Returns subnet mask for the given subnet ID, in dot decimal format.
e.g. 255.255.255.0

.EXAMPLE
Get-SubnetMask -SubnetId subnet-abc123
#>
function Get-SubnetMask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [string]$SubnetId
    )

    $subnet = Get-EC2Subnet -SubnetId $SubnetId
    $cidr = $subnet.CidrBlock
    $cidr_mask = $cidr.split('/')[1]

    $A = 0
    $A_Index = 8
    $B = 0
    $B_Index = 16
    $C = 0
    $C_Index = 24
    $D = 0
    $D_Index = 32

    for ($i = 1; $i -le $cidr_mask; $i++) {
        if ($i -le $A_Index) {
            $A += ([Math]::Pow(2, 8 - $i))
        } elseif ($i -le $B_Index) {
            $B += ([Math]::Pow(2, 8 - $i + $A_Index))
        } elseif ($i -le $C_Index) {
            $C += ([Math]::Pow(2, 8 - $i + $B_Index))
        } elseif ($i -le $D_Index) {
            $D += ([Math]::Pow(2, 8 - $i + $C_Index))
        }
    }

    $subnet_mask = "{0}.{1}.{2}.{3}" -f $A, $B, $C, $D

    return $subnet_mask
}

<#
.SYNOPSIS
Returns a custom object based on AD user properties, where applicable

.DESCRIPTION
Returns a single custom object with critical properties utilized across multiple scripts

.EXAMPLE
# Get user details for 'admin'
Get-UserAccountDetails -UserAccountSecretName 'Fake-Test-Admin-Secret-Id' -DomainDNSName 'example.com' -DomainUserName 'admin'

.LINK
https://learn.microsoft.com/en-us/windows/win32/secauthn/user-name-formats

# Get credentials only for SQL service account
Get-UserAccountDetails -UserAccountSecretName 'Fake-Test-SQLService-Secret-Id' -RetrieveCredentialOnly

.NOTES
- User principal name (UPN) format is used to specify an Internet-style name, such as UserName@Example.Microsoft.com.
- The down-level logon name format is used to specify a domain and a user account in that domain, for example, DOMAIN\UserName.
#>
function Get-UserAccountDetails {
    [CmdletBinding(DefaultParameterSetName='GetUserAccountDetails')]
    param(
        [Parameter(Mandatory=$true, ParameterSetName="GetUserAccountDetails")]
        [Parameter(Mandatory=$false, ParameterSetName="RetrieveCredentialOnly")]
        [string]$DomainDNSName,

        [Parameter(Mandatory=$false)]
        [string]$DomainNetBIOSName=$env:USERDOMAIN,

        [Parameter(Mandatory=$true, ParameterSetName="GetUserAccountDetails")]
        [Parameter(Mandatory=$false, ParameterSetName="RetrieveCredentialOnly")]
        [string]$DomainUserName,

        [Parameter(Mandatory=$false, ParameterSetName="RetrieveCredentialOnly")]
        [switch]$RetrieveCredentialOnly,

        [Parameter(Mandatory=$true)]
        [string]$UserAccountSecretName,

        [Parameter(Mandatory=$false)]
        [switch]$UsernameUPN
    )

    ## Retrieve credential set from Secrets Manager for specified domain user account
    try {
        $AccountCredentialBlob = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $UserAccountSecretName | Select-Object -ExpandProperty 'SecretString')
    } catch {
        throw "Encountered an error while retrieving secret $UserAccountSecretName. Exception message: $_"
    }

    ## Create PSCredential Object for specified user
    if ($RetrieveCredentialOnly.IsPresent) {
        if ($DomainDNSName.Length -ne 0 -and $DomainUserName.Length -ne 0) {
            $DomainUserAccountName = $DomainDNSName,$DomainUserName -Join "\"
        } elseif ($DomainDNSName.Length -ne 0 -and $DomainUserName.Length -eq 0) {
            $DomainUserAccountName = $DomainDNSName,$AccountCredentialBlob.username -Join "\"
        } else {
            $DomainUserAccountName = $AccountCredentialBlob.username
        }
    } else {
        ## Set down-level logon name format using domain; e.g. 'example.com\user'
        $DomainDLLN = $DomainDNSName,$DomainUserName -Join "\"

        ## Set down-level logon name format using NetBIOS name; e.g. 'example\user'
        $NetBIOSDLLN = $DomainNetBIOSName,$DomainUserName -Join "\"

        ## Set implicit UPN format; e.g. 'user@example.com'
        $AccountUpn = $DomainUserName,$DomainDNSName -Join "@"

        ## Sets the username value for the PSCredential object
        if ($UsernameUPN.IsPresent) {
            $DomainUserAccountName = $AccountUpn
        } else {
            $DomainUserAccountName = $DomainDLLN
        }
    }

    $SecureCredObject = New-Object PSCredential($DomainUserAccountName,(ConvertTo-SecureString $AccountCredentialBlob.password -AsPlainText -Force))

    ## Safely remove any variables housing sensitive data in memory which are no longer needed
    Remove-Variable -Name AccountCredentialBlob -ErrorAction SilentlyContinue
    [System.GC]::Collect()

    $props = @{
        Credential  = $SecureCredObject
        DomainDlln  = if ($null -eq $DomainDLLN)        { 'N/A' } else { $DomainDLLN }
        NetBIOSDlln = if ($null -eq $NetBIOSDLLN)       { 'N/A' } else { $NetBIOSDLLN }
        Upn         = if ($null -eq $AccountUpn)        { 'N/A' } else { $AccountUpn }
        Username    = if ($DomainUserName.Length -eq 0) { $SecureCredObject.UserName } else { $DomainUserName }
    }

    return New-Object PSObject -Property $props
}

<#
.SYNOPSIS
Configures basic settings used in majority of scripts

.DESCRIPTION
On a per-script basis, configures settings such as starting transcript logging,
setting error action preference, configuring security protocol, etc.

.PARAMETER SetErrorActionPref
When enabled, sets error action preference at script global level. Defaults to 'Stop'
if ErrorActionPref is not specified.

.PARAMETER ErrorActionPref
Defines the error action preference option; default is 'Stop'

.PARAMETER ScriptLogName
String value of script name - if parameter is present and non-null, enables transcript logging.

.EXAMPLE
# Configure default error action preference, and enable transcript logging
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName 'Test-Script.ps1'

.LINK
https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/ec2-windows-volumes.html#list-nvme-powershell

.NOTES
On the path to deprecate SecurityProtocol, InstallNuget, and TrustPSGallery
#>
function Set-ScriptSessionSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [switch]$SetErrorActionPref,

        [Parameter(Mandatory=$false)]
        [System.Management.Automation.ActionPreference]$ErrorActionPref,

        [Parameter(Mandatory=$false)]
        [string]$ScriptLogName,

        [Parameter(Mandatory=$false)]
        [switch]$SecurityProtocol,

        [Parameter(Mandatory=$false)]
        [switch]$InstallNuget,

        [Parameter(Mandatory=$false)]
        [switch]$TrustPSGallery
    )

    if ($SetErrorActionPref.IsPresent) {
        if ($ErrorActionPref.Length -eq 0) {
            ## Set default action to Stop if value was not provided
            $ErrorActionPref = "Stop"
        }

        try {
            ## Set script error action preference
            Set-Variable -Name ErrorActionPreference -Value $ErrorActionPref -Scope Global
        } catch {
            throw "Unable to set error action preference. Exception message: $($_.Message.Exception)"
        }
    }

    if ($ScriptLogName.Length -ne 0) {
        ## Set transcript log configuration
        $ScriptLogDirectory = 'C:\cfn\log'

        $ScriptLogFilePath = "$ScriptLogDirectory\$ScriptLogName.log"

        Start-Transcript -Path $ScriptLogFilePath -Append
    }

    if ($SecurityProtocol.IsPresent) {
        try {
            ## Ensure TLS 1.2 security protocol is enforced for session duration.
            Write-Host "Current security protocol: $([Net.ServicePointManager]::SecurityProtocol)"

            if (-not ([Net.ServicePointManager]::SecurityProtocol -match "Tls12")) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                Write-Host "Updated security protocol: $([Net.ServicePointManager]::SecurityProtocol)"
            }
        } catch {
            throw "Failed to set security protocol. Exception message: $($_.Message.Exception)"
        }
    }

    if ($InstallNuget.IsPresent) {
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers
        } catch {
            throw "Failed to install NuGet package provider. Exception message: $($_.Message.Exception)"
        }
    }

    if ($TrustPSGallery.IsPresent) {
        try {
            ## Set PSGallery installation policy to trusted if needed.
            $InstallationPolicy = (Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue).InstallationPolicy

            if ($null -ne $InstallationPolicy -and $InstallationPolicy -ne "Trusted") {
                Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
            }
        } catch {
            throw "Failed to set installation policy for PSGallery. Exception message: $($_.Message.Exception)"
        }
    }
}

<#
.SYNOPSIS
Simple function to safely install Powershell modules

.DESCRIPTION
Configures necessary script block settings, then attempts to install provided module
and validate completion

.PARAMETER ModuleNames
Array of module names to be installed

.EXAMPLE
Invoke-SimpleModuleInstaller -ModuleNames @('AWSPowershell')
#>
function Invoke-SimpleModuleInstaller {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$ModuleNames
    )

    try {
        ## Ensure TLS 1.2 security protocol is enforced for session duration.
        Write-Host "Current security protocol: $([Net.ServicePointManager]::SecurityProtocol)."

        if (-not ([Net.ServicePointManager]::SecurityProtocol -match "Tls12")) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            Write-Host "Updated security protocol: $([Net.ServicePointManager]::SecurityProtocol)"
        } else {
            Write-Host "Identified Tls12 - no further action needed."
        }
    } catch {
        throw "Failed to set security protocol. Exception message: $($_.Message.Exception)"
    }

    try {
        ## Validating NuGet package provider is installed and set to minimum required version.
        $NuGetProvider = Get-PackageProvider -ListAvailable -ErrorAction Ignore | Where-Object { $_.Name -match 'nuget' }
        $RequiredMinimumVersion = [Microsoft.PackageManagement.Internal.Utility.Versions.FourPartVersion]::Parse('2.8.5.201')

        if ($null -eq $NuGetProvider -or $NuGetProvider.Version -lt $RequiredMinimumVersion) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers
        }
    } catch {
        throw "Failed to install NuGet package provider. Exception message: $($_.Message.Exception)"
    }

    try {
        ## Set PSGallery installation policy to trusted if needed.
        $InstallationPolicy = (Get-PSRepository -Name 'PSGallery' -ErrorAction SilentlyContinue).InstallationPolicy

        if ($null -ne $InstallationPolicy -and $InstallationPolicy -ne "Trusted") {
            Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
        }
    } catch {
        throw "Failed to set installation policy for PSGallery. Exception message: $($_.Message.Exception)"
    }

    $AvailableModules = (Get-Module -ListAvailable).Name

    foreach ($ModuleName in $ModuleNames) {
        if (-not ($AvailableModules -match $ModuleName)) {
            try {
                Install-Module -Name $ModuleName -AllowClobber -Scope AllUsers -Force -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Out-Null
            } catch {
                Write-Host "Encountered an issue while installing module $ModuleName. Exception message: $($_.Message.Exception)"
            }
        } else {
            Write-Host "Module $ModuleName already installed, no action required."
        }
    }

    return
}

<#
.SYNOPSIS
Simple function to migrate cluster resources to caller node.

.DESCRIPTION
Validates whether node is sole owner of all cluster resources - if not,
attempt to migrate.

.EXAMPLE
Invoke-ClusterResourceMigration
#>
function Invoke-ClusterResourceMigration {
    [CmdletBinding()]
    param()

    [System.Collections.Generic.HashSet[string]]$OwnerNodeSet = (Get-ClusterGroup).OwnerNode.Name

    if (($OwnerNodeSet.Count -eq 1) -and ($OwnerNodeSet -contains $env:COMPUTERNAME)) {
        Write-Host "$($env:COMPUTERNAME) is owner node for all cluster resources, no action needed."
    } else {
        Get-ClusterGroup | Move-ClusterGroup -Node $env:COMPUTERNAME -Wait 30 -ErrorAction SilentlyContinue | Out-Null
    }
}

<#
.SYNOPSIS
Simple function to validate exit code.

.DESCRIPTION
Validates whether the exit code matches expected list of successful codes.

.EXAMPLE
Confirm-SafeExitCode -ExitCode 0
#>
function Confirm-SafeExitCode {
    [CmdletBinding()]
    [OutputType([boolean])]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [Int32]$ExitCode
    )

    ## Exit codes:
    #    0      - ERROR_SUCCESS
    #    3010   - ERROR_SUCCESS_REBOOT_REQUIRED
    $SafeExitCodes = @(0, 3010)

    ## For any exit code other than the above allowed, stop the deployment.
    if ($SafeExitCodes -notcontains $ExitCode) {
        return $false
    }

    return $true
}

$ExportableFunctions = @(
    "Confirm-SafeExitCode",
    "Invoke-ClusterResourceMigration",
    "Invoke-SimpleModuleInstaller",
    "Get-CommonConfigurationData",
    "Get-InstanceMetadataFromPath",
    "Get-OSDiskDetails"
    "Get-SubnetMask",
    "Get-UserAccountDetails",
    "Set-ScriptSessionSettings"
)

Export-ModuleMember -Function $ExportableFunctions
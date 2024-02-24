[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AMIID
)

function Get-InstalledSoftwareFromRegistry {
    [CmdletBinding()]
    [OutputType([PSObject[]])]
    param(
	    [Parameter(Mandatory=$True)]
	    [string]$Path,

	    [Parameter(Mandatory=$True)]
	    [string]$DisplayName
    )

    $ChildItemList = New-Object System.Collections.Generic.List[PSObject]

    Get-ChildItem -Path $Path | Get-ItemProperty | Where-Object {$_.DisplayName -match $DisplayName } | ForEach-Object { $ChildItemList.Add($_) }

    return $ChildItemList.ToArray()
}

function Uninstall-SoftwareFromRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [switch]$IsSqlNativeClient,

        [Parameter(Mandatory=$false)]
        [switch]$PassiveFlagOnly,

        [Parameter(Mandatory=$True)]
        [PSObject[]]$SoftwareUninstallList
    )

    foreach ($Application in $SoftwareUninstallList) {
        try {
            $UninstallString = $Application.UninstallString

            # ODBC and OLE DB drivers do not define registry uninstall strings using the '/X'
            # switch, and instead use '/I' for all options (Modify/Repair/Uninstall)
            # Attempt to obtain driver uninstall key explicitly and execute MsiExec from Start-Process.

            if ($UninstallString.StartsWith("MsiExec.exe /I", "CurrentCultureIgnoreCase")) {
                # Checking for key name pattern - generic example: {ABCD1234-AB12-AB12-AB12-ABCDEF123456}
                $RegexForKeyName = "{[A-Z0-9]{8}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{12}}"
                $UninstallKeyName = [regex]::matches($UninstallString, $RegexForKeyName).value

                if ($null -ne $UninstallKeyName) {
                    if ($PassiveFlagOnly.IsPresent) {
                        # '/qn' switch can cause uninstalls to fail in certain edge cases.
                        $arguments = "/X", "$UninstallKeyName", "/passive"
                    } else {
                        # For the majority of cases, use '/passive' and '/qn' together.
                        $arguments = "/X", "$UninstallKeyName", "/passive", "/qn"
                    }

                    try {
                        Start-Process 'msiexec.exe' -ArgumentList $arguments -Wait -NoNewWindow
                    } catch {
                        Write-Error "Error occurred when attempting to uninstall software: $($_.Exception.Message)"
                    }
                }
            } else {
                try {
                    # Assume uninstall string is listed as 'MsiExec.exe /X{ProductCode}'
                    cmd.exe /c "$UninstallString /passive /qn"
                } catch {
                    Write-Error "Error occurred when attempting to uninstall software: $($_.Exception.Message)"
                }
            }

            if ($IsSqlNativeClient.IsPresent) {
                $CurrentInstalledCount = Get-InstalledSoftwareFromRegistry -Path $UninstallRegPath -DisplayName $Application.DisplayName

                ## In situations where the above uninstall approach does not fully remove the client,
                ## attempt to uninstall directly from the source MSI.
                if ($null -ne $CurrentInstalledCount -and $CurrentInstalledCount.Length -ne 0) {
                    try {
                        [ValidateNotNullOrEmpty()]$NCinstance = Get-CimInstance -ClassName Win32_Product -Filter "Name LIKE 'Microsoft SQL Server 2012 Native Client%'"

                        if (-not (Test-Path -Path $NCinstance.InstallSource)) {
                            Write-Host "Install source not found. Attempting to create."

                            New-Item -Path "$($NCinstance.InstallSource)" -ItemType Directory
                            Copy-Item -Path "$($NCinstance.LocalPackage)" -Destination "$($NCinstance.InstallSource)\$($NCinstance.PackageName)"
                        }
                    } catch {
                        throw "Unable to locate or copy Native Client MSI. $($_.Exception.Message)"
                    }

                    $UninstallArguments = "/X $($NCinstance.IdentifyingNumber) /passive /log `"C:\cfn\log\2012NativeClientUninstall.log`" FORCEREMOVE=0"
                    $NCUninstallProcess = Start-Process 'msiexec.exe' -ArgumentList $UninstallArguments -Wait -PassThru -Verbose -Verb RunAs

                    Write-Host "Uninstall exit code for $($NCinstance.Name): $($NCUninstallProcess.ExitCode)"
                }
            }

            $FinalInstalledCount = Get-InstalledSoftwareFromRegistry -Path $UninstallRegPath -DisplayName $Application.DisplayName

            # Final validation that the uninstall was successful
            if ($null -ne $FinalInstalledCount -and $FinalInstalledCount.Length -ne 0) {
                throw "Unable to uninstall $($Application.DisplayName)."
            }
        } catch {
            throw "Exception caught while attempting to uninstall software. $($_.Exception.Message)"
        }
    }
}

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

if ((Get-EC2Image $AMIID).UsageOperation -eq 'RunInstances:0002') {
    Write-Output "SQL Server is BYOL. No uninstall required."
    exit 0
}

Write-Output "SQL LI AMI identified. Uninstalling SQL Server"

try {
    $arguments = '/q /ACTION="Uninstall" /SUPPRESSPRIVACYSTATEMENTNOTICE="True" /FEATURES="SQLENGINE,AS,RS" /INSTANCENAME="MSSQLSERVER"'
    $SQLUninstallProcess = Start-Process -FilePath "C:\SQLServerSetup\setup.exe" -ArgumentList $arguments -PassThru -Wait -NoNewWindow

    ## For any exit code besides 0, stop the deployment
    if (-not (Confirm-SafeExitCode -ExitCode $SQLUninstallProcess.ExitCode)) {
        throw "Uninstall action failed; Exit code: $($SQLUninstallProcess.ExitCode)"
    }

    # After performing the above, in order to successfully prepare the FCI setup,
    # the following drivers must be uninstalled separately:
    #   - Microsoft OLE DB Driver for SQL Server
    #   - Microsoft ODBC Driver ## for SQL Server
    # For SQL 2017, we must also remove the following:
    #   - Microsoft SQL Server 2012 Native Client

    $UninstallRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"

    if (-Not (Test-Path -Path $UninstallRegPath)) {
        throw "Unable to validate registry Uninstall path: $UninstallRegPath"
    }

    $OleDbDisplayName = "Microsoft OLE DB Driver for SQL Server"
    $OdbcDisplayName = "Microsoft ODBC Driver.+for SQL Server"
    $2012NativeClientDisplayName = "Microsoft SQL Server 2012 Native Client"

    $OleDbDriverList = Get-InstalledSoftwareFromRegistry -Path $UninstallRegPath -DisplayName $OleDbDisplayName
    $OdbcDriverList = Get-InstalledSoftwareFromRegistry -Path $UninstallRegPath -DisplayName $OdbcDisplayName
    $NativeClientList = Get-InstalledSoftwareFromRegistry -Path $UninstallRegPath -DisplayName $2012NativeClientDisplayName

    # If no existing drivers are discovered, no further action is required.
    if ($null -ne $OleDbDriverList -and $OleDbDriverList.Length -ne 0) {
        Uninstall-SoftwareFromRegistryValue -SoftwareUninstallList $OleDbDriverList
    }

    if ($null -ne $OdbcDriverList -and $OdbcDriverList.Length -ne 0) {
        Uninstall-SoftwareFromRegistryValue -SoftwareUninstallList $OdbcDriverList
    }

    if ($null -ne $NativeClientList -and $NativeClientList.Length -ne 0) {
        Uninstall-SoftwareFromRegistryValue -SoftwareUninstallList $NativeClientList -IsSqlNativeClient -PassiveFlagOnly
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}
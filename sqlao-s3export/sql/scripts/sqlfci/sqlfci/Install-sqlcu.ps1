<#
.SYNOPSIS
Installs SQL Cumulative Update

.DESCRIPTION
Installs and updates SQL to the latest CU. The CU files are downloaded from the following S3 bucket
    - https://s3.amazonaws.com/sqlspandcu/
The script looks at the S3 bucket based on the version of SQL installed on the machine and downloads the file from the "LATEST" folder.

.EXAMPLE
Install-Sqlcu.ps1
#>
[CmdletBinding()]
param()

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

if (Test-Path -Path "C:\cfn\sqlspcu\state.txt") {
    Remove-Item "C:\cfn\sqlspcu\state.txt" -Force
}

## Attempt to first obtain SQL patch level from current instance.
$RootPathForSQL = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"

# Check for existing installed SQL instances
$InstalledInstances = (Get-ItemProperty $RootPathForSQL).InstalledInstances

$SQLInstanceNamesPath = Join-Path $RootPathForSQL -ChildPath "Instance Names\SQL"

if ((Test-Path -Path $SQLInstanceNamesPath) -and ($InstalledInstances.Count -eq 1)) {
    $SQLInstanceName = (Get-ItemProperty $SQLInstanceNamesPath).$InstalledInstances

    if ($null -ne $SQLInstanceName) {
        $SQLInstanceSetupHivePath = Join-Path $RootPathForSQL -ChildPath "$SQLInstanceName\Setup"

        # If the Setup registry hive exists, attempt to set patch level.
        if (Test-Path -Path $SQLInstanceSetupHivePath) {
            $SQLInstanceSetupHive = Get-ItemProperty $SQLInstanceSetupHivePath
            $SQLPatchLevel = $SQLInstanceSetupHive.PatchLevel
        }
    }
}

## If the above logic fails to yield a version, then attempt to identify version by SQL installer.
if ($null -eq $SQLPatchLevel) {
    ## Attempt to determine SQL version by checking for CurrentVersion registry key
    # Defining registry key paths for SQL versions 2016, 2017, 2019, 2022
    $PathForSQL2016 = Join-Path $RootPathForSQL -ChildPath "130\SQLServer2016"
    $PathForSQL2017 = Join-Path $RootPathForSQL -ChildPath "140\SQL2017"
    $PathForSQL2019 = Join-Path $RootPathForSQL -ChildPath "150\SQL2019"
    $PathForSQL2022 = Join-Path $RootPathForSQL -ChildPath "160\SQL2022"

    $ListOfSQLPaths = New-Object -TypeName "System.Collections.Generic.List[String]"

    $ListOfSQLPaths.Add($PathForSQL2016)
    $ListOfSQLPaths.Add($PathForSQL2017)
    $ListOfSQLPaths.Add($PathForSQL2019)
    $ListOfSQLPaths.Add($PathForSQL2022)

    $ListOfSQLPaths.ToArray().ForEach({
        if (Test-Path -Path "$($_)\CurrentVersion") {
            $SQLCurrentVersion = Get-ItemProperty "$($_)\CurrentVersion"
            $SQLPatchLevel = $SQLCurrentVersion.PatchLevel
        }}
    )
}

if ($null -eq $SQLPatchLevel) {
    throw "Unable to identify installed SQL version."
}

# Matching the SQL Version to set CU path
switch -regex ($SQLPatchLevel) {
    "^13" {
        Write-Output "SQL 2016 identified - no further action required. Exiting script successfully."
        exit 0
    }
    "^14" {
        $WorkingDirectory = "C:\cfn\sqlspcu\14"
        $CUFilename = "sql2017cu31.exe"
    }
    "^15" {
        $WorkingDirectory = "C:\cfn\sqlspcu\15"
        $CUFilename = "sql2019cu19.exe"
    }
    "^16" {
        $WorkingDirectory = "C:\cfn\sqlspcu\16"
        $CUFilename = "sql2022cu2.exe"
    }
    default {
        throw "No matching version of SQL identified from input: $SQLPatchLevel"
    }
}

$StateFile = New-Item -Path $WorkingDirectory -ItemType "File" -Name "state.txt" -Value 0
$TargetDirectory = Join-Path $WorkingDirectory $CUFilename

# Read file version
$CUFile = Get-Item $TargetDirectory

try {
    [ValidateNotNullOrEmpty()][System.Version]$SQLProductVersion = (Get-Item $CUFile).VersionInfo.ProductVersion
    [ValidateNotNullOrEmpty()][System.Version]$PatchLevel = $SQLPatchLevel
} catch {
    throw "Unable to validate SQL patch level. $($_.Exception.Message)"
}

## If CU patch level is below current SQL patch level, exit script gracefully.
Write-Host "Identified CU Patch level: $SQLProductVersion"

if ($SQLProductVersion -le $PatchLevel) {
    Write-Host "Current SQL Patch level: $PatchLevel; no further action required."
    exit 0
} else {
    Write-Host "Current SQL Patch level: $PatchLevel; Preparing to update."
}

## Create CU file extraction directory
$ExtractDirectory = Join-Path $WorkingDirectory -ChildPath "Setup"

if (-not (Test-Path -Path $ExtractDirectory)) {
    New-Item -Path $ExtractDirectory -ItemType Directory
}

## Specify file extraction directory to avoid auto-selection opting for cluster disks.
$SQLCUExtractFilesExitCode = Start-Process -FilePath $CUFile.FullName -ArgumentList "/x:`"$ExtractDirectory`" /QUIET" -PassThru -Wait -WindowStyle Hidden

if ($SQLCUExtractFilesExitCode.ExitCode -ne 0) {
    Write-Host "SQL CU file extraction failed. Exit code: $($SQLCUExtractFilesExitCode.ExitCode). Attempting to proceed."

    $SetupExecutable = $CUFile.FullName
} else {
    $SetupExecutable = Join-Path $ExtractDirectory -ChildPath "Setup.exe"

    if (-not (Test-Path -Path $SetupExecutable)) {
        Write-Host "Setup.exe is missing from directory $ExtractDirectory. Attempting to proceed."
        $SetupExecutable = $CUFile.FullName
    }
}

## If node is not owner of all cluster resources, attempt to migrate.
Invoke-ClusterResourceMigration

$PatchAllInstancesProcess = Start-Process -FilePath $SetupExecutable -ArgumentList "/QUIET /IAcceptSQLServerLicenseTerms /Action=Patch /AllInstances" -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput "C:\cfn\log\Install-sqlcu-PatchAllInstances.txt"

try {
    ## For any exit code besides 0, stop the deployment
    if (-not (Confirm-SafeExitCode -ExitCode $PatchAllInstancesProcess.ExitCode)) {
        throw "Patch action failed; Exit code: $($PatchAllInstancesProcess.ExitCode)"
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}

## Directory cleanup
Remove-Item -Path $ExtractDirectory -Recurse -Force

if ((Get-Content $StateFile) -eq 1) {
    Remove-Item $WorkingDirectory -Recurse -Force
}
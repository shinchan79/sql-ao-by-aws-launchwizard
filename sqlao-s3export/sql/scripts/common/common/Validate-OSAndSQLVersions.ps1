[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [double]
    $MinimumOSVersion,

    [Parameter(Mandatory=$true)]
    [double]
    $MinimumSQLVersion,

    [Parameter(Mandatory=$true)]
    [double]
    $MaximumOSVersion,

    [Parameter(Mandatory=$true)]
    [double]
    $MaximumSQLVersion,

    [Parameter(Mandatory=$true)]
    [Boolean]
    $stockAMI

)

try
{

    if (-not $stockAMI)
    {

        Start-Transcript -Path C:\cfn\log\Validate-OSAndSQLVersions.ps1.txt -Append
        $ErrorActionPreference = "Stop"

        $osversion = [System.Environment]::OSVersion.Version
        [double]$osversionnum = "{0}.{1}" -F $osversion.Major, $osversion.Minor

        if ($osversionnum -ge $MinimumOSVersion -and $osversionnum -le $MaximumOSVersion)
        {
            [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | out-null
            $srv = new-object ('Microsoft.SqlServer.Management.Smo.Server') "LOCALHOST"
            [double]$sqlversion = $srv.Version.Major
            if ($sqlversion -ge $MinimumSQLVersion -and $sqlversion -le $MaximumSQLVersion)
            {
                Write-Output @{ status = "Completed"; reason = "Done." } | ConvertTo-Json -Compress
            }
            else
            {
                throw "Unsupported version of SQL Server.(Expected between: ($MinimumSQLVersion.*, $MaximumSQLVersion.*), Actual: $sqlversion)"
            }

        }
        else
        {
            throw "Unsupported version of Windows Server.(Expected between: ($MinimumOSVersion.*, $MaximumOSVersion.*), Actual: $osversionnum)"
        }
    }


}
catch
{
    $_ | Write-AWSLaunchWizardException
}

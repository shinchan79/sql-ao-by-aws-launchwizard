[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$SqlUserSecret,

    [Parameter(Mandatory=$true)]
    [string]$MSSQLMediaBucket,

    [Parameter(Mandatory=$true)]
    [string]$MSSQLMediaKey,

    [Parameter(Mandatory=$true)]
    [string]$AMIID,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    ## Retrieve secure credentials using provided secret name
    $AdminSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser

    ## Retrieve MSSQL service account
    # Credentials must be passed in down-level logon name format (DOMAIN\UserName) for SQL service user
    $SQLServiceSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $SqlUserSecret -DomainDNSName $DomainDNSName -RetrieveCredentialOnly
    $SQLServiceEncryptedCredentials = $SQLServiceSecureCredObject.Credential

    if ((Get-EC2Image $AMIID).UsageOperation -eq 'RunInstances:0002') {
        #Acquiring MSSQL installation media from S3
        $mediaIsoPath = 'c:\cfn\mssql-setup-media\SQL_server.iso'
        $mediaExtractPath = 'C:\SQLServerSetup'

        try {
            Copy-S3Object -BucketName $MSSQLMediaBucket -Key $MSSQLMediaKey -LocalFile $mediaIsoPath
        } catch {
            $_ | Write-AWSLaunchWizardException
        }

        #Mounting and extracting installation media files
        New-Item -Path $mediaExtractPath -ItemType Directory
        $mountResult = Mount-DiskImage -ImagePath $mediaIsoPath -PassThru
        $volumeInfo = $mountResult | Get-Volume
        $driveInfo = Get-PSDrive -Name $volumeInfo.DriveLetter
        Copy-Item -Path ( Join-Path -Path $driveInfo.Root -ChildPath '*' ) -Destination $mediaExtractPath -Recurse
        Dismount-DiskImage -ImagePath $mediaIsoPath

        ## Setting arguments to pass for SQL setup
        $SetupArguments = '/ACTION="PrepareFailoverCluster" /AGTSVCACCOUNT="{0}" /AGTSVCPASSWORD="{1}" /ENU="True" /FEATURES=SQLENGINE,REPLICATION,FULLTEXT,DQ /FILESTREAMLEVEL="0" /FTSVCACCOUNT="{2}" /HELP="False" /IACCEPTROPENLICENSETERMS="False" /IAcceptSQLServerLicenseTerms="True" /INDICATEPROGRESS="False" /INSTALLSHAREDDIR="C:\Program Files\Microsoft SQL Server" /INSTALLSHAREDWOWDIR="C:\Program Files (x86)\Microsoft SQL Server" /INSTANCEDIR="C:\Program Files\Microsoft SQL Server" /INSTANCEID="MSSQLSERVER" /INSTANCENAME="MSSQLSERVER" /QUIET="True" /SQLSVCACCOUNT="{3}" /SQLSVCINSTANTFILEINIT="False" /SQLSVCPASSWORD="{4}" /SUPPRESSPAIDEDITIONNOTICE="True" /SUPPRESSPRIVACYSTATEMENTNOTICE="True" /UpdateEnabled="False" /UpdateSource="MU" /USEMICROSOFTUPDATE="False"' -f $SQLServiceEncryptedCredentials.UserName, $SQLServiceEncryptedCredentials.GetNetworkCredential().Password, 'NT Service\MSSQLFDLauncher$MSSQLSERVER', $SQLServiceEncryptedCredentials.UserName, $SQLServiceEncryptedCredentials.GetNetworkCredential().Password
    } else {
        $SetupArguments = '/ACTION="PrepareFailoverCluster" /AGTSVCACCOUNT="{0}" /AGTSVCPASSWORD="{1}" /ENU="True" /FEATURES=SQLENGINE,REPLICATION,FULLTEXT,DQ /FILESTREAMLEVEL="0" /FTSVCACCOUNT="{2}" /HELP="False" /IACCEPTROPENLICENSETERMS="False" /IAcceptSQLServerLicenseTerms="True" /INDICATEPROGRESS="False" /INSTALLSHAREDDIR="C:\Program Files\Microsoft SQL Server" /INSTALLSHAREDWOWDIR="C:\Program Files (x86)\Microsoft SQL Server" /INSTANCEDIR="C:\Program Files\Microsoft SQL Server" /INSTANCEID="MSSQLSERVER" /INSTANCENAME="MSSQLSERVER" /QUIET="True" /SQLSVCACCOUNT="{3}" /SQLSVCINSTANTFILEINIT="False" /SQLSVCPASSWORD="{4}" /SUPPRESSPRIVACYSTATEMENTNOTICE="True" /UpdateEnabled="False" /UpdateSource="MU" /USEMICROSOFTUPDATE="False"' -f $SQLServiceEncryptedCredentials.UserName, $SQLServiceEncryptedCredentials.GetNetworkCredential().Password, 'NT Service\MSSQLFDLauncher$MSSQLSERVER', $SQLServiceEncryptedCredentials.UserName, $SQLServiceEncryptedCredentials.GetNetworkCredential().Password
    }

    ## If node is not owner of all cluster resources, attempt to migrate.
    Invoke-ClusterResourceMigration

    ## Configuring administrative PS session to capture exit code
    $LocalPSSession = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication credssp -Credential $AdminSecureCredObject.Credential

    ## Execute SQL setup and return exit code in existing session
    $SQLPrepProcExitCode = Invoke-Command -Session $LocalPSSession -ScriptBlock {
        $SQLPrepProc = Start-Process -FilePath C:\SQLServerSetup\setup.exe -ArgumentList $Using:SetupArguments -Wait -PassThru -WindowStyle Hidden
        return $SQLPrepProc.ExitCode
    }

    Remove-Variable -Name SetupArguments -ErrorAction SilentlyContinue
    [System.GC]::Collect()

    ## Destroy session if not already ended
    if ($null -ne $LocalPSSession) {
        Remove-PSSession -Session $LocalPSSession
    }

    ## For any exit code besides 0, stop the deployment
    if (-not (Confirm-SafeExitCode -ExitCode $SQLPrepProcExitCode)) {
        throw "PrepareFailoverCluster action failed; Exit code: $SQLPrepProcExitCode"
    }
} catch {
    $_ | Write-AWSLaunchWizardException
}
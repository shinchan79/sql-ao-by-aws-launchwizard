Configuration InstallNVMeDriver {
    param()

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $osVer = [System.Environment]::OSVersion.Version
    # Detect unsupported Version of Windows
    if (($osVer.Major -lt 6) -or (($osVer.Major -eq 6) -and ($osVer.Minor -eq 0))) {
        return 1
    }

    # Detect unsupported Windows Platform
    if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
        return 1
    }

    $DriverPath = 'C:\cfn\AWSDriver'

    # Create directory to hold driver files
    File SetupDir {
        Type               = 'Directory'
        DestinationPath    = $DriverPath
        Ensure             = 'Present'
    }

    # Retrieve the driver zip from S3
    xRemoteFile RemoteFile {
        Uri                = 'https://s3.us-east-1.amazonaws.com/ec2-windows-drivers-downloads/NVMe/Latest/AWSNVMe.zip'
        DestinationPath    = $DriverPath
        MatchSource        = $true
        DependsOn          = '[File]SetupDir'
    }

    # Unzip the driver
    Archive UnzipNVMeDriver {
        Ensure             = 'Present'
        Path               = "$DriverPath\AWSNVMe.zip"
        Destination        = $DriverPath
        DependsOn          = '[xRemoteFile]RemoteFile'
    }

}
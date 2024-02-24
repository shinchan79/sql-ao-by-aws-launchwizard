Configuration InstallPVDriver {
    param()

    Import-DscResource -ModuleName xPSDesiredStateConfiguration

    $DriverPath = 'C:\cfn\AWSPVDriver'

    # Create a directory to hold the driver
    File SetupDir {
        Type               = 'Directory'
        DestinationPath    = $DriverPath
        Ensure             = 'Present'
    }

    # Download the driver zip file into the directory
    xRemoteFile RemoteFile {
        Uri                = 'https://s3.us-east-1.amazonaws.com/ec2-windows-drivers-downloads/AWSPV/Latest/AWSPVDriver.zip'
        DestinationPath    = $DriverPath
        MatchSource        = $true
        DependsOn          = '[File]SetupDir'
    }

    # Unzip the driver and remove the contents
    Archive UnzipPVDriver {
        Ensure             = 'Present'
        Path               = "$DriverPath\AWSPVDriver.zip"
        Destination        = $DriverPath
        DependsOn          = '[xRemoteFile]RemoteFile'
    }

}
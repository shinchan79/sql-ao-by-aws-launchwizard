Configuration EC2ConfigLaunchSetup {
    param()

    $WindowsVersion = [System.Environment]::OSVersion.Version.Major
    $CutoffVersion = 10

    # Check windows version to see if EC2Config or EC2Launch should be installed
    if ($WindowsVersion -lt $CutoffVersion) {
        # Use EC2Config
	    Add-Type -AssemblyName System.IO.Compression.FileSystem

        # if EC2Config is not installed, install it
        $Ec2ConfigService = Get-Service -Name Ec2Config -ErrorAction SilentlyContinue

        if ($Ec2ConfigService.Length -lt 1) {
            New-Item -Name EC2Config -ItemType Directory -Path C:/cfn/
            Invoke-WebRequest -Uri https://s3.us-east-1.amazonaws.com/ec2-downloads-windows/EC2Config/EC2Install.zip -OutFile C:/cfn/EC2Config/EC2Install.zip
            [System.IO.Compression.ZipFile]::ExtractToDirectory('C:/cfn/EC2Config/EC2Install.zip', 'C:/cfn/EC2Config/EC2Install')
            Start-Process -FilePath 'C:/cfn/EC2Config/EC2Install/EC2Install.exe' -ArgumentList '/quiet'
            # If running EC2config 4.0 or later, must restart SSM agent on instance from microsoft snap in
            # The updated EC2Config version information will not appear in the instance System Log or Trusted Advisor check until you reboot or stop and start your instance.
        }
    } else {
        # Use EC2Launch
        $EC2LaunchPresent = Test-Path 'C:/ProgramData/Amazon/EC2-Windows/Launch/Module/Ec2Launch.psd1' -PathType Leaf

        # if EC2Launch is not installed, install it
        if (-not $EC2LaunchPresent) {
            New-Item -Name EC2Launch -ItemType Directory -Path C:/cfn/
            Invoke-WebRequest -Uri https://s3.us-east-1.amazonaws.com/ec2-downloads-windows/EC2Launch/latest/EC2-Windows-Launch.zip -OutFile C:/cfn/EC2Launch/EC2-Windows-Launch.zip
            Invoke-WebRequest -Uri https://s3.us-east-1.amazonaws.com/ec2-downloads-windows/EC2Launch/latest/install.ps1 -OutFile C:/cfn/EC2Launch/install.ps1
            Powershell.exe -File 'C:/cfn/EC2Launch/install.ps1'
            #Powershell.exe -File 'C:/ProgramData/Amazon/EC2-Windows/Launch/Scripts/InitializeInstance.ps1'
        }
    }
}
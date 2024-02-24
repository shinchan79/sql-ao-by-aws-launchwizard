Configuration LaunchWizard {
    param(

        [Parameter(Mandatory = $true)]
        [String]
        $Computername

    )

    # Import the custom DSC resources we create for LaunchWizard
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DSCResource -ModuleName LaunchWizard

    Node $Computername {

        # Currently commented out because Windows Update is needed later in SQL stack
        # DisableWindowsUpdate disableUpdates {}

        EC2ConfigLaunchSetup ec2Setup {}

        InstallPVDriver installPVDriver {}

    }
}
Configuration SQLHA {
    param(

        [Parameter(Mandatory = $true)]
        [String]
        $Computername,

        [Parameter(Mandatory = $true)]
        [String]
        $SecurityGroup

    )

    # Import the custom resources we build for SQLHA
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DSCResource -ModuleName SQLHA

    Node $Computername {

        EnableDHCP enableDHCP {}

        OpenFileAndPrinterSharing openFPS {}

        OpenSQLFirewallPorts openFirewallPorts {
            SecurityGroup = $SecurityGroup
        }

        SetRealTimeUniversal setTime {}

        InstallNVMeDriver installDriver {}

    }
}
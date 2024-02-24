Configuration SQLAddAdmins {
    param(

        [Parameter(Mandatory = $true)]
        [String]
        $Computername

    )

    # Import any necessary custom DSC resource
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DSCResource -ModuleName SQLAddAdmins

    Node $Computername {

        # Add local admins to sysadmin server role on SQL
        AddAdminsToServer addAdmins {
            SQLServerName = $env:COMPUTERNAME
        }

    }
}
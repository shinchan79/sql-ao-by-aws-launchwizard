Configuration AddAdminsToServer {
    param(

        [Parameter(Mandatory = $true)]
        [String]
        $SQLServerName

    )

    # Import needed custom DSC resources
    Import-DSCResource -ModuleName SqlServerDsc

    $AdminGroup = 'BUILTIN\Administrators'

    # Ensure the Admin Group is present on SQL server
    SqlLogin Add_Admin_Login {
        Ensure               = 'Present'
        Name                 = $AdminGroup
        LoginType            = 'WindowsGroup'
        ServerName           = $SQLServerName
        InstanceName         = 'MSSQLSERVER'
    }

    # Ensure the Admin Group is added to the sysadmin role on SQL server
    SqlRole Add_Admin_To_Sysadmin_Role {
        Ensure               = 'Present'
        ServerRoleName       = 'sysadmin'
        MembersToInclude     = $AdminGroup
        ServerName           = $SQLServerName
        InstanceName         = 'MSSQLSERVER'
    }
}
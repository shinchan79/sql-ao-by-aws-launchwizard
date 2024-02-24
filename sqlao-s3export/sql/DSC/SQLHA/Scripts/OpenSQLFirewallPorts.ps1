Configuration OpenSQLFirewallPorts {
    param(

        [Parameter(Mandatory = $true)]
        [String]
        $SecurityGroup

    )

    Import-DSCResource -ModuleName NetworkingDSC

    # List of all TCP and UDP ports that need to be open for SQL
    $TCPPortList = @('1433-1434', '137', '3343', '135', '445', '5985', '5022', '49152-65535', '53')
    $UDPPortList = @('137', '1434', '3343', '49152-65535', '53')

    # Open all TCP ports
    foreach ($TCPPort in $TCPPortList) {
	    $Name = 'TCP-'+$TCPPort
        FireWall $Name {
            Name                = $Name
            DisplayName         = 'Open-'+$Name
            Ensure              = 'Present'
            Enabled             = 'True'
            Protocol            = 'TCP'
            Direction           = 'Inbound'
            RemoteAddress       = $SecurityGroup
            LocalPort           = $TCPPort
            Description         = 'Open TCP ports for SQLHA'
        }
    }

    # Open all UDP ports
    foreach ($UDPPort in $UDPPortList) {
	    $Name = 'UDP-'+$UDPPort
        FireWall $Name {
            Name                = $Name
            DisplayName         = 'Open-'+$Name
            Ensure              = 'Present'
            Enabled             = 'True'
            Protocol            = 'UDP'
            Direction           = 'Inbound'
            RemoteAddress       = $SecurityGroup
            LocalPort           = $UDPPort
            Description         = 'Open UDP ports for SQLHA'
        }
    }

    # Open the ICMP ports
    FireWall ICMPv4In {
        Name               = 'ICMPv4-In'
        DisplayName        = 'ICMPv4In'
        Ensure             = 'Present'
        Enabled            = 'True'
        Protocol           = 'ICMPv4'
    }
    FireWall ICMPv4Out {
        Name               = 'ICMPv4-Out'
        DisplayName        = 'ICMPv4Out'
        Ensure             = 'Present'
        Enabled            = 'True'
        Protocol           = 'ICMPv4'
    }
    FireWall ICMPv6In {
        Name               = 'ICMPv6-In'
        DisplayName        = 'ICMPv6In'
        Ensure             = 'Present'
        Enabled            = 'True'
        Protocol           = 'ICMPv6'
    }
    FireWall ICMPv6Out {
        Name               = 'ICMPv6-Out'
        DisplayName        = 'ICMPv6Out'
        Ensure             = 'Present'
        Enabled            = 'True'
        Protocol           = 'ICMPv6'
    }

}
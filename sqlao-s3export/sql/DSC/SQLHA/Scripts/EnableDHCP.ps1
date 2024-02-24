Configuration EnableDHCP {
    param()

    # Ensure that DHCP is running
    Service EnableDHCP {
        Name     = 'DHCP'
        State    = 'Running'
    }
}
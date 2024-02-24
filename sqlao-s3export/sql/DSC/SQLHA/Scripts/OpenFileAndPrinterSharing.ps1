Configuration OpenFileAndPrinterSharing {
    param()

    Import-DSCResource -ModuleName NetworkingDsc

    # Get each Firewall port for file and printer sharing and ensure it's open
    $PortList = Get-NetFirewallRule -DisplayGroup "File and Printer Sharing"
    foreach ($Port in $PortList) {
        FireWall $Port.name {
            Name         = $Port.name
            Ensure       = 'Present'
            Enabled      = 'True'
        }
    }

    netsh advfirewall firewall set rule group = "File and Printer Sharing" new enable = Yes
}

Install-Module -Name NetworkingDsc
Configuration DisableWindowsUpdate {
    param()

    # Ensure Windows Update service is manual only
    Service 'Stop Windows Updates' {
        Name          = 'Windows Update'
        State         = 'Stopped'
        StartupType   = 'Manual'
    }
}
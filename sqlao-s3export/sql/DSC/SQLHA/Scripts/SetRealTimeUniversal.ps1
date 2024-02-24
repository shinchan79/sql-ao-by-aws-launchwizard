Configuration SetRealTimeUniversal {
    param()

    # Set the registry key in RealTimeIsUniversal to be true
    Registry SetTimeZoneToUniversal {
        Key = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
        ValueName    = 'RealTimeIsUniversal'
        Ensure       = 'Present'
        ValueType    = 'Dword'
        ValueData    = '1'
    }
}
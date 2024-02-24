function New-AWSLaunchWizardWaitHandle {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true)]
        [string]
        $Handle,

        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSLaunchWizard\',

        [Parameter(Mandatory=$false)]
        [switch]
        $Base64Handle
    )

    try {
        $ErrorActionPreference = "Stop"

        Write-Verbose "Creating $Path"
        New-Item $Path -Force

        if ($Base64Handle) {
            Write-Verbose "Trying to decode handle Base64 string as UTF8 string"
            $decodedHandle = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Handle))
            if ($decodedHandle -notlike "http*") {
                Write-Verbose "Now trying to decode handle Base64 string as Unicode string"
                $decodedHandle = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($Handle))
            }
            Write-Verbose "Decoded handle string: $decodedHandle"
            $Handle = $decodedHandle
        }

        Write-Verbose "Creating Handle Registry Key"
        New-ItemProperty -Path $Path -Name Handle -Value $Handle -Force

        Write-Verbose "Creating ErrorCount Registry Key"
        New-ItemProperty -Path $Path -Name ErrorCount -Value 0 -PropertyType dword -Force
    }
    catch {
        Write-Verbose $_.Exception.Message
    }
}

function New-AWSLaunchWizardResourceSignal {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]
        $Stack,

        [Parameter(Mandatory=$true)]
        [string]
        $Resource,

        [Parameter(Mandatory=$true)]
        [string]
        $Region,

        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSLaunchWizard\'
    )

    try {
        $ErrorActionPreference = "Stop"

        Write-Verbose "Creating $Path"
        New-Item $Path -Force

        Write-Verbose "Creating Stack Registry Key"
        New-ItemProperty -Path $Path -Name Stack -Value $Stack -Force

        Write-Verbose "Creating Resource Registry Key"
        New-ItemProperty -Path $Path -Name Resource -Value $Resource -Force

        Write-Verbose "Creating Region Registry Key"
        New-ItemProperty -Path $Path -Name Region -Value $Region -Force

        Write-Verbose "Creating ErrorCount Registry Key"
        New-ItemProperty -Path $Path -Name ErrorCount -Value 0 -PropertyType dword -Force
    }
    catch {
        Write-Verbose $_.Exception.Message
    }
}


function Get-AWSLaunchWizardErrorCount {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSLaunchWizard\'
    )

    process {
        try {
            Write-Verbose "Getting ErrorCount Registry Key"
            Get-ItemProperty -Path $Path -Name ErrorCount -ErrorAction Stop | Select-Object -ExpandProperty ErrorCount
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Set-AWSLaunchWizardErrorCount {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        [int32]
        $Count,

        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSLaunchWizard\'
    )

    process {
        try {
            $currentCount = Get-AWSLaunchWizardErrorCount
            $currentCount += $Count

            Write-Verbose "Creating ErrorCount Registry Key"
            Set-ItemProperty -Path $Path -Name ErrorCount -Value $currentCount -ErrorAction Stop
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Get-AWSLaunchWizardWaitHandle {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSLaunchWizard\'
    )

    process {
        try {
            $ErrorActionPreference = "Stop"

            Write-Verbose "Getting Handle key value from $Path"
            $key = Get-ItemProperty $Path

            return $key.Handle
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Get-AWSLaunchWizardResourceSignal {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSLaunchWizard\'
    )

    try {
        $ErrorActionPreference = "Stop"

        Write-Verbose "Getting Stack, Resource, and Region key values from $Path"
        $key = Get-ItemProperty $Path
        $resourceSignal = @{
            Stack = $key.Stack
            Resource = $key.Resource
            Region = $key.Region
        }
        $toReturn = New-Object -TypeName PSObject -Property $resourceSignal

        if ($toReturn.Stack -and $toReturn.Resource -and $toReturn.Region) {
            return $toReturn
        } else {
            return $null
        }
    }
    catch {
        Write-Verbose $_.Exception.Message
    }
}

function Remove-AWSLaunchWizardWaitHandle {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSLaunchWizard\'
    )

    process {
        try {
            $ErrorActionPreference = "Stop"

            Write-Verbose "Getting Handle key value from $Path"
            $key = Get-ItemProperty -Path $Path -Name Handle -ErrorAction SilentlyContinue

            if ($key) {
                Write-Verbose "Removing Handle key value from $Path"
                Remove-ItemProperty -Path $Path -Name Handle
            }
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Remove-AWSLaunchWizardResourceSignal {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$false)]
        [string]
        $Path = 'HKLM:\SOFTWARE\AWSLaunchWizard\'
    )

    try {
        $ErrorActionPreference = "Stop"

        foreach ($keyName in @('Stack','Resource','Region')) {
            Write-Verbose "Getting Stack, Resource, and Region key values from $Path"
            $key = Get-ItemProperty -Path $Path -Name $keyName -ErrorAction SilentlyContinue

            if ($key) {
                Write-Verbose "Removing $keyName key value from $Path"
                Remove-ItemProperty -Path $Path -Name $keyName
            }
        }
    }
    catch {
        Write-Verbose $_.Exception.Message
    }
}

Function Test-IsFileLocked {
    [cmdletbinding()]
    Param (
        [parameter(Mandatory=$True,ValueFromPipeline=$True,ValueFromPipelineByPropertyName=$True)]
        [Alias('FullName','PSPath')]
        [string[]]$Path
    )
    Process {
        ForEach ($Item in $Path) {
            #Ensure this is a full path
            $Item = Convert-Path $Item
            #Verify that this is a file and not a directory
            If ([System.IO.File]::Exists($Item)) {
                Try {
                    $FileStream = [System.IO.File]::Open($Item,'Open','Write')
                    $FileStream.Close()
                    $FileStream.Dispose()
                    $IsLocked = $False
                } Catch {
                    $IsLocked = $True
                }
                [pscustomobject]@{
                    File = $Item
                    IsLocked = $IsLocked
                }
            }
        }
    }
}

function Move-Item-Safely {
    [cmdletbinding()]
    Param (
        [string]
        $Path,

        [string]
        $Destination
    )

    For ($i = 0; $i -lt 5; $i++) {
        $obj = Test-IsFileLocked -Path $Path
        if ($obj."IsLocked") {
            Write-Verbose "$($Path) is locked, wait one min."
            Start-Sleep -s 60
        } else {
            Move-Item $Path $Destination
            break
        }
    }
}

function Write-AWSLaunchWizardEvent {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName=$true)]
        [string]
        $Message,

        [Parameter(Mandatory=$false)]
        [string]
        $EntryType = 'Error'
    )

    process {
        Write-Verbose "Checking for AWSLaunchWizard Eventlog Source"
        if(![System.Diagnostics.EventLog]::SourceExists('AWSLaunchWizard')) {
            New-EventLog -LogName Application -Source AWSLaunchWizard -ErrorAction SilentlyContinue
        }
        else {
            Write-Verbose "AWSLaunchWizard Eventlog Source exists"
        }

        Write-Verbose "Writing message to application log"

        try {
            Write-EventLog -LogName Application -Source AWSLaunchWizard -EntryType $EntryType -EventId 1001 -Message $Message
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}

function Write-AWSLaunchWizardException {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        [System.Management.Automation.ErrorRecord]
        $ErrorRecord
    )

    process {
        try {
            Write-Verbose "Incrementing error count"
            Set-AWSLaunchWizardErrorCount -Count 1

            Write-Verbose "Getting total error count"
            $errorTotal = Get-AWSLaunchWizardErrorCount
            $errorMessage = "{0} from {1} on line {2} of {3}" -f $ErrorRecord.Exception.ToString(), 
                                                                 $ErrorRecord.InvocationInfo.MyCommand.name,
                                                                 $ErrorRecord.InvocationInfo.ScriptLineNumber,
                                                                 $ErrorRecord.InvocationInfo.ScriptName

            $CmdSafeErrorMessage = $errorMessage -replace '[^a-zA-Z0-9\s\.\[\]\-,:_\\\/\(\)]', ''

            $handle = Get-AWSLaunchWizardWaitHandle -ErrorAction SilentlyContinue
            if ($handle) {
                Invoke-Expression "cfn-signal.exe -e 1 --reason='$CmdSafeErrorMessage' '$handle'"
            } else {
                $resourceSignal = Get-AWSLaunchWizardResourceSignal -ErrorAction SilentlyContinue
                if ($resourceSignal) {
                    Invoke-Expression "cfn-signal.exe -e 1 --stack '$($resourceSignal.Stack)' --resource '$($resourceSignal.Resource)' --region '$($resourceSignal.Region)'"
                } else {
                    throw "No handle or stack/resource/region found in registry"
                }
            }
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
        finally {
            Write-AWSLaunchWizardEvent -Message $errorMessage
            # throwing an exception to force cfn-init execution to stop
            throw $CmdSafeErrorMessage
        }
    }
}

function Write-AWSLaunchWizardStatus {
    [CmdletBinding()]
    Param()

    process {
        try {
            Write-Verbose "Checking error count"
            if((Get-AWSLaunchWizardErrorCount) -eq 0) {
                Write-Verbose "Getting Handle"
                $handle = Get-AWSLaunchWizardWaitHandle -ErrorAction SilentlyContinue
                if ($handle) {
                    Invoke-Expression "cfn-signal.exe -e 0 '$handle'"
                } else {
                    $resourceSignal = Get-AWSLaunchWizardResourceSignal -ErrorAction SilentlyContinue
                    if ($resourceSignal) {
                        Invoke-Expression "cfn-signal.exe -e 0 --stack '$($resourceSignal.Stack)' --resource '$($resourceSignal.Resource)' --region '$($resourceSignal.Region)'"
                    } else {
                        throw "No handle or stack/resource/region found in registry"
                    }
                }
            }
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
    }
}
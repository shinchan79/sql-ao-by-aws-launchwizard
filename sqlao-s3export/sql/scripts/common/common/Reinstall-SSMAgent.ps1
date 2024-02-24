[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$StackID = "",

    [Parameter(Mandatory=$false)]
    [string]$Resource = "",

    [Parameter(Mandatory=$false)]
    [string]$Region = "",

    [Parameter(Mandatory=$false)]
    [string]$Handler = "",

    [Parameter(Mandatory=$false)]
    [Boolean]$stockAMI = $True
)

function Write-CFNSignal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)]
        [string]$StackID = "",

        [Parameter(Mandatory=$false)]
        [string]$Resource = "",

        [Parameter(Mandatory=$false)]
        [string]$Region = "",

        [Parameter(Mandatory=$false)]
        [string]$Handler = "",

        [Parameter(Mandatory=$false)]
        [string]$ErrorMessage = ""
    )

    if ($Handler) {
        Invoke-Expression "cfn-signal.exe -e 1 --reason='$($ErrorMessage)' $($Handler)"
        throw $ErrorMessage
    } else {
        Invoke-Expression "cfn-signal.exe -e 1 --stack $($StackID) --resource $($Resource) --region $($Region)"
        throw "Failed to reinstall SSM Agent."
    }
}

Start-Transcript -Path C:\cfn\log\Reinstall-SSMAgent.ps1.txt -Append
$ErrorActionPreference = "stop"

if ($stockAMI) {
    Write-Output 'Stock AMI, no needs to reinstall SSM Agent'
    return
}

# https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-install-win.html
[System.Net.ServicePointManager]::SecurityProtocol = 'TLS12'
$progressPreference = 'silentlyContinue'

## SSM Agent setup executable path
$SSMAgentSetupPath = "C:\AmazonSSMAgentSetup.exe"

if ($null -eq (Get-Service | Where-Object { $_.Name -eq "AmazonSSMAgent" })) {
    try {
        Invoke-WebRequest -Uri https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/windows_amd64/AmazonSSMAgentSetup.exe -UseBasicParsing -OutFile $SSMAgentSetupPath

        Write-Output "Installing latest version of SSM Agent"
        Start-Process -FilePath $SSMAgentSetupPath -Wait -ArgumentList "/S"
    } catch {
        Write-Output "Failed to download and install latest SSM agent: $($_.Exception)"
        Write-CFNSignal -StackID $StackID -Resource $Resource -Region $Region -ErrorMessage $ErrorMessage -Handler "$($Handler)"
    }
}

## SSM Agent Service
$ServiceAmazonSSMAgent = Get-Service | Where-Object { $_.Name -eq "AmazonSSMAgent" }

if ($null -eq $ServiceAmazonSSMAgent) {
    throw "Unable to successfully install SSM Agent, stopping deployment."
}

try {
    if ($ServiceAmazonSSMAgent.StartType -ne "Automatic") {
        if ($ServiceAmazonSSMAgent.Status -ne "Stopped") {
            $ServiceAmazonSSMAgent | Stop-Service
        }

        $ServiceAmazonSSMAgent | Set-Service -StartupType "Automatic"
    }

    $ServiceAmazonSSMAgent | Start-Service -ErrorAction SilentlyContinue

    if ($ServiceAmazonSSMAgent.Status -ne "Running") {
        throw "Unable to start the AmazonSSMAgent service, stopping deployment."
    }
} catch {
    Write-CFNSignal -StackID $StackID -Resource $Resource -Region $Region -ErrorMessage "$($_.Exception.Message)" -Handler "$($Handler)"
}
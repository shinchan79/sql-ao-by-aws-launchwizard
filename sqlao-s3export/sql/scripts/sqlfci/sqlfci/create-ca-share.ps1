[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$Stackname,

    [Parameter(Mandatory=$true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$SqlAdminUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

try {
    ## Retrieve secure credentials using provided secret name
    $AdminSecureCredObject = Get-UserAccountDetails -UserAccountSecretName $AdminSecret -DomainDNSName $DomainDNSName -DomainUserName $DomainAdminUser

    $SQLServiceDomainAccountName = $DomainDNSName,$SqlAdminUser -Join "\"

    #Configure CA SMB share on FSx
    $shareName = "SqlShare"

    $fsxexists -eq $false
    do {
        $fsxshare = Get-FSXFileSystem | Where-Object { $_.Tags.Key -eq "aws:cloudformation:stack-name" -And $_.Tags.Value -eq $Stackname }

        if ($fsxshare) {
            $fsxexists -eq $true
        }
    } while ($fsxexists -eq $false)

    $fsList = Get-FSXFileSystem | Where-Object { $_.Tags.Key -eq 'aws:cloudformation:stack-name' -and $_.Tags.Value -eq $Stackname }

    Invoke-Command -ComputerName $fslist.WindowsConfiguration.RemoteAdministrationEndpoint -ConfigurationName FSxRemoteAdmin -scriptblock {
        New-FSxSmbShare -Name $Using:shareName -Path "D:\share\" -Description "CA share for MSSQL FCI" -ContinuouslyAvailable $True -Credential ($Using:AdminSecureCredObject).Credential
    } -Credential $AdminSecureCredObject.Credential

    Invoke-Command -ComputerName $fslist.WindowsConfiguration.RemoteAdministrationEndpoint -ConfigurationName FSxRemoteAdmin -scriptblock {
        Grant-FSxSmbShareAccess -Name $Using:shareName -AccountName ($Using:AdminSecureCredObject).DomainDlln -AccessRight Full -force
    } -Credential $AdminSecureCredObject.Credential

    Invoke-Command -ComputerName $fslist.WindowsConfiguration.RemoteAdministrationEndpoint -ConfigurationName FSxRemoteAdmin -scriptblock {
        Grant-FSxSmbShareAccess -Name $Using:shareName -AccountName $Using:SQLServiceDomainAccountName -AccessRight Full -force
    } -Credential $AdminSecureCredObject.Credential

    #Configure Witness SMB share on FSx
    $WitnessshareName = "SqlWitnessShare"

    Invoke-Command -ComputerName $fslist.WindowsConfiguration.RemoteAdministrationEndpoint -ConfigurationName FSxRemoteAdmin -scriptblock {
        New-FSxSmbShare -Name $Using:WitnessshareName -Path "D:\share\" -Description "Witness share for MSSQL FCI" -ContinuouslyAvailable $True -Credential ($Using:AdminSecureCredObject).Credential
    } -Credential $AdminSecureCredObject.Credential

    Invoke-Command -ComputerName $fslist.WindowsConfiguration.RemoteAdministrationEndpoint -ConfigurationName FSxRemoteAdmin -scriptblock {
        Grant-FSxSmbShareAccess -Name $Using:WitnessshareName  -AccountName Everyone -AccessRight Change -force
    } -Credential $AdminSecureCredObject.Credential
} catch {
    $_ | Write-AWSLaunchWizardException
}

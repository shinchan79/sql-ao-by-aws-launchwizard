[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$nameWsfc,

    [Parameter(Mandatory=$true)]
    [string]$domainPwdKey,

    [Parameter(Mandatory=$true)]
    [string]$domainUser,

    [Parameter(Mandatory=$true)]
    [string]$DomainNetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]$CreateNewAD
)

## Configure script and session settings
Set-ScriptSessionSettings -SetErrorActionPref -ScriptLogName $MyInvocation.MyCommand.Name

if ($CreateNewAD -eq $true) {
    try {
        Write-LogInfo "Create script for scheduled-task"

        $UpdateClusterPermissionScript = {
            $ErrorActionPreference = "Stop"
            For($i = 0; $i -lt 3; $i++) {
                Add-WindowsFeature RSAT-AD-PowerShell
                import-module activedirectory
                import-module ServerManager
                $addomainProperty = Get-Addomain
                $nameWsfc = $Using:nameWsfc
                $computer = get-adcomputer $nameWsfc
                $adPath = $computer.DistinguishedName.Replace("CN=$nameWsfc,", "AD:\")
                $acl = get-acl -path $adPath
                $sid = [System.Security.Principal.SecurityIdentifier] $computer.SID
                $identity = [System.Security.Principal.IdentityReference] $sid
                $CreateChildGUID = 'bf967a86-0de6-11d0-a285-00aa003049e2'
                $objectguid = new-object Guid $CreateChildGUID
                $adRights = [System.DirectoryServices.ActiveDirectoryRights] "CreateChild"
                $type = [System.Security.AccessControl.AccessControlType] "Allow"
                $ACE = New-Object System.DirectoryServices.ActiveDirectoryAccessRule $identity,$adRights,$type,$objectguid
                $acl.AddAccessRule($ace)
                Start-Sleep -s 3
                Set-acl -aclobject $acl -Path $adPath
                Start-Sleep -s 10
                $ClusterACL = $acl.GetAccessRules($true,$true,[System.Security.Principal.NTAccount]) | Where-Object { $_.ActiveDirectoryRights -eq "CreateChild" } | Where-Object { $_.ObjectType -eq $CreateChildGUID } | Where-Object { $_.IdentityReference -eq "$($addomainProperty.NetBIOSName)\$($nameWsfc)$" }
                if ($ClusterACL) {
                    break
                }
            }
        }

        [hashtable]$ex = @{}
        $ex.Message = ""
        $ex.IsError = $false

        try {
            $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $AdminSecret).SecretString
            $ClusterAdminUser = $DomainNetBIOSName + '\' + $domainUser
            # Creating Credential Object for Administrator
            $Credentials = (New-Object PSCredential($ClusterAdminUser,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))
            New-PSSession -ComputerName $env:COMPUTERNAME -Name 'aclSession' -Credential $Credentials -Authentication Credssp | Out-Null
            $Session = Get-PSSession -Name 'aclSession'
            Invoke-Command -Session $Session -ScriptBlock $UpdateClusterPermissionScript
            Remove-PSSession -Session $Session
        } catch {
            $ex.Message = "Failed to update WSFCluster's permissions: " + $_.Exception.Message
            $ex.IsError = $true
            Write-Log $ex
        }

        Write-LogInfo "Finished Updating WSFCluster's Permissions."
    } catch {
        $_ | Write-AWSLaunchWizardException
    }
} else {
    Write-Output "Existing AD. CLuster permissions needs to be prestaged"
}

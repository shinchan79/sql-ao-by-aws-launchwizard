[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]
    $WSFClusterName,

    [Parameter(Mandatory=$true)]
    [int]
    $NumberOfSubnets,

    [Parameter(Mandatory=$true)]
    [int]
    $NumberOfNodes,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainName,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminUser,

    [Parameter(Mandatory=$true)]
    [string]
    $DomainAdminPasswordKey,

    [Parameter(Mandatory=$false)]
    [string[]]
    $NodeNetBIOSNames,

    [Parameter(Mandatory=$true)]
    [string]
    $Node1IP2,

    [Parameter(Mandatory=$true)]
    [string]
    $Node2IP2,

    [Parameter(Mandatory=$false)]
    [string]
    $Node3IP2,

    [Parameter(Mandatory=$false)]
    [string]
    $NetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]
    $NodeAccessTypes

)
try {
    Start-Transcript -Path C:\cfn\log\Configure-WSFC.ps1.txt -Append
    $ErrorActionPreference = "Stop"

    $DomainAdminFullUser = $DomainName + '\' + $DomainAdminUser
    #$DomainAdminPassword = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
    #$DomainAdminSecurePassword = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
    #$DomainAdminCreds = New-Object System.Management.Automation.PSCredential($DomainAdminFullUser, $DomainAdminSecurePassword)
    $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
    $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))
    $NumberOfFailoverNodes = 0
    $AccessTypeArray = $NodeAccessTypes.split(",")
    foreach ($AccessType in $AccessTypeArray) {
        if ($AccessType -eq "SyncMode") {
            $NumberOfFailoverNodes++
        }
    }
   
    $ConfigWSFCPs={
        Start-Transcript -Path C:\cfn\log\Configure-WSFC.ps1.txt -Append
        $ErrorActionPreference = "Stop"
        $allNodes = $Using:NodeNetBIOSNames[0],$Using:NodeNetBIOSNames[1],$Using:NodeNetBIOSNames[2]
        $allAddr = $Using:Node1IP2,$Using:Node2IP2,$Using:Node3IP2
        $nodes = $allNodes[0..($Using:NumberOfFailoverNodes - 1)]
        $addr =  $allAddr[0..($Using:NumberOfFailoverNodes - 1)]
        New-Cluster -Name $Using:WSFClusterName -Node $nodes -StaticAddress $addr
        Write-Output "Created WSFCluster."
    }

    $AddWSFCPs={
        Start-Transcript -Path C:\cfn\log\Configure-WSFC.ps1.txt -Append
        $ErrorActionPreference = "Stop"
        $allNodes = $Using:NodeNetBIOSNames[0],$Using:NodeNetBIOSNames[1],$Using:NodeNetBIOSNames[2],$Using:NodeNetBIOSNames[3],$Using:NodeNetBIOSNames[4],$Using:NodeNetBIOSNames[5],$Using:NodeNetBIOSNames[6],$Using:NodeNetBIOSNames[7]
        $nodes = $allNodes[0..($Using:NumberOfNodes - 1)]
        
        $clusterNodes = Get-ClusterNode | select -Property Name
        $remainingNodes = @()
        foreach($node in $nodes) {
            if (-not ($clusterNodes.Name -contains $node)) {
                $remainingNodes += $node
                Write-Output "Remaining Nodes: " + $node
            }
        }

        if ($remainingNodes.Length -gt 0) {
            Write-Output "Adding nodes to Cluster."
            Get-Cluster -Name $Using:WSFClusterName | Add-ClusterNode -Name $remainingNodes
        }
        
        Write-Output "Successfully added nodes to Cluster."
    }

    $timeoutMinutes=25
    $intervalMinutes=1
    $elapsedMinutes = 0.0
    $startTime = Get-Date
    $stabilized = $false
    $cluster = $false
    $errorMessage = ""
    try {
        $cluster =  Get-Cluster -Name $WSFClusterName
    } catch {}
    
    While ($elapsedMinutes -lt $timeoutMinutes) {
        if ($cluster) {
            $stabilized = $true
            break
        }
        
        try {
            Invoke-Command -Authentication Credssp -Scriptblock $ConfigWSFCPs -ComputerName $NetBIOSName -Credential $DomainAdminCreds
            $stabilized = $true
            break
        } catch {
            Start-Sleep -Seconds $($intervalMinutes * 60)
            $elapsedMinutes = ($(Get-Date) - $startTime).TotalMinutes
            $errorMessage = $_.Exception.Message
        }
    }
    if (!$stabilized) {Throw "Failed to create Cluster within the timeout of $($timeoutMinutes) minutes: $($errorMessage)"
    }
    Write-Output "Successfully created Cluster."


    # Adding addtional cluster check before Adding node
    $tries = 0
    while ($tries -le 10)
    {
        try
        {
            Get-Cluster -Name $WSFClusterName
            break
        }
        catch
        {
            Write-Host "Cluster not available yet. Retrying in 30 seconds"
            Start-sleep 30
            $tries++
        }
    }

    if ($NumberOfNodes -gt $NumberOfFailoverNodes) {
        $timeoutMinutes=25
        $elapsedMinutes = 0.0
        $startTime = Get-Date
        $stabilized = $false
        $errorMessage = ""

        While ($elapsedMinutes -lt $timeoutMinutes) {
            try {
                Invoke-Command -Authentication Credssp -Scriptblock $AddWSFCPs -ComputerName $NetBIOSName -Credential $DomainAdminCreds
                $stabilized = $true
                break
            } catch {
                Start-Sleep -Seconds $($intervalMinutes * 60)
                $elapsedMinutes = ($(Get-Date) - $startTime).TotalMinutes
                $errorMessage = $_.Exception.Message
                Write-Output "Adding remaining nodes failed: " + $errorMessage
            }
        }

        if (!$stabilized) {
            Throw "Failed to add Cluster nodes within the timeout of $($timeoutMinutes) minutes: $($errorMessage)"
        }
    }

    # Adding nodes cannot observed immediately.
    Write-Output "Finished Configure WSFCluster task."
}
catch {
    $_ | Write-AWSLaunchWizardException
}

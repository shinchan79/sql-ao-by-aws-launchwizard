Function Write-LogInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]
        $logString
    )

    $info = @{}
    $info.IsError = $false
    $info.Message = $logString
    Write-Log $info
}

Function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [hashtable]
        $ex
    )
    
    $logString = $ex.Message
    $type = "Info"
    if ($ex.IsError) {
        $type = "Error"
    }
            
    $timeStamp = Get-Date -Format g
    $Logfile = "C:\LaunchWizard-SQLHA-$(get-date -f yyyy-MM-dd).txt"
    try {
        $logString = "$timeStamp $($type):  $logString"
        Write-Host $logString
        Add-content $Logfile -value $logString
    } catch {
        $errorMessage = $_.Exception.Message
        throw "Error writing log file: $errorMessage"
    }

    if ($ex.IsError) {
        exit 1
    }
}

################################################################################
#0. Set Cluster AD permission
################################################################################
Function Set-ClusterPermission {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $nameWsfc,

        [Parameter(Mandatory=$true)]
        [string]
        $domainPwdKey,

        [Parameter(Mandatory=$true)]
        [string]
        $domainUser
    )
    $ErrorActionPreference = "Stop"
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
            $ClusterACL = $acl.GetAccessRules($true,$true,[System.Security.Principal.NTAccount])|where ActiveDirectoryRights -eq "CreateChild"|where ObjectType -eq $CreateChildGUID|where IdentityReference -eq "$($addomainProperty.NetBIOSName)\$($nameWsfc)$"
            if ($ClusterACL) {
                break
            }
        }
    }

    [hashtable]$ex = @{}
    $ex.Message = ""
    $ex.IsError = $false

    try {
        $domainPwd = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $domainPwdKey).SecretString
        #$domainPwd = (Get-SSMParameterValue -Names $domainPwdKey -WithDecryption $True).Parameters[0].Value
        #$Pwd = ConvertTo-SecureString $domainPwd -AsPlainText -Force
        #$cred = New-Object System.Management.Automation.PSCredential $domainUser, $Pwd
        $cred = (New-Object PSCredential($domainUser,(ConvertTo-SecureString $domainPwd.Password -AsPlainText -Force)))
        New-PSSession -ComputerName $env:COMPUTERNAME -Name 'aclSession' -Credential $cred -Authentication Credssp | Out-Null
        $Session = Get-PSSession -Name 'aclSession'
        Invoke-Command -Session $Session -ScriptBlock $UpdateClusterPermissionScript
        Remove-PSSession -Session $Session
    } catch {
        $ex.Message = "Failed to update WSFCluster's permissions: " + $_.Exception.Message
        $ex.IsError = $true
        Write-Log $ex
    }

    Write-LogInfo "Finished Updating WSFCluster's Permissions."
}


################################################################################
#1. Start SQLServer
################################################################################
Function Start-SQLServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $primaryNode,

        [Parameter(Mandatory=$true)]
        [string[]]
        $nodes,

        [Parameter(Mandatory=$true)]
        [hashtable]
        $secondaryNodeFqdnMap,

        $cred
    )

    Write-LogInfo "Start SQLServer"
    $startSQLServerLog = (Invoke-Command -ComputerName $primaryNode -Credential $cred -ScriptBlock {
            param(
            $secondaryNodeFqdnMap,
            $cred
            )

        function Bring-Disks-Online {
            $disk = get-disk | where OperationalStatus -eq "Offline"
            $disk | Set-Disk -IsOffline $false
            $disk | Set-Disk -IsReadonly $False
        }

        function Remove-Cluster-Disks {
            param (
                $secondaryNodeFqdnMap,
                $cred
            )
            [hashtable]$ex = @{}
            $ex.Message = "Finished Starting SQLServer"
            $ex.IsError = $false

            try {
                $failedDisks = Get-ClusterResource -Name "Cluster Disk*"
                if (!$failedDisks) {
                    return $ex
                }

                $failedDisks | Remove-ClusterResource -Force

                Bring-Disks-Online
                Import-Module SQLPS -DisableNameChecking
                Start-Service -Name MSSQLSERVER
                ForEach ($node in $secondaryNodeFqdnMap.Keys) {
                    Invoke-Command -ComputerName $secondaryNodeFqdnMap.$node -Credential $cred -ScriptBlock {
                        Bring-Disks-Online
                        Import-Module SQLPS -DisableNameChecking
                        Start-Service -Name MSSQLSERVER
                    }
                }

                return $ex
            } catch {
                $ex.Message = "Failed to Remove Cluster Disks: " + $_.Exception.Message
                $ex.IsError = $true
                return $ex
            }    
        }

        return (Remove-Cluster-Disks $primaryNode, $secondaryNodeFqdnMap $cred)
    } -ArgumentList $nodes[0], $secondaryNodeFqdnMap, $cred)

    Write-Log $startSQLServerLog
            
} 

################################################################################
#2. Create test DB on Primary Node
################################################################################
Function New-DataBase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $primaryNode,

        $cred,

        [Parameter(Mandatory=$true)]
        [string]
        $dbName,

        [Parameter(Mandatory=$true)]
        [string]
        $sqlDataPath,

        [Parameter(Mandatory=$true)]
        [int]
        $dataSize,

        [Parameter(Mandatory=$true)]
        [int]
        $dataGrowth,

        [Parameter(Mandatory=$true)]
        [string]
        $sqlLogPath,

        [Parameter(Mandatory=$true)]
        [int]
        $logSize,

        [Parameter(Mandatory=$true)]
        [int]
        $logGrowth
    )

    Write-LogInfo "Create $($dbName) on Primary Node"
    Invoke-Command -ComputerName $primaryNode -Credential $cred -ScriptBlock {
        [hashtable]$ex = @{}
        $ex.Message = "Finished Creating DB on the Node"
        $ex.IsError = $false

        $databaseName = $Using:dbName
        $hostname = [System.Net.Dns]::GetHostName()
        Write-LogInfo "$hostname - Creating the database $databaseName"

        Import-Module SQLPS -DisableNameChecking
        $SQLServer = New-Object -TypeName Microsoft.SqlServer.Management.Smo.Server -ArgumentList 'localhost'

        # Only continue if the database does not exist
        $objDB = $SQLServer.Databases[$databaseName]

        if ($objDB) {
            $ex.Message = "$databaseName already existed, skipped this step"
            return $ex
        }

        try {
            # Create the primary file group and add it to the database
            $objDB = New-Object -TypeName Microsoft.SqlServer.Management.Smo.Database($SQLServer, $databaseName)
            $objPrimaryFG = New-Object `
                -TypeName Microsoft.SqlServer.Management.Smo.Filegroup($objDB, 'PRIMARY')
            $objDB.Filegroups.Add($objPrimaryFG)

            # Create a single data file and add it to the Primary filegroup
            $dataFileName = $databaseName + '_Data'
            $objData = New-Object `
                -TypeName Microsoft.SqlServer.Management.Smo.DataFile($objPrimaryFG, $dataFileName)
            $objData.FileName = $Using:sqlDataPath + '\' + $dataFileName + '.mdf'
            $objData.Size = ($Using:dataSize * 1024)
            $objData.GrowthType = 'KB'
            $objData.Growth = ($Using:dataGrowth * 1024)
            $objData.IsPrimaryFile = 'true'
            $objPrimaryFG.Files.Add($objData)

            # Create the log file and add it to the database
            $logFileName = $databaseName + '_Log'
            $objLog = New-Object Microsoft.SqlServer.Management.Smo.LogFile($objDB, $logFileName)
            $objLog.FileName = $Using:sqlLogPath + '\' + $logFileName + '.ldf'
            $objLog.Size = ($Using:logSize * 1024)
            $objLog.GrowthType = 'KB'
            $objLog.Growth = ($Using:logGrowth * 1024)
            $objDB.LogFiles.Add($objLog)
        
            # Create the database
            $objDB.Create()  # Create the database
            $objDB.SetOwner('sa')  # Change the owner to sa
        } catch {
            $ex.Message = "Failed to Create testDB on Primary Node: " + $_.Exception.Message
            $ex.IsError = $true
        }

        return $ex
    } -ArgumentList $dbName, $sqlDataPath, $dataSize, $dataGrowth, $sqlLogPath, $logSize, $logGrowth
}

################################################################################
#3. Create a shared folder for initial backup used by Availability Groups
################################################################################
Function New-SharedFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $primaryNode,

        $cred,

        [Parameter(Mandatory=$true)]
        [string]
        $domainUser,

        [Parameter(Mandatory=$true)]
        [string]
        $sqlServiceUser,

        [Parameter(Mandatory=$true)]
        [string]
        $sqlBackupPath, 

        [Parameter(Mandatory=$true)]
        [string]
        $shareName,

        [Parameter(Mandatory=$true)]
        [string[]] 
        $nodes,

        [Parameter(Mandatory=$true)]
        [int]
        $numberOfNodes
    )

    Invoke-Command -ComputerName $primaryNode -Credential $cred -ScriptBlock { 
        param(
            $domainUser,
            $sqlServiceUser,
            $sqlBackupPath, 
            $shareName, 
            $nodes, 
            $numberOfNodes
        )

        [hashtable]$ex = @{}
        $ex.Message = "Finished Creating a shared folder"
        $ex.IsError = $false

        $hostname = [System.Net.Dns]::GetHostName()

        # Create folder for the backup in Node2.
        Write-LogInfo "Creating Sharing Folders: $sqlBackupPath"
        if (!(Test-Path -Path $sqlBackupPath )) { 
            New-item -ItemType Directory $sqlBackupPath | Out-Null 
        }
        try {
            # Create a Windows share for the folder
            Write-LogInfo "$hostname - Creating Windows Share"
            Get-SmbShare | Where-Object -Property Name -eq $shareName | 
                Remove-SmbShare -Force
            # Grant secondaryNoes domianAdmin sqlsa fullaccess to sharefolder
            $users = ("$($domainUser)", "$($sqlServiceUser)", "NT SERVICE\MSSQLSERVER")
            ForEach ($secondaryNode in $nodes[1..($numberOfNodes - 1)]) {
                $users += "$($secondaryNode)`$"
            }

            New-SMBShare -Name $shareName -Path $sqlBackupPath -FullAccess ($users) | Out-Null
        } catch {
            $ex.Message = "Failed to Create Share folder: " + $_.Exception.Message
            $ex.IsError = $true
        }

        return $ex
    } -ArgumentList $domainUser, $sqlServiceUser, $sqlBackupPath, $shareName, $nodes, $numberOfNodes
}

################################################################################
#4.  Enable CredSSP Server on Each Nodes
################################################################################
Function Enable-CredSSp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]
        $nodesFqdn,

        $cred
    )

    # Enable CredSSP in local computer
    Write-LogInfo "Enable CredSSP Client in local machine"
    Enable-WSManCredSSP Client -DelegateComputer $nodesFqdn -Force | Out-Null

    # Wait 15 secs before enabling CredSSP in both servers
    # On ocassions got errors when running the command that follows without waiting
    Start-Sleep -s 15

    # Enable CredSSP Server in remote nodes
    Write-LogInfo "Enable CredSSP Server all remote Nodes"
    Invoke-Command -ComputerName $nodesFqdn -ScriptBlock { 
      Enable-WSManCredSSP Server -Force 
    } -Credential $cred -SessionOption $session_options | Out-Null
}

################################################################################
#5. Create the SQL Server endpoints for the Availability Groups
################################################################################
Function New-SQLServerEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $nodeFqdn,

        $cred,

        [Parameter(Mandatory=$true)]
        [string[]]
        $nodes,

        [Parameter(Mandatory=$true)]
        [string]
        $domainNetbios
    )
    return (Invoke-Command -ComputerName $nodeFqdn -Credential $cred -ScriptBlock { 
        param(
            $domainNetbios, 
            $nodes
        )

        [hashtable]$ex = @{}
        $ex.Message = "Finished Creating the SQL Server endpoints for the Availability Groups"
        $ex.IsError = $false

        $hostname = [System.Net.Dns]::GetHostName() 
        $remoteNodes = @()
        ForEach ($node in $nodes) {
         if ($hostname.ToLower() -eq $node) {
             continue    
         }
         $remoteNodes += "$($domainNetbios)\$($node)`$"
        }
 
        try {
            # Creating endpoint
            Import-Module SQLPS
            $endpoint = New-SqlHadrEndpoint "Hadr_endpoint" `
            -Port 5022 `
            -Path "SQLSERVER:\SQL\$hostname\Default"
            Set-SqlHadrEndpoint -InputObject $endpoint -State "Started" | Out-Null

            # Grant connect permissions to the endpoints
            Foreach($remoteNode in $remoteNodes) {
                $query = " `
                IF SUSER_ID('$($remoteNode)') IS NULL CREATE LOGIN [$($remoteNode)] FROM WINDOWS `
                GO
                GRANT CONNECT ON ENDPOINT::[Hadr_endpoint] TO [$($remoteNode)] `
                GO `
                IF EXISTS(SELECT * FROM sys.server_event_sessions WHERE name='AlwaysOn_health') `
                BEGIN `
                    ALTER EVENT SESSION [AlwaysOn_health] ON SERVER WITH (STARTUP_STATE=ON); `
                END `
                IF NOT EXISTS(SELECT * FROM sys.dm_xe_sessions WHERE name='AlwaysOn_health') `
                BEGIN `
                    ALTER EVENT SESSION [AlwaysOn_health] ON SERVER STATE=START; `
                END `
                GO "

                Import-Module SQLPS
                Invoke-Sqlcmd -Query $query
            }
        } catch {
            $ex.Message = "Failed to create endpoints for each node: " + $_.Exception.Message
            $ex.IsError = $true
        }

        return $ex
    } -ArgumentList $domainNetbios, $nodes)
}


################################################################################
#6. Create the Availability Group
################################################################################
Function New-AG {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $primaryNode,

        $cred,

        [Parameter(Mandatory=$true)]
        [string[]]
        $nodeAccessTypes,

        [Parameter(Mandatory=$true)]
        [string[]]
        $nodes,

        [Parameter(Mandatory=$true)]
        [int]
        $numberOfNodes,

        [Parameter(Mandatory=$true)]
        [string]
        $shareName,

        [Parameter(Mandatory=$true)]
        [string]
        $dbName,

        [Parameter(Mandatory=$true)]
        [string]
        $domain,

        [Parameter(Mandatory=$true)]
        [string]
        $agName,

        [Parameter(Mandatory=$true)]
        [string]
        $backupLog
    )

    Write-LogInfo "Creating the SQL Server Availability Group"
    Invoke-Command -ComputerName $primaryNode -Authentication Credssp -Credential $cred -ScriptBlock {
        param(
            $nodeAccessTypes,
            $nodes, 
            $numberOfNodes, 
            $shareName, 
            $dbName, 
            $domain, 
            $agName, 
            $backupLog
        )
        [hashtable]$ex = @{}
        $ex.Message = "Finished Creating the Availability Group"
        $ex.IsError = $false
        
        Import-Module SQLPS -DisableNameChecking
    
        # Check if the AG is already setup
        $AG = Get-ChildItem SQLSERVER:\SQL\$($nodes[0])\DEFAULT\AvailabilityGroups
    
        if (!($AG)) { 
            try {
                $hostname = [System.Net.Dns]::GetHostName()
    
                # Backup my database and its log on the primary
                Write-LogInfo "Creating backups of database $dbName"
                $backupDB = "\\$($nodes[0])\$($shareName)\$($dbName)_db.bak"
                Backup-SqlDatabase `
                    -Database $dbName `
                    -BackupFile $backupDB `
                    -ServerInstance $nodes[0] `
                    -Initialize

                ForEach($secondaryNode in $nodes[1..($numberOfNodes - 1)]) {
                    # Restore the database and log on the secondary (using NO RECOVERY)
                    Write-LogInfo "Restoring backups of database in $secondaryNode"
                    Restore-SqlDatabase `
                        -Database $dbName `
                        -BackupFile $backupDB `
                        -ServerInstance $secondaryNode `
                        -NoRecovery -ReplaceDatabase
                }
    
            $sql = Invoke-Sqlcmd -Query 'SELECT @@VERSION;' -QueryTimeout 20
            $SQLServerVersion = $sql.Column1
            # SQL Server 2014 can only have 2 automatic failover nodes
            if ($SQLServerVersion.StartsWith('Microsoft SQL Server 2014')) {
                $createAGScript = 'USE [master] `
                GO `
                CREATE AVAILABILITY GROUP [$($agName)] `
                WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY) `
                FOR DATABASE [$($dbName)] `
                REPLICA ON '
                For($i = 0; $i -lt $numberOfNodes; $i++) {
                    Write-LogInfo 'Create $secondaryNode Replica'
                    if ($i -eq 0) {
                        $failoverMode = 'AUTOMATIC'
                        $availabilityMode = 'SYNCHRONOUS_COMMIT'
                    } else {
                        $createAGScript += ', '
                    }
                    if ($i -eq 2){
                        $failoverMode = 'MANUAL'
                        $availabilityMode = 'SYNCHRONOUS_COMMIT'
                    }
                    if ($i -gt 2) {
                        $failoverMode = 'MANUAL'
                        $availabilityMode = 'ASYNCHRONOUS_COMMIT'
                    }
                    $createAGScript += "N'$($nodes[$i])' WITH (ENDPOINT_URL = N'TCP://$($nodes[$i])$($domain):5022', FAILOVER_MODE = $($failoverMode), AVAILABILITY_MODE = $($availabilityMode), SESSION_TIMEOUT = 10, BACKUP_PRIORITY = 50, PRIMARY_ROLE(ALLOW_CONNECTIONS = ALL), SECONDARY_ROLE(ALLOW_CONNECTIONS = NO))"
                }
                $createAGScript += '; `
                GO'
                Invoke-Sqlcmd -Query $createAGScript
            } else {
                # Find the version of SQL Server that Node 1 is running
                $Srv = Get-Item SQLSERVER:\SQL\$($nodes[0])\DEFAULT
                $Version = ($Srv.Version)
                $syncMode = @{
                    availabilityMode = 'SynchronousCommit'
                    failoverMode = 'Automatic'
                    connectionMode = 'None'
                }
                $readOnlyMode = @{
                    availabilityMode = 'AsynchronousCommit'
                    failoverMode = 'Manual'
                    connectionMode = 'AllowReadIntentConnectionsOnly'
                }
    
                $Replicas = @()
                # Create an in-memory representation of the replica
                # Getting the AMI ID from the registry to check SQL version.
                $AMI = Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Amazon\MachineImage\' -Name AMIName
                For ($i = 0; $i -lt $numberOfNodes; $i++) {
                    If ($AMI.Contains('Standard'))
                       {
                       Write-LogInfo "SQL AMi is standard. No read only replicas"
                        $currentMode = $syncMode
                        Write-LogInfo "Create syncMode $($nodes[$i]) Replica"
                        $Replicas += @(New-SqlAvailabilityReplica `
                            -Name $nodes[$i] `
                            -EndpointURL "TCP://$($nodes[$i]).$($domain):5022" `
                            -AvailabilityMode $($currentMode.availabilityMode) `
                            -FailoverMode $($currentMode.failoverMode) `
                            -Version $($Version) `
                            -AsTemplate)
                       }
                    else {
                        if ($nodeAccessTypes[$i] -eq "SyncMode") {
                        $currentMode = $syncMode
                        Write-LogInfo "Create syncMode $($nodes[$i]) Replica"
                        $Replicas += @(New-SqlAvailabilityReplica `
                            -Name $nodes[$i] `
                            -EndpointURL "TCP://$($nodes[$i]).$($domain):5022" `
                            -AvailabilityMode $($currentMode.availabilityMode) `
                            -FailoverMode $($currentMode.failoverMode) `
                            -Version $($Version) `
                            -AsTemplate)
                        } else {
                            $currentMode = $readOnlyMode
                            Write-LogInfo "Create readOnlyMode $($nodes[$i]) Replica"
                            $Replicas += @(New-SqlAvailabilityReplica `
                                -Name $nodes[$i] `
                                -EndpointURL "TCP://$($nodes[$i]).$($domain):5022" `
                                -AvailabilityMode $($currentMode.availabilityMode) `
                                -FailoverMode $($currentMode.failoverMode) `
                                -ConnectionModeInSecondaryRole $($currentMode.connectionMode) `
                                -Version $($Version) `
                                -AsTemplate)
                        }
                    }

                }
                # Create the availability group
                $newAG = New-SqlAvailabilityGroup `
                    -Name $agName `
                    -Path "SQLSERVER:\SQL\$($nodes[0])\DEFAULT" `
                    -AvailabilityReplica @($Replicas) `
                    -Database $dbName
            }
                # Join the secondary replica to the availability group.
                Foreach($secondaryNode in $nodes[1..($numberOfNodes - 1)]) {
                    Write-LogInfo "Join $secondaryNode to the Availability Group"
                    Join-SqlAvailabilityGroup `
                        -Path "SQLSERVER:\SQL\$($secondaryNode)\DEFAULT" `
                        -Name $agName
                }
            } catch {
                $ex.Message = "Failed to Create AG: " + $_.Exception.Message
                $ex.IsError = $true
            }
        } else {
            $ex.Message = "Skip creation of the Availability Group. This node is already member of the Availability Group"
        }
    
        return $ex
    } -ArgumentList $nodeAccessTypes, $nodes, $numberOfNodes, $shareName, $dbName, $domain, $agName, $backupLog
}
    
################################################################################
#7. Join secondary DBs to AG
################################################################################
Function New-JoinDBQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $dbName,

        [Parameter(Mandatory=$true)]
        [string]
        $agName
    )
    return "-- Wait for the replica to start communicating `
    begin try `
    declare @conn bit `
    declare @count int `
    declare @replica_id uniqueidentifier `
    declare @group_id uniqueidentifier `
    set @conn = 0 `
    set @count = 30 -- wait for 5 minutes `
    if (serverproperty('IsHadrEnabled') = 1) `
    and (isnull((select member_state from master.sys.dm_hadr_cluster_members where upper(member_name COLLATE Latin1_General_CI_AS) = upper(cast(serverproperty('ComputerNamePhysicalNetBIOS') as nvarchar(256)) COLLATE Latin1_General_CI_AS)), 0) <> 0) `
    and (isnull((select state from master.sys.database_mirroring_endpoints), 1) = 0) `
    begin `
    select @group_id = ags.group_id from master.sys.availability_groups as ags where name = N'$($agName)' `
    select @replica_id = replicas.replica_id from master.sys.availability_replicas as replicas where upper(replicas.replica_server_name COLLATE Latin1_General_CI_AS) = upper(@@SERVERNAME COLLATE Latin1_General_CI_AS) and group_id = @group_id `
    while @conn <> 1 and @count > 0 `
    begin `
    set @conn = isnull((select connected_state from master.sys.dm_hadr_availability_replica_states as states where states.replica_id = @replica_id), 1) `
    if @conn = 1 `
    begin `
    -- exit loop when the replica is connected, or if the query cannot find the replica status `
    break `
    end `
    waitfor delay '00:00:10' `
    set @count = @count - 1 `
    end `
    end `
    end try `
    begin catch `
    -- If the wait loop fails, do not stop execution of the alter database statement `
    end catch `
    ALTER DATABASE [$($dbName)] SET HADR AVAILABILITY GROUP = [$($agName)]; `
    GO` "
}

Function Join-secondaryDBs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $dbName,

        [Parameter(Mandatory=$true)]
        [string]
        $primaryNode,

        [Parameter(Mandatory=$true)]
        [string]
        $primaryNodeFqdn,

        [Parameter(Mandatory=$true)]
        [hashtable]
        $secondaryNodeFqdnMap,

        [Parameter(Mandatory=$true)]
        $cred,

        [Parameter(Mandatory=$true)]
        [string]
        $agName,

        [Parameter(Mandatory=$true)]
        [string]
        $backupLog 
    )

    [hashtable]$ex = @{}
    $ex.Message = "Finished Restoring DB on $node"
    $ex.IsError = $false

    $joinDBQuery = New-JoinDBQuery $dbName $agName
    # backup DB log on primary node
    Write-LogInfo "Start Backuping DB Log on Primary Node"
    try {
        Invoke-Command -ComputerName $primaryNodeFqdn -Credential $cred -ScriptBlock { 
            param(
                $dbName, 
                $backupLog, 
                $primaryNode
            )
            Import-Module SQLPS
            Backup-SqlDatabase `
                -Database $dbName `
                -BackupFile $backupLog `
                -ServerInstance $primaryNode `
                -BackupAction Log -Initialize

        } -ArgumentList $dbName, $backupLog, $primaryNode
        Write-LogInfo "Finished Backuping DB on Primary Node"
    } catch {
        $ex.Message = "Failed to Backup DB on Primary Node: " + $_.Exception.Message
        $ex.IsError = $true
        return $ex
    }

    # restore DB on secondaryNodes and join DB to AG
    ForEach ($node in $secondaryNodeFqdnMap.Keys) {
        Write-LogInfo "Start Restoring DB on $node and Joining DB to AG"
        Import-Module SQLPS
        try {
            Invoke-Command -ComputerName $secondaryNodeFqdnMap.$node -Credential $cred -ScriptBlock { 
                param(
                    $joinDBQuery, 
                    $backupLog, 
                    $dbName, 
                    $node
                )

                Restore-SqlDatabase `
                    -Database $dbName `
                    -BackupFile $backupLog `
                    -ServerInstance $node `
                    -RestoreAction Log `
                    -NoRecovery
                Invoke-Sqlcmd -Query $joinDBQuery
            } -ArgumentList $joinDBQuery, $backupLog, $dbName, $node
        } catch {
            $ex.Message = "Failed to Restore DB on $node : " + $_.Exception.Message
            $ex.IsError = $true
            return $ex
        }
    }
    
    return $ex
}

################################################################################
#8. Create AG Listener
################################################################################
Function New-AGListener {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]
        $ipAgListeners,

        [Parameter(Mandatory=$true)]
        [string[]]
        $subnetMasks,

        [Parameter(Mandatory=$false)]
        [string]
        $privateSubnetAssignment,

        [Parameter(Mandatory=$true)]
        [string]
        $nameAg,

        [Parameter(Mandatory=$true)]
        [string]
        $nameAgListener
    )

    [hashtable]$ex = @{}
    $ex.Message = "Finished Adding AG Listener"
    $ex.IsError = $false

    Write-LogInfo "Creating AG Listener"
    $addedSubnet = New-Object System.Collections.Generic.HashSet[String]
    $privateSubnetAssignments = $privateSubnetAssignment.split(',')
    $staticIps = "(N'$($ipAgListeners[0])', N'$($subnetMasks[0])')"
    if ($privateSubnetAssignment.Length -ne 0) {
        $addedSubnet.Add($privateSubnetAssignments[0]) > $null
    }
    
    For ($i=1; $i -lt $subnetMasks.Length; $i++) {
        if ($privateSubnetAssignment.Length -eq 0) { ## New VPC case
            if ($i -gt 3) {
                break
            }

            $staticIps += ", (N'$($ipAgListeners[$i])', N'$($subnetMasks[$i])')"
        } else {
            if (!$addedSubnet.Contains($privateSubnetAssignments[$i])) {
                $staticIps += ", (N'$($ipAgListeners[$i])', N'$($subnetMasks[$i])')"
                $addedSubnet.Add($privateSubnetAssignments[$i]) > $null
            }
        }
    }
    
    $addListenerQuery = "USE [master] `
    GO`
    EXEC sp_configure 'remote query timeout', 0 ;  
    GO`
    RECONFIGURE ;  
    GO`
    ALTER AVAILABILITY GROUP [$($nameAg)] ADD LISTENER N'$($nameAgListener)' (WITH IP ($($staticIps)), PORT=1433);
    GO"
    try {
        Import-Module SQLPS
        Invoke-Sqlcmd -Query $addListenerQuery > $null
    } catch {
        $ex.Message = "Failed to Create AG Listener : " + $_.Exception.Message
        $ex.IsError = $true
    }
    
    return $ex
}
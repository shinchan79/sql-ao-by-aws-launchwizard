#requires -version 5.0

enum Ensure
{
    Absent
    Present
}

enum SingleInstance
{
    Yes
}

enum AccessType
{
    Full
    ReadOnly
}

enum ClusterGroupType
{
    AvailableStorage
    Cluster
    ClusterSharedVolume
    ClusterStoragePool
    DhcpServer
    Dtc
    FileServer
    GenericApplication
    GenericScript
    GenericService
    IScsiNameService
    IScsiTarget
    Msmq
    ScaleoutFileServer
    StandAloneDfs
    TaskScheduler
    Temporary
    TsSessionBroker
    Unknown
    VirtualMachine
    VMReplicaBroker
    Wins
}

enum DependencyType
{
    And
    Or
}

###############################################
# Helper Functions (to support Pester Mocks)
#
Function New-AmznClusterHelper {
    return [AmznClusterHelper]::new()
}

Function New-AmazonAutoScalingClient {
    Param (
        [String] $Region
    )
    return New-Object -TypeName Amazon.AutoScaling.AmazonAutoScalingClient([Amazon.RegionEndPoint]::GetBySystemName($Region))
}


function Wait-ForClusterService
{
    param
    (
        [Parameter(Mandatory=$true)]
        [String]$State
    )

    $Counter = 0
    while ($Counter -lt 30)
    {
        # Check the Cluster service
        if ((Get-Service -DisplayName 'Cluster Service' -ErrorAction SilentlyContinue).Status -eq $State)
        {
            # Service is in the correct state, return true
            return $true
        }

        # Wait for retry
        Start-Sleep -Seconds 1
        $Counter++
    }

    # If we've waited for 30 executions of the loop, we'll return false
    return $false
}

###############################################
# Helper Classes
#
class AmznClusterHelper
{
    [Boolean] TestIsClusterAlive([String]$ClusterName,[String]$Domain)
    {
        $IsClusterAlive = $false

        try
        {
            $Cluster = Get-Cluster -Name $ClusterName -Domain $Domain -ErrorAction Stop
            if ($Cluster -eq $null)
            {
                Write-Verbose -Message "Cluster $ClusterName not found in domain $Domain; returning $false"
            }
            else
            {
                Write-Verbose -Message "Found cluster $ClusterName; returning $true"
                $IsClusterAlive = $true
            }
        }
        catch
        {
            Write-Verbose -Message "Exception message: $($_.Message.Exception); returning $false"
        }

        return $IsClusterAlive
    }
}

###############################################
# DSC Resources
#
[DscResource()]
class ASGFailoverCluster
{
    [DscProperty(Key)]
    [String] $ClusterName
    
    [DscProperty(Mandatory)]
    [Ensure] $Ensure
    
    [DscProperty()]
    [UInt32] $HostRecordTTL = 60
    
    [DscProperty(NotConfigurable)]
    [String] $ComputerName
    
    [DscProperty(NotConfigurable)]
    [String] $Domain
    
    [DscProperty(NotConfigurable)]
    [String] $InstanceId
    
    [DscProperty(NotConfigurable)]
    [String] $InstanceAZ
    
    [DscProperty(NotConfigurable)]
    [String] $Region
    
    [DscProperty(NotConfigurable)]
    [String] $AutoScalingGroupName
    
    [DscProperty(NotConfigurable)]
    [String] $BuildMasterTag
    
    [DscProperty(NotConfigurable)]
    [Boolean] $IsClusterMember
    
    [DscProperty(NotConfigurable)]
    [Boolean] $IsClusterAlive
    
    [DscProperty(NotConfigurable)]
    [Boolean] $DoesHostRecordTTLMatch
    
    [DscProperty(NotConfigurable)]
    [Boolean] $OuPath
    
    [DscProperty(NotConfigurable)]
    [Boolean] $ComputerOuPath
    
    [DscProperty(NotConfigurable)]
    [Boolean] $ADObjectClusterACL
    
    [ASGFailoverCluster] Get()
    {
        Write-Debug -Message '[ASGFailoverCluster]::Get() Start'
        
        # Hiding all output from Import-Module even if -Verbose was specified
        # The Verbose output from AWSPowerShell Module is extensive
        $SaveVerbosePreference = $Global:VerbosePreference
        $Global:VerbosePreference = 'SilentlyContinue'
        
        Import-Module -Name AWSPowerShell -ErrorAction Stop -Verbose:$false
        Import-Module -Name FailoverClusters -ErrorAction Stop -Verbose:$false
        
        # Optional hiding as Get() is called from both Test() and Set()
        # Allows displaying verbose output for only one of those methods
        if ($Global:HideVerbose -ne $true)
        {
            $Global:VerbosePreference = $SaveVerbosePreference
        }
        
        $GetObject = [ASGFailoverCluster]::new()
        $GetObject.ClusterName = $This.ClusterName
        
        $Win32ComputerSystem = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction Stop
        $GetObject.ComputerName = $Win32ComputerSystem.Name
        $GetObject.Domain = $Win32ComputerSystem.Domain
        
        try
        {
            Write-Debug -Message 'Retrieving EC2 Instance metadata'
            $token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri http://169.254.169.254/latest/api/token
            $GetObject.InstanceId = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Uri '-Headers @{"X-aws-ec2-metadata-token" = $token}/latest/meta-data/instance-id' -ErrorAction Stop
            Write-Debug -Message "Found InstanceId in meta-data: $($GetObject.InstanceId)"
            
            $GetObject.InstanceAZ = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Uri 'http://169.254.169.254/latest/meta-data/placement/availability-zone' -ErrorAction Stop
            $GetObject.Region = $GetObject.InstanceAZ.TrimEnd('abcdefghijklmnopqrstuvwxyz')
            Write-Debug -Message "Found Instance Region from meta-data: $($GetObject.Region)"
        }
        catch
        {
            throw "Exception caught retrieving EC2 Instance metadata using local web service. $($_.Exception.Message)"
        }
        
        try
        {
            $AutoScalingGroup = Get-ASAutoScalingGroup -Region "$($GetObject.Region)" | Where-Object {$_.Instances.InstanceId -like $GetObject.InstanceId}
            $GetObject.AutoScalingGroupName = $AutoScalingGroup.AutoScalingGroupName
            $GetObject.BuildMasterTag = ($AutoScalingGroup.Tags | Where-Object { $_.Key -eq 'BuildMaster' }).Value
        }
        catch
        {
            throw "Exception caught retrieving Auto Scaling Group details. $($_.Exception.Message)"
        }
        
        $AmznClusterHelper = New-AmznClusterHelper

        # Resolves to $null if the local machine is not a cluster member
        $LocalClusterName = (Get-Cluster -ErrorAction SilentlyContinue).Name
        if ($null -eq $LocalClusterName)
        {
            Write-Verbose -Message 'Local machine is did not respond to Get-Cluster cmdlet; performing cluster alive test'
            $GetObject.IsClusterAlive = $AmznClusterHelper.TestIsClusterAlive($GetObject.ClusterName, $GetObject.Domain)

            # Defaulting $GetObject.Ensure to [Ensure]::Absent.
            # If the local machine is found when querying the cluster, it will be set to [Ensure]::Present
            # If querying the cluster throws an exception, we will assume the local machine is not a member of the cluster.
            # This will trigger the Set() method where the local machine will try to join the cluster.
            $GetObject.Ensure = [Ensure]::Absent
            if ($GetObject.IsClusterAlive -eq $true)
            {
                Write-Debug -Message 'Cluster is alive; testing membership'
                
                Write-Verbose -Message 'As Cluster Service on Local Machine may be failed, paused, starting or stopped, cluster nodes are being tested for membership'
                try
                {
                    $ClusterNodes = Get-ClusterNode -Cluster "$($GetObject.ClusterName).$($GetObject.Domain)" -ErrorAction Stop
                    
                    foreach ($Node in $ClusterNodes)
                    {
                        Write-Debug -Message "Testing [$env:COMPUTERNAME] against [$($Node.Name)]"
                        
                        if ($env:COMPUTERNAME -eq $Node.Name)
                        {
                            Write-Verbose "Computer found in the Failover Cluster's nodes; returning [Ensure]::Present"
                            $GetObject.Ensure = [Ensure]::Present
                        }
                    }
                }
                catch
                {
                    throw "Failed to retrieve Cluster Nodes from Failover Cluster: $($GetObject.ClusterName).$($GetObject.Domain). $($_.Exception.Message)"
                }
            }
        }
        elseif ($LocalClusterName -eq $GetObject.ClusterName)
        {
            Write-Verbose -Message "Local instance is already a member of the Failover Cluster: $($GetObject.ClusterName)"
            $GetObject.Ensure = [Ensure]::Present
            $GetObject.IsClusterAlive = $true
        }
        else
        {
            Write-Verbose -Message 'Local machine is not a cluster member or is a member of a different Failover Cluster'
            $GetObject.Ensure = [Ensure]::Absent
            $GetObject.IsClusterAlive = $false
        }
        Write-Verbose -Message "Cluster alive status: $($GetObject.IsClusterAlive)"
        
        # Retrieve AD Computer Object permissions for Cluster Object
        $ComputerObject = Get-ADComputer -Identity $env:COMPUTERNAME
        $GetObject.OuPath = $ComputerObject.DistinguishedName.Substring($($ComputerObject.DistinguishedName.IndexOf('OU=')))
        $GetObject.ComputerOuPath = "CN=$($GetObject.ClusterName),$($GetObject.OuPath)"

        Write-Verbose -Message 'Retrieving AD Object ACLs'
        $DACLS = & dsacls.exe $($GetObject.ComputerOUPath)
        
        Write-Verbose -Message 'Retrieving AD Object ACLs for the Cluster Computer Object'
        $GetObject.ADObjectClusterACL = $DACLS | Where-Object {$_ -like "*$($env:COMPUTERNAME)*FULL CONTROL*"}
        Write-Verbose -Message "Cluster Object ACL: $($GetObject.ADObjectClusterACL)"

        # Testing Failover Cluster Membership with Get-ClusterNode cmdlet; could be a member of a different Failover Cluster
        if ($GetObject.IsClusterAlive -eq $true)
        {
            Write-Verbose -Message 'Looking up Cluster HostRecordTTL'
            try
            {
                if ($GetObject.Ensure -eq [Ensure]::Present)
                {
                    Write-Debug -Message 'Invoking Get-ClusterResource against local machine'
                    $GetObject.HostRecordTTL = (Get-ClusterResource -Name 'Cluster Name' -ErrorAction Stop | Get-ClusterParameter -Name HostRecordTTL).Value
                }
                else
                {
                    Write-Debug -Message 'Invoking Get-ClusterResource against remote cluster'
                    $GetObject.HostRecordTTL = (Get-ClusterResource -Cluster "$($GetObject.ClusterName).$($GetObject.Domain)" -Name 'Cluster Name' -ErrorAction Stop | Get-ClusterParameter -Name HostRecordTTL).Value
                }
                Write-Verbose -Message "Cluster HostRecordTTL: $($GetObject.HostRecordTTL)"
                
                Write-Debug -Message "DoesHostRecordTTLMatch: GetObject[$($GetObject.HostRecordTTL)] This[$($This.HostRecordTTL)]"
                $GetObject.DoesHostRecordTTLMatch = $GetObject.HostRecordTTL -eq $This.HostRecordTTL
            }
            catch
            {
                throw "Failed to retrieve HostRecordTTL from Failover Cluster. $($_.Exception.Message)"
            }
        }
        
        Write-Debug -Message '[ASGFailoverCluster]::Get() End'
        
        $Global:VerbosePreference = $SaveVerbosePreference
        return $GetObject
    }
    
    [Boolean] Test()
    {
        Write-Debug -Message '[ASGFailoverCluster]::Test() Start'
        #
        # The code will check the following in order:
        # 1. Does the cluster exist in the domain?
        # 2. Is the machine is in the cluster's nodelist?
        #  
        # Method will return FALSE if any item above is not true
        #
        
        $SaveVerbosePreference = $Global:VerbosePreference
        
        try
        {
            $TestObject = $This.Get()
        }
        catch
        {
            $Message = '$This.Get() call threw an exception: {0}; returning $false' -f $_.Exception.Message
            Write-Verbose -Message $Message
            return $false
        }
        
        $Global:VerbosePreference = $SaveVerbosePreference
        
        $ReturnValue = $true
        try
        {
            $ReturnValue = $ReturnValue -and ($TestObject.IsClusterAlive -eq $true)
            Write-Verbose -Message "Return Value after IsClusterAlive test: $ReturnValue"
            
            $ReturnValue = $ReturnValue -and ($TestObject.DoesHostRecordTTLMatch -eq $true)
            Write-Verbose -Message "Return Value after HostRecordTTL test: $ReturnValue"
            
            if ($This.Ensure -eq $TestObject.Ensure)
            {
                $ReturnValue = $ReturnValue -and $true
            }
            else
            {
                $ReturnValue = $ReturnValue -and $false
            }
            
            Write-Verbose -Message "Return Value after ClusterNode existence test: $ReturnValue"
        }
        catch
        {
            throw "Exception Caught; returning $false. $($_.Exception.Message)"
            $ReturnValue = $false
        }
        
        Write-Debug -Message '[ASGFailoverCluster]::Test() End'
        return $ReturnValue
    }
    
    [Void]Set()
    {
        Write-Debug -Message '[ASGFailoverCluster]::Set() Start'
        $SaveVerbosePreference = $Global:VerbosePreference;
        $Global:HideVerbose = $true
        
        try
        {
            $SetObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception'
        }
        
        Remove-Variable -Name HideVerbose -Scope Global -ErrorAction SilentlyContinue
        
        $Global:VerbosePreference = $SaveVerbosePreference;
        
        Write-Verbose -Message "Cluster alive status: $($SetObject.IsClusterAlive)"
        
        # This block is to mark the current InstanceId as the master if the BuildMaster tag is null
        # This tag is used to help decide whether to invoke New-Cluster or Add-ClusterNode
        Write-Debug -Message "SetObject.BuildMasterTag: $($SetObject.BuildMasterTag)"
        if ([String]::IsNullOrEmpty($SetObject.BuildMasterTag))
        {
            try
            {
                $this.UpdateBuildMasterTag($SetObject.AutoScalingGroupName,$SetObject.InstanceId,$SetObject.Region)
            }
            catch
            {
                Write-Verbose -Message 'Unable to set ASG Tag'
            }
        }
        
        $AmznClusterHelper = New-AmznClusterHelper

        if ($This.Ensure -eq [Ensure]::Present)
        {
            Write-Debug -Message 'This.Ensure equals [Ensure]::Present'
            
            # We want to invoke Add-ClusterNode if the cluster is already alive; or if the current InstanceId has not been marked as the 'BuildMaster'
            # If the cluster is not alive, and the current InstanceID *IS* the 'BuildMaster', we need to invoke New-Cluster
            # We are retrieving this tag again in case of collisions when setting the tag above (eg if multiple ASG nodes come online at once)
            $AutoScalingGroup = Get-ASAutoScalingGroup -Region "$($SetObject.Region)" | Where-Object {$_.Instances.InstanceId -like $SetObject.InstanceId}
            $AsgBuildMasterTag = ($AutoScalingGroup.Tags | Where-Object { $_.Key -eq 'BuildMaster' }).Value
            
            Write-Debug -Message "SetObject.IsClusterAlive: $SetObject.IsClusterAlive"
            Write-Debug -Message "Current ASG BuildMaster Tag: $AsgBuildMasterTag"
            if ($SetObject.IsClusterAlive -eq $false -and $AsgBuildMasterTag -eq $SetObject.InstanceId)
            {
                try
                {
                    Write-Verbose -Message "Attempting to create Failover Cluster: $($This.ClusterName)"
                    New-Cluster -Name "$($This.ClusterName)" -ErrorAction Stop
                    Write-Verbose -Message "Failover Cluster $($This.ClusterName) has been created"
                    
                    $ClusterCreated = $true

                    # Updating the Auto Scaling Groups 'BuildMaster' Tag to ensure the New-Cluster cmdlet *NEVER* gets processed
                    # again without manual intervention to clear it. After this change, the 'BuildMaster' Tag will never directly
                    # match an EC2 InstanceId.
                    try
                    {
                        $NewTagValue = 'New-Cluster invoked by {0}' -f $SetObject.InstanceId
                        $this.UpdateBuildMasterTag($SetObject.AutoScalingGroupName,$NewTagValue,$SetObject.Region)
                    }
                    catch
                    {
                        Write-Verbose -Message "Unable to update BuildMaster ASG Tag. Exception caught: $($_.Exception.Message)"
                        Write-Verbose -Message 'New-Cluster may be invoked if this instance runs this code block while the cluster is not alive.'
                        Write-Verbose -Message 'If this happens, the New-Cluster cmdlet will throw an exception as the cluster object already exists in Active Directory.'
                        throw "Unable to update BuildMaster ASG Tag. Exception caught: $($_.Exception.Message)"
                    }
                }
                catch
                {
                    "Failed to create Failover Cluster: $($_.Exception.Message)"
                    throw
                }
                
                # If the Failover Cluster was created, we need to remove the default 'Cluster IP Address' resource
                If ($ClusterCreated -eq $true)
                {
                    try
                    {
                        Write-Verbose -Message 'Attempting to remove default Cluster Resource'
                        Remove-ClusterResource -Name 'Cluster IP Address' -Force -ErrorAction Stop
                        Write-Verbose -Message 'Removed Cluster Resource: [Cluster IP Address]'
                    }
                    catch
                    {
                        throw "Failed to remove Cluster Resource [Cluster IP Address]. $($_.Exception.Message)"
                    }
                }
                
                Write-Verbose -Message "Existing ADObjectClusterACL: $($SetObject.ADObjectClusterACL)"
                if ($SetObject.ADObjectClusterACL -notlike "Allow*$($env:COMPUTERNAME)*FULL CONTROL*")
                {
                    $Result = & dsacls.exe $($SetObject.ComputerOUPath) /g ANT\$($env:COMPUTERNAME)`$:ga
                    Write-Verbose -Message "New ADObjectClusterACL: $($Result | Where-Object {$_ -like "*$($env:COMPUTERNAME)*"})"
                }

                Write-Debug -Message "DoesHostRecordTTLMatch: $($SetObject.DoesHostRecordTTLMatch)"
                if ($SetObject.DoesHostRecordTTLMatch -ne $true)
                {
                    try
                    {
                        Get-ClusterResource -Name 'Cluster Name' -ErrorAction Stop | Set-ClusterParameter HostRecordTTL $This.HostRecordTTL -ErrorAction Stop
                        Write-Verbose -Message "Updated HostRecordTTL to $($This.HostRecordTTL)"
                        
                        # Sleeps are to ensure the machine has completely finished perform the work
                        Stop-Cluster -Force -Confirm:$false
                        if (Wait-ForClusterService -State 'Stopped')
                        {
                            Write-Debug -Message 'Starting Cluster Service'
                            Start-Service -DisplayName 'Cluster Service'

                            Write-Debug -Message 'Starting Cluster'
                            Start-Cluster
                        }
                        else
                        {
                            throw 'Cluster service failed to stop in a timely fashion'
                        }

                        if (-not(Wait-ForClusterService -State 'Running'))
                        {
                            throw 'Cluster service failed to start in a timely fashion'
                        }
                        
                        # Starting the Cluster, then associated Network Names.
                        Get-ClusterResource -Name 'Cluster Name' | Start-ClusterResource
                        Get-ClusterResource | Where-Object { $_.ResourceType -eq 'Network Name' } | Start-ClusterResource
                        Write-Verbose -Message 'Restarted Cluster Service to complete HostRecordTTL change'
                    }
                    catch
                    {
                        throw "Failed to set HostRecordTTL. $($_.Exception.Message)"
                    }
                }
            } # End else ($SetObject.IsClusterAlive -eq $true)
            else
            {
                try
                {
                    Write-Verbose -Message "Attempting to add instance to Failover Cluster: $($This.ClusterName).$($SetObject.Domain) as user $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
                    Write-Verbose -Message "Is the resource running in an administrative context: $(([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrators'))"

                    Add-ClusterNode -Cluster "$($This.ClusterName).$($SetObject.Domain)" -Name '.' -NoStorage -ErrorAction Stop
                    Write-Verbose -Message 'Added instance to Failover Cluster'
                }
                catch
                {
                    throw "Failed to add instance to Failover Cluster: $($_.Exception.Message)"
                }
            }

        }
        else # $This.Ensure -eq [Ensure]::Absent
        {
            Try
            {
                Write-Verbose -Message 'Retrieving Cluster Nodes'
                $ClusterNode = Get-ClusterNode -ErrorAction Stop
                Write-Verbose -Message "Cluster nodes retrieved: $($ClusterNode.Count)"
                
                if ($ClusterNode.Count -eq 1)
                {
                    Write-Verbose -Message 'Only a single Cluster Node exists, destroying cluster.'
                    
                    Remove-Cluster -CleanupAD -Force -ErrorAction Stop
                    Write-Verbose -Message "Destroyed Failover Cluster $($This.ClusterName)"
                }
                elseif ($ClusterNode.Count -gt 1)
                {
                    Write-Verbose -Message 'Multiple Cluster Nodes exist, removing node.'
                    
                    Remove-ClusterNode -Force -ErrorAction Stop
                    Write-Verbose -Message "Removed instance from Failover Cluster $($This.ClusterName)"
                }
                else
                {
                    Write-Verbose -Message 'No cluster nodes retrieved. The Cluster Service may be stopped.'
                }
            }
            Catch
            {
                throw "Exception caught. $($_.Exception.Message)"
            }
        }
        
        Write-Debug -Message '[ASGFailoverCluster]::Set() End'
    }

    [void]UpdateBuildMasterTag([String]$AutoScalingGroupName,[String]$TagValue,[String]$Region)
    {
        Write-Verbose -Message "Updating tag on ASG '$AutoScalingGroupName' in Region '$Region': Key=BuildMaster; Value=$($TagValue)"

        $Tag = New-Object -TypeName Amazon.AutoScaling.Model.Tag
        $Tag.ResourceId = $AutoScalingGroupName
        $Tag.ResourceType = 'auto-scaling-group'
        $Tag.Key = 'BuildMaster'
        $Tag.Value = $TagValue
        $Tag.PropagateAtLaunch = $false
        
        $AsgTagRequest = New-Object -TypeName Amazon.AutoScaling.Model.CreateOrUpdateTagsRequest
        $AsgTagRequest.Tags = $Tag
        
        $AsgClient = New-AmazonAutoScalingClient -Region $Region
        $Response = $AsgClient.CreateOrUpdateTags($AsgTagRequest)
        Write-Verbose -Message "CreateOrUpdateTags Response Code: $($Response.HttpStatusCode)"
    }
}

[DscResource()]
class ClusterAccess
{
    [DscProperty(Key)]
    [String] $ClusterName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure
    
    [DscProperty(Mandatory)]
    [AccessType] $Access

    [DscProperty(Mandatory)]
    [String[]] $Members

    [DscProperty(NotConfigurable)]
    [String] $Domain

    [DscProperty(NotConfigurable)]
    [Boolean] $MembersSetCorrectly

    [ClusterAccess] Get()
    {
        Write-Debug -Message '[ClusterAccess]::Get() Start'
        $GetObject = [ClusterAccess]::new()
        $GetObject.ClusterName = $This.ClusterName
        $GetObject.Ensure = $This.Ensure
        $GetObject.Access = $This.Access

        try
        {
            $CurrentAccess = Get-ClusterAccess -ErrorAction Stop | Where-Object {$_.ClusterRights -eq "$($This.Access)"}
            Write-Verbose -Message "Current $($This.Access) Access Members: $(($CurrentAccess | Select-Object -ExpandProperty IdentityReference).Value -join ',')"
            $GetObject.Members = $CurrentAccess.IdentityReference.Value
        }
        catch
        {
            $GetObject.Members = [String]::Empty
        }

        $Win32ComputerSystem = Get-WmiObject -Class Win32_ComputerSystem
        $GetObject.Domain = $Win32ComputerSystem.Domain.Split('.')[0]

        $TestValue = $true

        foreach ($Member in $This.Members)
        {
            $Member = $This.GetDomainUser($Member, $($GetObject.Domain))
            Write-Debug -Message "Testing Cluster Access for: $Member"
            
            if ($GetObject.Members -contains "$Member")
            {
                Write-Verbose -Message "[$Member] does have $($This.Access) Cluster Access"
                if ($This.Ensure -eq [Ensure]::Absent)
                {
                    $TestValue = $TestValue -and $false
                }
            }
            else
            {
                Write-Verbose -Message "[$Member] does not have $($This.Access) Cluster Access"
                if ($This.Ensure -eq [Ensure]::Present)
                {
                    $TestValue = $TestValue -and $false
                }
            }
        }

        $GetObject.MembersSetCorrectly = $TestValue

        Write-Debug -Message '[ClusterAccess]::Get() End'
        return $GetObject
    }

    [Boolean] Test()
    {
        return $This.Get().MembersSetCorrectly
    }

    [Void] Set()
    {
        Write-Debug -Message '[ClusterAccess]::Set() Start'

        try
        {
            $SetObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception'
            $SetObject = $null
        }
        
        if ($This.Ensure -eq [Ensure]::Present)
        {
            foreach ($Member in $This.Members)
            {
                $Member = $This.GetDomainUser($Member, $($SetObject.Domain))

                try
                {
                    Switch ($This.Access)
                    {
                        'Full'     {Grant-ClusterAccess -User $Member -Full -ErrorAction Stop}
                        'ReadOnly' {Grant-ClusterAccess -User $Member -ReadOnly -ErrorAction Stop}
                    }
                }
                catch 
                {
                    throw "Error granting $($This.Access) access to $Member. $($_.Exception.Message)"
                }
            }
        }
        else # $This.Ensure -eq [Ensure]::Absent
        {
            foreach ($Member in $This.Members)
            {
                $Member = $This.GetDomainUser($Member, $($SetObject.Domain))
                
                try
                {
                    Write-Verbose -Message "Comparing [$Member] against $($SetObject.Members -join ',')"
                    if ($SetObject.Members -contains $Member)
                    {
                        Write-Verbose -Message "Removing [$Member] from Cluster Access"
                        Remove-ClusterAccess -User $Member -ErrorAction Stop
                    }
                }
                catch 
                {
                    throw "Error removing access for $Member. $($_.Exception.Message)"
                }
            }
        }
        Write-Debug -Message '[ClusterAccess]::Set() End'
    }
    
    [String] GetDomainUser([String]$Member,[String]$Domain)
    {
        if ($Member -notlike "$($Domain)\*")
        {
            $Member = "$($Domain)\$Member"
        }
        
        return $Member
    }
}

[DscResource()]
class ClusterCleanup
{
    [DscProperty(Key)]
    [SingleInstance] $SingleInstance

    [DscProperty(NotConfigurable)]
    [Boolean] $IsClusterOwner
    
    [DscProperty(NotConfigurable)]
    [String[]]$AsgEc2InstanceList
    
    [DscProperty(NotConfigurable)]
    [String[]] $AsgEc2InstanceTags

    [DscProperty(NotConfigurable)]
    [String[]] $ClusterResources

    [DscProperty(NotConfigurable)]
    [String[]] $ClusterResourcesToRemove

    [DscProperty(NotConfigurable)]
    [String[]] $ClusterNodes
    
    [DscProperty(NotConfigurable)]
    [String[]] $ClusterNodesToRemove
    
    [DscProperty(NotConfigurable)]
    [String] $InstanceId

    [DscProperty(NotConfigurable)]
    [String] $Region

    [ClusterCleanup] Get()
    {
        # Hiding all output from Import-Module even if -Verbose was specified
        # The Verbose output from AWSPowerShell Module is extensive
        $SaveVerbosePreference = $Global:VerbosePreference
        $Global:VerbosePreference = 'SilentlyContinue'
        
        Import-Module -Name AWSPowerShell -ErrorAction Stop
        Import-Module -Name FailoverClusters -ErrorAction Stop

        # Optional hiding as Get() is called from both Test() and Set()
        # Allows displaying verbose output for only one of those methods
        if ($Global:HideVerbose -ne $true)
        {
            $Global:VerbosePreference = $SaveVerbosePreference
        }

        $GetObject = [ClusterCleanup]::new()
        
        try
        {
            Write-Debug -Message 'Retrieving EC2 Instance metadata'
            $token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri http://169.254.169.254/latest/api/token
            $GetObject.InstanceId = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -ErrorAction Stop
            Write-Debug -Message "Found InstanceId in meta-data: $($GetObject.InstanceId)"
            
            $InstanceAZ = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Uri 'http://169.254.169.254/latest/meta-data/placement/availability-zone' -ErrorAction Stop
            $GetObject.Region = $InstanceAZ.TrimEnd('abcdefghijklmnopqrstuvwxyz')
            Write-Debug -Message "Found Instance Region from meta-data: $($GetObject.Region)"
        }
        catch
        {
            throw "Exception caught retrieving EC2 Instance metadata using local web service. $($_.Exception.Message)"
        }
        
        # Retrieve all ASG Instance Tags that look like IP Addresses
        try
        {
            $AutoScalingGroup = Get-ASAutoScalingGroup -Region "$($GetObject.Region)" -ErrorAction Stop | Where-Object { $_.Instances.InstanceId -like $GetObject.InstanceId }
        }
        catch
        {
            throw "Exception caught retrieving Auto Scaling Group details. $($_.Exception.Message)"
        }
        
        $TempNames = @()
        $TempTags = @()
        Write-Verbose -Message 'Retrieving Auto Scaling Group Nodes'
        foreach ($Instance in $AutoScalingGroup.Instances)
        {
            $TempInstance = Get-Ec2Instance -Instance "$($Instance.InstanceId)" -Region $GetObject.Region -ErrorAction Stop
            
            $TempNames += $TempInstance.Instances.Tags.Where{$_.Key -eq 'Name'} | Select-Object -ExpandProperty Value

            foreach ($Tag in $TempInstance.Instances.Tags.Where{$_.Value -like '*.*.*.*'} )
            {
                $TempTags += "IP Address $($Tag.Value)"
            }
            
            Remove-Variable -Name TempInstance
        }
        $GetObject.AsgEc2InstanceList = $TempNames
        $GetObject.AsgEc2InstanceTags = $TempTags
        Remove-Variable -Name TempNames,TempTags
        
        Write-Verbose -Message 'Checking for Cluster Owner Node'
        If ((Get-ClusterResource -Name 'Cluster Name').OwnerNode.Name -eq $env:COMPUTERNAME)
        {
            Write-Verbose -Message 'IsClusterOwner -eq $true'
            $GetObject.IsClusterOwner = $true
        }
        else
        {
            Write-Verbose -Message 'IsClusterOwner -eq $false'
            $GetObject.IsClusterOwner = $false
        }
        
        Write-Verbose -Message 'Retrieving all Failover Cluster IP Address Resources'
        $GetObject.ClusterResources = (Get-ClusterResource).Where{$_.Name -like 'IP Address *'} | Select-Object -ExpandProperty Name

        Write-Verbose -Message 'Finding Cluster Resources to be removed'
        $GetObject.ClusterResourcesToRemove = Compare-Object -ReferenceObject $GetObject.AsgEc2InstanceTags -DifferenceObject $GetObject.ClusterResources -PassThru | Where-Object {$_.SideIndicator -eq '=>'}

        Write-Verbose -Message 'Retrieving Failover Cluster Nodes'
        $GetObject.ClusterNodes = Get-ClusterNode | Select-Object -ExpandProperty Name

        Write-Verbose -Message 'Finding Cluster Nodes to be removed'
        $GetObject.ClusterNodesToRemove = Compare-Object -ReferenceObject $GetObject.AsgEc2InstanceList -DifferenceObject $GetObject.ClusterNodes -PassThru | Where-Object {$_.SideIndicator -eq '=>'}

        $Global:VerbosePreference = $SaveVerbosePreference
        return $GetObject
    }

    [Boolean] Test()
    {
        $SaveVerbosePreference = $Global:VerbosePreference

        try
        {
            $TestObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception; returning $false'
            return $false
        }

        $Global:VerbosePreference = $SaveVerbosePreference

        if ($TestObject.IsClusterOwner -eq $true)
        {
            if (($TestObject.ClusterNodesToRemove.Count -gt 0) -or ($TestObject.ClusterResourcesToRemove.Count -gt 0))
            {
                Write-Verbose -Message "There are $($TestObject.ClusterNodesToRemove.Count) Cluster Nodes to be removed"
                Write-Verbose -Message "There are $($TestObject.ClusterResourcesToRemove.Count) Cluster Resources to be removed"
                Write-Verbose -Message 'returning $false'
                return $false
            }
            else
            {
                Write-Verbose -Message 'There is nothing to clean up; returning $true'
                return $true
            }
        }
        else
        {
            Write-Verbose -Message 'Local machine is not the current Cluster Owner; returning $true'
            return $true
        }
    }

    [Void] Set()
    {
        $SaveVerbosePreference = $Global:VerbosePreference;
        $Global:HideVerbose = $true

        try
        {
            $SetObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception'
        }

        Remove-Variable -Name HideVerbose -Scope Global

        $Global:VerbosePreference = $SaveVerbosePreference;

        foreach ($Node in $SetObject.ClusterNodesToRemove)
        {
            try
            {
                Remove-ClusterNode -Name $Node -Force -ErrorAction Stop
            }
            catch
            {
                # No need for terminating error, while 'nice to have', this is simply cleanup
                Write-Verbose -Message "Failed to remove Cluster Node: $($Node)"
            }
        }

        foreach ($Resource in $SetObject.ClusterResourcesToRemove)
        {
            try
            {
                Remove-ClusterResource -Name $Resource -Force -ErrorAction Stop
            }
            catch
            {
                # No need for terminating error, while 'nice to have', this is simply cleanup
                Write-Verbose -Message "Failed to remove Cluster Resource: $($Resource)"
            }
        }
    }
}

[DscResource()]
class ClusterClientAccessPoint
{
    [DscProperty(Key)]
    [String] $ClientAccessPointName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [String] $ClusterName

    [DscProperty()]
    [UInt32]$HostRecordTTL = 60

    [DscProperty(NotConfigurable)]
    [String] $InstanceId
    
    [DscProperty(NotConfigurable)]
    [String] $InstanceAZ

    [DscProperty(NotConfigurable)]
    [String] $Region

    [DscProperty(NotConfigurable)]
    [String] $PrimaryIPAddress

    [DscProperty(NotConfigurable)]
    [Boolean] $ADComputerObjectExists

    [DscProperty(NotConfigurable)]
    [String] $ADObjectClusterACL

    [DscProperty(NotConfigurable)]
    [Boolean] $ProtectedFromAccidentalDeletion

    [DscProperty(NotConfigurable)]
    [String] $OUPath

    [DscProperty(NotConfigurable)]
    [String] $ComputerOUPath

    [DscProperty(NotConfigurable)]
    [Boolean]$DoesHostRecordTTLMatch

    [ClusterClientAccessPoint] Get()
    {
        Write-Debug -Message '[ClusterClientAccessPoint]::Get() Start'
        Write-Verbose -Message 'Importing required PowerShell Modules'
        
        # Hiding all output from Import-Module even if -Verbose was specified
        $SaveVerbosePreference = $Global:VerbosePreference
        $Global:VerbosePreference = 'SilentlyContinue'
        
        Import-Module -Name ActiveDirectory -ErrorAction Stop

        # Optional hiding as Get() is called from both Test() and Set()
        # Allows displaying verbose output for only one of those methods
        if ($Global:HideVerbose -ne $true)
        {
            $Global:VerbosePreference = $SaveVerbosePreference
        }

        $GetObject = [ClusterClientAccessPoint]::new()
        $GetObject.ClientAccessPointName = $This.ClientAccessPointName
        $GetObject.ClusterName = $This.ClusterName
        
        try
        {
            Write-Debug -Message 'Retrieving EC2 Instance metadata'
            $token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri http://169.254.169.254/latest/api/token
            $GetObject.InstanceId = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -ErrorAction Stop
            Write-Debug -Message "Found InstanceId in meta-data: $($GetObject.InstanceId)"
            
            $GetObject.InstanceAZ = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Uri 'http://169.254.169.254/latest/meta-data/placement/availability-zone' -ErrorAction Stop
            $GetObject.Region = $GetObject.InstanceAZ.TrimEnd('abcdefghijklmnopqrstuvwxyz')
            Write-Debug -Message "Found Instance Region from meta-data: $($GetObject.Region)"
        }
        catch
        {
            throw "Exception caught retrieving EC2 Instance metadata using local web service. $($_.Exception.Message)"
        }
        
        try
        {
            Write-Debug -Message 'Retrieving EC2 Instance Object'
            $EC2Instance = Get-EC2Instance -Instance "$($GetObject.InstanceId)" -Region $GetObject.Region -ErrorAction Stop

            $GetObject.PrimaryIPAddress = ($EC2Instance.Instances.NetworkInterfaces.PrivateIpAddresses | Where-Object {$_.Primary -eq $true}).PrivateIpAddress
        }
        catch
        {
            throw "Exception caught retrieving EC2 Instance Object from AWS API. $($_.Exception.Message)"
        }

        try
        {
            Write-Verbose -Message 'Retrieving AD Computer Object'
            $ADComputer = Get-ADComputer -Identity $GetObject.ClientAccessPointName -Properties ProtectedFromAccidentalDeletion -ErrorAction Stop

            Write-Verbose -Message "AD Computer Object $($GetObject.ClientAccessPointName) exists"
            $GetObject.ADComputerObjectExists = $true

            $GetObject.ProtectedFromAccidentalDeletion = $ADComputer.ProtectedFromAccidentalDeletion
            Write-Verbose -Message "AD Computer Object ProtectedFromAccidentalDeletion is set to: $($GetObject.ProtectedFromAccidentalDeletion)"
        }
        catch
        {
            Write-Verbose -Message "AD Computer Object $($GetObject.ClientAccessPointName) does not exist"
            $GetObject.ADComputerObjectExists = $false
            $GetObject.ProtectedFromAccidentalDeletion = $false
        }

        try
        {
            $Resource = Get-ClusterResource -Name $($GetObject.ClientAccessPointName) -ErrorAction Stop
            Write-Verbose -Message "Cluster Resource $($GetObject.ClientAccessPointName) exists"
            $GetObject.Ensure = [Ensure]::Present
        }
        catch
        {
            Write-Verbose -Message "Cluster Resource $($GetObject.ClientAccessPointName) does not exist"
            $GetObject.Ensure = [Ensure]::Absent
        }

        $ComputerObject = Get-ADComputer -Identity $env:COMPUTERNAME
        $GetObject.OuPath = $ComputerObject.DistinguishedName.Substring($($ComputerObject.DistinguishedName.IndexOf('OU=')))
        $GetObject.ComputerOuPath = "CN=$($GetObject.ClientAccessPointName),$($GetObject.OuPath)"

        $AmznClusterHelper = New-AmznClusterHelper

        Write-Verbose -Message 'Retrieving AD Object ACLs'
        $DACLS = & dsacls.exe $($GetObject.ComputerOUPath)
        
        Write-Verbose -Message 'Retrieving AD Object ACLs for the Cluster Computer Object'
        $GetObject.ADObjectClusterACL = $DACLS | Where-Object {$_ -like "*$($GetObject.ClusterName)*FULL CONTROL*"}
        Write-Verbose -Message "Cluster Object ACL: $($GetObject.ADObjectClusterACL)"

        Write-Verbose -Message 'Looking up Cluster HostRecordTTL'
        try
        {
            if ($GetObject.Ensure -eq [Ensure]::Present)
            {
                Write-Debug -Message 'Invoking Get-ClusterResource against local machine'
                $GetObject.HostRecordTTL = (Get-ClusterResource -Name $GetObject.ClientAccessPointName -ErrorAction Stop | Get-ClusterParameter -Name HostRecordTTL).Value
            }
            Write-Verbose -Message "Cluster HostRecordTTL: $($GetObject.HostRecordTTL)"
            
            Write-Debug -Message "DoesHostRecordTTLMatch: GetObject[$($GetObject.HostRecordTTL)] This[$($This.HostRecordTTL)]"
            $GetObject.DoesHostRecordTTLMatch = $GetObject.HostRecordTTL -eq $This.HostRecordTTL
        }
        catch
        {
            Write-Verbose -Message 'Failed to retrieve HostRecordTTL from Cliand Access Point' -Exception $_.Exception.Message
        }

        Write-Debug -Message '[ClusterClientAccessPoint]::Get() End'
        
        $Global:VerbosePreference = $SaveVerbosePreference
        return $GetObject
    }

    [Boolean] Test()
    {
        Write-Debug -Message '[ClusterClientAccessPoint]::Test() Start'

        try
        {
            $TestObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception; returning $false'
            return $false
        }
        
        $TestValue = $true
        if ($This.Ensure -eq [Ensure]::Present)
        {
            if ($TestObject.Ensure -eq [Ensure]::Absent)
            {
                Write-Verbose -Message "Cluster Resource does not exist; returning $false"
                $TestValue = $false
            }

            if ($TestObject.ADComputerObjectExists -ne $true)
            {
                Write-Verbose -Message "AD Computer Object does not exist; returning $false"
                $TestValue = $false
            }
            
            if ($TestObject.ProtectedFromAccidentalDeletion -ne $true)
            {
                Write-Verbose -Message "AD Computer Object ProtectedFromAccidentalDeletion is not set; returning $false"
                $TestValue = $false
            }

            if ($TestObject.ADObjectClusterACL -notlike "Allow*$($TestObject.ClusterName)*FULL CONTROL")
            {
                Write-Verbose -Message "Cluster Computer Object does not have full access to the AD Computer Object; returning $false"
                $TestValue = $false
            }

            if ($TestObject.DoesHostRecordTTLMatch -eq $false)
            {
                Write-Verbose -Message "Cluster HostRecordTTL does not match; returning $false"
                $TestValue = $false
            }
        }
        else # $This.Ensure -eq [Ensure]::Absent
        {
            if ($TestObject.Ensure -eq [Ensure]::Present)
            {
                Write-Verbose -Message "Cluster Resource exists; returning $false"
                $TestValue = $false
            }

            if ($TestObject.ADComputerObjectExists -eq $true)
            {
                Write-Verbose -Message "AD Computer Object exists; returning $false"
                $TestValue = $false
            }
            
            if ($TestObject.ProtectedFromAccidentalDeletion -eq $true)
            {
                Write-Verbose -Message "AD Computer Object ProtectedFromAccidentalDeletion is set; returning $false"
                $TestValue = $false
            }
        }

        Write-Debug -Message '[ClusterClientAccessPoint]::Test() End'
        return $TestValue
    }

    [Void] Set()
    {
        Write-Debug -Message '[ClusterClientAccessPoint]::Set() Start'
        $SaveVerbosePreference = $Global:VerbosePreference
        $Global:HideVerbose = $true

        try
        {
            $SetObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception'
        }

        Remove-Variable -Name HideVerbose -Scope Global -ErrorAction SilentlyContinue
        $Global:VerbosePreference = 'SilentlyContinue'
        
        Import-Module -Name FailoverClusters -ErrorAction Stop

        $Global:VerbosePreference = $SaveVerbosePreference
        
        $AmznClusterHelper = New-AmznClusterHelper

        if ($This.Ensure -eq [Ensure]::Present)
        {
            Write-Debug -Message '[$This.Ensure -eq [Ensure]::Present'
                
            if ($SetObject.ADComputerObjectExists -ne $true)
            {
                try
                {
                    New-ADComputer -Name $This.ClientAccessPointName -Description 'Failover cluster virtual network name account' -Path $SetObject.OuPath -Enabled $false
                    Write-Verbose -Message "Created AD Computer Object: $($This.ClientAccessPointName)$"
                }
                catch 
                {
                    throw "Failed to create the AD Computer Object. $($_.Exception.Message)"
                }
            }

            Write-Verbose -Message "Existing ADObjectClusterACL: $($SetObject.ADObjectClusterACL)"
            if ($SetObject.ADObjectClusterACL -notlike "Allow*$($SetObject.ClusterName)*FULL CONTROL*")
            {
                $Result = & dsacls.exe $($SetObject.ComputerOUPath) /g ANT\$($SetObject.ClusterName)`$:ga
                Write-Verbose -Message "New ADObjectClusterACL: $($Result | Where-Object {$_ -like "*$($SetObject.ClusterName)*"})"
            }

            if ($SetObject.ProtectedFromAccidentalDeletion -ne $true)
            {
                Get-ADObject -Identity $($SetObject.ComputerOUPath) | Set-ADObject -ProtectedFromAccidentalDeletion $true -Verbose
                Write-Verbose -Message 'Enabled ProtectedFromAccidentalDeletion bit on AD Computer Object'
            }
            
            Write-Debug -Message "SetObject.Ensure: $($SetObject.Ensure)"
            if ($SetObject.Ensure -eq [Ensure]::Absent)
            {
                Add-ClusterServerRole -Name $This.ClientAccessPointName -Verbose
                Write-Verbose -Message "Created Cluster Server Role $($This.ClientAccessPointName)"

                try
                {
                    $Resource = Get-ClusterResource -Name "IP Address $($SetObject.PrimaryIPAddress)" -ErrorAction Stop | Where-Object {$_.OwnerGroup -eq "$($This.ClientAccessPointName)"}
                }
                catch
                {
                    Remove-ClusterResource -Name $Resource.Name -Verbose -Force
                    Write-Verbose -Message 'Removed the default IP Address Cluster Resource that is created when invoking Add-ClusterServerRole'
                }
            }

            Write-Debug -Message "SetObject.DoesHostRecordTTLMatch: $($SetObject.DoesHostRecordTTLMatch)"
            if ($SetObject.DoesHostRecordTTLMatch -ne $true)
            {
                try
                {
                    Write-Debug -Message "SetObject.ClientAccessPointName = '$($SetObject.ClientAccessPointName)'" 
                    Get-ClusterResource -Name $SetObject.ClientAccessPointName -ErrorAction Stop | Set-ClusterParameter -Name 'HostRecordTTL' -Value $This.HostRecordTTL -ErrorAction Stop
                    Write-Verbose -Message "Updated HostRecordTTL to $($This.HostRecordTTL)"
                        
                    # Restarting the Cluster resource Network Name
                    Get-ClusterResource -Name $SetObject.ClientAccessPointName | Stop-ClusterResource | Start-ClusterResource
                    Write-Verbose -Message "Restarted cluster resource $($SetObject.ClientAccessPointName) to complete HostRecordTTL change"
                }
                catch
                {
                    throw "Failed to set HostRecordTTL. $($_.Exception.Message)"
                }
            }
        }
        else # $This.Ensure -eq [Ensure]::Absent
        {
            Write-Debug -Message '[$This.Ensure -ne [Ensure]::Present'

            if ($SetObject.ProtectedFromAccidentalDeletion -eq $true)
            {
                Get-ADObject -Identity $($SetObject.ComputerOUPath) | Set-ADObject -ProtectedFromAccidentalDeletion $false -Verbose
                Write-Verbose -Message 'Disabled ProtectedFromAccidentalDeletion bit on AD Computer Object'
            }

            if ($SetObject.Ensure -eq [Ensure]::Present)
            {
                Remove-ClusterGroup -Name $This.ClientAccessPointName -RemoveResources -Force -Verbose
                Write-Verbose -Message "Removed Cluster Server Role $($This.ClientAccessPointName)"
            }

            if ($SetObject.ADComputerObjectExists -eq $true)
            {
                Remove-ADComputer -Identity $This.ClientAccessPointName -Verbose -Confirm:$false
                Write-Verbose -Message "Removed AD Computer Object for $($This.ClientAccessPointName)"
            }
        }

        Write-Debug -Message '[ClusterClientAccessPoint]::Set() End'
    }
}

[DscResource()]
class ClusterGroup
{
    [DscProperty(Key)]
    [String] $GroupName

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(Mandatory)]
    [ClusterGroupType] $GroupType

    [DscProperty(NotConfigurable)]
    [Boolean] $ADComputerObjectExists

    [DscProperty(NotConfigurable)]
    [String] $ADObjectACL

    [DscProperty(NotConfigurable)]
    [String] $ADObjectClusterACL

    [DscProperty(NotConfigurable)]
    [Boolean] $ProtectedFromAccidentalDeletion

    [DscProperty(NotConfigurable)]
    [String] $OUPath

    [DscProperty(NotConfigurable)]
    [String] $ComputerOUPath

    [ClusterGroup] Get()
    {
        Write-Debug -Message '[ClusterGroup]::Get() Start'
        Write-Verbose -Message 'Importing required PowerShell Modules'
        
        # Hiding all output from Import-Module even if -Verbose was specified
        $SaveVerbosePreference = $Global:VerbosePreference
        $Global:VerbosePreference = 'SilentlyContinue'
        
        Import-Module -Name FailoverClusters -ErrorAction Stop -Verbose:$false

        # Optional hiding as Get() is called from both Test() and Set()
        # Allows displaying verbose output for only one of those methods
        if ($Global:HideVerbose -ne $true)
        {
            $Global:VerbosePreference = $SaveVerbosePreference
        }

        $GetObject = [ClusterGroup]::new()
        $GetObject.GroupName = $This.GroupName
        $GetObject.GroupType = $This.GroupType
        
        try
        {
            Write-Verbose -Message 'Retrieving Cluster Group'
            $ClusterGroup = Get-ClusterGroup -Name $GetObject.GroupName -Verbose -ErrorAction Stop
            $GetObject.Ensure = [Ensure]::Present
        }
        catch
        {
            Write-Verbose -Message "Cluster Group $($GetObject.GroupName) does not exist"
            $GetObject.Ensure = [Ensure]::Absent
        }

        Write-Debug -Message '[ClusterGroup]::Get() End'
        
        $Global:VerbosePreference = $SaveVerbosePreference
        return $GetObject
    }

    [Boolean] Test()
    {
        Write-Debug -Message '[ClusterGroup]::Test() Start'
        $SaveVerbosePreference = $Global:VerbosePreference
        
        try
        {
            $TestObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception; returning $false'
            return $false
        }
        
        $Global:VerbosePreference = $SaveVerbosePreference
        
        $TestValue = $true
        if ($This.Ensure -eq [Ensure]::Present)
        {
            if ($TestObject.Ensure -eq [Ensure]::Absent)
            {
                Write-Verbose -Message "Cluster Group does not exist; returning $false"
                $TestValue = $false
            }
        }
        else
        {
            if ($TestObject.Ensure -eq [Ensure]::Present)
            {
                Write-Verbose -Message "Cluster Group exists; returning $false"
                $TestValue = $false
            }
        }

        Write-Debug -Message '[ClusterGroup]::Test() End'
        return $TestValue
    }

    [Void] Set()
    {
        Write-Debug -Message '[ClusterGroup]::Set() Start'
        $SaveVerbosePreference = $Global:VerbosePreference;
        $Global:HideVerbose = $true

        try
        {
            $SetObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception'
        }

        Remove-Variable -Name HideVerbose -Scope Global -ErrorAction SilentlyContinue

        $Global:VerbosePreference = $SaveVerbosePreference
        
        $AmznClusterHelper = New-AmznClusterHelper

        if ($This.Ensure -eq [Ensure]::Present)
        {
            if ($SetObject.Ensure -eq [Ensure]::Absent)
            {
                Add-ClusterGroup -Name $This.GroupName -GroupType "$($This.GroupType)" -Verbose
                Write-Verbose -Message "Created Cluster Group $($This.GroupName)"
            }
        }
        else # $This.Ensure -eq [Ensure]::Absent
        {
            if ($SetObject.Ensure -eq [Ensure]::Present)
            {
                Remove-ClusterGroup -Name $This.ClientAccessPointName -RemoveResources -Force -Verbose
                Write-Verbose -Message "Removed Cluster Server Role $($This.ClientAccessPointName)"
            }
        }
        
        Write-Debug -Message '[ClusterGroup]::Set() End'
    }
}

[DscResource()]
class ClusterIPAddressResource
{
    [DscProperty(Key)]
    [String] $OwnerGroup

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty(NotConfigurable)]
    [String] $InstanceId
    
    [DscProperty(NotConfigurable)]
    [String] $InstanceAZ

    [DscProperty(NotConfigurable)]
    [String] $Region

    [DscProperty(NotConfigurable)]
    [String] $NetworkInterfaceId

    [DscProperty(NotConfigurable)]
    [String] $IPAddress

    [DscProperty(NotConfigurable)]
    [String] $SubnetMask

    [DscProperty(NotConfigurable)]
    [String] $NetworkAddress

    [DscProperty(NotConfigurable)]
    [String] $ResourceName

    [DscProperty(NotConfigurable)]
    [String[]] $ResourceNameOwners

    [DscProperty(NotConfigurable)]
    [String] $ResourceNetworkName

    [DscProperty(NotConfigurable)]
    [String] $ResourceNetworkNameDependency

    [DscProperty(NotConfigurable)]
    [String] $Ec2Tag

    [DscProperty(NotConfigurable)]
    [String] $ClusterNetworkName

    [ClusterIPAddressResource] Get()
    {
        Write-Debug -Message '[ClusterIPAddressResource]::Get() Start'

        # Hiding all output from Import-Module even if -Verbose was specified
        # The Verbose output from AWSPowerShell Module is extensive
        $SaveVerbosePreference = $Global:VerbosePreference
        $Global:VerbosePreference = 'SilentlyContinue'
        
        Import-Module -Name AWSPowerShell -ErrorAction Stop

        # Optional hiding as Get() is called from both Test() and Set()
        # Allows displaying verbose output for only one of those methods
        if ($Global:HideVerbose -ne $true) {
            $Global:VerbosePreference = $SaveVerbosePreference
        }

        $GetObject = [ClusterIPAddressResource]::new()
        $GetObject.OwnerGroup = $This.OwnerGroup
        
        try
        {
            Write-Debug -Message 'Retrieving EC2 Instance metadata'
            $token = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token-ttl-seconds" = "21600"} -Method PUT -Uri http://169.254.169.254/latest/api/token
            $GetObject.InstanceId = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Uri 'http://169.254.169.254/latest/meta-data/instance-id' -ErrorAction Stop
            Write-Debug -Message "Found InstanceId in meta-data: $($GetObject.InstanceId)"
            
            $GetObject.InstanceAZ = Invoke-RestMethod -Headers @{"X-aws-ec2-metadata-token" = $token} -Uri 'http://169.254.169.254/latest/meta-data/placement/availability-zone' -ErrorAction Stop
            $GetObject.Region = $GetObject.InstanceAZ.TrimEnd('abcdefghijklmnopqrstuvwxyz')
            Write-Debug -Message "Found Instance Region from meta-data: $($GetObject.Region)"
        }
        catch
        {
            throw "Exception caught retrieving EC2 Instance metadata using local web service. $($_.Exception.Message)"
        }
        
        try
        {
            Write-Debug -Message 'Retrieving EC2 Instance Object'
            $EC2Instance = Get-EC2Instance -Instance "$($GetObject.InstanceId)" -Region $GetObject.Region -ErrorAction Stop

            $GetObject.NetworkInterfaceId = $EC2Instance.Instances.NetworkInterfaces.NetworkInterfaceId
            Write-Debug -Message "Found NetworkInterfaceId: $($GetObject.NetworkInterfaceId)"
            
            $GetObject.Ec2Tag = $EC2Instance.Instances.Tags | Where-Object {$_.Key -eq $GetObject.OwnerGroup} | Select-Object -ExpandProperty Value
        }
        catch
        {
            throw "Exception caught retrieving EC2 Instance Object from AWS API. $($_.Exception.Message)"
        }
        
        Write-Debug -Message 'Find a spare EC2 Private IP Address'
        For ($Count = 0; $Count -lt 10; $Count++)
        {
            $GetObject.IPAddress = $GetObject.GetSpareIPAddress($EC2Instance,$GetObject.Ec2Tag)

            Write-Debug -Message "GetObject.IPAddress: $($GetObject.IPAddress)"

            if ([String]::IsNullOrEmpty($GetObject.IPAddress))
            {
                Write-Verbose -Message 'No spare IP Address found, registering a new Private IP Address'
                    
                try
                {
                    Register-EC2PrivateIpAddress -NetworkInterfaceId $GetObject.NetworkInterfaceId -SecondaryPrivateIpAddressCount 1 -Region $GetObject.Region -ErrorAction Stop
                        
                    # Give the registration some extra time to ensure the address has registered with the instance
                    Start-Sleep 1
                    Write-Verbose -Message "Registered a new E2 Private IP Address for instance [$($GetObject.InstanceId)]"
                    $EC2Instance = Get-EC2Instance -Instance "$($GetObject.InstanceId)" -Region $GetObject.Region -ErrorAction Stop
                }
                catch
                {
                    Write-Verbose -Message "Failed to register a new EC2 Private IP Address on InstanceId: $($GetObject.InstanceId)"
                }
            }
            else
            {
                break
            }
        }
        Write-Verbose -Message "Using IPAddress: $($GetObject.IPAddress)"

        $GetObject.ResourceName = "IP Address $($GetObject.IPAddress)"
        Write-Verbose -Message "Using ResourceName: $($GetObject.ResourceName)"

        $Wmi = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -filter "ipenabled = 'true'"
        $GetObject.SubnetMask = $Wmi.IPSubnet | Where-Object {$_ -like '255*'} | Select-Object -First 1
        Write-Verbose -Message "Using SubnetMask: $($GetObject.SubnetMask)"

        try
        {
            $GetObject.NetworkAddress = $This.GetNetworkAddress($GetObject.IPAddress,$GetObject.SubnetMask)
            Write-Verbose -Message "Using Network Address: $($GetObject.NetworkAddress)"
        }
        catch
        {
            # This exception is expected when there are no spare Private IP Addresses available
            Write-Debug -Message "Exception caught: $($_.Exception.Message)"
        }

        try
        {
            Write-Debug -Message "Invoking Get-ClusterResource -Name $($GetObject.ResourceName) -ErrorAction Stop"
            $ClusterResource = Get-ClusterResource -Name $GetObject.ResourceName -ErrorAction Stop
            Write-Verbose "Cluster Resource [$($GetObject.ResourceName)] exists"
            
            $ClusterResourceOwners = $ClusterResource | Get-ClusterOwnerNode -ErrorAction Stop
            
            $GetObject.ResourceNameOwners = $ClusterResourceOwners.OwnerNodes.Name
            $GetObject.Ensure = [Ensure]::Present
        }
        catch
        {
            $GetObject.Ensure = [Ensure]::Absent
            Write-Verbose "Cluster Resource [$($GetObject.ResourceName)] does not exist"
        }

        Write-Debug -Message "Invoking Get-ClusterResource -ErrorAction Stop"
        $NetworkNameResource = Get-ClusterResource -ErrorAction Stop | Where-Object {$_.OwnerGroup -eq $GetObject.OwnerGroup -and $_.ResourceType -eq 'Network Name'}
        $GetObject.ResourceNetworkName = $NetworkNameResource.Name
        Write-Debug -Message "GetObject.ResourceNetworkName: $($GetObject.ResourceNetworkName)"
        
        $ClusterResourceDependency = Get-ClusterResourceDependency -Resource $GetObject.ResourceNetworkName -ErrorAction Stop
        $GetObject.ResourceNetworkNameDependency = $ClusterResourceDependency.DependencyExpression

        $GetObject.ClusterNetworkName = (Get-ClusterNetwork -ErrorAction Stop | Where-Object {$_.Ipv4Addresses -eq $GetObject.NetworkAddress}).Name

        Write-Debug -Message '[ClusterIPAddressResource]::Get() End'
        
        $Global:VerbosePreference = $SaveVerbosePreference
        return $GetObject
    }

    [Boolean] Test()
    {
        Write-Debug -Message '[ClusterIPAddressResource]::Test() Start'

        try
        {
            $TestObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception; returning $false'
            return $false
        }

        if ($This.Ensure -eq [Ensure]::Present)
        {
            if ($TestObject.ResourceNameOwners.Count -gt 1)
            {
                Write-Verbose -Message "Cluster Resource [$($TestObject.ResourceName)] does not have 1 owner; returning $false"
                $TestValue = $false
            }
            elseif ($TestObject.ResourceNameOwners -ne $env:COMPUTERNAME)
            {
                Write-Verbose -Message "Cluster Resource [$($TestObject.ResourceName)] does not have [$($env:COMPUTERNAME)] as its Owner Node Name; returning $false"
                $TestValue = $false
            }
            elseif ($TestObject.ResourceNetworkNameDependency -notlike "*$($TestObject.ResourceName)*")
            {
                Write-Verbose -Message "Cluster Network Name Resource does not include the [$($TestObject.ResourceName)] Resource in it's dependencies; returning $false"
                $TestValue = $false
            }
            else
            {
                $TestValue = $true
            }
        }
        else
        {
            try
            {
                # If the resource doesn't exist, this cmdlet throws an exception
                $Resource = Get-ClusterResource -Name $TestObject.ResourceName -ErrorAction Stop
                $TestValue = $false
            }
            catch
            {
                $TestValue = $true
            }
        }

        Write-Verbose -Message $TestValue

        Write-Debug -Message '[ClusterIPAddressResource]::Test() End'
        return $TestValue
    }

    [Void] Set()
    {
        Write-Debug -Message '[ClusterIPAddressResource]::Set() Start'
        $SaveVerbosePreference = $Global:VerbosePreference;
        $Global:HideVerbose = $true

        try
        {
            $SetObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception'
        }

        Remove-Variable -Name HideVerbose -Scope Global

        $Global:VerbosePreference = $SaveVerbosePreference;

        if ($This.Ensure -eq [Ensure]::Present)
        {
            Write-Debug -Message '$This.Ensure -eq [Ensure]::Present'
            try
            {
                try
                {
                    Write-Debug -Message "Invoking Get-ClusterResource -Name $($SetObject.ResourceName) -ErrorAction Stop"
                    $Resource = Get-ClusterResource -Name $SetObject.ResourceName -ErrorAction Stop

                    Write-Debug -Message '$SetObject.Ensure -eq [Ensure]::Present'
                    Write-Verbose -Message "Retrieved [$($SetObject.ResourceName)] Resource from [$($SetObject.OwnerGroup)] Cluster Group"
                }
                catch
                {
                    Write-Debug -Message '$SetObject.Ensure -ne [Ensure]::Present'
                    
                    $Resource = Add-ClusterResource -Name "$($SetObject.ResourceName)" -ResourceType 'IP Address' -Group "$($SetObject.OwnerGroup)" -ErrorAction Stop
                    Write-Verbose -Message "Created [$($SetObject.ResourceName)] Resource in [$($SetObject.OwnerGroup)] Cluster Group"
                }

                try
                {
                    Write-Debug -Message 'Creating IP Address ClusterParameter'
                    $Param1 = New-Object -TypeName Microsoft.FailoverClusters.PowerShell.ClusterParameter -ArgumentList  $Resource, 'Address', $SetObject.IPAddress
                    $Param2 = New-Object -TypeName Microsoft.FailoverClusters.PowerShell.ClusterParameter -ArgumentList  $Resource, 'SubnetMask', $SetObject.SubnetMask
                    $Params = $Param1,$Param2

                    $Params | Set-ClusterParameter -ErrorAction Stop
                    Write-Verbose -Message "Configured IP Address [$($SetObject.IPAddress)] on [$($SetObject.ResourceName)] Resource"
                }
                catch
                {
                    throw "Set-ClusterParameter threw an exception. $($_.Exception.Message)"
                }
       
                try
                {
                    Write-Debug -Message 'Invoking Set-ClusterOwnerNode'
                    Set-ClusterOwnerNode -Resource $Resource -Owners $($env:COMPUTERNAME) -ErrorAction Stop
                    Write-Verbose -Message "Set Cluster Resource Owner Node on [$($SetObject.ResourceName)]"
                }
                catch
                {
                    throw "Set-ClusterOwnerNode threw an exception. $($_.Exception.Message)"
                }

                if ($SetObject.ResourceNetworkNameDependency -notlike "*$($SetObject.ResourceName)*")
                {
                    Write-Verbose -Message 'Building resource dependency expression'
                    $DependencyExpression = $SetObject.ResourceNetworkNameDependency -replace '[()]',''
                    
                    if ([String]::IsNullOrEmpty($DependencyExpression))
                    {
                        $NewDependencyExpression = "[$($SetObject.ResourceName)]"
                    }
                    else
                    {
                        $NewDependencyExpression = "$DependencyExpression or [$($SetObject.ResourceName)]"
                    }
                
                    Write-Debug -Message 'Invoking Set-ClusterResourceDependency'

                    Set-ClusterResourceDependency -Resource $SetObject.ResourceNetworkName -Dependency $NewDependencyExpression -ErrorAction Stop
                    Write-Verbose -Message 'Cluster Resource Dependency has been updated'
                }
                try
                {
                    Write-Debug -Message 'Invoking Start-ClusterGroup'
                    Get-ClusterGroup -Name $SetObject.OwnerGroup -ErrorAction Stop | Stop-ClusterGroup -Verbose | Start-ClusterGroup -Verbose
                    Write-Verbose -Message "Started Cluster Resource [$($SetObject.ResourceName)]"
                }
                catch
                {
                    thorw "Get-ClusterGroup threw an exception. $($_.Exception.Message)"
                }
                
                try
                {
                    Write-Debug -Message "Invoking Get-ClusterResource -Name $($SetObject.ResourceNetworkName) -ErrorAction Stop"
                    $ClusterNetworkNameResource = Get-ClusterResource -Name $SetObject.ResourceNetworkName -ErrorAction Stop
                    if ($ClusterNetworkNameResource.State -ne 'Online')
                    {
                        try
                        {
                            Write-Debug -Message "Invoking Start-ClusterResource -Name $($SetObject.ResourceNetworkName) -ErrorAction Stop"
                            Start-ClusterResource -Name $SetObject.ResourceNetworkName -ErrorAction Stop
                        }
                        catch
                        {
                            throw "Start-ClusterResource threw an exception. $($_.Exception.Message)"
                        }
                        
                    }
                }
                catch
                {
                    throw "Failed to bring Cluster Resource $($SetObject.ResourceNetworkName) online. $($_.Exception.Message)"
                }
            }
            catch
            {
                throw "Exception caught: Failed to configure Cluster Resource [$($SetObject.ResourceName)]. $($_.Exception.Message)"
            }
        }
        else # $This.Ensure -eq [Ensure]::Absent
        {
            try
            {
                if ($SetObject.Ensure -eq [Ensure]::Present)
                {
                    Remove-ClusterResource -Name $SetObject.ResourceName -Force -ErrorAction Stop
                    Write-Verbose -Message "Removed Cluster Resource [$($SetObject.ResourceName)]"
                }
            }
            catch
            {
                throw "Exception caught: Failed to remove Cluster Resource [$($SetObject.ResourceName)]. $($_.Exception.Message)"
            }
            Write-Debug -Message '[ClusterIPAddressResource]::Set() End'
        }
    }

    [String] GetSpareIPAddress([Object]$InstanceObject,[String]$Ec2Tag)
    {
        Write-Debug -Message '[ClusterIPAddressResource]::GetSpareIPAddress() Start'

        $ReturnValue = [String]::Empty
        
        $NonPrimaryPrivateIpAddress = ($InstanceObject.Instances.NetworkInterfaces.PrivateIpAddresses | Where-Object {$_.Primary -eq $false}).PrivateIpAddress
        Write-Debug -Message "GetSpareIPAddress: Found $($NonPrimaryPrivateIpAddress.Count) Secondary Private IP Addresses. These are used in the Set() method."

        if ($NonPrimaryPrivateIpAddress -contains $Ec2Tag)
        {
            $IPAddressFound = $true
            $ReturnValue = $Ec2Tag
        }
        else
        {
            foreach ($IPAddress in $NonPrimaryPrivateIpAddress)
            {
                $IPAddressFound = $false
            
                if (($InstanceObject.Instances.Tags | Select-Object -ExpandProperty Value) -match $IPAddress)
                {
                    $IPAddressFound = $true
                }

                if ($IPAddressFound -eq $false)
                {
                    Write-Verbose -Message "Found a free IP Address: $IPAddress"
                    $ReturnValue = $IPAddress
                    break
                }
            }
        }

        Write-Debug -Message '[ClusterIPAddressResource]::GetSpareIPAddress() End'

        return $ReturnValue
    }

    [String] ConvertToDecimalIP([Net.IPAddress]$IPAddress) {
        <#
            .SYNOPSIS
                Converts a Decimal IP address into a 32-bit unsigned integer.
            .DESCRIPTION
                ConvertTo-DecimalIP takes a decimal IP, uses a shift-like operation on each octet and returns a single UInt32 value.
            .PARAMETER IPAddress
                An IP Address to convert.
            .LINK
                http://www.indented.co.uk/2010/01/23/powershell-subnet-math/
        #>

        $i = 3; $DecimalIP = 0;
        $IPAddress.GetAddressBytes() | ForEach-Object { $DecimalIP += $_ * [Math]::Pow(256, $i); $i-- }

        return [UInt32]$DecimalIP
    }

    [String] ConvertToDottedDecimalIP([String]$IPAddressInput) {
        <#
            .SYNOPSIS
            Returns a dotted decimal IP address from either an unsigned 32-bit integer or a dotted binary string.

            .DESCRIPTION
            ConvertTo-DottedDecimalIP uses a regular expression match on the input string to convert to an IP address.

            .PARAMETER IPAddress
            A string representation of an IP address from either UInt32 or dotted binary.

            .LINK
            http://www.indented.co.uk/2010/01/23/powershell-subnet-math/
        #>

        Switch -RegEx ($IPAddressInput) {
            '([01]{8}.){3}[01]{8}' {
                    return [String]::Join('.', $( $IPAddressInput.Split('.') | ForEach-Object { [Convert]::ToUInt32($_, 2) } ))
            }

            '\d' {
                $IPAddressInput = [UInt32]$IPAddressInput
                $DottedIP = $( For ($i = 3; $i -gt -1; $i--) {
                    $Remainder = $IPAddressInput % [Math]::Pow(256, $i)
                    ($IPAddressInput - $Remainder) / [Math]::Pow(256, $i)
                    $IPAddressInput = $Remainder
                    } )
       
                return [String]::Join('.', $DottedIP)
            }
        
            default {
                Write-Error 'Cannot convert this format'
                return $null
            }
        }

        return $null
    }

    [String] GetNetworkAddress([Net.IPAddress]$IPAddressInput,[Net.IPAddress]$SubnetMaskInput) {
        <#
            .SYNOPSIS
            Takes an IP address and subnet mask then calculates the network address for the range.
            
            .DESCRIPTION
            Get-NetworkAddress returns the network address for a subnet by performing a bitwise AND 
            operation against the decimal forms of the IP address and subnet mask. Get-NetworkAddress 
            expects both the IP address and subnet mask in dotted decimal format.
            
            .PARAMETER IPAddress
            Any IP address within the network range.
            
            .PARAMETER SubnetMask
            The subnet mask for the network.
            
            .LINK
            http://www.indented.co.uk/2010/01/23/powershell-subnet-math/
        #>

        return $This.ConvertToDottedDecimalIP( ($This.ConvertToDecimalIP($IPAddressInput)) -band ($This.ConvertToDecimalIP($SubnetMaskInput)) )
    }
}

[DscResource()]
class ServiceResource
{
    [DscProperty(Key)]
    [String] $ServiceDisplayName

    [DscProperty(Mandatory)]
    [String] $ServiceName

    [DscProperty(Mandatory)]
    [String] $ClusterGroup

    [DscProperty(Mandatory)]
    [Ensure] $Ensure

    [DscProperty()]
    [String[]] $ResourceDependency

    [DscProperty()]
    [DependencyType] $DependencyType

    [DscProperty()]
    [Boolean] $UseNetworkName

    [DscProperty(NotConfigurable)]
    [String] $DependencyExpression

    [DscProperty(NotConfigurable)]
    [String] $PlannedDependencyExpression

    [ServiceResource] Get()
    {
        Write-Debug -Message '[ServiceResource]::Get() Start'
        Write-Verbose -Message 'Importing required PowerShell Modules'
        
        # Hiding all output from Import-Module even if -Verbose was specified
        $SaveVerbosePreference = $Global:VerbosePreference
        $Global:VerbosePreference = 'SilentlyContinue'
        
        Import-Module -Name FailoverClusters -ErrorAction Stop

        # Optional hiding as Get() is called from both Test() and Set()
        # Allows displaying verbose output for only one of those methods
        if ($Global:HideVerbose -ne $true)
        {
            $Global:VerbosePreference = $SaveVerbosePreference
        }

        $GetObject = [ServiceResource]::new()
        $GetObject.ServiceDisplayName = $This.ServiceDisplayName
        $GetObject.ServiceName = $This.ServiceName
        $GetObject.ClusterGroup = $This.ClusterGroup
        $GetObject.ResourceDependency = $This.ResourceDependency
        $GetObject.DependencyType = $This.DependencyType

        # Build the DependencyExpression that we are trying to configure
        $stringBuilder = [System.Text.StringBuilder]::new()

        for ($i = 0; $i -lt ($This.ResourceDependency.Count); $i++)
        {
            # Add the Resource
            $null = $stringBuilder.Append('([{0}])' -f $This.ResourceDependency[$i])
            
            # Append the expression if not the last item in the array
            if ($i -ne ($This.ResourceDependency.Count - 1))
            {
                $null = $stringBuilder.Append(' {0} ' -f $This.DependencyType)
            }
        }
        $GetObject.PlannedDependencyExpression = $stringBuilder.ToString()

        try
        {
            $ClusterResource = Get-ClusterResource -Name $GetObject.ServiceDisplayName -ErrorAction Stop
            Write-Verbose -Message "Cluster Resource $($GetObject.ServiceDisplayName) exists"
            $GetObject.Ensure = [Ensure]::Present

            $ClusterResourceDependency = Get-ClusterResourceDependency -Resource $GetObject.ServiceDisplayName
            $GetObject.DependencyExpression = $ClusterResourceDependency.DependencyExpression

            $UseNetworkNameValue = (Get-ClusterParameter -InputObject $ClusterResource -Name 'UseNetworkName').Value
            if ($UseNetworkNameValue -eq 0)
            {
                $GetObject.UseNetworkName = $false
            }
            else
            {
                $GetObject.UseNetworkName = $true
            }
        }
        catch
        {
            Write-Verbose -Message "Cluster Resource $($GetObject.ServiceDisplayName) does not exist"
            $GetObject.Ensure = [Ensure]::Absent
        }

        Write-Debug -Message '[ServiceResource]::Get() End'
        
        $Global:VerbosePreference = $SaveVerbosePreference
        return $GetObject
    }

    [Boolean] Test()
    {
        Write-Debug -Message '[ServiceResource]::Test() Start'

        try
        {
            $TestObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception; returning $false'
            return $false
        }

        # Debug code added to help identify issues when testing.
        Write-Debug -Message "This.Ensure = '$($This.Ensure)'"
        Write-Debug -Message "TestObject.Ensure = '$($TestObject.Ensure)'"
        Write-Debug -Message "This.UseNetworkName = '$($This.UseNetworkName)'"
        Write-Debug -Message "TestObject.UseNetworkName = '$($TestObject.UseNetworkName)'"
        Write-Debug -Message "TestObject.PlannedDependencyExpression = '$($TestObject.PlannedDependencyExpression)'"
        Write-Debug -Message "TestObject.DependencyExpression = '$($TestObject.DependencyExpression)'"

        if ($This.Ensure -eq $TestObject.Ensure -and $This.Ensure -eq [Ensure]::Absent)
        {
            # We want to remove the ServiceResource, so if the TestObject returns Absent, the
            # resource does not exist and we are in the correct state. No further checks required.
            return $true
        }
        elseif ($This.Ensure -eq $TestObject.Ensure)
        {
            # $This.Ensure -eq [Ensure]::Present. Do some further checks.
            if ($This.UseNetworkName -eq $TestObject.UseNetworkName -and
                $TestObject.PlannedDependencyExpression -eq $TestObject.DependencyExpression
            )
            {
                return $true
            }
            else
            {
                return $false
            }
        }
        else
        {
            # If we're in this block, $This.Ensure does not match $TestObject.Ensure
            return $false
        }
        Write-Debug -Message '[ServiceResource]::Test() End'
    }

    [Void] Set()
    {
        Write-Debug -Message '[ServiceResource]::Set() Start'
        $SaveVerbosePreference = $Global:VerbosePreference;
        $Global:HideVerbose = $true

        try
        {
            $SetObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception'
        }

        Remove-Variable -Name HideVerbose -Scope Global -ErrorAction SilentlyContinue

        $Global:VerbosePreference = $SaveVerbosePreference;

        if ($This.Ensure -eq [Ensure]::Present)
        {
            # We only want to try adding the Cluster Resource if it doesn't already exist
            Write-Debug -Message "SetObject.Ensure is set to '$($SetObject.Ensure)'"
            if ($SetObject.Ensure -ne [Ensure]::Present) {
                try
                {
                    Add-ClusterResource -Name $This.ServiceDisplayName -Group $This.ClusterGroup -ResourceType 'Generic Service' -ErrorAction Stop | Set-ClusterParameter -Name ServiceName -Value $This.ServiceName -ErrorAction Stop
                    Write-Verbose -Message "Created Cluster Service Resource $($This.ServiceDisplayName)"

                    Start-ClusterResource -Name $This.ServiceDisplayName
                }
                catch
                {
                    throw "Failed to create Cluster Service Resource $($This.ServiceDisplayName). $($_.Exception.Message)"
                }
            }

            <#
            From a logical standpoint:
            1. We will perform a simple test whether the configuration is valid. If it is not, we will
               throw an exception.
            2. We can use ResourceDependencies *without* the UseNetworkName setting, so we will first
               evaluate if the ResourceDependency is null
            3. If we have configured a ResourceDependency, we will configure those dependencies
            4. After configuring the ResourceDependencies, we will then evaluate whether the UseNetworkName
               is configured. If it is, we will then enable the UseNetworkName configuration.
            #>
            Write-Debug -Message "ResourceDependency set to '$($This.ResourceDependency)'"
            Write-Debug -Message "UseNetworkName set to '$($This.UseNetworkName)'"

            if ([String]::IsNullOrEmpty($This.ResourceDependency) -and $This.UseNetworkName -eq $true)
            {
                throw 'UseNetworkName is configured, however ResourceDependencies are not configured. This is an invalid configuration.'
            }
            elseif (-not ([String]::IsNullOrEmpty($This.ResourceDependency)))
            {
                Write-Verbose -Message "Need to configure a Resource Dependency for Cluster Service Resource $($This.ServiceDisplayName)"
                
                Write-Verbose -Message "Setting Dependency Expression to: $($SetObject.PlannedDependencyExpression)"

                try
                {
                    Set-ClusterResourceDependency -Resource $SetObject.ServiceDisplayName -Dependency $SetObject.PlannedDependencyExpression -ErrorAction Stop
                    Write-Verbose -Message 'Cluster Resource Dependency has been updated'
                }
                catch
                {
                    throw "Failed to update Cluster Resource Dependency. $($_.Exception.Message)"
                }

                # If we want enable the UseNetworkName setting, we need to enable it,
                # then restart all the Resources that were stopped in the process
                if ($this.UseNetworkName -eq $true)
                {
                    Write-Verbose -Message 'Attempting to enable the UseNetworkName setting'
                    try
                    {
                        Get-ClusterResource -Name $SetObject.ServiceDisplayName | Set-ClusterParameter -Name 'UseNetworkName' -Value 1
                        Write-Verbose -Message 'UseNetworkName enabled. Restarting the service so the change takes effect'
                        
                        # Capture the online resources so we can start all of these if they're taken offline due to dependencies
                        $OnlineResources = Get-ClusterResource | Where-Object {$_.ResourceType -ne 'IP Address' -and $_.State -eq 'Online'}

                        Get-ClusterResource -Name $SetObject.ServiceDisplayName | Stop-ClusterResource -ErrorAction Stop
                        Get-ClusterResource -Name $SetObject.ServiceDisplayName | Start-ClusterResource -ErrorAction Stop

                        foreach ($Resource in $OnlineResources)
                        {
                            $Resource | Start-ClusterResource -ErrorAction Stop
                        }
                    }
                    catch
                    {
                        throw "Failed to update the UseNetworkName Cluster Parameter. $($_.Exception.Message)"
                    }
                }
            }
        }
        else # $This.Ensure -eq [Ensure]::Absent
        {
            try
            {
                Remove-ClusterResource -Name $This.ServiceDisplayName -Force -ErrorAction Stop
                Write-Verbose -Message "Removed cluster Service Resource $($This.ServiceDisplayName)"
            }
            catch
            {
                throw "Failed to remove Cluster Service Resource $($This.ServiceDisplayName). $($_.Exception.Message)"
            }
        }
        Write-Debug -Message '[ServiceResource]::Set() End'
    }
}

[DscResource()]
class IsNotClusterOwner
{
    [DscProperty(Key)]
    [SingleInstance] $SingleInstance

    [DscProperty(Mandatory)]
    [String[]]$ServiceNamesToManage
    
    [DscProperty(NotConfigurable)]
    [Boolean] $IsClusterOwner

    [IsNotClusterOwner] Get()
    {
        # Hiding all output from Import-Module even if -Verbose was specified
        # The Verbose output from AWSPowerShell Module is extensive
        $SaveVerbosePreference = $Global:VerbosePreference
        $Global:VerbosePreference = 'SilentlyContinue'
        
        Import-Module -Name FailoverClusters -ErrorAction Stop

        # Optional hiding as Get() is called from both Test() and Set()
        # Allows displaying verbose output for only one of those methods
        if ($Global:HideVerbose -ne $true)
        {
            $Global:VerbosePreference = $SaveVerbosePreference
        }

        $GetObject = [IsNotClusterOwner]::new()
        $GetObject.ServiceNamesToManage = $This.ServiceNamesToManage        

        Write-Verbose -Message 'Checking for Cluster Owner Node'
        $OwnerNodeName = (Get-ClusterResource | Where-OBject {$_.Name -ne 'Cluster Name' -and $_.ResourceType -eq 'Network Name'}).OwnerNode.Name
        Write-Verbose -Message "OwnerNodeName: $OwnerNodeName"
        If ($OwnerNodeName -eq $env:COMPUTERNAME)
        {
            Write-Verbose -Message 'IsClusterOwner -eq $true'
            $GetObject.IsClusterOwner = $true
        }
        else
        {
            Write-Verbose -Message 'IsClusterOwner -eq $false'
            $GetObject.IsClusterOwner = $false
        }

        $Global:VerbosePreference = $SaveVerbosePreference
        return $GetObject
    }

    [Boolean] Test()
    {
        $SaveVerbosePreference = $Global:VerbosePreference

        try
        {
            $TestObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception; returning $false'
            return $false
        }

        $Global:VerbosePreference = $SaveVerbosePreference

        Write-Verbose -Message "IsClusterOwner: $($TestObject.IsClusterOwner)"

        $TestValue =$true
        if ($TestObject.IsClusterOwner -eq $false)
        {
            foreach ($Service in $TestObject.ServiceNamesToManage)
            {
                $ServiceStatus = (Get-Service -Name $Service).Status
                Write-Verbose -Message "Service: [$Service] | Status: [$ServiceStatus]"
                if ($ServiceStatus -eq 'Running')
                {
                    $TestValue = $false
                }
            }
        }

        return $TestValue
    }

    [Void] Set()
    {
        $SaveVerbosePreference = $Global:VerbosePreference;
        $Global:HideVerbose = $true

        try
        {
            $SetObject = $This.Get()
        }
        catch
        {
            Write-Verbose -Message '$This.Get() call threw an exception'
        }

        Remove-Variable -Name HideVerbose -Scope Global

        $Global:VerbosePreference = $SaveVerbosePreference;

        if ($SetObject.IsClusterOwner -eq $false)
        {
            foreach ($Service in $SetObject.ServiceNamesToManage)
            {
                if ((Get-Service -Name $Service).Status -eq 'Running')
                {
                    Stop-Service -Name $Service
                }
            }
        }
    }
}

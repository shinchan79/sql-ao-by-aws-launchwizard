<# This script has been adapted from sql DB tools to configure tempdb 
Reference Link https://dbatools.io/Set-SqlTempDbConfiguration#>
[CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $NetBIOSName,
       [Parameter(Mandatory=$true)]
        [string]
        $DomainAdminUser,
        [Parameter(Mandatory=$true)]
        [string]
        $DomainAdminPasswordKey,

        [Parameter(Mandatory=$true)]
        [string[]]
        $DriveLetters,
    
        [Parameter(Mandatory=$true)]
        [string[]]
        $DriveTypes
    )
    try{
        Start-Transcript -Path C:\cfn\log\Reconfigure-tempdb.ps1.txt -Append
        $DomainNetBIOSName = $env:USERDOMAIN
        $ErrorActionPreference = "Stop"   
        $dataPath = ""
        $logPath = ""
        $backupPath = ""
        $tempPath=""
        for ($i = 0; $i -lt $DriveTypes.count; $i++) {
                switch ($DriveTypes[$i]) {
                    "logs"{$logPath = $DriveLetters[$i] + ':\MSSQL\LOG'}
                    "data"{$dataPath = $DriveLetters[$i] + ':\MSSQL\DATA'}
                    "backup"{$backupPath = $DriveLetters[$i] + ':\MSSQL\Backup'
                             $tempPath = $DriveLetters[$i] + ':\MSSQL\TempDB'}
            }
        }
        [array]$paths = $dataPath,$logPath,$backupPath,$tempPath
        $DomainAdminFullUser = $DomainNetBIOSName + '\' + $DomainAdminUser
        $AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminPasswordKey).SecretString
        $DomainAdminCreds = (New-Object PSCredential($DomainAdminFullUser,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))
        $configuretempdb={        
                Import-Module SQLPS
                Set-Location "SQLSERVER:\SQL\$env:COMPUTERNAME\DEFAULT" 
                $smosrv = (Get-Item .)
                $ErrorActionPreference = "Stop"
                #Check cores for datafile count
                $cores = (Get-WmiObject Win32_Processor -ComputerName $smosrv.ComputerNamePhysicalNetBIOS).NumberOfLogicalProcessors
                if($cores -gt 8){$cores = 8}   
                        
                #Set DataFileCount if not specified. If specified, check against best practices.
                $DataFileCount = $cores
                Write-Verbose "Data file count set to number of cores: $DataFileCount"
                $DataPath = 'T:\MSSQL\TempDB'
                Write-Verbose "Using data path: $DataPath"
                $LogPath = 'T:\MSSQL\TempDB'
                Write-Verbose "Using log path: $LogPath"

                #Checks passed, process reconfiguration
                for($i=0;$i -lt $DataFileCount;$i++){
                $file=$smosrv.Databases['TempDB'].FileGroups['Primary'].Files[$i]
                if($file){
                    $filename = ($file.FileName).Substring((($file.FileName).LastIndexof('\'))+1)
                    $logicalname = $file.Name
                    $tempdevname = Join-Path $DataPath -ChildPath $filename
                    Invoke-Sqlcmd -Query "USE [master]
                    GO
                    ALTER DATABASE [tempdb] MODIFY FILE ( NAME = N'$logicalname', FILENAME = N'$tempdevname' , SIZE = 8MB , FILEGROWTH = 64MB )
                    GO"
                    } else {
                    $tempdevname = Join-Path $LogPath -ChildPath "tempdev`.ndf"
                    Invoke-Sqlcmd -Query "USE [master]
                    GO
                    ALTER DATABASE [tempdb] MODIFY FILE ( NAME = N'$logicalname', FILENAME = N'$tempdevname' , SIZE = 8MB , FILEGROWTH = 64MB )
                    GO"
                    }
                }
                $logfile = $smosrv.Databases['TempDB'].LogFiles[0]
                $filename = ($logfile.FileName).Substring((($logfile.FileName).LastIndexof('\'))+1)
                $logicalname = $logfile.Name
                $templogname = Join-Path $LogPath -ChildPath $filename
                Invoke-Sqlcmd -Query "USE [master]
                GO
                ALTER DATABASE [tempdb] MODIFY FILE ( NAME = N'$logicalname', FILENAME = N'$templogname' , SIZE = 8MB , FILEGROWTH = 64MB )
                GO"
                Write-Verbose "TempDB successfully reconfigured"
                
                # Stop SQL Service
                $SQLService = Get-Service -Name 'MSSQLSERVER'
                if ($SQLService.status -eq 'Running') {$SQLService.Stop()}
                $SQLService.WaitForStatus('Stopped','00:01:00')

                $tempDevFile = "$DataPath\tempdb.mdf"
                $tempLogFile = "$LogPath\templog.ldf"
                Move-Item-Safely "$using:tempPath\tempdb.mdf" $tempDevFile
                Move-Item-Safely "$using:tempPath\templog.ldf" $tempLogFile
                Remove-Item -Path "$using:tempPath" -Force
                # Start service
                $SQLService.Start()
                $SQLService.WaitForStatus('Running','00:01:00')
            }
            Invoke-Command -Authentication Credssp -Scriptblock $configuretempdb -ComputerName $NetBIOSName -Credential $DomainAdminCreds
        }
        catch{
            $_ | Write-AWSLaunchWizardException
        }



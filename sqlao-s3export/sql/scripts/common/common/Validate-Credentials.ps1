    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$DomainName,

        [Parameter(Mandatory=$false)]
        [string]$UserName,

        [Parameter(Mandatory=$true)]
        [string]$DomainAdminPasswordKey,

        [Parameter(Mandatory=$true)]
        [boolean]$isSecretManagerSupported,

        [Parameter(Mandatory=$false)]
        [string]$UserCredentials



    )

    $Failed= $false
    $FailedUsers = @()

    try
    {
        # Verify Domain Join worked fine

        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            Install-WindowsFeature RSAT-AD-PowerShell *>$null
        }
        if ($isSecretManagerSupported) {
            try {
                $secure = Get-SECSecretValue -secretId $DomainAdminPasswordKey -Select SecretString | ConvertFrom-Json | Select -ExpandProperty password
                $UserName = Get-SECSecretValue -secretId $DomainAdminPasswordKey  -Select SecretString | ConvertFrom-Json | Select -ExpandProperty username
            }
            catch {
                $Failed = $true
                Write-Output @{status= "Failed"; reason="Unable to fetch secret, check secret name $DomainAdminPasswordKey and access to Secrets Manager"} | ConvertTo-Json -Compress
                exit(1)
            }
        }
        else {
            $secure = (Get-SSMParameterValue -Names $DomainAdminPasswordKey -WithDecryption $True).Parameters[0].Value
        }
        $pass = ConvertTo-SecureString $secure -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential -ArgumentList $UserName, $pass
        Import-Module ActiveDirectory *>$null
        $domain = (Get-ADDomain -Server $DomainName -Credential $cred).DNSRoot
        if ($UserCredentials -ne $null) {
            # Convert the credentials to Hashtable
            # Example of user credentials: "{"SQL Server Account": {"user":"sqlsa", "password":"ssm.parameter.store.key1"}, "Some other account": {"user": "someuser", "password":"ssm.parameter.store.key2"}}"
            $UserCredentialsJson = ConvertFrom-Json $UserCredentials
            $UserCredentialsHashTable = @{}
            foreach ($property in $UserCredentialsJson.PSObject.Properties) {
                $UserCredentialsHashTable[$property.Name] = $property.Value
            }
            foreach ($Account in $UserCredentialsHashTable.Keys) {
                $credentials = @{}
                foreach ($property in $UserCredentialsHashTable[$Account].PSObject.Properties) {
                    $credentials[$property.Name] = $property.Value
                }

                $User = $credentials["user"]
                $PasswordKey = $credentials["password"]

                try {
                    # Check if user exists in AD
                    if (Get-ADUser -Server $domain -Filter {sAMAccountName -eq $User} -Credential $cred) {
                        # If user exists in AD, check for it credentials. If the user does not exist, provisioning process will create new user
			            $usersecure = (Get-SSMParameterValue -Names $PasswordKey -WithDecryption $True).Parameters[0].Value
			            $userpass = ConvertTo-SecureString $usersecure -AsPlainText -Force
                        $usercred = New-Object System.Management.Automation.PSCredential -ArgumentList $User, $userpass


                        $user = (Get-ADUser -Server $domain -Filter {sAMAccountName -eq $User} -Credential $usercred).Name

                        if (-Not $user) {
                            $Failed = $true
                            $FailedUsers += "$Account (username - $User)"
                        }

                    } else {
                        # Did not find the user in AD, we will create it during Provisioning process
                    }
                } catch {
                    $Failed = $true
                    $FailedUsers += "$Account (username - $User)"
                }
            }
        }
    }
    catch
    {
        Write-Output @{ status = "Failed"; reason = "Failed to join domain with provided Active Directory credentials. Exception: $_" } | ConvertTo-Json -Compress
        exit(1)
    }

    if($Failed -ne $true) {
        Write-Output @{ status= "Completed"; reason= "Done." } | ConvertTo-Json -Compress
    } else {
        Write-Output @{ status = "Failed"; reason = "Incorrect credentials for $($FailedUsers -join ', ')" } | ConvertTo-Json -Compress
    }

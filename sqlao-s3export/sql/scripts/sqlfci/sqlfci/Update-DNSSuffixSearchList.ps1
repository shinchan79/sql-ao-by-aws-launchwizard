[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]
    [string]$DomainDNSName
)

try {
    $ErrorActionPreference = "Stop"

    Start-Transcript -Path C:\cfn\log\Update-DNSSuffixSearchList.log -Append

    $DNSSuffixSearchList =  Get-DnsClientGlobalSetting | select -ExpandProperty SuffixSearchList
    if ($DNSSuffixSearchList.Contains($DomainDNSName)) {
        $NewSearchList = @($DomainDNSName)
        for ($i = 0; $i -lt $DNSSuffixSearchList.Length; $i ++) {
            if ($DNSSuffixSearchList[$i] -ne $DomainDNSName) {
               $NewSearchList += $DNSSuffixSearchList[$i]
            }
        }
        $DNSSuffixSearchList = $NewSearchList
    } else {
    	$DNSSuffixSearchList = @($DomainDNSName) + $DNSSuffixSearchList
    }

    Set-DnsClientGlobalSetting -SuffixSearchList $DNSSuffixSearchList
}
catch {
    $_ | Write-AWSLaunchWizardException
}
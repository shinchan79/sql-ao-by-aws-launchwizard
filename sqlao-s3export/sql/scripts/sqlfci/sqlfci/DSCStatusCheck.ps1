function DscStatusCheck () {
   $LCMState = (Get-DscLocalConfigurationManager).LCMState
   if ($LCMState -eq 'PendingConfiguration' -Or $LCMState -eq 'PendingReboot') {
       Start-DscConfiguration -UseExisting -Force -Wait
   } else {
     'Completed'
   }
}
DscStatusCheck


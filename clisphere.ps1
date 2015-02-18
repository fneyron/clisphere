#variables
$ScriptRoot = Split-Path $MyInvocation.MyCommand.Path
$csvfile = "$ScriptRoot\vmsdeploy.csv"
$vcenter_srv = 'pcc-37-187-228-26.ovh.com'
$timeout = 1800
$loop_control = 0

$vmsnapin = Get-PSSnapin VMware.VimAutomation.Core -ErrorAction SilentlyContinue
$Error.Clear()
if ($vmsnapin -eq $null) 	
	{
	Add-PSSnapin VMware.VimAutomation.Core
	if ($error.Count -eq 0)
		{
		write-host "PowerCLI VimAutomation.Core Snap-in was successfully enabled." -ForegroundColor Green
		}
	else
		{
		write-host "ERROR: Could not enable PowerCLI VimAutomation.Core Snap-in, exiting script" -ForegroundColor Red
		Exit
		}
	}
else
	{
	Write-Host "PowerCLI VimAutomation.Core Snap-in is already enabled" -ForegroundColor Green
	}

# 32-bit PowerCLI is required to run *-OSCustomizationSpec cmdlets
if ($env:Processor_Architecture -eq "x86") {

	#Connect to vCenter
	Connect-VIServer -Server $vcenter_srv

	$vms2deploy = Import-Csv -Path $csvfile
	
	#deploy vms as per information in each line, wait for customization (a reboot) then wait for vmware tools to change ip settings
	foreach ($vm in $vms2deploy) {
		
        #validate input, at least vm name, template name and OS Customization Spec name should be provided
		if (($vm.name -ne "") -and ($vm.template -ne "") -and ($vm.oscust -ne "")){
			
			#check if vm with this name already exists (some funny results are produced once we deploy vm with duplicate name)
			if (!(get-vm $vm.name -erroraction 0)){
				$vmhost = get-cluster $vm.cluster | get-vmhost -state connected | Get-Random
    			
                #check if we want to attempt IP configuration, if "none" is written in .csv file (because we use DHCP for example) we deploy immediately, otherwise we insert IP into CustomizationSpec, then deploy
				if ($vm.ip -match ‘none’){
					Write-Host "No IP configuration in .csv file, moving on" -ForegroundColor Yellow
                    write-Host "Deploying VM $($vm.name) to datastore cluster $($vm.datastore-cluster)"
	   			    new-vm -name $vm.name -template $(get-template -name $vm.template) -vmhost $vmhost -oscustomizationspec $(get-oscustomizationspec -name $vm.oscust) -datastore $(get-datastore -name $vm.datastore) -location $(get-folder -name $vm.folder) | Out-Null
				}
				else {
                    #clone the "master" OS Customization Spec, then use it to apply vm specific IP configuration
					$cloned_oscust = Get-OSCustomizationSpec $vm.oscust | New-OSCustomizationSpec -name "$($vm.oscust)_$($vm.name)"
					 
					Set-OSCustomizationNicMapping -OSCustomizationNicMapping ($cloned_oscust | Get-OscustomizationNicMapping) -Position 1 -IpMode UseStaticIp -IpAddress $vm.ip -SubnetMask $vm.mask -DefaultGateway $vm.gw -Dns $vm.dns1,$vm.dns2 | Out-Null
                    write-Host "Deploying VM $($vm.name) to datastore cluster $($vm.datastore)"
	   			    new-vm -name $vm.name -template $(get-template -name $vm.template) -vmhost $vmhost -oscustomizationspec $cloned_oscust -datastore $(get-datastorecluster -name $vm.datastore-cluster) -location $(get-folder -name $vm.folder) | Out-Null
				}
				
                #this is where we try to track deployment progress
                $loop_control = 0
				write-host "Starting VM $($vm.name)"
    			start-vm -vm $vm.name -confirm:$false | Out-Null

				write-host "Waiting for first boot of $($vm.name)" -ForegroundColor Yellow
	    		do {
    	    		$toolsStatus = (Get-VM -name $vm.name).extensiondata.Guest.ToolsStatus
        			Start-Sleep 3
					$loop_control++
    			} until ( ($toolsStatus -match ‘toolsOk’) -or ($loop_control -gt $timeout) )

				write-host "Waiting for customization spec to apply for $($vm.name) (a reboot)" -ForegroundColor Green
    			do {
        			$toolsStatus = (Get-VM -name $vm.name).extensiondata.Guest.ToolsStatus
        			Start-Sleep 3
					$loop_control++
    			} until ( ($toolsStatus -match ‘toolsNotRunning’) -or ($loop_control -gt $timeout) )

				Write-Host "OS customization in progress for $($vm.name)" -ForegroundColor red
	    		do {
    	    		$toolsStatus = (Get-VM -name $vm.name).extensiondata.Guest.ToolsStatus
        			Start-Sleep 3
                                $loop_control++
    			} until ( ($toolsStatus -match ‘toolsOk’) -or ($loop_control -gt $timeout) )

				#wait another minute "just in case" feel free to remove this line
				Start-Sleep 60
			    
                #clean-up the cloned OS Customization spec
				Remove-OSCustomizationSpec -CustomizationSpec $cloned_oscust -Confirm:$false | Out-Null
				
				if ($loop_control -gt $timeout){
					Write-Host "Deployment of $($vm.name) took more than $($timeout/20) minutes, check if everything OK" -ForegroundColor red
				}
				else {
				Write-Host "$($vm.name) successfully deployed, moving on" -ForegroundColor Green
				}
			}
			else {
				Write-Host "$($vm.name) already exists, moving on" -ForegroundColor Red
			}
		}
		else {
			Write-Host "Check input file $csvfile for line with empty vm, template or OS customization spec value" -ForegroundColor Red
		}
	}

	Write-Host "All vms deployed, exiting" -ForegroundColor Green
	#disconnect vCenter
	Disconnect-VIServer -Confirm:$false
}
else {
Write-Host "This script should be run from 32-bit version of PowerCLI only, Open 32-bit PowerCLI window and start again" -ForegroundColor Red
}
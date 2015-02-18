$vcserver = "pcc-37-187-228-26.ovh.com"
$csvfile = "vmsdeploy.csv"
$guestCredential = get-credential -message "Guest credential"
$timeout = 1800
$loop_control = 0

# check vSphere snap in is loaded and connected to vcenter
if(!$global:DefaultVIServer) {
	if(!(Get-PSSnapin | Where {$_.name -eq "vmware.vimautomation.core"})) {
		try {
			$now = Get-Date
			Write-Host "Snapin was not loaded, loading snapin: $now"
			Add-PSSnapin VMware.VimAutomation.Core -ea 0| out-null
		}
		catch {
			throw "Could not load PowerCLI snapin"
		}
	}
	try {
		$now = Get-Date
		Write-Host "Not connected to VC server, connecting: $now"
		Connect-VIServer $vcserver
	}
	catch {
		throw "Failed to connect to VI server $vcserver"
	}
}

$ScriptRoot = Split-Path $MyInvocation.MyCommand.Path
$vms2deploy = Import-Csv -Path "$ScriptRoot\$csvfile"
foreach ($vm in $vms2deploy) {
    # Check parameter are not empty in csv file
    if (($vm.name -ne "") -and ($vm.template -ne "") -and ($vm.oscust -ne "")){
        # Check vm Exist 
        $vm_exist = Get-VM -Name $vm.name -ErrorAction SilentlyContinue
        if (!($vm_exist)){
            # Put VM on a random host in the cluster
            $vmhost = Get-Cluster $vm.cluster | Get-VMHost -state connected | Get-Random
            # If nothing configure in ip then use customization spec 
            if ($vm.ip -eq $Null){
                Write-Host "No IP configuration in .csv file, moving on" -ForegroundColor Yellow
                write-Host "Deploying VM $($vm.name) to datastore cluster $($vm.datastore)"
                new-vm -name $vm.name -template $(get-template -name $vm.template) -vmhost $vmhost -oscustomizationspec $(get-oscustomizationspec -name $vm.oscust) -datastore $(get-datastore -name $vm.datastore) -location $(get-folder -name $vm.folder) | Out-Null
            }
            else {
                # clone the "master" OS Customization Spec, then use it to apply vm specific IP configuration
                $cloned_oscust = Get-OSCustomizationSpec $vm.oscust | New-OSCustomizationSpec -name "$($vm.oscust)_$($vm.name)"
                Set-OSCustomizationNicMapping -OSCustomizationNicMapping ($cloned_oscust | Get-OscustomizationNicMapping) -Position 1 -IpMode UseStaticIp -IpAddress $vm.ip -SubnetMask $vm.mask -DefaultGateway $vm.gw | Out-Null
                write-Host "Deploying VM $($vm.name) to datastore cluster $($vm.datastore)"
                new-vm -name $vm.name -template $(get-template -name $vm.template) -vmhost $vmhost -oscustomizationspec $cloned_oscust -datastore $(get-datastore -name $vm.datastore) -location $(get-folder -name $vm.folder) | Out-Null
            }

            $loop_control = 0
            write-host "Starting VM $($vm.name)"
            start-vm -vm $vm.name -confirm:$false | Out-Null
            write-host "Waiting for first boot of $($vm.name)" 
            do {
                $toolsStatus = (Get-VM -name $vm.name).extensiondata.Guest.ToolsStatus
                Start-Sleep 3
                $loop_control++
            } until ( ($toolsStatus -eq "toolsOk") -or ($loop_control -gt $timeout) )
            
            #Set-VM –VM $vm.name –OSCustomizationSpec $cloned_oscust –Confirm:$false
            $command = "ifconfig eth0 down; ifconfig eth0 192.168.140.101; ifconfig eth0 up;"
            Invoke-VMScript -VM CL02-SANDBOXFN-V001 -ScriptText $command -GuestUser $guestUser -GuestPassword VMware!
            
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
    Write-Host "All vms deployed, exiting" -ForegroundColor Green
    #disconnect vCenter
    Disconnect-VIServer -Confirm:$false
}
else {
Write-Host "This script should be run from 32-bit version of PowerCLI only, Open 32-bit PowerCLI window and start again" -ForegroundColor Red
}

$vcserver = "pcc-37-187-228-26.ovh.com"
$csvfile = "vmsdeploy.csv"
$timeout = 240
$loop_control = 0

function GetItemIdFromTitle([string]$LookupTitle, [ref]$LookupId)
{   
    $LookupField = $LookupList.Fields["DEPTCATEGORY"]   
    $LookupItem = $LookupList.Items | where {$_['DEPTCATEGORY'] -like "*$LookupTitle*"} 
    $LookupId.Value = $LookupItem.ID
}

Function checkCSV($vm)
{
    $required = ($vm.Name, $vm.ressourcepool, $vm.Datastore, $vm.Template, $vm.Folder, $vm.Cluster, $vm.Custom)
    foreach ($item in $required){
        if ($item -eq $null) { 
            Write-Host "Empty required value in CSV file. Exiting" -Foregroundcolor Red
            Exit
        }
    }
}

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
            Exit
		}
	}
	try {
		$now = Get-Date
		Write-Host "Not connected to VC server, connecting: $now"
		Connect-VIServer $vcserver
	}
	catch {
		throw "Failed to connect to VI server $vcserver"
        Exit
	}
}

#$GuestCredential = $Host.UI.PromptForCredential("Please enter credentials", "Enter Guest credentials for Template", "", "")
$ScriptRoot = Split-Path $MyInvocation.MyCommand.Path

$csvfile = "$ScriptRoot\$csvfile"
if (!(Test-Path $csvfile)){
    Write-Host "No csv file present $csvfile" -Foregroundcolor Red
    Exit
}
$vms2deploy = Import-Csv -Path $csvfile
foreach ($vm in $vms2deploy) {
    # Check parameter are not empty in csv file
    checkCSV($vm)
    # Check vm Exist 
    $vm_exist = Get-VM -Name $vm.name -ErrorAction SilentlyContinue
    if (!($vm_exist)){
        # Put VM on a random host in the cluster
        $vmhost = Get-Cluster $vm.cluster | Get-VMHost -state connected | Get-Random
        # If nothing configure in ip then use customization spec 
        if (($vm.IP -eq $Null) -or ($vm.Netmask -eq $Null) -or ($vm.Gateway -eq $Null)){
            
            Write-Host "No IP configuration in .csv file, moving on" -ForegroundColor Yellow
            write-Host "Deploying VM $($vm.name) to datastore cluster $($vm.datastore)"
            new-vm -name $vm.name -template $(get-template -name $vm.template) -vmhost $vmhost -oscustomizationspec $(get-oscustomizationspec -name $vm.Custom) -datastore $(get-datastore -name $vm.datastore) -location $(get-folder -name $vm.folder) | Out-Null
        }
        else {
            # clone the "master" OS Customization Spec, then use it to apply vm specific IP configuration
            if (Get-OSCustomizationSpec "$($vm.Custom)_$($vm.Name)" -ErrorAction SilentlyContinue){
                Remove-OSCustomizationSpec "$($vm.Custom)_$($vm.Name)" -Confirm:$false | Out-Null
            }
            $cloned_oscust = Get-OSCustomizationSpec $($vm.Custom) | New-OSCustomizationSpec -name "$($vm.Custom)_$($vm.Name)"
            Set-OSCustomizationNicMapping -OSCustomizationNicMapping ($cloned_oscust | Get-OscustomizationNicMapping) -Position 1 -IpMode UseStaticIp -IpAddress $vm.IP -SubnetMask $vm.Netmask -DefaultGateway $vm.Gateway | Out-Null
            write-Host "Deploying VM $($vm.name) to datastore cluster $($vm.datastore)"
            new-vm -name $vm.Name -template $(get-template -name $vm.Template) -vmhost $vmhost -oscustomizationspec $cloned_oscust -Datastore $(get-datastore -name $vm.Datastore) -Location $(get-folder -name $vm.Folder) -ResourcePool $(get-resourcepool -name $vm.RessourcePool) | Out-Null
        }

        # Setting VLAN
        Get-NetworkAdapter -vm $vm.Name | Set-NetworkAdapter -NetworkName $vm.VLAN -Confirm:$false

        $loop_control = 0
        write-host "Starting VM $($vm.name)"
        start-vm -vm $vm.name -confirm:$false | Out-Null
       
       <# $command = "ifconfig eth0 down; ifconfig eth0 192.168.140.101; ifconfig eth0 up;"
        Invoke-VMScript -VM CL02-SANDBOXFN-V001 -ScriptText $command -GuestUser $guestUser -GuestPassword VMware!#>

        #clean-up the cloned OS Customization spec
        Remove-OSCustomizationSpec -CustomizationSpec $cloned_oscust -Confirm:$false | Out-Null

        # Wait until vm toosl start
        write-host "Waiting for first boot of $($vm.name)" 
        do {
            $toolsStatus = (Get-VM -name $vm.name).extensiondata.Guest.ToolsStatus
            Start-Sleep 1
            $loop_control++
        } until ( ($toolsStatus -eq "toolsOk") -or ($loop_control -gt $timeout) )
        

        Restart-vmGuest -vm $vm.Name
       <# if ($loop_control -gt $timeout){
            Write-Host "Deployment of $($vm.name) took more than $($timeout/60) minutes, check if everything OK" -ForegroundColor red
        }
        else {
        Write-Host "$($vm.name) successfully deployed, moving on" -ForegroundColor Green
        }#>
    }
    else {
        Write-Host "$($vm.name) already exists, moving on" -ForegroundColor Red
    }
    Write-Host "All vms deployed, exiting" -ForegroundColor Green
    #disconnect vCenter
    #Disconnect-VIServer -Confirm:$false
}

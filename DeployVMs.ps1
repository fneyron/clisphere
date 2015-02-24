# Developed by Florent NEYRON
# florent.neyron@gmail.com

# Global variables
# datastore search variables
$datastoreMinimumSpaceGB = 10
$datastoreMaximumVMs = 80
#$defaultDatastores = 'VNX1-OSCARO-CLI3_LUN_100','VNX1-OSCARO-CLI3_LUN_101','VNX1-OSCARO-STD3_LUN_0','VNX1-OSCARO-STD3_LUN_1'
$defaultDatastores = 'pcc-000090','pcc-000050'
# PowerOn timeout
$timeout = 60
$loop_control = 0

#DNS server
$DNS = $true
$DNSServer = "CL02-INFRA-V001"
$ZoneName = "oscaroad.com"

Function Connect($vcserver)
{
    Write-Host "---------------------------------------------------"
    Write-Host "Connecting to $vcserver..."
    Write-Host "---------------------------------------------------"
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
    Write-Host "Success"
}

Function FindDatastore($vm)
{
    Write-Host "---------------------------------------------------"
    Write-Host "Finding best datastores..."
    Write-Host "---------------------------------------------------"

    # get datastores
    $datastores = @(Get-Cluster -Name $vm.Cluster | Get-VMHost $vmhost | Get-Datastore | `
        # filter to datastores with name like $datastoreNameQuery with at least $datastoreMinumumSpace free space
        ? {($defaultDatastores -contains ($_.Name)) -and ($_.FreeSpaceGB -ge $datastoreMinimumSpaceGB)} | `
        # select relevant data and get number of powered on VMs
        select name, freespacegb, @{N="NumberVMs";E={@($_ | Get-VM | where {$_.PowerState -eq "PoweredOn"}).Count}} | `
        # filter to datastores with less than $datastoreMaximumVMs
        ? {($_.NumberVMs -lt $datastoreMaximumVMs)} | `
        # sort VMs by number VMs then FreeSpace
        Sort @{expression="FreeSpaceGB";Descending=$true})
        # if at any point we run out of space throw an error and exit
    Write-Host $datastores
    if(!$datastores) {
        Write-Host "Not enough datastore space to deploy $vmQuantity VMs or no datastore found, check conf or deploy a new datastore" -ForegroundColor Red
        exit
    }
    # if there are stores available continue and deduct a VM from the best store
    else {
        Write-Host "Using $($datastores[0].name), $([Math]::Round($datastores[0].FreeSpaceGB))GB free, $($datastores[0].NumberVMs) vms"
    }
    return $($datastores[0].name)
}

function RetrieveResourcePoolID($path)
{
    $SplitedPath = $path.split('/')
    $i = 0
    $id = $(get-resourcepool -name $SplitedPath[$i] -location $vm.Cluster).ID
    while ($i -ne $SplitedPath.length - 1){
        $rps = Get-View $(get-resourcepool -name $SplitedPath[$i] -location $vm.Cluster).ExtensionData.ResourcePool
        foreach ($rp in $rps){
            if($rp.Name -eq $SplitedPath[$i + 1]){
                $id = $rp.MoRef
                $i = $i + 1
                break
            }
        }
    }
    return $(get-resourcepool -Id $id)
}

function CreateVM($vm)
{
    # Put VM on a random host in the cluster
    $vmhost = Get-Cluster $vm.cluster | Get-VMHost -state connected | Get-Random
    # If nothing configure in ip then use customization spec 
    if (($vm.IP -eq $Null) -or ($vm.Netmask -eq $Null) -or ($vm.Gateway -eq $Null)){
        Write-Host "No IP configuration in .csv file, moving on using default customization $vm.custom" 
        $oscust = Get-OsCustomizationSpec -Name $vm.Custom
    }
    else {
        # clone the "master" OS Customization Spec, then use it to apply vm specific IP configuration
        if (Get-OSCustomizationSpec "$($vm.Custom)_$($vm.Name)" -ErrorAction SilentlyContinue){
            Remove-OSCustomizationSpec "$($vm.Custom)_$($vm.Name)" -Confirm:$false | Out-Null
        }
        $oscust = Get-OSCustomizationSpec $($vm.Custom) | New-OSCustomizationSpec -name "$($vm.Custom)_$($vm.Name)"
        if ($oscust.OSType -eq "Windows"){
            Set-OSCustomizationNicMapping -OSCustomizationNicMapping ($oscust | Get-OscustomizationNicMapping) -Position 1 -IpMode UseStaticIp -IpAddress $vm.IP -SubnetMask $vm.Netmask -DefaultGateway $vm.Gateway -dns $($oscust | Get-OscustomizationNicMapping).dns | Out-Null
        }
        elseif ($oscust.OSType -eq "Linux")
        {
            Set-OSCustomizationNicMapping -OSCustomizationNicMapping ($oscust | Get-OscustomizationNicMapping) -Position 1 -IpMode UseStaticIp -IpAddress $vm.IP -SubnetMask $vm.Netmask -DefaultGateway $vm.Gateway | Out-Null

        }
        else 
        {
            Write-Host "OS Type not recognized in Customization spec" -ForegroundColor Red
        }
    }
    if ([string]::IsNullOrEmpty($vm.datastore))
    {
        # Finding Datastore
        $datastore = FindDatastore($vm)
        echo $datastore
    }
    else 
    {
        $datastore = $vm.Datastore
    }
   
    # Creating vm
    new-vm -name $vm.Name -template $(get-template -name $vm.Template) -oscustomizationspec $oscust -vmhost $vmhost -Datastore $(get-datastore -name $datastore) -Location $(get-folder -name $vm.Folder) -ResourcePool $(RetrieveResourcePoolID($vm.ressourcepool)) | Out-Null
    #clean-up the cloned OS Customization spec
    Remove-OSCustomizationSpec -CustomizationSpec $oscust -Confirm:$false | Out-Null
}

Function Main
{
    #$GuestCredential = $Host.UI.PromptForCredential("Please enter credentials", "Enter Guest credentials for Template", "", "")
    $csvfile = "$ScriptRoot\$csvfile"
    if (!(Test-Path $csvfile)){
        Write-Host "No csv file present $csvfile" -Foregroundcolor Red
        Exit
    }
    $vms2deploy = Import-Csv -Path $csvfile -delimiter ";"
    foreach ($vm in $vms2deploy) {
        # Check parameter are not empty in csv file
        checkCSV($vm)
        Write-Host "---------------------------------------------------"
        Write-Host "Deploying VM $($vm.Name) ..."
        Write-Host "---------------------------------------------------"
        # Check vm Exist 
        $VMExist = Get-VM -Name $vm.name -ErrorAction SilentlyContinue
        if ($VMExist)
        {  
            Write-Host "VM $($vm.Name) already exist, Skipping" -ForegroundColor Red
        }
        else
        {

            # Create VM
            CreateVM($vm)

            # Setting VLAN
            Get-NetworkAdapter -vm $vm.Name | Set-NetworkAdapter -Portgroup $vm.VLAN -Confirm:$false | Out-Null

            $loop_control = 0
            write-host "Starting VM $($vm.name)"
            start-vm -vm $vm.name -confirm:$false | Wait-Tools -TimeoutSeconds $timeout | Out-Null
            
            write-host "VMTools Ok, Restart guest OS"
            Restart-vmGuest -vm $vm.Name
            
            if (($vm.IP -ne $Null) -and ($DNS))
            {
                Write-Host "---------------------------------------------------"
                Write-Host "Updating DNS Entries ..."
                Write-Host "---------------------------------------------------"
                Invoke-Command -ComputerName $DNSServer -ScriptBlock {
                    Add-DnsServerResourceRecordA -ZoneName $args[0] -Name $args[1] -IPv4Address $args[2] -CreatePtr
                } -ArgumentList $ZoneName,$vm.Name,$vm.IP
            }
        }
    }
    Write-Host "All process Successfull, exiting" -ForegroundColor Green
    #disconnect vCenter
    #Disconnect-VIServer -Confirm:$false
}

Function checkCSV($vm)
{
    $required = ($vm.Name, $vm.ressourcepool, $vm.Template, $vm.Cluster, $vm.Custom)
    foreach ($item in $required){
        if ([string]::IsNullOrEmpty($item)) { 
            Write-Host "Empty required value in CSV file. Exiting" -Foregroundcolor Red
            Exit
        }
    }
    if($vm.Folder){
        foreach ($dir in $vm.Folder.split('/')){
            if (!(get-folder -name $dir -ErrorAction SilentlyContinue) -or ($(get-folder -name $dir -ErrorAction SilentlyContinue).Type -ne "VM")){ 
                Write-Host "Directory not found or it's not a directory: $dir"
                Exit
            }
        }
    }
    else { $vm.Folder = 'vm' }
}

# Define script path
$ScriptRoot = Split-Path $MyInvocation.MyCommand.Path

# Check Arguements
if ($args.Length -ne 2)
{
    Write-Host "Usage: clisphere.ps1 <server> <csv>"
}
else
{
    $server = $args[0]
    $csvfile = $args[1]
    Connect($server)
    Main
}

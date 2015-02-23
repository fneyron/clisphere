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

Function Main
{
    #$GuestCredential = $Host.UI.PromptForCredential("Please enter credentials", "Enter Guest credentials for Template", "", "")
    $csvfile = "$ScriptRoot\$csvfile"
    if (!(Test-Path $csvfile)){
        Write-Host "No csv file present $csvfile" -Foregroundcolor Red
        Exit
    }
    $vms2deploy = Import-Csv -Path $csvfile -Delimiter ";"
    foreach ($vm in $vms2deploy) {
        Write-Host "---------------------------------------------------"
        Write-Host "Deleting VM $($vm.Name) ..."
        Write-Host "---------------------------------------------------"
        $VMExist = Get-VM -Name $vm.name -ErrorAction SilentlyContinue
        if (!($VMExist))
        {  
            Write-Host "VM $($vm.Name) doesn't exist, Skipping" -ForegroundColor Red
        }
        else {
            Stop-VM -VM (Get-VM -Name $vm.name) -Confirm:$false
            Remove-VM $vm.name -DeleteFromDisk

            
            Write-Host "VM $($vm.Name) successfully deleted" -foregrouncolor Green
        }
        if ($DNS)
        {
            Write-Host "---------------------------------------------------"
            Write-Host "Delete DNS Entries ..."
            Write-Host "---------------------------------------------------"
            Invoke-Command -ComputerName $DNSServer -ScriptBlock {
                Remove-DnsServerResourceRecord -ZoneName $args[0] -Name $args[1] -RRType "A" -confirm:$false
            } -ArgumentList $ZoneName,$vm.Name
        }
    }
    #disconnect vCenter
    Disconnect-VIServer -Confirm:$false
}


Function checkCSV($vm)
{
    $required = ($vm.Name)
    foreach ($item in $required){
        if ($item -eq $null) { 
            Write-Host "Empty required value in CSV file. Exiting" -Foregroundcolor Red
            Exit
        }
    }
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

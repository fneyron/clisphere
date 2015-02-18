<#
========================================================================================
Title:           Deploy VM
Author:          Harry John
Website:         http://www.harryjohn.org/deploy-multiple-vms-from-template/
Version:         1.0
Usage:           For use with .\DeployMultipleVMs.ps1
Date Created:    18/10/2013
Last Update:     03/01/2014

Outstanding Updates:

Change log:

========================================================================================
#>

#=======================================================================================
# PARAMETERS
#=======================================================================================
Param ($session=$(throw "missing -session parameter"),$vcserver,$name,$datastore,$ipaddr,$template,$folderName)

# VMware variables
# VM host
$vmhost = "vcenter1-oscaro.ecritel.net"

# customisation spec
$custSpecName = "Ubuntu 14.10"

# location
$folder = Get-Folder -Location "Virtual Machines" -Name $folderName

$now = Get-Date

Write-Host "Starting deploy script: $now"

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
		Connect-VIServer $vcserver -session $session
	}
	catch {
		throw "Failed to connect to VI server $vcserver"
	}
}

$now = Get-Date
Write-Host "Starting deployment process: $now"

if (!$datastore) {
	Write-Host "No datastore could be found. VM cannot be deployed! Aborting."
	return
}

$custSpec = Get-OSCustomizationSpec $custSpecName 
if (!$custSpec) {
	Write-Host "Guest OS customization specification could not be found. Aborting."
	return
}

Write-Host "Cloning VM ..."
try {
$vm = New-VM -Name $name `
	-VMHost $vmhost `
	-Template $template `
	-OSCustomizationSpec $custSpec `
	-Datastore $datastore `
	-Location $folder `
	-ErrorAction:Stop
}
catch
{
        Write-Host "An error ocurred during template clone operation:"
 
        # output all exception information
        $_ | fl
 
        Write-Host "Cleaning up ..."
 
        # clean up and exit
        $exists = Get-VM -Name $name -ErrorAction SilentlyContinue
        If ($Exists){
                Remove-VM -VM $exists -DeletePermanently
        }
        return
}
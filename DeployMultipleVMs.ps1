<#
========================================================================================
Title:           Deploy Multiple VMs
Author:          Harry John
Website:         http://www.harryjohn.org/deploy-multiple-vms-from-template/
Version:         1.1
Usage:           .\DeployMultipleVMs.ps1
Date Created:    18/10/2013
Last Update:     03/01/2014

Outstanding Updates:
- check template exists before starting script
- confirm settings before starting script
- validate user input
- error checking at each stage
- change datastore minumum space to percentage
- change $vmTemplateSizeGB to fetch actual size from template
- add option for CSV import?

Change log:
v1.1:
- removed all "hard coded" variables and added to parameters
- added option to enable/disable specific tasks
- added option for DHCP address ($enableStaticIP)
========================================================================================
#>

Write-Host "---------------------------------------------------"
Write-Host "Mass VM Deployment Tool"
Write-Host "---------------------------------------------------"

#=======================================================================================
# PARAMETERS
#=======================================================================================

# enable/disable specific tasks
$enableAutoPowerOn = 1
$enableMoveToAdOu = 0
$enableActivateWindows = 0
$enableActivateOffice = 0
$enableStaticIP = 1
$enableStartService = 1

# task parameters
$serviceToStart = "IMAService"

# script settings
$maxConcurrentJobs = 1
$cycleTime = 10
$domainAdminGroup = "Domain Admins"

# vm settings
$vmTemplateSizeGB = 50
$folder = "Dev"
$template = 'CL02-TEMPLATE-Ubuntu-14.04'
$adOrganisationUnit = 'ou=Computers,dc=domain,dc=local'
$vcserver = "vcenter1-oscaro.ecritel.net"

# vm OS settings
$localAdminUser = "admin-infra"
$localNICNameQuery = "Local Area Connection*"

# network variables
$networkSubnet = "255.255.0.0"
$networkGateway = "172.16.0.1"
$networkDns = "172.16.0.2","172.16.0.3"

# datastore search variables
$datastoreMinimumSpaceGB = 100
$datastoreMaximumVMs = 80
$datastoreNameQuery = "pcc-000*"




#=======================================================================================
# FUNCTIONS
#=======================================================================================

###################
# Function to test existance of computer in AD (without exceptions in console)
###################
Function Test-XADComputer() {
	[CmdletBinding(ConfirmImpact="Low")]
	
	Param (
		[Parameter(
			Mandatory=$true,
			Position=0,
			ValueFromPipeline=$true,
			HelpMessage="Identity of the AD object to verify if exists or not."
		)]
		[Object] $Identity
	)
	trap [Exception] {
		return $false
	}
	$auxObject = Get-ADComputer $Identity
	return $true
}

###################
# Function to activate Windows on a remote computer
###################
Function Register-Computer 
{  [CmdletBinding(SupportsShouldProcess=$True)] 
   param ([String] $Server=".")
 

    $objService = get-wmiObject -query "select * from SoftwareLicensingService" -computername $server 
	
    #if ($ProductKey) { If ($psCmdlet.shouldProcess($Server , $lStr_RegistrationSetKey)) {
    #                       $objService.InstallProductKey($ProductKey) | out-null  
    #                       $objService.RefreshLicenseStatus()         | out-null  } 
    #}

	get-wmiObject -query  "SELECT * FROM SoftwareLicensingProduct WHERE PartialProductKey <> null
                                                                   AND ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f'
                                                                   AND LicenseIsAddon=False" -Computername $server |

      foreach-object { If ($psCmdlet.shouldProcess($_.name , "Activate product" )) 

                             { $_.Activate()                      | out-null 

                               $objService.RefreshLicenseStatus() | out-null

                               $_.get()
                               If     ($_.LicenseStatus -eq 1) {
							   		#write-host "Product activated successfully."
									return 1
								} 
                               Else {
							   		#write-host ("Activation failed, and the license state is '{0}'" -f $licenseStatus[[int]$_.LicenseStatus] ) 
									return 0
								}
                            If     (-not $_.LicenseIsAddon) { return } 

              }               
             else { write-Host ($lStr_RegistrationState -f $lStr_licenseStatus[[int]$_.LicenseStatus]) } 
    } 
}

###################
# Function to enable and start Citrix IMA service on a remote computer
###################
Function Enable-CitrixService {
	param([string] $Server)
	$resultChangeServiceMode = (gwmi win32_service -computername $server -filter "name='$serviceToStart'").ChangeStartMode("Automatic") 
	$resultStartService = (gwmi win32_service -computername $server -filter "name='$serviceToStart'").startservice() 
}

#=======================================================================================
# SCRIPT START
#=======================================================================================

###################
# Prepare console and run checks
###################

# first check user is a domain admin
# $isDomainAdmin = Get-ADGroupMember $domainAdminGroup | ? { $_.samAccountName -eq [Environment]::UserName } 
# if(!$isDomainAdmin) {
	# "You are logged on as $([Environment]::UserName) and this user is not a Domain Admin"
	# exit
# }

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

# set current path, vcserver and session info for passing to job threads
$currentPath = (Split-Path -parent $MyInvocation.MyCommand.Definition)
$session = $global:DefaultVIServer | %{ $_.sessionsecret }

###################
# Prepare variables
###################

# get VM info from user
Write-Host "Please note the following questions are currently not validated, care is needed!"

# get VM local admin password
while (!$localAdminPasswordConfirmed) {
	$localAdminPassword = Read-Host "Please enter the template local admin password"-AsSecureString
	$localAdminPassword2 = Read-Host "Please confirm this password" -AsSecureString
	$localAdminPasswordDecrypt = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($localAdminPassword))
	$localAdminPasswordDecrypt2 = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($localAdminPassword2))

	if ($localAdminPasswordDecrypt -eq $localAdminPasswordDecrypt2) {
		$localAdminPasswordConfirmed = 1
	}
	else {
		Write-Host "Passwords do not match, please try again"
	}
}

# get VM name prefix
$vmFirstName = Read-Host "Enter the name of the first VM (e.g. MAILSERVER01)"
# !! validation needed !!

# get number of VMs to build
[int]$vmQuantity = Read-Host "How many VMs are you creating?"
# !! validation needed !!

# gather IP Address if not using DHCP
if($enableStaticIP) {
    $ipAddress = Read-Host "You need a block of $vmQuantity adjacent IP addresses, enter the first"
    # !! validation needed !!

    # split up IP address
    $ipSplit = $ipAddress.Split(".")
    $ipPrefix = $ipSplit[0] + "." + $ipSplit[1] + "." + $ipSplit[2] + "." 
    [int]$ipSuffix = $ipSplit[3]
}

# split up VM name
[int]$vmFirstNumber = $vmFirstName.Substring($vmFirstName.length - 2,2)
$vmNamePrefix = $vmFirstName.Substring(0,$vmFirstName.length - 2)

#confirm details with user:
Write-Host "---------------------------------------------------"
Write-Host "Confirm the following details are correct:"
Write-Host "---------------------------------------------------"
Write-Host "First VM: 		$vmFirstName"
Write-Host "First IP Address: 	$($ipPrefix + $ipSuffix)"
Write-Host "Number of VMs: 		$vmQuantity"
Write-Host "Template Name:		$template"
Write-Host "Folder Name:		$folder"
Write-Host "Press any key to continue, or Ctrl + C to cancel..."
$x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

###################
# Datastore preparation - check we have space and compile list of best datastores
###################

Write-Host "---------------------------------------------------"
Write-Host "Finding best datastores for $vmQuantity VMs..."
Write-Host "---------------------------------------------------"

# check there is available storage space for the quantity vms required
$availableDatastores = @()

# get datastores
$datastores = @(Get-Datastore | `
	# filter to datastores with name like $datastoreNameQuery with at least $datastoreMinumumSpace free space
	? {($_.Name -like $datastoreNameQuery) -and ($_.FreeSpaceGB -ge $datastoreMinimumSpaceGB)} | `
	# select relevant data and get number of powered on VMs
	select name, freespacegb, @{N="NumberVMs";E={@($_ | Get-VM | where {$_.PowerState -eq "PoweredOn"}).Count}} | `
	# filter to datastores with less than $datastoreMaximumVMs
	? {($_.NumberVMs -lt $datastoreMaximumVMs)} | `
	# sort VMs by number VMs then FreeSpace
	Sort @{expression="NumberVMs";Ascending=$true},@{expression="FreeSpaceGb";Descending=$true})

# deduct 1 VM and $vmTemplateSizeGB from each datastore for each VM required
1..$vmQuantity | foreach {

	# if at any point we run out of space throw an error and exit
	if(!$datastores) {
		Write-Host "Not enough datastore space to deploy $vmQuantity VMs, deploy an extra datastore and run the script again"
		exit
	}
	
	# if there are stores available continue and deduct a VM from the best store
	else {
		Write-Host "Deducting VM from datastore: $($datastores[0].name)"
		Write-Host "Before: $([Math]::Round($datastores[0].FreeSpaceGB))GB free, $($datastores[0].NumberVMs) vms"
		
		# remove $vmTemplateSizeGB and add 1 VM to the best datastore
		$datastores[0].FreeSpaceGB -= $vmTemplateSizeGB
		$datastores[0].NumberVMs += 1
		
		Write-Host "After: $([Math]::Round($datastores[0].FreeSpaceGB))GB free, $($datastores[0].NumberVMs) vms"
		
		# add best datastore to list of available datastores, this 
		$availableDatastores += $datastores[0].Name
		
		# re-filter list of potential datastores
		$datastores = $datastores | ? {($_.FreeSpaceGB -ge $datastoreMinimumSpaceGB) -and ($_.NumberVMs -lt $datastoreMaximumVMs)}
	}
}

###################
# Build $vmStatus array to keep track of VMs and completed tasks
###################

# create an object collection holding status info for all VMs being built
$vmStatus = @()

# create counters for VM name and IP address/datastore
$vmNumber = $vmFirstNumber
$vmCounter = 0

1..$vmQuantity | foreach {
	# if VM number is less than 10 add a 0 onto the server name so we dont have MAILSERVER1 for example
	if ($vmNumber -lt 10) {
		$vmName = $vmNamePrefix + "0" + $vmNumber
	} else {
		$vmName = $vmNamePrefix + $vmNumber
	}
	
	# compile IP address if $enableStaticIP is enabled
	if($enableStaticIP) {
        $vmIpAddress = $ipPrefix + ($ipSuffix + ($vmCounter))
    } else {
        $vmIpAddress = "DHCP"
    }

    # choose next datastore from list (put here to make obvious)
    $vmDatastore = $availableDatastores[$vmCounter]
    
	Write-Host "$($vmName) $($vmIpAddress) $($vmDatastore) "
	# setup object properties
	$properties = [ordered]@{
		MachineName = $vmName
		IpAddress = $vmIpAddress
        Datastore = $vmDatastore
		CloneInitiated = 0
		Cloned = 0
		PoweredOn = 0
		InAD = $enableMoveToAdOu - 1
		ActivateWin = $enableActivateWindows - 1
		ActivateOffice = $enableActivateOffice - 1
 		ReIP = $enableStaticIP - 1       
        StartService = $enableStartService - 1
	}

    <#
    Note, the above properties will give the following "task status" when running through the script later on:
    -1 = disabled
     0 = enabled, not done
     1 = enabled, done

    From this I can say, if all previous tasks are not equal to 0, they are either done or disabled so go ahead...
    If the current task is equal to 0, it is not done and needs doing...

    You may understand this better when you see the following code at the beggining of each task later in the script (example):
    $vmStatus | where {($_.Cloned -ne 0) -and ($_.PoweredOn -ne 0) -and ($_.InAD -ne 0) -and ($_.ActivateWin -eq 0)} | foreach {
    #>
	
	# create object and add to collection
	$obj = New-Object -TypeName PSObject -Property $properties
	$vmStatus += $obj
	
	# increase counters
	$vmNumber++
	$vmCounter++
}

$vmStatus | select MachineName, IpAddress, Datastore

###################
# Prepare to start deploying VMs
###################

# prepare VM deploy job command
$job= {
	Set-Location $args[0]
	powershell -command ".\DeployVM.ps1 -session $($args[1]) -vcserver $($args[2]) -name $($args[3]) -datastore $($args[4]) -ipaddr $($args[5]) -template `'$($args[6])`' -folder `'$($args[7])`'"
}

# clear job list
Get-Job | Remove-Job

###################
# Start job processing loop - this is the main script
###################

Write-Host "---------------------------------------------------"
Write-Host "Starting build process..."
Write-Host "---------------------------------------------------"

# loop here while there are VMs still to be built, or jobs are still running (following loop monitors jobs and starts new jobs)
while ($vmsCompleted.Count -lt $vmQuantity) {

	###################
	# Initiate VM cloning, using $maxConcurrentJobs as the limit
	###################
	
	# do not start job if $maxConcurrentJobs are already running, do not start if all VMs are now cloned (clone initiated) - skip this task
	if (($vmsCloneInitiated.Count -lt $vmQuantity) -and ($runningJobCount -lt $maxConcurrentJobs)) {
	    
        # select VMs which have not yet been cloned - and only the first $maxConcurrentJobs VMs
        $vmStatus | where {($_.Cloned -eq 0)} | Select-Object -first $maxConcurrentJobs | foreach {

		    Write-Host "$($_.MachineName): Cloning onto datastore: $($_.Datastore)"
		
		    # create job
		    Start-Job -Name $_.MachineName -ScriptBlock $job -ArgumentList $currentPath, $session, $vcserver, $_.MachineName, $_.Datastore, $_.IpAddress, $template, $folder		
		
		    # update vmStatus object collection
		    $_.CloneInitiated = 1
        }
	}
	
	###################
	# Check running job count and look for VMs which have finished cloning
	###################

	# count current running jobs
	$jobs = Get-Job 
	$runningJobs = $jobs | ? { $_.state -eq "Running" }
	$runningJobCount = $runningJobs.count
	
	# check for vms which have finished cloning
	$completedJobs = $jobs | ? { $_.state -eq "Completed" }	
	
	# update $vmStatus
	foreach ($completedJob in $completedJobs) {
	
		# get index of object and set cloned to 1
		$vmStatusIndex = 0..($vmStatus.Count -1) | where {$vmStatus[$_].MachineName -eq $completedJob.Name}
		$vmStatus[$vmStatusIndex].Cloned = 1
		#Remove-Job $completedJob.Name
	}
	
	###################
	# Power on VMs which have finished cloning
	###################
	
    if($enableAutoPowerOn) {
	    $vmStatus | where {($_.Cloned -ne 0) -and ($_.PoweredOn -eq 0)} | foreach {
	
		    Write-Host "$($_.MachineName): Clone completed, powering on..."
		
		    # start the VM
		    Start-VM $_.MachineName
		
		    # update $vmStatus
		    $_.PoweredOn = 1
	    }
    }	

	###################
	# Wait for VM to arrive in AD and move to correct OU
	###################
	
    if($enableMoveToAdOu) {
	    $vmStatus | where {($_.Cloned -ne 0) -and ($_.PoweredOn -ne 0) -and ($_.InAD -eq 0)} | foreach {
	
		    # check computer is in AD
		    $computerExist = try {
			    Get-ADComputer $_.MachineName
		    } catch {
			    $null
		    }

		    if($computerExist -ne $null) {
		
			    Write-Host "$($_.MachineName): Found in AD, moving to correct OU..."
			
			    # move VM to correct OU
			    $vmADComputer = Get-ADComputer $_.MachineName
			    Move-ADObject -Identity $vmADComputer.objectguid -TargetPath $adOrganisationUnit
			
			    # update $vmStatus
			    $_.InAD = 1
		    }
	    }
	}
        

	###################
	# Activate Windows for VMs which are in AD and online (pingable)
	###################
	
    if($enableActivateWindows) {
	    $vmStatus | where {($_.Cloned -ne 0) -and ($_.PoweredOn -ne 0) -and ($_.InAD -ne 0) -and ($_.ActivateWin -eq 0)} | foreach {
	
		    # check machine is online
		    if (Test-Connection $_.MachineName -Count 1 -ErrorAction SilentlyContinue) {
		
			    Write-Host "$($_.MachineName): Activating Windows..."
			
			    # activate Windows
			    if(Register-Computer -Server $_.MachineName) {
				    Write-Host "$($_.MachineName): Activation successful! "
				
				    # update $vmStatus
				    $_.ActivateWin = 1

			    } else {
				    Write-Host "$($_.MachineName): Activation unsuccessful, will try again"
			    }
		    }
	    }
	}

	###################
	# Activate Microsoft Office for VMs have had Windows activated
	###################
	
    if($enableActivateOffice) {
	    $vmStatus | where {($_.Cloned -ne 0) -and ($_.PoweredOn -ne 0) -and ($_.InAD -ne 0) -and ($_.ActivateWin -ne 0) -and ($_.ActivateOffice -eq 0)} | foreach {
	
		    # check machine is online
		    if (Test-Connection $_.MachineName -Count 1 -ErrorAction SilentlyContinue) {
		
			    Write-Host "$($_.MachineName): Activating Microsoft Office..."
			
			    # activate Office
			    cscript 'C:\Program Files (x86)\Microsoft Office\Office14\OSPP.VBS' /act $_.MachineName
			
			    # update $vmStatus
			    $_.ActivateOffice = 1
		    }
	    }
    }	

	###################
	# Set correct IP address for VMs and start Citrix service
	###################
	
    if($enableStaticIP) {
	$vmStatus | where {($_.Cloned -ne 0) -and ($_.PoweredOn -ne 0) -and ($_.InAD -ne 0) -and ($_.ActivateWin -ne 0) -and ($_.ActivateOffice -ne 0) -and ($_.ReIP -eq 0)} | foreach {
	
		# check machine is online
		if (Test-Connection $_.MachineName -Count 1 -ErrorAction SilentlyContinue) {
		
			Write-Host "$($_.MachineName): Online, changing IP address"
			
			# change IP settings
			try {
				Get-VM -Name $_.MachineName | Get-VMGuestNetworkInterface `
					-Guestuser $localAdminUser `
					-GuestPassword $localAdminPassword | `
						? { $_.name -like $localNICNameQuery } | `
							Set-VMGuestNetworkInterface `
								-Guestuser $localAdminUser `
								-GuestPassword $localAdminPassword `
								-IPPolicy static `
								-IP $_.IpAddress `
								-Netmask $networkSubnet  `
								-Gateway $networkGateway `
								-DNS $networkDns

				Write-Host "$($_.MachineName): IP Address changed"
				
				# flush dns
				ipconfig /flushdns
                Start-Sleep 10

        		# update $vmStatus	
				$_.ReIP = 1
			}
			catch {
                $null
			}
		}
	}
    }

	###################
	# Start service
	###################
	
    if($enableStartService) {
	    $vmStatus | where {($_.Cloned -ne 0) -and ($_.PoweredOn -ne 0) -and ($_.InAD -ne 0) -and ($_.ActivateWin -ne 0) -and ($_.ActivateOffice -ne 0) -and ($_.ReIP -ne 0) -and ($_.StartService -eq 0)} | foreach {
	
		    # check machine is online
		    if (Test-Connection $_.MachineName -Count 1 -ErrorAction SilentlyContinue) {
                Write-Host "$($_.MachineName): Starting service: $serviceToStart..."
                Enable-CitrixService -server $_.MachineName
                $_.StartService = 1
		    }
	    }
    }
	
	###################
	# Update counters and sleep
	###################
	
	# update counters
	[ARRAY]$vmsCloneInitiated = $vmStatus | ? CloneInitiated -eq 1
	[ARRAY]$vmsCompleted = $vmStatus | ? {($_.Cloned -ne 0) -and ($_.PoweredOn -ne 0) -and ($_.InAD -ne 0) -and ($_.ActivateWin -ne 0) -and ($_.ActivateOffice -ne 0) -and ($_.ReIP -ne 0) -and ($_.StartService -ne 0)}
	
	# sleep for $cycleTime seconds
	Start-Sleep $cycleTime
}


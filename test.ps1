Write-Host "---------------------------------------------------"
Write-Host "Updating DNS Entries ..."
Write-Host "---------------------------------------------------"



Invoke-Command -ComputerName CL02-INFRA-V001 -ScriptBlock {Get-Process}

Enter-pssession -ComputerName CL02-INFRA-V001
Add-DnsServerResourceRecordA -ZoneName oscaroad.com -Name "test" -IPv4Address 192.168.141.199
exit-pssession
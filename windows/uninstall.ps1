# Removes the PaneLink service, firewall rules and program files. Keeps C:\ProgramData\PaneLink
# (logs, pairings, fan hooks) unless -Purge is given.
param([switch]$Purge)
$ErrorActionPreference = 'Continue'
if (Get-Service PaneLink -EA 0) { Stop-Service PaneLink -Force; sc.exe delete PaneLink | Out-Null }
Get-Process panelink -EA 0 | Stop-Process -Force
Get-NetFirewallRule -DisplayName 'PaneLink*' -EA 0 | Remove-NetFirewallRule
Start-Sleep -Milliseconds 500
Remove-Item -Recurse -Force 'C:\Program Files\PaneLink' -EA 0
if ($Purge) { Remove-Item -Recurse -Force 'C:\ProgramData\PaneLink' -EA 0 }
Write-Host 'PaneLink removed.'

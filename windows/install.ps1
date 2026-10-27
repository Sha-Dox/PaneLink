# Installs PaneLink as a Windows service (LocalSystem, starts at boot) so it works on the lock screen
# and with nobody logged in. Firewall: LAN + Tailscale only. Run Install.cmd (it asks for admin).
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
Get-ChildItem $src | Unblock-File   # downloaded zip: drop the 'from the internet' mark
$dst = 'C:\Program Files\PaneLink'
$exe = "$dst\panelink.exe"

# remove the old per-user logon task (v1) and any running copies
Unregister-ScheduledTask -TaskName 'PaneLink Agent' -Confirm:$false -EA 0
if (Get-Service PaneLink -EA 0) { Stop-Service PaneLink -Force -EA 0 }
Get-Process panelink -EA 0 | Stop-Process -Force
Start-Sleep -Milliseconds 500
New-Item -ItemType Directory -Force $dst | Out-Null
Copy-Item "$src\*" $dst -Force -Exclude 'Install.cmd'

# pairing tokens: SYSTEM + Administrators only
$priv = 'C:\ProgramData\PaneLink\private'
New-Item -ItemType Directory -Force $priv | Out-Null
icacls $priv /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

if (-not (Get-Service PaneLink -EA 0)) {
  New-Service -Name PaneLink -BinaryPathName "`"$exe`" service" -DisplayName 'PaneLink display receiver' -StartupType Automatic -Description 'Shows the Mac displays streamed by PaneLink (works on the lock screen).' | Out-Null
}
sc.exe failure PaneLink reset= 60 actions= restart/1000/restart/1000/restart/5000 | Out-Null

Get-NetFirewallRule -DisplayName 'PaneLink*' -EA 0 | Remove-NetFirewallRule
$remote = @('LocalSubnet', '100.64.0.0/10')   # LAN + Tailscale
New-NetFirewallRule -DisplayName 'PaneLink (TCP)' -Direction Inbound -Program $exe -Protocol TCP -LocalPort 49500 -RemoteAddress $remote -Action Allow -Profile Any | Out-Null
New-NetFirewallRule -DisplayName 'PaneLink (UDP)' -Direction Inbound -Program $exe -Protocol UDP -LocalPort 49500,49510-49525 -RemoteAddress $remote -Action Allow -Profile Any | Out-Null

Start-Service PaneLink
Start-Sleep 1
Get-Service PaneLink | Select Name, Status, StartType
Write-Host "`nPaneLink is installed. On your Mac, open PaneLink and pick '$env:COMPUTERNAME' to pair."

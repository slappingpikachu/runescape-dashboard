# One-time setup so the dashboard opens on your phone over your home Wi-Fi.
# Needs admin (Windows asks once). Only devices on the same network can connect.
#   Enable:  right-click > Run with PowerShell   (or double-click enable-phone-access.bat)
#   Undo:    powershell -ExecutionPolicy Bypass -File tools\enable-phone-access.ps1 -Undo
param([switch]$Undo)
$Port = 8765
$Rule = "OSRS dashboard (phone access)"

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
  $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
  if ($Undo) { $argList += "-Undo" }
  Start-Process powershell -Verb RunAs -ArgumentList $argList
  exit
}

# "Everyone" by SID so it also works on non-English Windows
$everyone = (New-Object Security.Principal.SecurityIdentifier("S-1-1-0")).Translate([Security.Principal.NTAccount]).Value

if ($Undo) {
  netsh http delete urlacl url=http://+:$Port/ | Out-Null
  netsh advfirewall firewall delete rule name="$Rule" | Out-Null
  Write-Host "Phone access removed. Restart start.bat." -ForegroundColor Yellow
} else {
  netsh http delete urlacl url=http://+:$Port/ 2>$null | Out-Null
  netsh http add urlacl url=http://+:$Port/ user="$everyone" | Out-Null
  netsh advfirewall firewall delete rule name="$Rule" 2>$null | Out-Null
  # Only devices on your local network (remoteip=localsubnet), nothing from the internet
  netsh advfirewall firewall add rule name="$Rule" dir=in action=allow protocol=TCP localport=$Port remoteip=localsubnet profile=any | Out-Null

  # Restart the dashboard so it starts listening on the network
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*runescape-dashboard*server.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
  $project = Split-Path $PSScriptRoot -Parent
  Start-Process powershell -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$project\server.ps1`"", "-NoBrowser"

  $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254*" } | ForEach-Object { $_.IPAddress }
  Write-Host "Phone access is on. On your phone (same Wi-Fi), open:" -ForegroundColor Green
  foreach ($ip in $ips) { Write-Host "  http://${ip}:$Port/" -ForegroundColor Green }
}
Write-Host ""
Read-Host "Press Enter to close"

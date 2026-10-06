# Установка (PowerShell от имени администратора): задача планировщика "OpenWRT-Gateway-Watchdog".
#   - запускается от вашего пользователя (VirtualBox хранит VM в профиле пользователя, под SYSTEM VM не видна), с повышенными правами, без запроса UAC;
#   - при входе в Windows и каждую минуту; окно не показывается (через wscript + watchdog-hidden.vbs).
# Удаление: Unregister-ScheduledTask -TaskName OpenWRT-Gateway-Watchdog -Confirm:$false
$dir  = $PSScriptRoot
$user = "$env:USERDOMAIN\$env:USERNAME"
$vbs  = Join-Path $dir 'watchdog-hidden.vbs'
$ps1  = Join-Path $dir 'gateway-watchdog.ps1'
$vbsText = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""' + $ps1 + '""", 0, False'
[System.IO.File]::WriteAllText($vbs, $vbsText, (New-Object System.Text.ASCIIEncoding))

$action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"' + $vbs + '"')
$t1        = New-ScheduledTaskTrigger -AtLogOn -User $user
$t2        = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' -Action $action -Trigger @($t1, $t2) -Principal $principal -Settings $settings -Force | Out-Null
Get-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' | Select-Object TaskName, State
Write-Host "Готово. Лог сторожа: $env:ProgramData\win-gateway\watchdog.log"

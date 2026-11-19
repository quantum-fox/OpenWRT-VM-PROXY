# Пауза виртуального роутера: Windows работает через ФИЗИЧЕСКИЙ роутер (Wi-Fi или кабель), VM OpenWRT выключена и сама не запускается. Запускать от имени администратора.
#   1) выключает шлюз Windows (маршруты и DNS возвращаются как обычно, флаг "шлюз включён" снимается);
#   2) отключает задачу сторожа OpenWRT-Gateway-Watchdog (иначе она через минуту запустит VM снова);
#   3) корректно выключает VM OpenWRT (кнопка питания гостя, через 60 с - принудительно).
# Вернуть как было: vm-resume.ps1
. "$PSScriptRoot\gateway-lib.ps1"
Assert-Admin
Disable-Gateway
Write-Host 'Шлюз Windows выключен.'
if (Get-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' -ErrorAction SilentlyContinue) {
  Disable-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' | Out-Null
  Write-Host 'Сторож отключён (VM сама не запустится).'
} else { Write-Host 'Задачи сторожа нет - пропускаю.' }
if (Test-VmRunning) {
  & $script:VBox controlvm $script:VmName acpipowerbutton 2>&1 | Out-Null
  for ($i = 0; $i -lt 30 -and (Test-VmRunning); $i++) { Start-Sleep -Seconds 2 }
  if (Test-VmRunning) { & $script:VBox controlvm $script:VmName poweroff 2>&1 | Out-Null; Write-Host 'VM не выключилась сама - выключена принудительно.' }
  else { Write-Host 'VM OpenWRT выключена.' }
} else { Write-Host 'VM OpenWRT уже выключена.' }
# 4) адаптер VirtualBox Host-Only с адресом 10.99.77.x выключаем: если физический роутер тоже раздаёт 10.99.77.x (pw2-lan-ip), два адаптера в одной подсети ломают маршрутизацию
$ho = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '10.99.77.*' } | ForEach-Object { (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'VirtualBox Host-Only' }).Name } | Where-Object { $_ })
if ($ho) {
  New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
  $ho | Set-Content -Path (Join-Path $script:StateDir 'disabled-adapters.txt') -Encoding UTF8
  $ho | ForEach-Object { Disable-NetAdapter -Name $_ -Confirm:$false; Write-Host "Адаптер '$_' (Host-Only) выключен." }
}
Write-Host ''
Write-Host 'Теперь подключайтесь к Wi-Fi физического роутера (или кабелем) - интернет пойдёт через него. Включить VM обратно: vm-resume.ps1'

# Вернуть виртуальный роутер: включает сторож, запускает VM OpenWRT и (по умолчанию) шлюз Windows. Запускать от имени администратора.
#   .\vm-resume.ps1              # сторож + VM + шлюз Windows
#   .\vm-resume.ps1 -NoGateway   # только сторож и VM (шлюз позже: gateway-on.ps1)
# Перед этим отключитесь от Wi-Fi физического роутера, иначе Windows будет выходить в интернет двумя путями.
param([switch]$NoGateway)
. "$PSScriptRoot\gateway-lib.ps1"
Assert-Admin
if (Get-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' -ErrorAction SilentlyContinue) {
  Enable-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' | Out-Null
  Write-Host 'Сторож включён.'
}
$state = Join-Path $script:StateDir 'disabled-adapters.txt'      # адаптеры Host-Only, выключенные в vm-pause
if (Test-Path $state) {
  Get-Content $state | Where-Object { $_ } | ForEach-Object { Enable-NetAdapter -Name $_ -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "Адаптер '$_' (Host-Only) включён." }
  Remove-Item $state -Force; Start-Sleep -Seconds 3
}
if (-not (Test-VmRunning)) {
  & $script:VBox startvm $script:VmName --type headless 2>&1 | Out-Null
  Write-Host 'VM OpenWRT запускается...'
} else { Write-Host 'VM OpenWRT уже запущена.' }
if ($NoGateway) { Write-Host 'Шлюз Windows не включаю (-NoGateway). Включить: gateway-on.ps1'; exit 0 }
for ($i = 0; $i -lt 60 -and -not (Test-Gateway); $i++) { Start-Sleep -Seconds 3 }     # до 3 минут: роутер загружается
if (-not (Test-Gateway)) { Write-Host 'Роутер пока не отвечает. Сторож включит шлюз сам, как только он загрузится (если ранее шлюз был включён через gateway-on.ps1).'; exit 0 }
Enable-Gateway
Write-Host 'Шлюз Windows включён: интернет идёт через VM OpenWRT.'

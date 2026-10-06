# Сторож. Запускается планировщиком от имени ВАШЕГО пользователя (с повышенными правами): при входе в Windows и каждую минуту.
#   1) Всегда: если VM OpenWRT не запущена - запускает её (headless). Т.е. роутер стартует вместе с Windows.
#   2) Если шлюз включён (есть файл enabled, его создаёт gateway-on.ps1; удаляет gateway-off.ps1):
#        - OpenWRT отвечает, маршрутов нет        -> включает шлюз (после самопроверки интернета);
#        - маршруты есть, но DNS "уехал" (смена Wi-Fi) -> возвращает DNS на роутер;
#        - OpenWRT НЕ отвечает                    -> FAIL-OPEN: выключает маршруты/DNS, интернет работает напрямую (без пула/USA).
#   Если запущен Throne - шлюз не трогает (конфликт маршрутов).
# Лог: C:\ProgramData\win-gateway\watchdog.log
. "$PSScriptRoot\gateway-lib.ps1"
$log = Join-Path $script:StateDir 'watchdog.log'
function W($m) { New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null; Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format s), $m); if ((Get-Item $log).Length -gt 200KB) { Get-Content $log -Tail 200 | Set-Content $log } }

# --- 1. VM
if (-not (Test-VmRunning)) {
  W "VM $($script:VmName) не запущена - запускаю"
  & $script:VBox startvm $script:VmName --type headless 2>&1 | Out-Null
  exit 0                                                         # дать роутеру загрузиться; следующий запуск (через минуту) займётся шлюзом
}

# --- 1б. WAN роутера: нет маршрута по умолчанию 3 минуты подряд (залипший мост VirtualBox) -> перезапуск VM, не чаще раза в 15 минут (см. Invoke-WanRecovery в gateway-lib.ps1)
if (Test-Gateway) { if (Invoke-WanRecovery -Alias 'openwrt' -Key 'wan' -Log { param($m) W $m }) { exit 0 } }

# --- 2. шлюз
if (-not (Test-Path $script:FlagFile)) { exit 0 }
if (Test-ThroneUp) { exit 0 }

if (Test-Gateway) {
  if (-not (Test-GatewayActive)) {
    try { Enable-Gateway; W 'OpenWRT доступен - шлюз включён, интернет проверен' } catch { W "не удалось включить: $($_.Exception.Message)" }
  } else {
    try { [void](Set-GatewayDns) } catch {}
  }
} else {
  if (Test-GatewayActive) { Disable-Gateway -KeepFlag; W 'OpenWRT НЕ отвечает - FAIL-OPEN: шлюз временно выключен, интернет напрямую' }
}

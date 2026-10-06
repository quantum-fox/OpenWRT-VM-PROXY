# Включить "вся система через OpenWRT" (от имени администратора). Откат: gateway-off.ps1
# Перед запуском закройте Throne (иначе конфликт маршрутов), либо добавьте -Force.
# После успешного включения сторож (install-watchdog-task.ps1) поддерживает шлюз включённым и после перезагрузки Windows.
param([switch]$Force)
. "$PSScriptRoot\gateway-lib.ps1"
try {
  Enable-Gateway -Force:$Force
} catch {
  Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
  exit 1
}
Write-Host 'Шлюз включён, интернет проверен.' -ForegroundColor Green
try { Write-Host ('Внешний IP сейчас (общий трафик, узел из пула): ' + (Invoke-RestMethod -Uri 'https://icanhazip.com' -TimeoutSec 15)) } catch { Write-Host 'Внешний IP определить не удалось.' }
Write-Host 'Отключить: gateway-off.ps1'

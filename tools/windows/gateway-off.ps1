# Выключить шлюз: убрать маршруты через OpenWRT, вернуть DNS по DHCP. Запускать от имени администратора.
. "$PSScriptRoot\gateway-lib.ps1"
Disable-Gateway
Write-Host 'Шлюз выключен. Маршрутизация и DNS как обычно.'

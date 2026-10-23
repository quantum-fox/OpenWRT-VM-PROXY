# Подключить проводной порт компьютера к сети роутера: устройства, подключённые к этому порту (кабелем напрямую или через свитч), получают адрес по DHCP (10.99.88.x, шлюз и DNS - роутер) и интернет через прокси БЕЗ настройки.
# Запускать от администратора. ВНИМАНИЕ: перезагружает роутер (простой ~1-2 минуты; у Windows сработает fail-open).
#   .\lan-port.ps1                                  # порт определяется сам (проводной адаптер, который сейчас подключён)
#   .\lan-port.ps1 -Adapter "Realtek PCIe GbE Family Controller"   # конкретный адаптер (имя из Get-NetAdapter, столбец InterfaceDescription)
#   .\lan-port.ps1 -Address 192.168.100.1/24        # роутер получает этот адрес в сети порта, DHCP на порту выключен: для устройств со СТАТИЧЕСКИМИ адресами 192.168.100.x и шлюзом 192.168.100.1
#   .\lan-port.ps1 -Remove                          # убрать порт обратно (VM без третьей карты)
# Что делает: отключает сторожа -> сохраняет параметры VM -> ssh poweroff -> VBoxManage modifyvm (третья карта VM = мост на проводной адаптер) -> старт -> в роутере pw2-lan add eth2 [адрес] (порт - отдельная сеть роутера) -> проверка (SSH, интернет роутера, порт в LAN) -> при неудаче ОТКАТ.
# Ограничения: только ПРОВОДНОЙ адаптер (мост VirtualBox на Wi-Fi не пропускает чужие MAC-адреса); к порту нельзя подключать сеть со своим DHCP-сервером (домашний роутер); при выключенном компьютере устройства остаются без интернета.
param([string]$Adapter = '', [string]$Address = '', [switch]$Remove)
. "$PSScriptRoot\gateway-lib.ps1"
Assert-Admin
$vb = $script:VBox; $vm = $script:VmName
$logDir = Join-Path $env:ProgramData 'win-gateway'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
& $vb showvminfo $vm --machinereadable | Set-Content (Join-Path $logDir "vm-before-lanport-$ts.txt") -Encoding UTF8
Write-Host "Параметры VM до изменений сохранены: $logDir\vm-before-lanport-$ts.txt"
$cur = & $vb showvminfo $vm --machinereadable
$prevNic3 = ($cur | Select-String '^nic3="([^"]+)"').Matches | ForEach-Object { $_.Groups[1].Value }
$prevBr3 = ($cur | Select-String '^bridgeadapter3="([^"]+)"').Matches | ForEach-Object { $_.Groups[1].Value }

if (-not $Remove) {
  if (-not $Adapter) {
    $c = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -eq '802.3' -and $_.InterfaceDescription -notmatch 'VirtualBox|TAP|VPN|Bluetooth|Wireless|Wi-?Fi|Hyper-V|Virtual' } | Select-Object -First 1
    if (-not $c) { throw 'Не найден подключённый проводной адаптер. Укажите: -Adapter "<InterfaceDescription из Get-NetAdapter>"' }
    $Adapter = $c.InterfaceDescription
  }
  $found = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -eq $Adapter }
  if (-not $found) { throw "Адаптер '$Adapter' не найден (Get-NetAdapter)." }
  if ($found.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11') { throw 'Wi-Fi-адаптер не подходит: мост VirtualBox на Wi-Fi не пропускает чужие MAC-адреса. Нужен проводной адаптер.' }
  $wanBridge = ($cur | Select-String '^bridgeadapter2="([^"]+)"').Matches | ForEach-Object { $_.Groups[1].Value }
  if ($wanBridge -eq $Adapter) { throw "Этот адаптер уже используется как WAN роутера (мост nic2). Выберите другой." }
  Write-Host "Проводной адаптер: $Adapter"
}

function Stop-Vm {
  ssh openwrt "sync; poweroff" 2>$null | Out-Null
  $t = 0; while ((& $vb list runningvms) -match ('"' + $vm + '"') -and $t -lt 60) { Start-Sleep 2; $t += 2 }
  if ((& $vb list runningvms) -match ('"' + $vm + '"')) { & $vb controlvm $vm poweroff 2>&1 | Out-Null; Start-Sleep 3 }
}
function Start-VmWait {
  & $vb startvm $vm --type headless 2>&1 | Out-Null
  for ($i = 0; $i -lt 60; $i++) { Start-Sleep 3; if ((Test-Connection $script:Gw -Count 1 -Quiet -ErrorAction SilentlyContinue)) { break } }
  Start-Sleep 10
}
function Test-Wan {   # WAN роутера поднят: есть маршрут по умолчанию (ping/HTTP наружу не годятся: мобильный оператор и белые списки их режут)
  for ($i = 0; $i -lt 18; $i++) { ssh -o BatchMode=yes -o ConnectTimeout=6 openwrt "ip route | grep -q '^default'" 2>$null; if ($LASTEXITCODE -eq 0) { return $true }; Start-Sleep 5 }
  return $false
}

$task = Get-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' -ErrorAction SilentlyContinue
$ok = $false
try {
  if ($task) { Disable-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' | Out-Null }
  if ($Remove) {
    Write-Host 'Убираю порт из LAN роутера...'
    ssh openwrt 'pw2-lan del eth2' 2>$null
  }
  Write-Host 'Останавливаю роутер...'; Stop-Vm
  if ($Remove) { & $vb modifyvm $vm --nic3 none 2>&1 | Out-Null }
  else { & $vb modifyvm $vm --nic3 bridged --bridgeadapter3 $Adapter --nictype3 virtio --cableconnected3 on 2>&1 | Out-Null }
  Write-Host 'Запускаю...'; Start-VmWait
  if (-not $Remove) {
    $a = if ($Address) { " $Address" } else { '' }
    ssh openwrt "pw2-lan add eth2$a" 2>$null | Select-Object -Last 3 | ForEach-Object { Write-Host $_ }
  }
  # проверка по ASCII-выводу (кириллица из ssh в PowerShell 5.1 приходит в другой кодировке): у eth2 есть адрес роутера
  $st = ssh -o BatchMode=yes -o ConnectTimeout=8 openwrt "ip -br addr show eth2 2>&1 | tr -s ' '" 2>$null
  $st | ForEach-Object { Write-Host $_ }
  $portOk = if ($Remove) { -not ($st -match 'eth2\s+\S+\s+\d') } else { [bool]($st -match 'eth2\s+\S+\s+\d+\.\d+\.\d+\.\d+') }
  $ok = $portOk -and (Test-Wan)
  if (-not $ok) {
    Write-Host 'ПРОВЕРКА НЕ ПРОШЛА - ОТКАТ к прежним параметрам VM' -ForegroundColor Red
    & $vb controlvm $vm poweroff 2>&1 | Out-Null; Start-Sleep 4
    if ($prevNic3 -eq 'bridged' -and $prevBr3) { & $vb modifyvm $vm --nic3 bridged --bridgeadapter3 $prevBr3 2>&1 | Out-Null } else { & $vb modifyvm $vm --nic3 none 2>&1 | Out-Null }
    Start-VmWait
    ssh -o BatchMode=yes openwrt 'pw2-lan del eth2 >/dev/null 2>&1' 2>$null | Out-Null     # убрать из настроек роутера следы порта, которого в VM больше нет
    exit 1
  }
  if ($Remove) { Write-Host 'Готово: порт убран, VM снова с двумя сетевыми картами.' -ForegroundColor Green }
  else {
    Write-Host "Готово: проводной порт ($Adapter) в сети роутера." -ForegroundColor Green
    Write-Host 'Подключите устройство к этому порту: оно получит адрес по DHCP (без -Address: 10.99.88.x, шлюз и DNS 10.99.88.1; с -Address - ваш статический адрес) и выйдет в интернет через прокси без настройки.'
    Write-Host 'Проверка на устройстве: https://ifconfig.me (адрес сервера из пула). Вернуть как было: .\lan-port.ps1 -Remove'
  }
} finally {
  if ($task) { Enable-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' | Out-Null }
}

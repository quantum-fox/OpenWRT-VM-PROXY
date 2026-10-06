# Общие функции для gateway-on / gateway-off / gateway-watchdog.
# Идея: Win10 направляет ВЕСЬ IPv4-трафик и DNS на OpenWRT (10.99.77.1) через host-only адаптер VirtualBox;
# PassWall2 на OpenWRT прозрачно заворачивает его в прокси-узел (по умолчанию - пул). Приложения ничего настраивать не нужно.
# Файл в UTF-8 С BOM (иначе Windows PowerShell 5.1 ломает кириллицу).
$script:Gw        = '10.99.77.1'                                   # LAN-адрес OpenWRT
$script:VmName    = 'OpenWRT'
$script:VBox      = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$script:StateDir  = Join-Path $env:ProgramData 'win-gateway'
$script:StateFile = Join-Path $StateDir 'state.json'                   # что восстанавливать при выключении
$script:FlagFile  = Join-Path $StateDir 'enabled'                      # есть файл = шлюз должен быть включён (для сторожа)
$script:Prefixes  = @('0.0.0.0/1', '128.0.0.0/1')                      # две половины "default", перебивают обычный 0.0.0.0/0

function Assert-Admin {
  $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Запустите PowerShell от имени администратора.' }
}

function Get-HostOnlyIfIndex {          # адаптер host-only: тот, у которого адрес 10.99.77.x (подсеть OpenWRT)
  $a = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '10.99.77.*' -and $_.IPAddress -ne $script:Gw } | Select-Object -First 1
  if (-not $a) { throw "Не найден адаптер с адресом 10.99.77.x (VirtualBox Host-Only). Запущена ли VM '$($script:VmName)'?" }
  return $a.InterfaceIndex
}

function Get-WifiIfIndex {              # внешний физический адаптер, смотрящий в интернет (Wi-Fi или кабель; для DNS)
  $n = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'VirtualBox|Virtual|Hyper-V|TAP|Bluetooth' } | Select-Object -First 1
  if ($n) { return $n.ifIndex } else { return $null }
}

function Test-Gateway { return (Test-Connection -ComputerName $script:Gw -Count 2 -Quiet -ErrorAction SilentlyContinue) }

function Test-VmRunning {
  if (-not (Test-Path $script:VBox)) { return $false }
  return [bool]((& $script:VBox list runningvms) -match ('"' + $script:VmName + '"'))
}

function Get-ConflictingAdapters {      # активные TUN/VPN-адаптеры (Throne/sing-tun, Clash, WireGuard, OpenVPN, Outline, TAP/Wintun) - их маршруты конфликтуют со шлюзом
  Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'sing-tun|Wintun|TAP-Windows|TAP-Win32|WireGuard|OpenVPN|Clash|Mihomo|Meta Tunnel|Outline|VPN Client' } | ForEach-Object { $_.Name }
}
function Test-ThroneUp { return [bool]@(Get-ConflictingAdapters).Count }

function Test-LanOverlap {              # внешняя сеть (Wi-Fi/Ethernet) в той же подсети 10.99.77.0/24, что LAN роутера -> конфликт адресов
  $hostOnly = $null; try { $hostOnly = Get-HostOnlyIfIndex } catch {}
  $o = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '10.99.77.*' -and $_.InterfaceIndex -ne $hostOnly }
  return [bool]$o
}

function Test-Internet {                # есть ли интернет прямо сейчас (проверка и DNS, и TCP)
  foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt', 'https://icanhazip.com') {
    try { $r = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 12; if ($r.StatusCode -eq 200) { return $true } } catch {}
  }
  return $false
}

function Test-GatewayActive {
  return [bool](Get-NetRoute -DestinationPrefix $script:Prefixes[0] -NextHop $script:Gw -ErrorAction SilentlyContinue)
}

function Set-GatewayDns {               # DNS на OpenWRT для host-only и Wi-Fi (иначе утечки/подмена имён)
  $idx = Get-HostOnlyIfIndex; $wifi = Get-WifiIfIndex
  foreach ($i in @($idx, $wifi) | Where-Object { $_ }) {
    $cur = (Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
    if (-not ($cur -and $cur.Count -eq 1 -and $cur[0] -eq $script:Gw)) { Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses $script:Gw }
  }
  Clear-DnsClientCache
  return @{ hostOnly = $idx; wifi = $wifi }
}

function Enable-Gateway {
  param([switch]$Force, [switch]$NoVerify)
  Assert-Admin
  if (-not (Test-Gateway)) { throw "OpenWRT ($($script:Gw)) не отвечает - шлюз НЕ включён (чтобы не потерять интернет)." }
  if (Test-LanOverlap) { throw "Внешняя сеть использует подсеть 10.99.77.x - она совпадает с LAN роутера. Шлюз не включён (см. docswindows-setup.md, раздел 'Ограничения')." }
  if ((Test-ThroneUp) -and -not $Force) { throw ("Активны туннельные адаптеры: " + ((Get-ConflictingAdapters) -join ', ') + " - их маршруты конфликтуют со шлюзом. Закройте Throne/VPN-клиент (затем проверьте Get-NetAdapter) или добавьте -Force.") }
  $idx = Get-HostOnlyIfIndex
  New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
  Set-Content -Path $script:FlagFile -Value '1'                      # желаемое состояние: ВКЛ (сторож будет поддерживать)
  foreach ($p in $script:Prefixes) {
    if (-not (Get-NetRoute -DestinationPrefix $p -InterfaceIndex $idx -ErrorAction SilentlyContinue)) {
      New-NetRoute -DestinationPrefix $p -InterfaceIndex $idx -NextHop $script:Gw -RouteMetric 1 -PolicyStore ActiveStore | Out-Null   # ActiveStore: после перезагрузки Windows исчезает само
    }
  }
  $d = Set-GatewayDns
  @{ hostOnlyIfIndex = $d.hostOnly; wifiIfIndex = $d.wifi; enabledAt = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content -Path $script:StateFile -Encoding UTF8
  if (-not $NoVerify) {
    Start-Sleep 2
    if (-not (Test-Internet)) {
      Disable-Gateway -KeepFlag
      throw 'После включения шлюза интернета нет (PassWall2 на роутере ещё не готов или сломан) - шлюз автоматически выключен. Флаг "включено" сохранён: сторож повторит попытку.'
    }
  }
}

function Disable-Gateway {
  param([switch]$KeepFlag)
  Assert-Admin
  foreach ($p in $script:Prefixes) {
    Get-NetRoute -DestinationPrefix $p -NextHop $script:Gw -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
  }
  $ids = @()
  if (Test-Path $script:StateFile) { $s = Get-Content $script:StateFile -Raw | ConvertFrom-Json; $ids += $s.hostOnlyIfIndex, $s.wifiIfIndex }
  $ids += (Get-WifiIfIndex)
  foreach ($i in ($ids | Where-Object { $_ } | Select-Object -Unique)) { Set-DnsClientServerAddress -InterfaceIndex $i -ResetServerAddresses -ErrorAction SilentlyContinue }
  Clear-DnsClientCache
  if (-not $KeepFlag) { Remove-Item -Path $script:FlagFile -Force -ErrorAction SilentlyContinue }
}

function Ensure-HostOnlyAdapter {       # находит (или создаёт) Host-Only адаптер VirtualBox с заданным адресом хоста; возвращает его имя в VirtualBox
  param([string]$HostIp = '10.99.77.2')
  $vb = $script:VBox; $name = $null; $cand = $null
  foreach ($l in (& $vb list hostonlyifs)) {
    if ($l -match '^Name:\s+(.+)$') { $cand = $Matches[1].Trim() }
    if ($l -match '^IPAddress:\s+(\S+)' -and $Matches[1] -eq $HostIp) { $name = $cand }
  }
  if (-not $name) {
    Assert-Admin
    $before = @(& $vb list hostonlyifs | Where-Object { $_ -match '^Name:' })
    & $vb hostonlyif create | Out-Null
    $after = @(& $vb list hostonlyifs | Where-Object { $_ -match '^Name:' })
    $name = (@($after | Where-Object { $before -notcontains $_ })[0] -replace '^Name:\s+', '').Trim()
    if (-not $name) { throw 'Не удалось создать Host-Only адаптер VirtualBox.' }
    & $vb hostonlyif ipconfig $name --ip $HostIp --netmask 255.255.255.0 | Out-Null
  }
  return $name
}

function Get-DefaultWanAdapter {        # имя физического адаптера (как его видит VirtualBox), через который Windows сейчас выходит в интернет: с лучшей метрикой маршрута по умолчанию, не виртуальный
  $cand = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'VirtualBox|Virtual|Hyper-V|TAP|Bluetooth' }
  $best = $cand | ForEach-Object {
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex $_.ifIndex -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $m = (Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceMetric
    if ($r) { [pscustomobject]@{ Name = $_.InterfaceDescription; Metric = $r.RouteMetric + $m } }
  } | Sort-Object Metric | Select-Object -First 1
  if (-not $best) { throw 'Не найден подключённый физический сетевой адаптер для WAN. Укажите его вручную (-WanAdapter "<имя из VBoxManage list bridgedifs>").' }
  return $best.Name
}

function Test-RouterSsh {               # отвечает ли роутер по SSH-алиасу openwrt (ключ настроен)
  param([string]$Alias = 'openwrt', [int]$Seconds = 6)
  $o = ssh -o BatchMode=yes -o ConnectTimeout=$Seconds $Alias 'echo ok' 2>$null
  return ($o -eq 'ok')
}

function Invoke-VBox {                  # VBoxManage с проверкой кода возврата (ошибка VirtualBox = исключение)
  $ErrorActionPreference = 'Continue'      # VBoxManage пишет прогресс в stderr - это не ошибка
  $out = & $script:VBox @args 2>&1
  if ($LASTEXITCODE -ne 0) { throw ("VBoxManage " + ($args -join ' ') + " -> код $LASTEXITCODE`n" + ($out -join "`n")) }
  return $out
}

function Invoke-WanRecovery {           # Бывает, что после переподключения Wi-Fi хоста (особенно мобильная точка доступа) мост VirtualBox "залипает": роутер отвечает, но у него нет маршрута по умолчанию.
                                         # Лечится перезапуском VM. Три проверки подряд без маршрута -> корректное выключение роутера по SSH (сторож запустит VM сам). Возвращает $true, если выключение запущено.
  param([string]$Alias = 'openwrt', [string]$Key = 'wan', [int]$Threshold = 3, [int]$CooldownMin = 15, [scriptblock]$Log = { param($m) })
  $fail = Join-Path $script:StateDir "$Key-fail.txt"; $last = Join-Path $script:StateDir "$Key-restart.txt"
  New-Item -ItemType Directory -Force -Path $script:StateDir | Out-Null
  $def = ([string](ssh -o BatchMode=yes -o ConnectTimeout=6 $Alias 'ip route | grep -c ^default' 2>$null)).Trim()
  if ($def -match '^\d+$' -and $def -ne '0') { Remove-Item $fail -ErrorAction SilentlyContinue; return $false }
  if ($def -ne '0') { return $false }                                 # SSH не ответил: состояние неизвестно, ничего не делаем
  $n = 1; if (Test-Path $fail) { $n = [int](Get-Content $fail -ErrorAction SilentlyContinue) + 1 }
  Set-Content -Path $fail -Value $n
  if ($n -lt $Threshold) { return $false }
  $prev = if (Test-Path $last) { [datetime](Get-Content $last) } else { [datetime]'2000-01-01' }
  if (((Get-Date) - $prev).TotalMinutes -le $CooldownMin) { return $false }
  & $Log "У роутера ($Alias) нет выхода в сеть (маршрута по умолчанию) $n проверок подряд - перезапускаю VM (мост VirtualBox)"
  Set-Content -Path $last -Value (Get-Date -Format s); Remove-Item $fail -ErrorAction SilentlyContinue
  ssh -o BatchMode=yes -o ConnectTimeout=6 $Alias 'sync; poweroff' 2>$null | Out-Null
  return $true
}

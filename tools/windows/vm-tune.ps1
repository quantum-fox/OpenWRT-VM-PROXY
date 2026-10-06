# Настройка виртуальной машины роутера под нагрузку: больше vCPU, паравиртуальная сеть virtio вместо эмуляции Intel e1000, KVM-паравиртуализация.
# ВНИМАНИЕ: перезагружает роутер (простой ~1-2 минуты: интернет через шлюз/прокси на это время пропадает; у Win10 сработает fail-open). Запускать от администратора.
#   .\vm-tune.ps1                      # 2 vCPU + virtio + kvm (рекомендуется, см. docsm-settings.md)
#   .\vm-tune.ps1 -Cpus 2 -NicType 82540EM    # только добавить vCPU, сеть не менять
#   .\vm-tune.ps1 -MemMB 384            # только изменить объём ОЗУ VM (МБ); остальные параметры не трогать (виртуальные CPU и сеть остаются, -Cpus/-NicType указывайте как сейчас)
#   .\vm-tune.ps1 -Rollback            # вернуть 1 vCPU, e1000 (82540EM), paravirt default
# Что делает: отключает сторожа (иначе он запустит VM во время изменений) -> ssh poweroff -> VBoxManage modifyvm -> старт -> проверка
# (число vCPU, соответствие сетевых карт: eth0 = LAN с MAC 08:00:27:fd:08:3f, адрес br-lan 10.99.77.1, SSH, интернет на WAN) -> при любой неудаче АВТОМАТИЧЕСКИЙ ОТКАТ.
param([int]$Cpus = 2, [ValidateSet('virtio', '82540EM')][string]$NicType = 'virtio', [ValidateSet('kvm', 'default')][string]$Paravirt = 'kvm', [int]$MemMB = 0, [switch]$Rollback)
. "$PSScriptRoot\gateway-lib.ps1"
Assert-Admin
if ($Rollback) { $Cpus = 1; $NicType = '82540EM'; $Paravirt = 'default' }
$vb = $script:VBox; $vm = $script:VmName
$lanMac = '08:00:27:fd:08:3f'
$logDir = Join-Path $env:ProgramData 'win-gateway'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
& $vb showvminfo $vm --machinereadable | Set-Content (Join-Path $logDir "vm-before-$ts.txt") -Encoding UTF8
Write-Host "Параметры VM до изменений сохранены: $logDir\vm-before-$ts.txt"
$cur = & $vb showvminfo $vm --machinereadable
$prev = @{ mem = ($cur | Select-String '^memory=(\d+)').Matches[0].Groups[1].Value
           cpus = ($cur | Select-String '^cpus=(\d+)').Matches[0].Groups[1].Value
           nic1 = ($cur | Select-String '^nictype1="([^"]+)"').Matches[0].Groups[1].Value
           nic2 = ($cur | Select-String '^nictype2="([^"]+)"').Matches[0].Groups[1].Value
           para = ($cur | Select-String '^paravirtprovider="([^"]+)"').Matches[0].Groups[1].Value }
Write-Host ("Было: vCPU {0}, nic1 {1}, nic2 {2}, paravirt {3}" -f $prev.cpus, $prev.nic1, $prev.nic2, $prev.para)

function Stop-Vm {
  ssh openwrt "sync; poweroff" 2>$null | Out-Null
  $t = 0; while ((& $vb list runningvms) -match ('"' + $vm + '"') -and $t -lt 60) { Start-Sleep 2; $t += 2 }
  if ((& $vb list runningvms) -match ('"' + $vm + '"')) { & $vb controlvm $vm poweroff 2>&1 | Out-Null; Start-Sleep 3 }
}
function Start-VmWait {
  & $vb startvm $vm --type headless 2>&1 | Out-Null
  for ($i = 0; $i -lt 60; $i++) { Start-Sleep 3; if ((Test-Connection $script:Gw -Count 1 -Quiet -ErrorAction SilentlyContinue)) { break } }
  Start-Sleep 8
}
function Test-Vm {
  $o = ssh -o BatchMode=yes -o ConnectTimeout=6 openwrt "echo vcpu=`$(grep -c ^processor /proc/cpuinfo); echo mac0=`$(cat /sys/class/net/eth0/address); echo ip=`$(ip -4 addr show br-lan | grep -o 'inet [0-9.]*' | head -1); echo drv0=`$(readlink /sys/class/net/eth0/device/driver | sed 's#.*/##'); echo drv1=`$(readlink /sys/class/net/eth1/device/driver | sed 's#.*/##')" 2>$null
  return $o
}
function Test-Wan {   # интернет на WAN-карте роутера (ping 1.1.1.1), ждём до ~90 с (DHCP после смены карты)
  for ($i = 0; $i -lt 18; $i++) { ssh -o BatchMode=yes -o ConnectTimeout=6 openwrt "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1" 2>$null; if ($LASTEXITCODE -eq 0) { return $true }; Start-Sleep 5 }
  return $false
}
function Apply-Settings($c, $n, $p) {
  & $vb modifyvm $vm --cpus $c --nictype1 $n --nictype2 $n --paravirt-provider $p 2>&1 | Out-Null
  if ($MemMB -gt 0) { & $vb modifyvm $vm --memory $MemMB 2>&1 | Out-Null }
}

$task = Get-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' -ErrorAction SilentlyContinue
try {
  if ($task) { Disable-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' | Out-Null }
  Write-Host 'Останавливаю роутер...'; Stop-Vm
  Write-Host "Применяю: vCPU $Cpus, сеть $NicType, paravirt $Paravirt$(if ($MemMB -gt 0) { ", ОЗУ $MemMB МБ" })"; Apply-Settings $Cpus $NicType $Paravirt
  Write-Host 'Запускаю...'; Start-VmWait
  $res = Test-Vm; Write-Host ($res -join '; ')
  $ok = ($res -match "vcpu=$Cpus") -and ($res -match [regex]::Escape("mac0=$lanMac")) -and ($res -match 'inet 10\.99\.77\.1') -and (Test-Wan)
  if (-not $ok) {
    Write-Host 'ПРОВЕРКА НЕ ПРОШЛА (SSH/адрес/соответствие карт/WAN) - ОТКАТ к прежним параметрам' -ForegroundColor Red
    & $vb controlvm $vm poweroff 2>&1 | Out-Null; Start-Sleep 4
    & $vb modifyvm $vm --cpus $prev.cpus --nictype1 $prev.nic1 --nictype2 $prev.nic2 --paravirt-provider $prev.para --memory $prev.mem 2>&1 | Out-Null
    Start-VmWait; Write-Host ('После отката: ' + ((Test-Vm) -join '; '))
    exit 1
  }
  Write-Host 'Готово. Роутер работает с новыми параметрами.' -ForegroundColor Green
  Write-Host 'Откат при необходимости: .\vm-tune.ps1 -Rollback'
} finally {
  if ($task) { Enable-ScheduledTask -TaskName 'OpenWRT-Gateway-Watchdog' | Out-Null }
}

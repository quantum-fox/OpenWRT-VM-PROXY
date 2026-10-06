# Создание виртуальной машины роутера OpenWrt в VirtualBox "с нуля" (вариант A).
# Запускать от администратора (создаётся сетевой адаптер VirtualBox Host-Only).
#   .\vm-create.ps1                                   # скачает образ OpenWrt, создаст VM "OpenWRT" и сеть 10.99.77.0/24
#   .\vm-create.ps1 -WanAdapter "Realtek PCIe GbE Family Controller"    # WAN-карту выбрать самому (имя из списка VBoxManage list bridgedifs)
#   .\vm-create.ps1 -Image D:\img\openwrt-...-combined-efi.img.gz       # уже скачанный образ
# Что делает: образ -> диск VDI (3 ГБ) -> VM (2 vCPU, virtio, kvm, ОЗУ 384 МБ) -> LAN = отдельный Host-Only адаптер 10.99.77.2/24,
# WAN = мост на ваш сетевой адаптер (Wi-Fi или кабель, который смотрит в интернет). Роутер получит LAN-адрес 10.99.77.1 на первом запуске (см. руководство).
param(
  [string]$Name = 'OpenWRT',
  [string]$Dir = (Join-Path $env:USERPROFILE 'VirtualBox VMs'),
  [string]$Image = '',
  [string]$WanAdapter = '',                 # пусто = автоматически: первый подключённый физический адаптер
  [string]$HostIp = '10.99.77.2',           # адрес Windows в сети роутера (роутер = .1)
  [int]$DiskMB = 3072, [int]$MemMB = 384, [int]$Cpus = 2,
  [string]$Wan = 'bridged',                 # bridged | nat (nat - только для отладки/сборки)
  [int]$SerialPort = 0                      # >0: консоль роутера по TCP localhost:<порт> (для автоматизации)
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\gateway-lib.ps1"
Assert-Admin
$vb = $script:VBox
if (-not (Test-Path $vb)) { throw "Не найден VBoxManage: $vb. Установите VirtualBox 7.x." }
if ((& $vb list vms) -match ('"' + [regex]::Escape($Name) + '"')) { throw "VM '$Name' уже существует. Удалите её или выберите другое имя (-Name)." }

# --- 1. образ
$ver = '23.05.6'; $fname = "openwrt-$ver-x86-64-generic-ext4-combined-efi.img.gz"
$work = Join-Path $env:TEMP 'pw2-vm-create'; New-Item -ItemType Directory -Force -Path $work | Out-Null
if (-not $Image) {
  $Image = Join-Path $work $fname
  if (-not (Test-Path $Image)) { Write-Host "Скачиваю $fname ..."; Invoke-WebRequest -UseBasicParsing "https://downloads.openwrt.org/releases/$ver/targets/x86/64/$fname" -OutFile $Image }
}
$raw = Join-Path $work 'openwrt.img'
Write-Host 'Распаковываю образ...'
$in = [System.IO.File]::OpenRead($Image); $gz = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress); $out = [System.IO.File]::Create($raw)
try { $gz.CopyTo($out) } catch { Write-Host "(предупреждение распаковки: $($_.Exception.Message) - для образов OpenWrt это нормально, если файл получился)" } finally { $out.Close(); $gz.Close(); $in.Close() }
if ((Get-Item $raw).Length -lt 50MB) { throw 'Распакованный образ слишком мал - файл повреждён.' }

# --- 2. диск
$vmDir = Join-Path $Dir $Name; New-Item -ItemType Directory -Force -Path $vmDir | Out-Null
$vdi = Join-Path $vmDir "$Name.vdi"
Invoke-VBox convertfromraw $raw $vdi --format VDI | Out-Null
Invoke-VBox modifymedium disk $vdi --resize $DiskMB | Out-Null
Remove-Item $raw -Force

# --- 3. сеть: отдельный Host-Only адаптер с адресом $HostIp
$hoName = Ensure-HostOnlyAdapter -HostIp $HostIp
if ($Wan -eq 'bridged' -and -not $WanAdapter) { $WanAdapter = Get-DefaultWanAdapter }

# --- 4. VM
Invoke-VBox createvm --name $Name --ostype Linux26_64 --basefolder $Dir --register | Out-Null
Invoke-VBox modifyvm $Name --memory $MemMB --cpus $Cpus --paravirt-provider kvm --boot1 disk --boot2 none --boot3 none --boot4 none --graphicscontroller vmsvga --vram 16 --audio-driver none --usb off --rtcuseutc on | Out-Null
Invoke-VBox modifyvm $Name --nic1 hostonly --hostonlyadapter1 $hoName --nictype1 virtio --cableconnected1 on | Out-Null
if ($Wan -eq 'nat') { & $vb modifyvm $Name --nic2 nat --nictype2 virtio | Out-Null }
else { & $vb modifyvm $Name --nic2 bridged --bridgeadapter2 $WanAdapter --nictype2 virtio | Out-Null }
if ($SerialPort -gt 0) { & $vb modifyvm $Name --uart1 0x3F8 4 --uartmode1 tcpserver $SerialPort | Out-Null }
Invoke-VBox storagectl $Name --name SATA --add sata --controller IntelAhci --portcount 1 --hostiocache on | Out-Null
Invoke-VBox storageattach $Name --storagectl SATA --port 0 --device 0 --type hdd --medium $vdi --nonrotational on | Out-Null
Write-Host ''
Write-Host "Готово: VM '$Name' создана (диск $DiskMB МБ, $Cpus vCPU, $MemMB МБ ОЗУ)." -ForegroundColor Green
Write-Host "  LAN (nic1): Host-Only '$hoName', адрес Windows $HostIp/24"
Write-Host "  WAN (nic2): $(if ($Wan -eq 'nat') { 'NAT' } else { "мост на '$WanAdapter'" })"
Write-Host "Дальше: запустите VM (VBoxManage startvm $Name --type headless  или с окном: --type gui) и следуйте руководству, шаг «Первый запуск»."

# Импорт готового образа роутера (вариант B). Запускать от администратора.
#   .\vm-import.ps1                              # образ ищется в B-ready-image\image\*.ova
#   .\vm-import.ps1 -Ova D:\x\pw2-router.ova -WanAdapter "Intel(R) Wi-Fi 6 AX201 160MHz"
# Делает: проверка контрольной суммы -> импорт VM "OpenWRT" -> LAN = отдельный Host-Only адаптер 10.99.77.2/24 (создаётся) -> WAN = мост на ваш адаптер -> 2 vCPU, virtio, kvm.
param([string]$Ova = '', [string]$Name = 'OpenWRT', [string]$Dir = (Join-Path $env:USERPROFILE 'VirtualBox VMs'),
      [string]$WanAdapter = '', [string]$HostIp = '10.99.77.2', [int]$MemMB = 384, [int]$Cpus = 2)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\gateway-lib.ps1"
Assert-Admin
$vb = $script:VBox
if (-not (Test-Path $vb)) { throw "Не найден VBoxManage: $vb. Установите VirtualBox 7.x." }
if (-not $Ova) { foreach ($c in '..\image', '..\..\B-ready-image\image') { $f = Get-ChildItem (Join-Path $PSScriptRoot $c) -Filter *.ova -ErrorAction SilentlyContinue | Select-Object -First 1; if ($f) { $Ova = $f.FullName; break } } }
if (-not $Ova -or -not (Test-Path $Ova)) { throw 'Файл образа .ova не найден (положите его в B-ready-image\image или укажите -Ova).' }
if ((& $vb list vms) -match ('"' + [regex]::Escape($Name) + '"')) { throw "VM '$Name' уже существует. Удалите её или выберите другое имя (-Name)." }
$sumFile = "$Ova.sha256"
if (Test-Path $sumFile) {
  $want = ((Get-Content $sumFile -Raw).Trim() -split '\s+')[0].ToLower()
  $got = (Get-FileHash $Ova -Algorithm SHA256).Hash.ToLower()
  if ($want -ne $got) { throw "Контрольная сумма образа не совпала (файл повреждён при копировании).`nожидалось $want`nполучено   $got" }
  Write-Host 'Контрольная сумма образа верна.'
}
$hoName = Ensure-HostOnlyAdapter -HostIp $HostIp
if (-not $WanAdapter) { $WanAdapter = Get-DefaultWanAdapter }
Write-Host 'Импортирую образ (1-2 минуты)...'
Invoke-VBox import $Ova --vsys 0 --vmname $Name --basefolder $Dir | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Импорт не удался (см. сообщение VirtualBox выше).' }
Invoke-VBox modifyvm $Name --memory $MemMB --cpus $Cpus --paravirt-provider kvm | Out-Null
Invoke-VBox modifyvm $Name --nic1 hostonly --hostonlyadapter1 $hoName --nictype1 virtio --cableconnected1 on | Out-Null
Invoke-VBox modifyvm $Name --nic2 bridged --bridgeadapter2 $WanAdapter --nictype2 virtio --cableconnected2 on | Out-Null
Write-Host ''
Write-Host "Готово: VM '$Name' импортирована ($Cpus vCPU, $MemMB МБ ОЗУ)." -ForegroundColor Green
Write-Host "  LAN (nic1): Host-Only '$hoName', адрес Windows $HostIp/24"
Write-Host "  WAN (nic2): мост на '$WanAdapter'"
Write-Host "Дальше: VBoxManage startvm $Name --type headless, затем router-ssh-setup.ps1 и pw2-setup (см. руководство)."

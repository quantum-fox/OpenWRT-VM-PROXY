# Загрузка скриптов установки на роутер в /usr/share/pw2 и установка команды pw2-setup.
#   .\install-router.ps1                 # каталог со скриптами определяется сам (..\router или ..\openwrt)
# Требует настроенный SSH-алиас openwrt (router-ssh-setup.ps1). Файлы передаются через ssh (в dropbear нет sftp, scp не работает).
param([string]$Alias = 'openwrt', [string]$Dir = '')
$ErrorActionPreference = 'Continue'     # ssh пишет предупреждения в stderr; коды возврата проверяются явно
if (-not $Dir) { foreach ($c in '..\router', '..\openwrt') { $p = Join-Path $PSScriptRoot $c; if (Test-Path (Join-Path $p 'pw2-setup')) { $Dir = $p; break } } }
if (-not $Dir -or -not (Test-Path (Join-Path $Dir 'pw2-setup'))) { throw 'Не найден каталог со скриптами роутера (нет файла pw2-setup).' }
$ex = $null
foreach ($c in (Join-Path $Dir 'secrets.env.example'), (Join-Path $PSScriptRoot '..\..\configs\openwrt\secrets.env.example')) { if (Test-Path $c) { $ex = $c; break } }
if (-not $ex) { throw 'Не найден secrets.env.example.' }
ssh $Alias 'mkdir -p /usr/share/pw2' 2>$null
$files = @(Get-ChildItem $Dir -File | Where-Object { $_.Name -match '^(\d\d-.*\.sh|pw2-.*|verify-.*\.sh|VERSION)$' }) + (Get-Item $ex)
foreach ($f in $files) {
  # на роутер уходят файлы с переводами строк LF
  $tmp = Join-Path $env:TEMP ('pw2-up-' + $f.Name)
  [System.IO.File]::WriteAllText($tmp, ([System.IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
  cmd /c "ssh $Alias `"cat > /usr/share/pw2/$($f.Name)`" < `"$tmp`" 2>nul"
  if ($LASTEXITCODE -ne 0) { throw "Не удалось передать $($f.Name)" }
  Remove-Item $tmp -Force
}
# данные (двоичные файлы, например российская база рекламы) передаются без преобразования строк
if (Test-Path (Join-Path $Dir 'data')) {
  ssh $Alias 'mkdir -p /usr/share/pw2/data' 2>$null
  foreach ($f in Get-ChildItem (Join-Path $Dir 'data') -File) {
    cmd /c "ssh $Alias `"cat > /usr/share/pw2/data/$($f.Name)`" < `"$($f.FullName)`" 2>nul"
    if ($LASTEXITCODE -ne 0) { throw "Не удалось передать data\$($f.Name)" }
  }
}
ssh $Alias 'chmod +x /usr/share/pw2/* ; cp /usr/share/pw2/pw2-setup /usr/bin/pw2-setup ; chmod +x /usr/bin/pw2-setup ; ls /usr/share/pw2 | wc -l' 2>$null
Write-Host "Готово: скрипты загружены в /usr/share/pw2 ($($files.Count) файлов). Команда на роутере: pw2-setup" -ForegroundColor Green

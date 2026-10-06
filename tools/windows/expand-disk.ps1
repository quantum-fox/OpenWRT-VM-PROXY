# Расширение корневого раздела роутера на весь виртуальный диск (скрипт 00-expand-disk.sh запускается до трёх раз с автоматическими перезагрузками).
# Требует: SSH-алиас openwrt, загруженные скрипты (install-router.ps1), интернет у роутера. Занимает ~5 минут.
param([string]$Alias = 'openwrt')
. "$PSScriptRoot\gateway-lib.ps1"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
for ($n = 1; $n -le 4; $n++) {
  Write-Host "--- запуск $n"
  $o = ssh $Alias 'sh /usr/share/pw2/00-expand-disk.sh 2>&1' 2>$null
  $o | ForEach-Object { Write-Host $_ }
  if ($o -match 'ГОТОВО') { Write-Host 'Диск расширен.' -ForegroundColor Green; exit 0 }
  if ($o -match 'ОШИБКА') { Write-Host 'Остановлено из-за ошибки (см. выше).' -ForegroundColor Red; exit 1 }
  Write-Host 'Роутер перезагружается, жду...'
  Start-Sleep 20
  for ($t = 0; $t -lt 60 -and -not (Test-RouterSsh -Alias $Alias 4); $t++) { Start-Sleep 5 }
  if (-not (Test-RouterSsh -Alias $Alias 4)) { Write-Host 'Роутер не вернулся за 5 минут: откройте окно VM и проверьте консоль.' -ForegroundColor Red; exit 1 }
  Start-Sleep 5
}
Write-Host 'Не завершено за 4 запуска - см. вывод выше.' -ForegroundColor Red; exit 1

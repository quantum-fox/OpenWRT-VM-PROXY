# Прописать прокси OpenWRT в профиль Firefox через user.js (читается при запуске профиля; закройте этот профиль перед запуском скрипта).
#   .\firefox-proxy.ps1 -ProfileDir "$env:APPDATA\Mozilla\Firefox\Profiles\<имя профиля>" -Port 1081    # рабочий профиль: порт 1081 (рабочий выход)
#   .\firefox-proxy.ps1 -ProfileDir "<профиль>" -Off                                                     # убрать
# SOCKS5 + удалённый DNS (запросы имён идут через прокси, DNS-утечек нет); DoH отключён (network.trr.mode=5), чтобы не обходить прокси.
# Порт 1081 = рабочий выход (ваш сервер), порт 1080 = пул.
param([Parameter(Mandatory = $true)][string]$ProfileDir, [int]$Port = 1081, [string]$ProxyHost = '10.99.77.1', [switch]$Off)
if (-not (Test-Path $ProfileDir)) { Write-Host "Нет каталога профиля: $ProfileDir"; exit 1 }
$uj = Join-Path $ProfileDir 'user.js'
$mark = '// --- openwrt-proxy (tools/win-gateway/firefox-proxy.ps1) ---'
$endmark = '// --- /openwrt-proxy ---'
$cur = if (Test-Path $uj) { Get-Content $uj -Raw -Encoding UTF8 } else { '' }
$cur = [regex]::Replace($cur, [regex]::Escape($mark) + '.*?' + [regex]::Escape($endmark) + '\r?\n?', '', 'Singleline')
if (-not $Off) {
  $blk = @(
    $mark,
    'user_pref("network.proxy.type", 1);',
    "user_pref(""network.proxy.socks"", ""$ProxyHost"");",
    "user_pref(""network.proxy.socks_port"", $Port);",
    'user_pref("network.proxy.socks_version", 5);',
    'user_pref("network.proxy.socks_remote_dns", true);',
    "user_pref(""network.proxy.no_proxies_on"", ""localhost, 127.0.0.1, $ProxyHost"");",
    'user_pref("network.trr.mode", 5);',
    $endmark
  ) -join "`r`n"
  $cur = $cur.TrimEnd() + "`r`n" + $blk + "`r`n"
}
[System.IO.File]::WriteAllText($uj, $cur.TrimStart(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Готово: {0} ({1}). Запустите Firefox с этим профилем и откройте https://icanhazip.com" -f $uj, $(if ($Off) { 'прокси убран' } else { "SOCKS5 ${ProxyHost}:$Port" }))

# Настройка VS Code: ВЕСЬ VS Code (сам редактор, расширения, терминал, Claude Code) ходит через USA-прокси OpenWRT 8081.
#   .\vscode-proxy.ps1 -On     включить (делает резервную копию settings.json рядом)
#   .\vscode-proxy.ps1 -Off    убрать только добавленные ключи
# Что меняется в %APPDATA%\Code\User\settings.json:
#   http.proxy / http.proxySupport=override / http.noProxy        - сетевой стек VS Code и расширения (Marketplace, Codeium и др.)
#   terminal.integrated.env.windows                               - HTTP(S)_PROXY для встроенного терминала (git, npm, pip, curl, python...)
#   claudeCode.environmentVariables                               - HTTP(S)_PROXY для процесса Claude Code
# После -On/-Off: в VS Code выполнить "Developer: Reload Window" (или перезапустить VS Code).
param([switch]$On, [switch]$Off, [string]$Proxy = 'http://10.99.77.1:8081')
if (-not ($On -xor $Off)) { Write-Host 'Укажите -On или -Off'; exit 1 }
$set = Join-Path $env:APPDATA 'Code\User\settings.json'
if (-not (Test-Path $set)) { Set-Content -Path $set -Value '{}' -Encoding UTF8 }
$raw = [System.IO.File]::ReadAllText($set, [System.Text.Encoding]::UTF8)
try { $j = $raw | ConvertFrom-Json } catch { Write-Host "settings.json не удаётся разобрать как JSON (комментарии?): $($_.Exception.Message)"; exit 1 }
if ($null -eq $j) { $j = [pscustomobject]@{} }

$noProxy = 'localhost,127.0.0.1,::1,10.99.77.1,.lan'
# в Windows имена переменных окружения не зависят от регистра, поэтому достаточно верхнего
$envPairs = [ordered]@{ HTTP_PROXY = $Proxy; HTTPS_PROXY = $Proxy; NO_PROXY = $noProxy }
function Set-Key($o, $name, $value) { if ($o.PSObject.Properties[$name]) { $o.$name = $value } else { $o | Add-Member -NotePropertyName $name -NotePropertyValue $value } }
function Remove-Key($o, $name) { if ($o.PSObject.Properties[$name]) { $o.PSObject.Properties.Remove($name) } }

$bak = "$set.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
Copy-Item $set $bak
if ($On) {
  Set-Key $j 'http.proxy' $Proxy
  Set-Key $j 'http.proxySupport' 'override'
  Set-Key $j 'http.noProxy' @('localhost', '127.0.0.1', '::1', '10.99.77.1')
  # терминал
  $t = if ($j.PSObject.Properties['terminal.integrated.env.windows']) { $j.'terminal.integrated.env.windows' } else { [pscustomobject]@{} }
  foreach ($k in $envPairs.Keys) { Set-Key $t $k $envPairs[$k] }
  Set-Key $j 'terminal.integrated.env.windows' $t
  # Claude Code
  $cur = @(); if ($j.PSObject.Properties['claudeCode.environmentVariables']) { $cur = @($j.'claudeCode.environmentVariables') }
  $cur = @($cur | Where-Object { $envPairs.Keys -notcontains $_.name })
  foreach ($k in 'HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY') { $cur += [pscustomobject]@{ name = $k; value = $envPairs[$k] } }
  Set-Key $j 'claudeCode.environmentVariables' $cur
} else {
  foreach ($k in 'http.proxy', 'http.proxySupport', 'http.noProxy') { Remove-Key $j $k }
  if ($j.PSObject.Properties['terminal.integrated.env.windows']) {
    $t = $j.'terminal.integrated.env.windows'; foreach ($k in $envPairs.Keys) { Remove-Key $t $k }
    if (-not $t.PSObject.Properties.Name) { Remove-Key $j 'terminal.integrated.env.windows' }
  }
  if ($j.PSObject.Properties['claudeCode.environmentVariables']) {
    $cur = @($j.'claudeCode.environmentVariables' | Where-Object { $envPairs.Keys -notcontains $_.name })
    if ($cur.Count) { $j.'claudeCode.environmentVariables' = $cur } else { Remove-Key $j 'claudeCode.environmentVariables' }
  }
}
$out = $j | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($set, $out, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Готово ({0}). Резервная копия: {1}" -f $(if ($On) { 'proxy ВКЛ' } else { 'proxy ВЫКЛ' }), $bak)
Write-Host 'Теперь в VS Code: Ctrl+Shift+P -> "Developer: Reload Window".'

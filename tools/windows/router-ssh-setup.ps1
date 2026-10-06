# Настройка входа на роутер по SSH-ключу и алиаса "openwrt" (чтобы дальше команды выполнялись без пароля).
#   .\router-ssh-setup.ps1                       # спросит пароль root роутера
#   .\router-ssh-setup.ps1 -Password "..."       # без вопроса
# Создаёт ключ %USERPROFILE%\.ssh\openwrt_router (если нет), добавляет блок "Host openwrt" в %USERPROFILE%\.ssh\config,
# кладёт публичный ключ на роутер (/etc/dropbear/authorized_keys) и проверяет вход.
param([string]$Router = '10.99.77.1', [string]$Password = '', [string]$Alias = 'openwrt')
$ErrorActionPreference = 'Continue'     # ssh пишет предупреждения в stderr - это не ошибка; коды возврата проверяются явно
$ssh = Join-Path $env:USERPROFILE '.ssh'; New-Item -ItemType Directory -Force -Path $ssh | Out-Null
$key = Join-Path $ssh 'openwrt_router'
if (-not (Test-Path $key)) { ssh-keygen -t ed25519 -N '""' -f $key -C 'pw2-router' | Out-Null; Write-Host "Создан ключ $key" }
$cfg = Join-Path $ssh 'config'
$cur = if (Test-Path $cfg) { Get-Content $cfg -Raw } else { '' }
if ($cur -notmatch "(?m)^Host $Alias\s*$") {
  $blk = "`r`nHost $Alias`r`n  HostName $Router`r`n  User root`r`n  IdentityFile ~/.ssh/openwrt_router`r`n  IdentitiesOnly yes`r`n  StrictHostKeyChecking accept-new`r`n"
  [System.IO.File]::AppendAllText($cfg, $blk, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "Добавлен алиас '$Alias' в $cfg"
}
if (-not $Password) { $sec = Read-Host 'Пароль root роутера' -AsSecureString; $Password = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)) }

# публичный ключ передаётся маленьким скриптом, который выполняется на роутере (без вложенных кавычек)
$pubKey = (Get-Content "$key.pub" -Raw).Trim()
$remote = "mkdir -p /etc/dropbear`ntouch /etc/dropbear/authorized_keys`ngrep -qxF '$pubKey' /etc/dropbear/authorized_keys || echo '$pubKey' >> /etc/dropbear/authorized_keys`nchmod 600 /etc/dropbear/authorized_keys`n"
$tmp = Join-Path $env:TEMP 'pw2-authkey.sh'
[System.IO.File]::WriteAllText($tmp, $remote, (New-Object System.Text.UTF8Encoding($false)))
# пароль передаётся ssh через SSH_ASKPASS (временный .cmd, удаляется)
$askpass = Join-Path $env:TEMP 'pw2-askpass.cmd'
Set-Content -Path $askpass -Value '@echo %PW2_PASS%' -Encoding ASCII
$env:PW2_PASS = $Password; $env:SSH_ASKPASS = $askpass; $env:SSH_ASKPASS_REQUIRE = 'force'; $env:DISPLAY = 'pw2'
try {
  cmd /c "ssh -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password -o PubkeyAuthentication=no -o ConnectTimeout=10 root@$Router sh -s < `"$tmp`" 2>nul"
  if ($LASTEXITCODE -ne 0) { throw "Не удалось войти на роутер $Router по паролю (код $LASTEXITCODE). Роутер запущен? Пароль верный?" }
} finally {
  Remove-Item $askpass, $tmp -Force -ErrorAction SilentlyContinue
  Remove-Item Env:PW2_PASS, Env:SSH_ASKPASS, Env:SSH_ASKPASS_REQUIRE, Env:DISPLAY -ErrorAction SilentlyContinue
}
$o = ssh -o BatchMode=yes $Alias 'echo ok' 2>$null
if ($o -eq 'ok') { Write-Host "Готово: 'ssh $Alias' работает без пароля." -ForegroundColor Green } else { throw "Ключ добавлен, но вход по ключу не работает. Проверьте: ssh -v $Alias" }

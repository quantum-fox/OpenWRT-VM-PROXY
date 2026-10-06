# Windows: подключение к роутеру

Выполняйте после того, как роутер собран и `pw2-setup` показал выходы 1080 и 1081 (варианты A/B). Скрипты — в `tools\windows\` (запуск из PowerShell; если политика выполнения мешает — двойной щелчок по `.cmd` либо `powershell -ExecutionPolicy Bypass -File …`). Все `.ps1` сохранены в **UTF-8 с BOM** — иначе PowerShell 5.1 ломает кириллицу.

## 1. Что получите
| Трафик | Путь | Выход |
|---|---|---|
| **Вся система** (Windows, браузеры без настроек, обновления, программы) | шлюз Windows → роутер → прозрачный прокси → `shunt_pool` | пул (узел с лучшим пингом); RU и CN напрямую; UA блок |
| **Рабочий браузер** (отдельный профиль Firefox) | явный SOCKS5 `10.99.77.1:1081` | ваш сервер (запасной — при отказе) |
| **VS Code целиком** (редактор, расширения, терминал, расширения ИИ) | `http.proxy` и переменные окружения → `10.99.77.1:8081` | ваш сервер |
| Любая программа по выбору | `10.99.77.1:8080` / `:1080` (пул) или `:8081` / `:1081` (рабочий) | как у соответствующего порта |
| Сам роутер | напрямую | — |

Сервисы, закрытые для российских IP, через пул могут отвечать 403 (регион закрыт) — открывайте их через рабочий порт.

## 2. Шаги (порядок важен)

### Шаг 1. Проверка связи
```powershell
Test-Connection 10.99.77.1 -Count 2 -Quiet                 # True
ssh openwrt 'pw2-setup status'                             # выходы 1080 и 1081 заданы
```

### Шаг 2. (по желанию) VS Code через рабочий выход
```powershell
cd <папка PRODUCT>\tools\windows
.\vscode-proxy.ps1 -On          # делает резервную копию settings.json рядом
```
В VS Code: `Ctrl+Shift+P` → **Developer: Reload Window**. Проверка во встроенном терминале: `echo $env:HTTPS_PROXY` → `http://10.99.77.1:8081`; `curl.exe -s https://icanhazip.com` → IP вашего сервера. Убрать: `.\vscode-proxy.ps1 -Off` (и Reload Window).
Что меняется в `%APPDATA%\Code\User\settings.json`: `http.proxy`, `http.proxySupport=override`, `http.noProxy`, `terminal.integrated.env.windows` (HTTP(S)_PROXY, NO_PROXY), `claudeCode.environmentVariables`.

### Шаг 3. (по желанию) Рабочий браузер — профиль Firefox
Вручную: Firefox → Настройки → Параметры сети → **Ручная настройка прокси**: «Узел SOCKS» `10.99.77.1`, порт `1081`, **SOCKS v5**, галка **«Proxy DNS при использовании SOCKS v5»**, «Не использовать прокси для» — `localhost, 127.0.0.1, 10.99.77.1`; остальные поля пустые.
Скриптом (профиль должен быть закрыт):
```powershell
.\firefox-proxy.ps1 -ProfileDir "$env:APPDATA\Mozilla\Firefox\Profiles\<имя профиля>" -Port 1081
.\firefox-proxy.ps1 -ProfileDir "…" -Off          # убрать
```
Проверка: `https://icanhazip.com` → IP вашего сервера. Остальные профили оставьте «Использовать системные настройки» — они пойдут через шлюз.

### Шаг 4. Закрыть конфликтующие туннели
Закройте (через «Выход» в трее, не просто окно) любые VPN/TUN-клиенты: Throne, v2rayN (TUN), Clash, Outline, WireGuard, OpenVPN. Их маршруты конфликтуют со шлюзом; скрипт откажется включаться, если найдёт активный туннель (`-Force` игнорирует проверку). Проверка:
```powershell
Get-NetAdapter | Where-Object Status -eq Up | Select Name, InterfaceDescription
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select ProxyEnable, ProxyServer, AutoConfigURL   # ProxyEnable=0
```

### Шаг 5. Сторож (автозапуск VM и поддержание шлюза)
PowerShell **от администратора**:
```powershell
cd <папка PRODUCT>\tools\windows
.\install-watchdog-task.ps1
```
Создаётся задача `OpenWRT-Gateway-Watchdog` (от вашего пользователя, с повышенными правами, без окна): при входе в Windows и **каждую минуту** она (1) запускает VM `OpenWRT`, если она не работает; (2) если шлюз включён — поддерживает маршруты и DNS; (3) если роутер не отвечает — **fail-open**: выключает шлюз, интернет идёт напрямую; (4) не трогает шлюз при активном туннельном адаптере; (5) если у роутера пропал выход в сеть (нет маршрута по умолчанию 3 минуты подряд, см. [troubleshooting.md](troubleshooting.md), «Роутер не пингует»), корректно перезапускает VM (не чаще раза в 15 минут). Лог: `C:\ProgramData\win-gateway\watchdog.log`.

### Шаг 6. Включить шлюз
PowerShell от администратора (или двойной щелчок по `gateway-on.cmd`):
```powershell
.\gateway-on.ps1
```
Ожидаемо: `Шлюз включён, интернет проверен.` и внешний IP узла пула. Скрипт проверяет роутер, туннели и пересечение подсетей → добавляет маршруты `0.0.0.0/1` и `128.0.0.0/1` через `10.99.77.1` (метрика 1; вместе они перекрывают `0.0.0.0/0`, локальные подсети остаются прямыми) → ставит DNS `10.99.77.1` на внешний и host-only адаптеры → проверяет интернет; если интернета нет — **сам выключает шлюз**. Выключить в любой момент: `.\gateway-off.ps1`. Маршруты хранятся в `ActiveStore` и исчезают при перезагрузке Windows — сторож возвращает их, когда роутер готов.

### Шаг 7. Проверка результата
| № | Проверка | Ожидание |
|---|---|---|
| 1 | `curl.exe --noproxy "*" -s https://icanhazip.com` (в терминале VS Code **обязательно** `--noproxy "*"`) | IP узла пула, **не** IP вашего сервера |
| 2 | `tracert -d -h 2 1.1.1.1` | хоп 1 = `10.99.77.1` |
| 3 | `nslookup example.com` | `Server: 10.99.77.1` |
| 4 | терминал VS Code: `curl.exe -s https://icanhazip.com` | IP вашего сервера |
| 5 | рабочий Firefox: `https://icanhazip.com` | IP вашего сервера |
| 6 | `ssh openwrt "tail -5 /tmp/log/passwall2.log"` | нет ошибок |

После шагов 1–7 всё работает само. Как это выглядит каждый день, как проверить выход в браузере и что делать при сбое — [daily-use.md](daily-use.md).

### Шаг 8. Проверка автозапуска и fail-open (один раз)
1. Перезагрузите Windows. После входа подождите 2–4 минуты: VM стартует, роутер грузится ~30 с + 20 с на PassWall2, затем сторож включает шлюз. Первые минуты интернет идёт напрямую. `Get-Content C:\ProgramData\win-gateway\watchdog.log -Tail 10`; `Get-NetRoute -NextHop 10.99.77.1 | Select DestinationPrefix`.
2. Fail-open: `ssh openwrt poweroff` → в течение минуты интернет вернётся напрямую («FAIL-OPEN» в логе), затем сторож запустит VM и снова включит шлюз.

## 3. Если что-то не работает
| Симптом | Что сделать |
|---|---|
| После `gateway-on` нет интернета | `.\gateway-off.ps1`; `ssh openwrt pw2-setup status`; `ssh openwrt "tail -30 /tmp/log/passwall2.log"`; при необходимости `ssh openwrt /etc/init.d/passwall2 restart` |
| `gateway-on` пишет о туннельных адаптерах | закройте названную программу (шаг 4) |
| `gateway-on` пишет о подсети `10.99.77.x` | внешняя сеть использует ту же подсеть, что LAN роутера (крайне маловероятно): шлюз не включится; сменить подсеть роутера на другую редкую — см. [troubleshooting.md](troubleshooting.md) |
| `выполнение сценариев отключено` | запускайте `.cmd`, либо `powershell -ExecutionPolicy Bypass -File …`, либо один раз `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| «после включения интернета нет» | на роутере не работает DNS PassWall2 — см. [troubleshooting.md](troubleshooting.md), «Обычный `dnsmasq` ломает прозрачный режим» |
| Сайты не открываются по имени | `ipconfig /flushdns`; `nslookup example.com 10.99.77.1`; DNS адаптера должен быть `10.99.77.1` |
| Рабочий Firefox показывает IP пула | в профиле другие настройки прокси: проверьте шаг 3 и закройте Firefox перед `firefox-proxy.ps1` |
| После смены Wi-Fi нет интернета | подождите ≤1 минуты (сторож вернёт DNS/маршруты); иначе `gateway-off.ps1` → `gateway-on.ps1` |
| Нужно запустить другой VPN | **сначала** `.\gateway-off.ps1` (иначе сторож продолжит держать маршруты), потом `gateway-on.ps1` |

Если ничего не помогло, соберите: `Get-NetRoute -NextHop 10.99.77.1`, `Get-DnsClientServerAddress`, `Get-Content C:\ProgramData\win-gateway\watchdog.log -Tail 20`, `ssh openwrt "tail -50 /tmp/log/passwall2.log"`.

## 4. Полный откат
```powershell
.\gateway-off.ps1                                                             # маршруты, DNS, флаг
Unregister-ScheduledTask -TaskName OpenWRT-Gateway-Watchdog -Confirm:$false   # сторож и автозапуск VM (админ)
.\vscode-proxy.ps1 -Off                                                       # VS Code (потом Reload Window)
.\firefox-proxy.ps1 -ProfileDir "<профиль>" -Off
ssh openwrt "uci set passwall2.@global[0].enabled=0; uci commit passwall2; /etc/init.d/passwall2 restart"   # (необязательно) выключить прозрачный режим; порты 1080/1081/8080/8081 продолжат работать
```
Если интернет пропал совсем — перезагрузите Windows (маршруты шлюза исчезнут), DNS: `Get-NetAdapter | ForEach-Object { Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ResetServerAddresses }`.

## 5. Ограничения
- **Сеть роутера `10.99.77.0/24`** отдельная (роутер `.1`, Windows `.2`, свой Host-Only адаптер) и не затрагивает ваши прочие VM на другом адаптере. Если внешняя сеть окажется в той же подсети, шлюз откажется включаться.
- **Правила маршрутизации** — [routing-rules.md](routing-rules.md): на рабочем порту блокируются RU и UA (если рабочему браузеру нужен российский сайт — он недоступен намеренно).
- **leastPing меняет узел**: внешний IP общего трафика меняется со временем; сайты с привязкой сессии к IP могут разлогинивать. Рабочие порты стабильны (один IP).
- **Git в панели Source Control VS Code** запускается вне терминала и не получает переменные окружения → идёт через пул; в терминале VS Code git идёт через рабочий выход. Принудительно: `git config --global http.proxy http://10.99.77.1:8081`.
- WSL2, Docker Desktop, мессенджеры и т. п. без своих настроек идут через шлюз → пул.
- **Сон/гибернация Windows:** VM ставится на паузу и возобновляется; сторож восстанавливает состояние за минуту.
- **Сторож сам запускает VM.** Чтобы выключить VM намеренно: `Disable-ScheduledTask OpenWRT-Gateway-Watchdog` (админ), затем `ssh openwrt poweroff`; вернуть: `Enable-ScheduledTask OpenWRT-Gateway-Watchdog`.
- **Fail-open:** при падении роутера Windows временно идёт напрямую (без пула и рабочего выхода). Жёсткий kill-switch (лучше без интернета, чем напрямую) — убрать из `gateway-watchdog.ps1` строку `Disable-Gateway -KeepFlag …`.
- **IPv6:** на роутере полностью отключён (`pw2-ipv6 off`, делает `pw2-setup`): LAN не раздаёт IPv6, адресов нет. На Windows отключите привязку IPv6 на внешнем адаптере (Wi-Fi/Ethernet) и на адаптере host-only (PowerShell от администратора: `Disable-NetAdapterBinding -Name "<имя адаптера>" -ComponentID ms_tcpip6`; посмотреть: `Get-NetAdapterBinding -ComponentID ms_tcpip6`), иначе возможны утечки мимо шлюза. Вернуть: `pw2-ipv6 on` на роутере и `Enable-NetAdapterBinding …` на Windows.

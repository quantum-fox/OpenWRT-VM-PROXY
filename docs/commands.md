# Справочник команд

Роутер: `ssh openwrt` (алиас создаёт `router-ssh-setup.ps1`, вход по ключу; адрес `10.99.77.1`). Скрипты Windows — `tools\windows\` (двойной щелчок по `.cmd`, если ExecutionPolicy блокирует `.ps1`; от администратора там, где указано).

## Роутер
| Команда | Назначение |
|---|---|
| `pw2-setup` | ввести ваши данные (подписка, сервер) и применить всё; при первом запуске требует сменить пароль root |
| `pw2-setup apply` | применить `/root/secrets.env` без вопросов (после ручной правки файла) |
| `pw2-setup status` | узлы, выходы 1080/1081, режимы, службы |
| `pw2-routing-apply` | применить `/etc/pw2-routing.conf` (правила RU/UA/CN, shunt-узлы, запасной выход); перезапускает PassWall2 |
| `pw2-cn-mode <режим>` | режимы: `status` (показать), `auto` (автоматически), `direct` (всегда напрямую), `proxy` (всегда через пул) — Китай |
| `pw2-ipv6 off`, `pw2-ipv6 on`, `pw2-ipv6 status` | полностью отключить IPv6 на роутере (по умолчанию так и настроено) / вернуть / показать состояние; копия настроек в `/root/*.before-ipv6-<время>` |
| `pw2-geosite status`, `merge`, `ensure`, `restore` | дополнительные списки доменов (российская база рекламы) в `geosite.dat`: показать / подключить / проверить и восстановить (cron раз в 15 мин) / вернуть чистый файл — [routing-rules.md](routing-rules.md) |
| `pw2-update status`, `pw2-update` | версия и обновление до версии загруженных скриптов (все недостающие шаги по порядку, с копиями настроек) — [update.md](update.md) |
| `pw2-ads status`, `pw2-ads on`, `pw2-ads off`, `pw2-ads allow <домен>` | блокировка рекламы и трекеров: состояние / включить / выключить / разблокировать свой домен — [routing-rules.md](routing-rules.md) |
| `pw2-ali-mode <режим>` | режимы: `status`, `direct` (AliExpress/Alibaba напрямую), `pool` (через пул), `node <ID>` (через узел/цепочку) — см. [routing-rules.md](routing-rules.md) |
| `pw2-usa-mode <режим>` | режимы: `status` (какой выход сейчас), `backup` (закрепить запасной), `auto` (автоматический) — рабочий выход 1081/8081 |
| `pw2-pool-sync` | обновить подписку и пересобрать пул (cron `17 */6 * * *`); `PW2_NO_UPDATE=1 pw2-pool-sync` — без скачивания |
| `pw2-ua-block` | пересобрать наборы IP Украины файрвола (`inet ua_block`); cron раз в неделю |
| `/etc/init.d/cn-watch <действие>` | действия: `start`, `stop`, `restart` — сторож доступности Китая (лог `/root/pw2-cn-watch.log`) |
| `/etc/init.d/ua-block restart` | перезагрузить блокировку UA |
| `/etc/init.d/passwall2 restart` | перезапуск PassWall2 (обрывает соединения на ~10 с) |
| `sh /usr/share/pw2/verify-usa-chain.sh` | доказательство, что рабочий выход идёт через туннель (0 прямых сокетов на ваш сервер) |
| `sh /usr/share/pw2/pw2-chain-bench` | замер времени ответа рабочего сервера через разные первые хопы (временные порты, рабочие не затрагиваются); параметры — в шапке скрипта и в [troubleshooting.md](troubleshooting.md) |

Файлы настроек: `/etc/pw2-routing.conf` (после правки — `pw2-routing-apply`), `/etc/pw2-pool.conf`, `/root/secrets.env` (после правки — `pw2-setup apply`).

Диагностика:
```sh
logread | tail -50                          # системный журнал
tail -30 /tmp/log/passwall2.log             # журнал PassWall2
nft list table inet passwall2 | head -50    # прозрачный прокси
nft list table inet ua_block | head         # блокировка UA
grep -c ^processor /proc/cpuinfo; free; uptime
```
Проверка выходов с Windows:
```powershell
curl.exe -x http://10.99.77.1:8080 https://icanhazip.com      # пул
curl.exe -x http://10.99.77.1:8081 https://icanhazip.com      # рабочий: IP вашего сервера
curl.exe --noproxy "*" https://icanhazip.com                  # системный путь (при включённом шлюзе)
```
Внимание: если в терминале заданы `HTTP(S)_PROXY=…:8081` (после `vscode-proxy.ps1`), простой `curl` идёт через рабочий выход; для системного пути нужен `--noproxy "*"` (он же отключает и явный `-x`).

## Windows (`tools\windows\`)
| Команда | Назначение |
|---|---|
| `vm-create.ps1` (админ) | вариант A: скачать образ OpenWrt, создать VM и сеть |
| `vm-import.ps1` (админ) | вариант B: импортировать готовый образ, создать сеть |
| `router-ssh-setup.ps1` | создать SSH-ключ и алиас `openwrt`, положить ключ на роутер |
| `install-router.ps1` | загрузить скрипты установки на роутер (`/usr/share/pw2`) |
| `expand-disk.ps1` | вариант A: расширить корневой раздел на весь диск (автоматические перезагрузки) |
| `gateway-on.cmd` / `gateway-off.cmd` | включить / выключить прозрачный шлюз (маршруты 0/1 и 128/1 через `10.99.77.1`, DNS на роутер) |
| `install-watchdog-task.ps1` (админ) | задача `OpenWRT-Gateway-Watchdog`: автозапуск VM, поддержание шлюза, fail-open |
| `cn-mode.cmd <режим>` | то же, что `pw2-cn-mode` (`status`, `auto`, `direct`, `proxy`), с Windows |
| `vscode-proxy.ps1 -On` / `vscode-proxy.ps1 -Off` | включить / выключить VS Code через рабочий выход 8081 |
| `firefox-proxy.ps1 -ProfileDir … [-Port 1081] [-Off]` | профиль Firefox через SOCKS5 роутера |
| `vm-tune.ps1 [-Cpus N] [-Rollback]` (админ) | vCPU / virtio / паравирт. VM (см. [vm-settings.md](vm-settings.md)) |

## Последовательность установки «с нуля»
`vm-create.ps1` → консоль VM (адрес LAN, пароль) → `router-ssh-setup.ps1` → `install-router.ps1` → `expand-disk.ps1` → `01-packages.sh` → `pw2-setup` (выполняет `02`…`08`) → Windows ([windows-setup.md](windows-setup.md)). Подробно — [A-from-scratch/README.md](../A-from-scratch/README.md).

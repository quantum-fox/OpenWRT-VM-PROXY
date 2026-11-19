# Вариант A — сборка роутера с нуля

Результат: виртуальный роутер OpenWrt 23.05.6 + PassWall2 с вашей подпиской и вашим рабочим сервером, идентичный готовому образу. Общая картина и требования — [../README.md](../README.md). Время ~40 минут, из них ~10 — ожидание скриптов.

> **Метки.** Перед каждой командой стоит метка, **где** её вводить: 🖥️ **ПК · PowerShell** (на вашем Windows-компьютере), 📡 **Роутер · консоль** (на самом роутере), 🖥️➜📡 **ПК ➜ роутер** (вводится на ПК как `ssh openwrt …`, выполняется на роутере). Таблица всех меток: [../docs/where-to-run.md](../docs/where-to-run.md).

Если не сказано иное, команды вводятся на Windows в **PowerShell от имени администратора**, в каталоге скриптов:

🖥️ **ПК · PowerShell (админ)**
```powershell
cd <папка OpenWRT-VM-PROXY>\tools\windows
```
Если политика выполнения блокирует `.ps1`: `powershell -ExecutionPolicy Bypass -File .\имя.ps1` либо один раз `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

## Подготовьте данные заранее
- Адрес подписки провайдера (`https://…`).
- Ссылку `vless://…` вашего сервера для рабочего выхода (**для Reality — обязательно с `flow=xtls-rprx-vision`**, если сервер его требует).
- По желанию — вторую ссылку `vless://…` вашего сервера для общего пула.

## Шаг 1. Создать VM
🖥️ **ПК · PowerShell (админ)**
```powershell
.\vm-create.ps1
```
Скрипт скачивает образ OpenWrt 23.05.6 (`downloads.openwrt.org`, ~11 МБ), создаёт диск 3 ГБ, VM `OpenWRT` (2 vCPU, 384 МБ ОЗУ, virtio, kvm), Host-Only адаптер с адресом Windows `10.99.77.2/24` (LAN роутера) и мост на ваш внешний сетевой адаптер (WAN). Адаптер WAN выбирается автоматически (с лучшей метрикой маршрута по умолчанию); при необходимости: `-WanAdapter "<имя из VBoxManage list bridgedifs>"`. Параметры и ошибки — [../docs/troubleshooting.md](../docs/troubleshooting.md).

## Шаг 2. Первый запуск: адрес LAN и пароль
🖥️ **ПК · PowerShell** — запустить VM с окном:
```powershell
& "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe" startvm OpenWRT --type gui
```
Откроется окно виртуальной машины. Подождите, пока перестанут бежать строки, и нажмите **Enter** в этом окне (появится приглашение `root@OpenWrt:/#`). Теперь вы **на роутере** (окно VM — это его консоль, мышь в нём не нужна, только клавиатура).

📡 **Роутер · консоль (окно VM)**
```sh
uci set network.lan.ipaddr='10.99.77.1'; uci commit network; /etc/init.d/network restart
passwd && touch /etc/pw2-passwd.done
```
(`passwd` спросит новый пароль root дважды; он нужен для SSH и веб-интерфейса; при вводе пароля символы на экране не появляются — это нормально.) Через несколько секунд вернитесь в PowerShell на ПК:

🖥️ **ПК · PowerShell**
```powershell
Test-Connection 10.99.77.1 -Count 2 -Quiet      # True
```
Окно VM можно просто свернуть (оставьте его открытым, не выключайте принудительно). Позже сторож Windows сам запускает VM без окна (`--type headless`).

## Шаг 3. Вход по SSH-ключу
🖥️ **ПК · PowerShell (админ)**
```powershell
.\router-ssh-setup.ps1           # спросит пароль из шага 2
```
Создаёт ключ `%USERPROFILE%\.ssh\openwrt_router`, алиас `openwrt` в `%USERPROFILE%\.ssh\config` и кладёт ключ на роутер. Проверка: 🖥️➜📡 `ssh openwrt uname -a`. Дальше все команды — через `ssh openwrt …` (вводятся на ПК, выполняются на роутере).

## Шаг 4. Загрузить скрипты на роутер
🖥️ **ПК · PowerShell (админ)**
```powershell
.\install-router.ps1
```
Копирует `tools\router\*` в `/usr/share/pw2` (в dropbear нет sftp — файлы идут через `ssh … cat`) и ставит команду `pw2-setup`.

## Шаг 5. Расширить диск (~5 минут)
🖥️ **ПК · PowerShell (админ)**
```powershell
.\expand-disk.ps1
```
В образе OpenWrt корень ~100 МБ — для PassWall2 мало. Скрипт 3 раза запускает `00-expand-disk.sh` (на роутере) с двумя автоматическими перезагрузками (причина и устройство — [../docs/vm-settings.md](../docs/vm-settings.md), раздел «Расширение диска»). В конце: `ГОТОВО`, корень ~2,9 ГБ. Требуется интернет у роутера (ставятся `parted`, `e2fsprogs`, `resize2fs`, `blkid`). **Не прерывайте** процесс.

## Шаг 6. Установить пакеты (~5 минут)
🖥️➜📡 **ПК ➜ роутер**
```powershell
ssh openwrt 'sh /usr/share/pw2/01-packages.sh'
```
Ставит LuCI, **`dnsmasq-full`** (обязателен: нужен `nftset`, иначе DNS PassWall2 падает), подключает фид и ключ PassWall2 (`luci-app-passwall2`, русская локализация), обновляет `xray-core` из фида PassWall2 (нужен 26.x), ставит `kmod-nft-tproxy`/`kmod-nft-socket` (прозрачный UDP). В конце печатает версии: `xray-core 26.9.x`, `luci-app-passwall2 26.10.x`.

## Шаг 7. Ввести данные и применить всё
🖥️➜📡 **ПК ➜ роутер** (вопросы задаёт роутер, вы отвечаете в том же окне PowerShell)
```powershell
ssh -t openwrt pw2-setup
```
(`-t` нужен для вопросов.) Скрипт спросит:
1. адрес подписки;
2. ссылку `vless://…` рабочего сервера;
3. (необязательно) ссылку второго сервера для пула — Enter, чтобы пропустить.

Данные сохраняются в `/root/secrets.env` (права 600), затем автоматически выполняются шаги `02…08` (на роутере):

| Скрипт | Что делает |
|---|---|
| `02-subscription-and-nodes.sh` | скачивает подписку; добавляет ваши узлы (`USA-via-pool`, при наличии — дополнительный) |
| `03-pool-sync-install.sh` | ставит `pw2-pool-sync` (обновление подписки и пула, cron раз в 6 часов) и `/etc/pw2-pool.conf` |
| `04-balancer-socks-chain.sh` | узел-балансировщик `POOL leastPing`, цепочка «пул → ваш сервер», порты 1080/1081/8080/8081 |
| `06-routing-rules.sh` (как `pw2-routing-apply`) | правила RU/UA/CN, узлы `shunt_*`, запасной рабочий выход, автопереключение |
| `05-transparent.sh` | прозрачный режим для клиентов LAN (Main switch, `start_delay=20`) |
| `07-ua-firewall.sh` | файрвол-блок IP Украины (`inet ua_block`) |
| `08-cn-fallback.sh` | сторож Китая `cn-watch` и команда `pw2-cn-mode` |

Скрипты идемпотентны: `pw2-setup apply` можно запускать повторно (например, после правки `/root/secrets.env`).

## Шаг 8. Проверка
🖥️ **ПК · PowerShell** (строки с `curl.exe`) и 🖥️➜📡 **ПК ➜ роутер** (строки с `ssh openwrt`)
```powershell
ssh openwrt pw2-setup status
curl.exe -x socks5h://10.99.77.1:1080 https://icanhazip.com      # IP узла пула
curl.exe -x socks5h://10.99.77.1:1081 https://icanhazip.com      # IP ВАШЕГО сервера
ssh openwrt 'sh /usr/share/pw2/verify-usa-chain.sh'               # рабочий выход идёт через туннель, прямых сокетов на ваш сервер 0
```
Ожидается: пул — любой IP подписки, рабочий — IP вашего сервера, `автопереключение 1081: 1` (если в подписке есть узел с `USA` или `США` в имени), `cn-watch: running`, `ua_block: 1`. 🌐 **Браузер**: веб-интерфейс `http://10.99.77.1/cgi-bin/luci/admin/services/passwall2` (логин `root`).

## Дальше
1. Подключите Windows (шлюз, сторож, браузер, VS Code): [../docs/windows-setup.md](../docs/windows-setup.md).
2. Прочитайте, как это работает каждый день и как проверить, что всё в порядке: [../docs/daily-use.md](../docs/daily-use.md) (локальный VLESS-клиент не нужен; рабочий браузер настраивается отдельным профилем).
3. Как менять правила — [../docs/routing-rules.md](../docs/routing-rules.md); все команды — [../docs/commands.md](../docs/commands.md).

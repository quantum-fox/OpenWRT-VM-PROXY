#!/bin/sh
# install-router.sh - загрузка скриптов проекта на роутер (в /usr/share/pw2) без Windows: Linux, macOS, WSL, Git Bash.
# Это то же, что делает install-router.ps1 на Windows.
#   ./install-router.sh                       # роутер root@10.99.77.1
#   ./install-router.sh root@192.168.1.1      # любой адрес роутера
#   ./install-router.sh openwrt               # или имя из ~/.ssh/config
# Требуется вход по SSH (по ключу или по паролю - ssh спросит). Файлы передаются через ssh (в dropbear нет sftp, scp не работает).
# После загрузки: ssh -t РОУТЕР pw2-setup (первая настройка) или ssh РОУТЕР "sh /usr/share/pw2/pw2-update" (обновление).
# Запускать из папки со скриптами роутера (tools/router в продукте; рядом лежат pw2-setup, VERSION, secrets.env.example, data/).
HOST=${1:-root@10.99.77.1}
DIR=$(cd "$(dirname "$0")" && pwd)
[ -f "$DIR/pw2-setup" ] || { echo "ОШИБКА: рядом со скриптом нет pw2-setup ($DIR)"; exit 1; }
EX="$DIR/secrets.env.example"; [ -f "$EX" ] || EX="$DIR/../../configs/openwrt/secrets.env.example"      # во втором месте лежит в рабочем дереве проекта
[ -f "$EX" ] || { echo "ОШИБКА: нет secrets.env.example в $DIR"; exit 1; }
SSH="ssh -o ConnectTimeout=15 $HOST"
$SSH 'mkdir -p /usr/share/pw2/data' || { echo "ОШИБКА: нет входа на роутер по SSH ($HOST)"; exit 1; }
n=0
for f in "$DIR"/[0-9][0-9]-*.sh "$DIR"/pw2-* "$DIR"/verify-*.sh "$DIR"/VERSION "$EX"; do
  [ -f "$f" ] || continue
  b=$(basename "$f")
  tr -d '\r' < "$f" | $SSH "cat > /usr/share/pw2/$b" || { echo "ОШИБКА: не удалось передать $b"; exit 1; }
  n=$((n+1))
done
if [ -d "$DIR/data" ]; then
  for f in "$DIR"/data/*; do
    [ -f "$f" ] || continue
    $SSH "cat > /usr/share/pw2/data/$(basename "$f")" < "$f" || { echo "ОШИБКА: не удалось передать data/$(basename "$f")"; exit 1; }
  done
fi
$SSH 'chmod +x /usr/share/pw2/*; cp /usr/share/pw2/pw2-setup /usr/bin/pw2-setup; chmod +x /usr/bin/pw2-setup'
echo "Готово: скрипты загружены в /usr/share/pw2 ($n файлов). Команда на роутере: pw2-setup"
echo "Дальше: ssh -t $HOST pw2-setup   (первая настройка)   или   ssh $HOST \"sh /usr/share/pw2/pw2-update\"   (обновление)"

#!/bin/sh
# Доказательство, что рабочий USA идёт ЧЕРЕЗ туннель (пул), а не напрямую:
#  1) внешний IP через 1081 = IP USA;  2) у процесса sockB есть сокеты на узлы пула и НЕТ ни одного сокета на IP USA.
USA_ID=$(for id in $(uci show passwall2 | grep '=nodes$' | cut -d. -f2 | cut -d= -f1); do [ "$(uci -q get passwall2.$id.remarks)" = USA-via-pool ] && echo $id; done)
USA_IP=$(uci -q get passwall2.$USA_ID.address)   # адрес вашего рабочего сервера
PIDB=$(ps w | grep 'sockB+http.json' | grep -v grep | awk '{print $1}')
[ -n "$PIDB" ] || { echo "sockB не запущен"; exit 1; }
( curl -s -m 25 -x socks5h://127.0.0.1:1081 -o /dev/null "https://speed.cloudflare.com/__down?bytes=30000000" & )   # нагрузка, чтобы были живые сокеты
sleep 6
echo "== внешний IP через 1081 (ожидаем $USA_IP):  $(curl -s -m 20 -x socks5h://127.0.0.1:1081 https://icanhazip.com)"
echo "== сокеты процесса sockB (pid $PIDB) по удалённым адресам:"
netstat -tnp 2>/dev/null | awk -v p="$PIDB/" '$7 ~ p && $6=="ESTABLISHED" {print $5}' | grep -Ev '^::ffff:(192\.168|10\.99\.77)\.' | sort | uniq -c | sort -rn | head
N=$(netstat -tnp 2>/dev/null | awk -v p="$PIDB/" -v ip="$USA_IP:" '$7 ~ p && index($5, ip)==1' | wc -l)
echo "== сокетов sockB напрямую на $USA_IP: $N  ($( [ "$N" = 0 ] && echo 'OK: USA достигается только изнутри туннеля' || echo 'ВНИМАНИЕ: есть прямое соединение' ))"
sleep 20

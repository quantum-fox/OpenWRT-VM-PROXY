#!/bin/sh
# 05: прозрачный прокси PassWall2 для клиентов LAN (включая Win10 после gateway-on.ps1).
# "Main switch" (global.enabled) = 1 -> nftables: TCP REDIRECT, UDP TPROXY на выбранный узел для ВСЕХ устройств за LAN.
# Узел по умолчанию - "POOL leastPing" (общий трафик системы идёт через пул с лучшим пингом).
# Рабочие приложения (браузер, VS Code) явно направляются на прокси 8081/1081 = USA-via-pool (см. PRODUCT/docs/windows-setup.md).
# localhost_proxy=0: собственный трафик роутера (opkg, пробы, сам xray) идёт напрямую - иначе возможны петли.
# Переопределить узел: GLOBAL_NODE="USA-via-pool" sh 05-transparent.sh
C=passwall2
GN_IN="${GLOBAL_NODE:-}"
GLOBAL_NODE="${GLOBAL_NODE:-POOL leastPing}"
NODE=$(for id in $(uci show $C | grep '=nodes$' | cut -d. -f2 | cut -d= -f1); do [ "$(uci -q get $C.$id.remarks)" = "$GLOBAL_NODE" ] && echo $id; done)
# если уже создан shunt_global (скрипт 06: блок UA в прозрачном режиме) - использовать его, пока GLOBAL_NODE не задан явно
if [ -z "$GN_IN" ]; then
  # правила маршрутизации из скрипта 06: SYSTEM_MODE=same -> shunt_pool, SYSTEM_MODE=ua_only -> shunt_global
  if   [ -n "$(uci -q get $C.shunt_global)" ]; then NODE=shunt_global
  elif [ -n "$(uci -q get $C.shunt_pool)" ];   then NODE=shunt_pool
  fi
fi
[ -n "$NODE" ] || { echo "нет узла '$GLOBAL_NODE'"; exit 1; }

uci set $C.@global[0].node="$NODE"
uci set $C.@global[0].localhost_proxy='0'
uci set $C.@global[0].client_proxy='1'
uci set $C.@global[0].enabled='1'            # <-- главный переключатель
# после загрузки роутера PassWall2 по умолчанию ждёт 60 с - сокращаем, чтобы прокси поднимался быстрее (Win10 ждёт шлюз)
uci set $C.@global_delay[0].start_delay='20'
uci commit $C
/etc/init.d/passwall2 restart >/dev/null 2>&1
sleep 10
grep -E 'Use the (TCP|UDP) node|nftables firewall rules load' /tmp/log/passwall2.log | tail -3
nft list tables | grep passwall2
rm -f /tmp/secrets.env /tmp/links.conf       # секреты на роутере больше не нужны

#!/bin/sh
# 04: узел-балансировщик POOL (leastPing), цепочка "пул -> USA", два SOCKS/HTTP-инстанса PassWall2.
#   sockA  SOCKS 1080 / HTTP 8080  -> POOL leastPing        (личный/общий)
#   sockB  SOCKS 1081 / HTTP 8081  -> USA-via-pool          (рабочий: пул -> USA)
# Требует: выполнены 02 и 03. Идемпотентно.
C=passwall2
POOL=pool_ping
POOL_CHAIN=pool_chain      # первый хоп цепочки (может содержать узлы, исключённые из 1080/8080, см. EXCLUDE_FROM_PROXY_REGEX в /etc/pw2-pool.conf)

id_by_remarks() { for id in $(uci show $C | grep '=nodes$' | cut -d. -f2 | cut -d= -f1); do [ "$(uci -q get $C.$id.remarks)" = "$1" ] && { echo $id; return; }; done; }

USA=$(id_by_remarks USA-via-pool)
[ -n "$USA" ] || { echo "нет узла USA-via-pool (скрипт 02)"; exit 1; }

# --- узел-балансировщик (список узлов заполнит pw2-pool-sync по правилам из /etc/pw2-pool.conf)
uci -q get $C.$POOL >/dev/null || uci set $C.$POOL=nodes
uci set $C.$POOL.remarks='POOL leastPing'
uci set $C.$POOL.type='Xray'
uci set $C.$POOL.protocol='_balancing'
uci set $C.$POOL.group='own'
uci set $C.$POOL.balancingStrategy='leastPing'
uci set $C.$POOL.probeInterval='1m'
uci -q get $C.$POOL_CHAIN >/dev/null || uci set $C.$POOL_CHAIN=nodes
uci set $C.$POOL_CHAIN.remarks='POOL chain (first hop)'
uci set $C.$POOL_CHAIN.type='Xray'
uci set $C.$POOL_CHAIN.protocol='_balancing'
uci set $C.$POOL_CHAIN.group='own'
uci set $C.$POOL_CHAIN.balancingStrategy='leastPing'
uci set $C.$POOL_CHAIN.probeInterval='1m'
uci commit $C
PW2_NO_UPDATE=1 /usr/bin/pw2-pool-sync        # заполняет balancing_node

# --- цепочка: трафик узла USA сначала идёт через пул (dialerProxy), потом на USA
uci set $C.$USA.chain_proxy='1'
uci set $C.$USA.preproxy_node="$POOL_CHAIN"

# --- SOCKS/HTTP-инстансы
mk_socks() {   # имя узел порт http_порт
  uci -q get $C.$1 >/dev/null || uci set $C.$1=socks
  uci set $C.$1.enabled='1'
  uci set $C.$1.node="$2"
  uci set $C.$1.bind_local='0'               # слушать на всех интерфейсах; наружу (WAN) закрывает файрвол OpenWrt
  uci set $C.$1.port="$3"
  uci set $C.$1.http_port="$4"
  uci set $C.$1.log='0'
}
# если уже настроена RU-маршрутизация (скрипт 06), SOCKS-инстансы остаются на shunt-узлах; RU_ROUTING=0 sh 04... вернёт обычные узлы
NODE_A="$POOL"; NODE_B="$USA"
if [ "${RU_ROUTING:-1}" != "0" ]; then
  [ -n "$(uci -q get $C.shunt_pool)" ] && NODE_A=shunt_pool
  [ -n "$(uci -q get $C.shunt_usa)" ]  && NODE_B=shunt_usa
fi
mk_socks sockA "$NODE_A" 1080 8080
mk_socks sockB "$NODE_B" 1081 8081
uci set $C.@global[0].socks_enabled='1'      # "Socks Main switch" (раздел Socks Config)
uci commit $C

/etc/init.d/passwall2 enable
/etc/init.d/passwall2 restart >/dev/null 2>&1
sleep 8
echo "== порты:"; netstat -ltn | grep -E ':(1080|1081|8080|8081) '
echo "== цепочка в конфиге sockB:"; grep -o '"dialerProxy": *"[^"]*"' /tmp/etc/passwall2/sockB+http.json | sort | uniq -c

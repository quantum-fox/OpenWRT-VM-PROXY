#!/bin/sh
# 06: правила маршрутизации PassWall2 (RU / UA / CN) для SOCKS/HTTP-прокси и прозрачного режима системы.
#
#   Узел (shunt)                 где используется                                  UA     RU (ru/su/рф + IP RU)   CN (cn + geosite:cn + IP CN)
#   shunt_pool   (default=пул)   sockA: SOCKS 1080 / HTTP 8080  +  прозрачный      БЛОК   НАПРЯМУЮ                НАПРЯМУЮ, а если Китай напрямую
#                                режим системы (шлюз Win10), если SYSTEM_MODE=same                                недоступен - через пул (CN_MODE, см. 08)
#   shunt_usa    (default=USA)   sockB: SOCKS 1081 / HTTP 8081                     БЛОК   БЛОК                    как обычно (через USA)
#   shunt_global (default=пул)   прозрачный режим, если SYSTEM_MODE=ua_only        БЛОК   как обычно              как обычно
# Порядок правил (секции shunt_rules в /etc/config/passwall2) = приоритет: rule_ua, rule_ads, rule_ru, rule_ali, rule_cn.
# rule_ads: реклама и трекеры (geosite:category-ads-all + ADS_DOMAINS) - БЛОК на всех портах и в системном трафике (ADS_BLOCK=0 выключает).
# rule_ali: семейство AliExpress/Alibaba целиком напрямую на 1080/8080 и в системном трафике (иначе часть узлов сайта - страница, картинки, аналитика - уходила бы разными путями, и антибот сайта зависает);
#           на 8081/1081 - как обычно (через рабочий выход). aliexpress.ru остаётся под правилом RU (там блок), остальное - под этим правилом.
# Прямой трафик (мимо Xray) от UA защищает отдельно файрвол: см. 07-ua-firewall.sh.
# Списки и режимы редактируются в /etc/pw2-routing.conf; применить: pw2-routing-apply (этот же скрипт, установлен на роутере). Идемпотентен.
C=passwall2
CONF=/etc/pw2-routing.conf
[ -f "$CONF" ] || cat > "$CONF" <<'EOF'
# Списки правил маршрутизации. Домены - слова через пробел; префикс "domain:" добавляется сам (подходят сам домен и все поддомены).
# xn--p1ai = .рф, xn--j1amh = .укр, xn--fiqs8s = .中国, xn--fiqz9s = .中國
# Россия: напрямую на 8080/1080 и в системном трафике, блок на 8081/1081
RU_DOMAINS="ru su xn--p1ai aestatic.net"      # aestatic.net - российский CDN AliExpress: открывается только с российского IP (напрямую)
RU_GEOSITE="geosite:category-ru"
RU_GEOIP="geoip:ru"
# Украина: блок везде; IP в прямом трафике блокирует файрвол (07)
UA_DOMAINS="ua xn--j1amh"
UA_GEOSITE=""
UA_GEOIP="geoip:ua"
# Китай: напрямую на 8080/1080 и в системном трафике (на 8081/1081 - как обычно, через USA)
CN_DOMAINS="cn xn--fiqs8s xn--fiqz9s"
CN_GEOSITE="geosite:cn"
CN_GEOIP="geoip:cn"
EOF
# --- переменные, добавленные позже: дописываем в существующий конфиг, если их ещё нет
ensure() { grep -q "^$1=" "$CONF" || printf '%s\n' "$2" >> "$CONF"; }
ensure ADS_BLOCK '# Блокировка рекламы и трекеров (Xray, по доменам): 1 = блокировать на всех портах (1080/8080, 1081/8081) и в системном трафике, 0 = не блокировать. Блок виден только для трафика, проходящего через Xray (прокси и прозрачный режим).
ADS_BLOCK=1
ADS_GEOSITE="geosite:category-ads-all"          # готовый список рекламных доменов мира (~800 правил); пусто = не использовать
ADS_GEOSITE_EXTRA=""                           # дополнительные списки через пробел, например geosite:custom-ads (файл geosite_CUSTOM-ADS.dat положить в /usr/share/pw2/data/, выполнить pw2-geosite merge)
ADS_GEOSITE_RU=1                                # 1 = дополнительно российская база рекламы (~150 тыс. доменов, тег RU-ADS, данные /usr/share/pw2/data/geosite_RU-ADS.dat, подключается pw2-geosite); 0 = не использовать
ADS_DOMAINS="mc.yandex.ru mc.yandex.com an.yandex.ru yandexadexchange.net adfox.ru adriver.ru ad.mail.ru top-fwz1.mail.ru counter.yadro.ru tns-counter.ru"   # дополнительные рекламные/счётчиковые домены (российские в списке geosite не покрыты)'
ensure ALI_DOMAINS '# AliExpress/Alibaba: целиком напрямую на 8080/1080 и в системном трафике (на 8081/1081 - как обычно). Нужно, чтобы страница, картинки, API и аналитика сайта шли ОДНИМ путём (с одним IP). Пустое значение отключает правило.
ALI_DOMAINS="aliexpress.com aliexpress.ru aliexpress.us aliexpress-media.com alicdn.com alicdn.net aliyuncs.com aliyun.com mmstat.com alibabausercontent.com alibaba.com alibaba.net alipay.com alibabadns.com"'
ensure ALI_ACTION '# Куда направлять AliExpress/Alibaba на 8080/1080 и в системном трафике: _direct = напрямую (по умолчанию; работает с домашней/мобильной российской сети, Alibaba не пускает IP дата-центров), _default = через пул (если напрямую режет оператор)
ALI_ACTION="_direct"'
ensure SYSTEM_MODE '# Прозрачный режим системы (шлюз Win10): same = те же правила, что на 8080/1080 (узел shunt_pool); ua_only = только блок UA, остальное через пул (узел shunt_global)
SYSTEM_MODE="same"'
ensure CN_MODE '# Китай напрямую: auto = напрямую, пока Китай доступен с роутера напрямую, иначе через пул (следит pw2-cn-watch, см. 08); direct = всегда напрямую; proxy = всегда через пул
CN_MODE="auto"'
ensure CN_PROBES '# Проверка доступности Китая напрямую (для CN_MODE=auto): адреса, которые роутер открывает сам, минуя прокси; достаточно CN_PROBE_MIN ответов 2xx/3xx
CN_PROBES="https://www.baidu.com/ https://www.taobao.com/ https://www.aliyun.com/ https://www.bilibili.com/ https://www.sina.com.cn/"
CN_PROBE_MIN=2
CN_PROBE_TIMEOUT=8
CN_CHECK_INTERVAL=30      # секунд между проверками
CN_FAIL_THRESHOLD=20      # столько проверок подряд неудачно -> перейти на пул (~10 мин: Китай должен быть недоступен долго)
CN_OK_THRESHOLD=60        # столько проверок подряд удачно -> вернуться на напрямую (~30 мин; каждое переключение перезапускает PassWall2 и рвёт потоки, поэтому режим держится долго)'
ensure USA_BACKUP '# Запасной USA для 8081/1081: 1 = при отказе собственного USA (USA-via-pool) порт 1081/8081 автоматически переключается на узел USA ИЗ ПОДПИСКИ, при восстановлении - обратно.
# Работает штатное автопереключение SOCKS-инстанса PassWall2 (проверка реальным запросом через порт 1081). Запасной узел ищется в группе подписки по имени (egrep): USA_BACKUP_GROUP / USA_BACKUP_MATCH (ниже).
USA_BACKUP=1
USA_PROBE_URL="https://www.google.com/generate_204"   # проверочный адрес; запрос идёт ЧЕРЕЗ 1081, т.е. через USA
USA_CHECK_INTERVAL=5       # секунд между проверками (быстрое обнаружение отказа: ~25-30 с до переключения)
USA_CHECK_TIMEOUT=3        # таймаут одной попытки, с
USA_CHECK_RETRY=1          # повторов при неудаче (две попытки подряд защищают от разовых провалов)'
BG=$(. /etc/pw2-pool.conf 2>/dev/null; echo "$INCLUDE_GROUPS")      # группа подписки = та же, что у пула
ensure USA_BACKUP_GROUP "USA_BACKUP_GROUP=\"${BG:-subscription}\"   # группа подписки, где ищется запасной USA"
ensure USA_BACKUP_MATCH 'USA_BACKUP_MATCH="USA"          # регулярное выражение (egrep) по имени узла'
. "$CONF"

id_by_remarks() { for id in $(uci show $C | grep '=nodes$' | cut -d. -f2 | cut -d= -f1); do [ "$(uci -q get $C.$id.remarks)" = "$1" ] && { echo $id; return; }; done; }
POOL=pool_ping
[ -n "$(uci -q get $C.pool_chain)" ] && POOL_CHAIN=pool_chain
USA=$(id_by_remarks USA-via-pool)
[ -n "$USA" ] && [ -n "$(uci -q get $C.$POOL)" ] || { echo "нет узлов pool_ping / USA-via-pool (скрипты 02-04)"; exit 1; }

NL='
'
dl() { out=""; for d in $1; do out="${out}domain:${d}${NL}"; done; [ -n "$2" ] && out="${out}${2}${NL}"; printf '%s' "$out"; }   # домены + geosite -> текст по строке

# --- действие правила CN на shunt_pool: _direct (напрямую) или _default (через пул)
case "${CN_MODE:-auto}" in
  proxy)  CN_ACT=_default ;;
  direct) CN_ACT=_direct ;;
  *)      CN_ACT=$(cat /etc/pw2-cn.state 2>/dev/null); [ "$CN_ACT" = "_default" ] || CN_ACT=_direct ;;   # auto: последнее решение сторожа
esac

# --- миграция: убрать прежние секции/узлы (порядок правил = порядок создания, поэтому создаём заново)
for s in ruz_exc ruz_zones rule_ua rule_ads rule_ru rule_ali rule_cn shunt_pool shunt_usa shunt_usa_b shunt_global usa_ha; do uci -q delete $C.$s; done

# --- правила (группа RULES)
mk_rule() {   # имя remarks domain_list ip_list
  uci set $C.$1=shunt_rules
  uci set $C.$1.remarks="$2"
  uci set $C.$1.group='RULES'
  uci set $C.$1.network='tcp,udp'
  [ -n "$3" ] && uci set $C.$1.domain_list="$3"
  [ -n "$4" ] && uci set $C.$1.ip_list="$4"
}
mk_rule rule_ua 'UA: ua/ukr domains + UA IPs' "$(dl "$UA_DOMAINS" "$UA_GEOSITE")" "$UA_GEOIP"
ADS_LIST="$(dl "$ADS_DOMAINS" "$ADS_GEOSITE")${NL}"      # $(...) отбрасывает последний перевод строки - возвращаем, иначе следующая строка склеится
# дополнительные списки (российская база и т. п.): PassWall2 не поддерживает "ext:файл:тег", поэтому pw2-geosite дописывает их в geosite.dat, и они подключаются как geosite:<тег>
[ -x /usr/bin/pw2-geosite ] && /usr/bin/pw2-geosite merge >/dev/null 2>&1
if [ "${ADS_GEOSITE_RU:-1}" = "1" ]; then
  if grep -qa "RU-ADS" /usr/share/v2ray/geosite.dat 2>/dev/null; then ADS_LIST="${ADS_LIST}geosite:ru-ads${NL}"; else echo "ВНИМАНИЕ: российская база рекламы (RU-ADS) не подключена к geosite.dat - пропущена (загрузите данные: install-router.ps1, затем pw2-geosite merge)"; fi
fi
for t in $ADS_GEOSITE_EXTRA; do   # например geosite:custom-ads (только если такой тег есть в geosite.dat)
  tag=$(echo "${t#geosite:}" | tr 'a-z' 'A-Z')
  if grep -qa "$tag" /usr/share/v2ray/geosite.dat 2>/dev/null; then ADS_LIST="${ADS_LIST}${t}${NL}"; else echo "ВНИМАНИЕ: список $t не найден в geosite.dat - пропущен (pw2-geosite merge)"; fi
done
[ "${ADS_BLOCK:-1}" = "1" ] && mk_rule rule_ads 'ADS: advertising and trackers' "$ADS_LIST" ""
mk_rule rule_ru 'RU: ru/su/rf domains + RU IPs' "$(dl "$RU_DOMAINS" "$RU_GEOSITE")" "$RU_GEOIP"
[ -n "$ALI_DOMAINS" ] && mk_rule rule_ali 'ALI: AliExpress/Alibaba domains' "$(dl "$ALI_DOMAINS" "")" ""
mk_rule rule_cn 'CN: cn domains + geosite:cn + CN IPs' "$(dl "$CN_DOMAINS" "$CN_GEOSITE")" "$CN_GEOIP"

# --- shunt-узлы
mk_shunt() {   # имя remarks default_node
  uci set $C.$1=nodes
  uci set $C.$1.remarks="$2"
  uci set $C.$1.type='Xray'
  uci set $C.$1.protocol='_shunt'
  uci set $C.$1.group='own'
  uci set $C.$1.default_node="$3"
  uci set $C.$1.domainStrategy='IPOnDemand'      # домен резолвится для проверки по IP-правилам (geoip)
  uci set $C.$1.domainMatcher='hybrid'
  uci set $C.$1.PrivateIP='_direct'
  uci set $C.$1.shunt_group='RULES'              # применять правила группы RULES
}
mk_shunt shunt_pool   'SHUNT pool: RU+CN direct, UA blocked' "$POOL"
[ "${ADS_BLOCK:-1}" = "1" ] && uci set $C.shunt_pool.rule_ads='_blackhole'
uci set $C.shunt_pool.rule_ua='_blackhole'; uci set $C.shunt_pool.rule_ru='_direct'; uci set $C.shunt_pool.rule_cn="$CN_ACT"
[ -n "$ALI_DOMAINS" ] && uci set $C.shunt_pool.rule_ali="${ALI_ACTION:-_direct}"
mk_shunt shunt_usa    'SHUNT USA: RU+UA blocked'              "$USA"
[ "${ADS_BLOCK:-1}" = "1" ] && uci set $C.shunt_usa.rule_ads='_blackhole'
uci set $C.shunt_usa.rule_ua='_blackhole';  uci set $C.shunt_usa.rule_ru='_blackhole'
[ -n "$ALI_DOMAINS" ] && uci set $C.shunt_usa.rule_ali='_default'

# --- запасной USA (штатное автопереключение PassWall2 для sockB): узел shunt_usa_b = те же правила, но выход через USA из подписки
BK=""
if [ "${USA_BACKUP:-1}" = "1" ]; then
  for id in $(uci show $C | grep '=nodes$' | cut -d. -f2 | cut -d= -f1); do
    [ "$(uci -q get $C.$id.group)" = "$USA_BACKUP_GROUP" ] || continue
    uci -q get $C.$id.remarks | grep -qE "$USA_BACKUP_MATCH" && { BK=$id; break; }
  done
  [ -n "$BK" ] || echo "ВНИМАНИЕ: в группе '$USA_BACKUP_GROUP' нет узла по шаблону '$USA_BACKUP_MATCH' - запасной USA не настроен"
fi
if [ -n "$BK" ]; then
  mk_shunt shunt_usa_b 'SHUNT USA backup: RU+UA blocked (subscription USA via pool)' "$BK"
  [ "${ADS_BLOCK:-1}" = "1" ] && uci set $C.shunt_usa_b.rule_ads='_blackhole'
  uci set $C.shunt_usa_b.rule_ua='_blackhole'; uci set $C.shunt_usa_b.rule_ru='_blackhole'
  [ -n "$ALI_DOMAINS" ] && uci set $C.shunt_usa_b.rule_ali='_default'
  uci set $C.shunt_usa_b.default_proxy_tag="${POOL_CHAIN:-$POOL}"   # цепочка: пул -> USA из подписки (напрямую он бывает недоступен); проверено: прямых сокетов к узлу нет
fi
if [ "${SYSTEM_MODE:-same}" = "ua_only" ]; then
  mk_shunt shunt_global 'SHUNT global: UA blocked'            "$POOL"
  [ "${ADS_BLOCK:-1}" = "1" ] && uci set $C.shunt_global.rule_ads='_blackhole'
  uci set $C.shunt_global.rule_ua='_blackhole'
  [ -n "$ALI_DOMAINS" ] && uci set $C.shunt_global.rule_ali='_default'
  SYS_NODE=shunt_global
else
  SYS_NODE=shunt_pool
fi

# --- привязка
uci set $C.sockA.node='shunt_pool'
uci set $C.sockB.node='shunt_usa'
uci -q delete $C.sockB.autoswitch_backup_node
if [ -n "$BK" ]; then
  uci set $C.sockB.enable_autoswitch='1'
  uci set $C.sockB.backup_node_add_mode='manual'
  uci add_list $C.sockB.autoswitch_backup_node='shunt_usa_b'
  uci set $C.sockB.autoswitch_restore_switch='1'               # когда основной USA снова работает - вернуться на него
  uci set $C.sockB.autoswitch_probe_url="$USA_PROBE_URL"
  uci set $C.sockB.autoswitch_testing_time="$USA_CHECK_INTERVAL"
  uci set $C.sockB.autoswitch_connect_timeout="$USA_CHECK_TIMEOUT"
  uci set $C.sockB.autoswitch_retry_num="$USA_CHECK_RETRY"
else
  uci set $C.sockB.enable_autoswitch='0'
fi
uci set $C.@global[0].node="$SYS_NODE"
uci commit $C

/etc/init.d/passwall2 restart >/dev/null 2>&1
sleep 10
echo "== узлы: sockA=$(uci get $C.sockA.node) sockB=$(uci get $C.sockB.node) система(global)=$(uci get $C.@global[0].node)"
echo "== CN_MODE=${CN_MODE:-auto}; правило CN сейчас: $CN_ACT  (_direct = напрямую, _default = через пул)"
for f in sockA sockB; do
  echo "== правила $f:"; jsonfilter -i /tmp/etc/passwall2/$f+http.json -e '@.routing.rules[*].ruleTag' 2>/dev/null
done

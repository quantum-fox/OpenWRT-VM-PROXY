#!/bin/sh
# 02: подписка провайдера + собственные узлы. Идемпотентно: существующие узлы не дублируются (REPLACE=1 - заменить их).
# Читает /tmp/secrets.env (шаблон: secrets.env.example):
#   SUB_URL      адрес подписки провайдера (обязательно; пусто или PLACEHOLDER = подписку не скачивать)
#   SUB_SECTION  имя секции подписки в UCI (по умолчанию sub1);  SUB_REMARK - имя группы узлов (по умолчанию subscription)
#   LINK_WORK    ссылка vless:// вашего сервера для РАБОЧЕГО выхода (порт 1081/8081); станет узлом USA-via-pool (цепочка пул -> этот сервер)
#   LINK_EXTRA   необязательно: ещё один ваш сервер, который войдёт в общий пул; EXTRA_NAME - его имя в PassWall2
# Имена узлов задаёт этот скрипт, а не фрагмент после # в ссылке.
C=passwall2
[ -f /tmp/secrets.env ] || { echo "нет /tmp/secrets.env"; exit 1; }
. /tmp/secrets.env
SUB_SECTION="${SUB_SECTION:-sub1}"; SUB_REMARK="${SUB_REMARK:-subscription}"

# --- подписка; автообновление PassWall2 НЕ включаем - этим занимается pw2-pool-sync (cron каждые 6 часов)
uci -q get $C.$SUB_SECTION >/dev/null || uci set $C.$SUB_SECTION=subscribe_list
uci set $C.$SUB_SECTION.remark="$SUB_REMARK"
# защита: если в secrets.env заглушка, а на роутере уже настоящий адрес подписки - оставляем настоящий
case "$SUB_URL" in
  ""|*PLACEHOLDER*|*example.invalid*)
    cur=$(uci -q get $C.$SUB_SECTION.url)
    case "$cur" in ""|*example.invalid*) ;; *) SUB_URL="$cur"; echo "== в secrets.env адрес подписки не задан - оставлен текущий";; esac ;;
esac
uci set $C.$SUB_SECTION.url="$SUB_URL"
uci set $C.$SUB_SECTION.allowInsecure='0'
uci commit $C
case "$SUB_URL" in
  ""|*PLACEHOLDER*|*example.invalid*) echo "== адрес подписки не задан - загрузка пропущена" ;;
  *) echo "== скачиваю подписку"
     # Многие провайдеры отдают вместо узлов заглушку («приложение не поддерживается»), если программа-клиент им незнакома.
     # Поэтому пробуем несколько имён клиента (User-Agent) по очереди и оставляем то, при котором пришли настоящие узлы.
     good_count() {   # число настоящих узлов подписки: не заглушки placeholder-*, не «служебные» ответы провайдера
       n=0; for id in $(uci show $C | grep '=nodes$' | cut -d. -f2 | cut -d= -f1); do
         [ "$(uci -q get $C.$id.group)" = "$SUB_REMARK" ] || continue
         rem=$(uci -q get $C.$id.remarks)
         case "$rem" in placeholder-*) continue;; esac
         echo "$rem" | grep -qiE 'не поддерж|not supported|unsupported|обнови|update (the )?app|upgrade|expired|истек|истёк|лимит|traffic' && continue
         n=$((n+1)); done; echo $n; }
     found=0
     for UA in "" "v2rayN/7.0" "Happ/2.0" "clash-verge/v1.7.7" "Hiddify/2.0" "sing-box" "passwall2"; do
       if [ -n "$UA" ]; then uci set $C.$SUB_SECTION.user_agent="$UA"; else uci -q delete $C.$SUB_SECTION.user_agent; fi
       uci commit $C
       lua /usr/share/passwall2/subscribe.lua start $SUB_SECTION manual >/dev/null 2>&1
       cnt=$(good_count)
       if [ "$cnt" -ge 2 ]; then echo "подписка загружена: $cnt узлов (имя клиента: ${UA:-по умолчанию})"; found=1; break; fi
       echo "  имя клиента '${UA:-по умолчанию}': настоящих узлов нет ($cnt) - пробую следующее"
     done
     if [ $found = 0 ]; then
       uci -q delete $C.$SUB_SECTION.user_agent; uci commit $C
       echo "ПРЕДУПРЕЖДЕНИЕ: подписка не дала узлов ни с одним именем клиента. Проверьте адрес (откройте его в браузере: должен показать длинный набор символов или список ссылок vless://) и действие подписки у провайдера."
     fi
     # убрать «служебные» узлы-ответы провайдера, чтобы они не попали в пул
     for id in $(uci show $C | grep '=nodes$' | cut -d. -f2 | cut -d= -f1); do
       [ "$(uci -q get $C.$id.group)" = "$SUB_REMARK" ] || continue
       echo "$(uci -q get $C.$id.remarks)" | grep -qiE 'не поддерж|not supported|unsupported' && uci delete $C.$id
     done; uci commit $C ;;
esac

# --- собственные узлы (группа 'own')
ids_now()    { uci show $C | grep '=nodes$' | cut -d. -f2 | cut -d= -f1 | sort; }
ids_by_rem() { for id in $(ids_now); do [ "$(uci -q get $C.$id.remarks)" = "$1" ] && echo $id; done; }
add_link() {   # $1 = имя узла, $2 = ссылка
  [ -n "$2" ] || return 0
  if [ -n "$(ids_by_rem "$1")" ]; then
    if [ "$REPLACE" = 1 ]; then for id in $(ids_by_rem "$1"); do uci delete $C.$id; done; uci commit $C
    else echo "узел '$1' уже есть - пропуск"; return 0; fi
  fi
  ids_now > /tmp/ids.before
  printf '%s\n' "$2" > /tmp/links.conf
  lua /usr/share/passwall2/subscribe.lua add own >/dev/null 2>&1
  new=$(ids_now | grep -vxFf /tmp/ids.before | head -1)
  if [ -n "$new" ]; then uci set $C.$new.remarks="$1"; uci commit $C; echo "узел '$1' добавлен ($new)"
  else echo "ОШИБКА: ссылка для '$1' не распознана (нужен vless:// ...)"; fi
}
add_link USA-via-pool "$LINK_WORK"
[ -n "$LINK_EXTRA" ] && add_link "${EXTRA_NAME:-own-extra}" "$LINK_EXTRA"
rm -f /tmp/ids.before

echo "== узлы (id | группа | имя | адрес:порт):"
for id in $(ids_now); do
  echo "$id | $(uci -q get $C.$id.group) | $(uci -q get $C.$id.remarks) | $(uci -q get $C.$id.address):$(uci -q get $C.$id.port)"
done

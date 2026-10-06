#!/bin/sh
# 03: установка pw2-pool-sync (+конфиг правил и cron раз в 6 часов).
# Файл pw2-pool-sync берётся из /usr/share/pw2 (там же лежит этот скрипт) или из /tmp.
# Значения для /etc/pw2-pool.conf (SUB_SECTION, SUB_REMARK, EXTRA_NAME) читаются из /tmp/secrets.env, если он есть.
PW2_DIR=${PW2_DIR:-/usr/share/pw2}
SRC=$PW2_DIR/pw2-pool-sync; [ -f "$SRC" ] || SRC=/tmp/pw2-pool-sync
[ -f "$SRC" ] || { echo "нет pw2-pool-sync (ни в $PW2_DIR, ни в /tmp)"; exit 1; }
[ -f /tmp/secrets.env ] && . /tmp/secrets.env
tr -d '\r' < "$SRC" > /usr/bin/pw2-pool-sync && chmod +x /usr/bin/pw2-pool-sync && sh -n /usr/bin/pw2-pool-sync || exit 1

[ -f /etc/pw2-pool.conf ] || cat > /etc/pw2-pool.conf <<EOF
# Правила состава пула (читает /usr/bin/pw2-pool-sync). Меняйте тут, а не в скрипте.
SUB_SECTIONS="${SUB_SECTION:-sub1}"          # секции subscribe_list для обновления
POOL_NODE="pool_ping"                  # балансировщик для 1080/8080 и системного трафика
POOL_CHAIN_NODE="pool_chain"           # балансировщик - первый хоп цепочки на рабочий сервер
EXCLUDE_FROM_PROXY_REGEX=''            # узлы, которые не используются как выход 1080/8080/система, но остаются первым хопом цепочки (egrep), например 'Russia'
INCLUDE_GROUPS="${SUB_REMARK:-subscription}"      # группы (remark подписки), узлы которых входят в пул; несколько - через |
EXCLUDE_REGEX='USA'                    # исключить узлы, в имени которых это встречается
EXTRA_REMARKS="${LINK_EXTRA:+$EXTRA_NAME}"      # узлы по точному имени из любых групп; несколько - через |
MIN_NODES=5                            # защита: если подходящих узлов меньше - список не трогаем
DO_UPDATE=1                            # 1 = сначала скачать подписку
EOF

# cron: каждые 6 часов в :17. Имя скрипта без слова "passwall2" - иначе PassWall2 сотрёт строку при перезапуске.
touch /etc/crontabs/root
grep -q pw2-pool-sync /etc/crontabs/root || echo '17 */6 * * * /usr/bin/pw2-pool-sync >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron enable; /etc/init.d/cron restart
echo "установлено. cron:"; grep pw2-pool-sync /etc/crontabs/root

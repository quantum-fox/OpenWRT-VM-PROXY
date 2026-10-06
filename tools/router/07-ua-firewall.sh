#!/bin/sh
# 07: файрвол-блок IP Украины (nftables) для всего трафика через роутер и от роутера. См. pw2-ua-block.
# Файл pw2-ua-block берётся из /usr/share/pw2 (там же лежит этот скрипт) или из /tmp.
PW2_DIR=${PW2_DIR:-/usr/share/pw2}
SRC=$PW2_DIR/pw2-ua-block; [ -f "$SRC" ] || SRC=/tmp/pw2-ua-block
[ -f "$SRC" ] || { echo "нет pw2-ua-block (ни в $PW2_DIR, ни в /tmp)"; exit 1; }
tr -d '\r' < "$SRC" > /usr/bin/pw2-ua-block && chmod +x /usr/bin/pw2-ua-block && sh -n /usr/bin/pw2-ua-block || exit 1

# автозагрузка при старте роутера (таблица живёт отдельно от fw4 и PassWall2)
cat > /etc/init.d/ua-block <<'EOF'
#!/bin/sh /etc/rc.common
START=19
STOP=19
start() { [ -f /etc/ua-block.nft ] && nft -f /etc/ua-block.nft && logger -t ua-block "UA IP block loaded"; }
stop()  { nft delete table inet ua_block 2>/dev/null; }
EOF
chmod +x /etc/init.d/ua-block
/etc/init.d/ua-block enable

# раз в неделю пересобирать список из актуального geoip.dat (в имени команды нет слова "passwall2" - иначе PassWall2 сотрёт строку cron)
touch /etc/crontabs/root
grep -q pw2-ua-block /etc/crontabs/root || echo '30 4 * * 0 /usr/bin/pw2-ua-block >/dev/null 2>&1' >> /etc/crontabs/root
/etc/init.d/cron restart

/usr/bin/pw2-ua-block
echo "--- таблица:"; nft list table inet ua_block | grep -E 'table|chain|counter' | head -8

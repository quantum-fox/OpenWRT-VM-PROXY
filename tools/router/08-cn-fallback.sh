#!/bin/sh
# 08: автопереключение "Китай напрямую / через пул" (служба cn-watch) и ручное управление (команда pw2-cn-mode).
# Файлы pw2-cn-watch и pw2-cn-mode берутся из /usr/share/pw2 (там же лежит этот скрипт) или из /tmp.
# Требует выполненный 06 (создаёт /etc/pw2-routing.conf с переменными CN_*).
PW2_DIR=${PW2_DIR:-/usr/share/pw2}
for f in pw2-cn-watch pw2-cn-mode; do
  SRC=$PW2_DIR/$f; [ -f "$SRC" ] || SRC=/tmp/$f
  [ -f "$SRC" ] || { echo "нет $f (ни в $PW2_DIR, ни в /tmp)"; exit 1; }
  tr -d '\r' < "$SRC" > /usr/bin/$f && chmod +x /usr/bin/$f && sh -n /usr/bin/$f || exit 1
done

cat > /etc/init.d/cn-watch <<'EOF'
#!/bin/sh /etc/rc.common
START=98
USE_PROCD=1
start_service() {
  procd_open_instance
  procd_set_param command /usr/bin/pw2-cn-watch
  procd_set_param respawn
  procd_close_instance
}
EOF
chmod +x /etc/init.d/cn-watch
/etc/init.d/cn-watch enable
/etc/init.d/cn-watch restart
sleep 2
pw2-cn-mode status

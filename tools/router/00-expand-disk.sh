#!/bin/sh
# 00: расширение корневого раздела образа OpenWrt (ext4-combined-efi) на весь виртуальный диск. Причина и разбор: см. docs "Расширение диска".
# Почему так сложно: в штатном образе resize-inode ext4 несогласован, онлайн-расширение (resize2fs) падает с "Invalid argument".
# Лечится только офлайн, а корень работающей системы отмонтировать нельзя - поэтому система временно загружается с копии корня (sda3).
# ЗАПУСКАТЬ ПОВТОРНО после каждой автоматической перезагрузки, пока не появится "ГОТОВО" (всего 3 запуска, 2 перезагрузки).
# Требования: виртуальный диск уже увеличен (VBoxManage modifymedium --resize 3072) и есть интернет (opkg).
DISK=/dev/sda
say() { echo "== $*"; }
puid() { blkid "$1" 2>/dev/null | sed -n 's/.*PARTUUID="\([^"]*\)".*/\1/p'; }
fail() { echo "ОШИБКА: $*" >&2; exit 1; }

say "пакеты (parted, e2fsprogs, resize2fs, blkid)"
opkg update >/dev/null 2>&1; opkg install parted e2fsprogs resize2fs blkid >/dev/null 2>&1
for c in parted blkid e2fsck resize2fs mkfs.ext4; do command -v $c >/dev/null 2>&1 || fail "не установлен $c (нет интернета/opkg?)"; done

CMDROOT=$(sed -n 's/.*root=PARTUUID=\([^ ]*\).*/\1/p' /proc/cmdline)
P2=$(puid ${DISK}2); P3=$(puid ${DISK}3)
TOTAL=$(cat /sys/block/sda/size)                      # секторов по 512 Б

mount_boot() {   # монтируем FAT-раздел с GRUB отдельно и находим grub.cfg
  mkdir -p /mnt/p1; grep -q ' /mnt/p1 ' /proc/mounts || mount ${DISK}1 /mnt/p1 || fail "не удалось смонтировать ${DISK}1"
  GRUBCFG=$(find /mnt/p1 -name grub.cfg | head -1); [ -n "$GRUBCFG" ] || fail "grub.cfg не найден"
}

if [ -n "$P3" ] && [ "$CMDROOT" = "$P3" ]; then PHASE=2
elif [ -n "$P3" ]; then PHASE=3
else
  KB=$(df -k / | awk 'NR==2{print $2}')
  [ "$KB" -gt 1500000 ] && { say "ГОТОВО: корень уже $((KB/1024)) МБ"; df -h /; exit 0; }
  [ "$TOTAL" -gt 4200000 ] || fail "виртуальный диск слишком мал ($((TOTAL/2048)) МБ): увеличьте до 3072 МБ командой VBoxManage modifymedium disk <vdi> --resize 3072 (VM выключена)"
  PHASE=1
fi
say "этап $PHASE из 3"

case $PHASE in
1)
  parted -s -f $DISK print >/dev/null 2>&1                    # -f: чинит резервную GPT-таблицу после роста диска
  END=$((TOTAL/2048*2048 - 2048 - 1)); START=$(( (END - 2097152 + 1)/2048*2048 ))   # временный раздел: последний гигабайт диска
  parted -s -f $DISK mkpart tmproot ext4 ${START}s ${END}s || fail "не создан раздел sda3"
  i=0; while [ ! -b ${DISK}3 ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
  [ -b ${DISK}3 ] || fail "раздел sda3 не появился (перезагрузите роутер и запустите заново)"
  mkfs.ext4 -F -L tmproot ${DISK}3 >/dev/null 2>&1 || fail "mkfs.ext4 не удался"
  mkdir -p /mnt/new && mount ${DISK}3 /mnt/new || fail "не смонтирован sda3"
  for e in /*; do b=${e#/}
    case "$b" in proc|sys|dev|tmp|mnt|boot|lost+found) mkdir -p /mnt/new/$b; continue;; esac
    cp -a "$e" /mnt/new/ || fail "ошибка копирования $e"
  done
  chmod 1777 /mnt/new/tmp; sync; umount /mnt/new
  P3=$(puid ${DISK}3); [ -n "$P3" ] || fail "нет PARTUUID у sda3"
  mount_boot
  [ -f "$GRUBCFG.orig" ] || cp "$GRUBCFG" "$GRUBCFG.orig"
  { sed -n '1,/^menuentry/{/^menuentry/!p}' "$GRUBCFG.orig"
    sed -n '/^menuentry "OpenWrt" {/,/^}/p' "$GRUBCFG.orig" | sed "s/$P2/$P3/; s/\"OpenWrt\"/\"OpenWrt (TEMP root on sda3)\"/"
    sed -n '/^menuentry/,$p' "$GRUBCFG.orig"; } > "$GRUBCFG"
  sync; say "перезагрузка (временный корень sda3). После загрузки запустите этот скрипт снова."; reboot ;;
2)
  [ "$(df -k / | awk 'NR==2{print $2}')" -lt 1500000 ] || say "корень на sda3"
  S3=$(parted -s $DISK unit s print | awk '$1=="3"{gsub("s","",$2); print $2}')
  parted -s -f $DISK resizepart 2 $((S3 - 1))s || fail "не расширен раздел sda2"
  e2fsck -f -y ${DISK}2 >/dev/null 2>&1                       # чинит resize-inode (код возврата 1-2 = исправлено)
  resize2fs ${DISK}2 >/dev/null 2>&1 || fail "офлайн resize2fs не удался"
  e2fsck -f -y ${DISK}2 >/dev/null 2>&1
  e2fsck -f -n ${DISK}2 >/dev/null 2>&1 || fail "файловая система sda2 не прошла проверку"
  mkdir -p /mnt/old && mount ${DISK}2 /mnt/old || fail "не смонтирован sda2"
  cp -a /etc/. /mnt/old/etc/ && cp -a /root/. /mnt/old/root/; sync; umount /mnt/old   # свежие настройки, изменившиеся после копирования
  mount_boot; cp "$GRUBCFG.orig" "$GRUBCFG"; sync
  say "перезагрузка (возврат на sda2). После загрузки запустите этот скрипт снова."; reboot ;;
3)
  parted -s -f $DISK rm 3 || fail "не удалён sda3"
  parted -s -f $DISK resizepart 2 100% || fail "не расширен sda2"
  resize2fs ${DISK}2 >/dev/null 2>&1 || fail "онлайн resize2fs не удался"
  say "ГОТОВО"; df -h / ;;
esac

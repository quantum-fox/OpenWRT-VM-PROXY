#!/bin/sh
# 01: пакеты. LuCI + фид PassWall2 + luci-app-passwall2 + xray-core (свежий из фида PassWall2) + модули tproxy.
# Платформа: OpenWrt 23.05.x, x86_64 (для другой архитектуры замените x86_64 в URL фидов).
# ВАЖНО: списки opkg лежат в /var/opkg-lists = tmpfs и пропадают после перезагрузки -> перед install всегда opkg update.
set -e
B=https://master.dl.sourceforge.net/project/openwrt-passwall-build
ARCH=x86_64
REL=packages-23.05

opkg update
opkg install luci luci-ssl                      # веб-интерфейс (на образе уже стоял)

# dnsmasq-full ОБЯЗАТЕЛЕН. Штатный dnsmasq собран без nftset: собственный DNS-экземпляр PassWall2 тогда падает
# ("dnsmasq_acl_default crashed, restarting" в /tmp/log/passwall2.log, ошибка "recompile with HAVE_NFTSET"),
# клиенты LAN не могут резолвить имена -> "нет интернета" при прозрачном прокси.
if ! dnsmasq --version | grep -q ' nftset'; then
  cp /etc/config/dhcp /root/dhcp.backup
  rm -f /etc/resolv.conf; echo "nameserver 1.1.1.1" > /etc/resolv.conf       # на время замены пакета локального резолвера нет
  opkg remove dnsmasq
  opkg install dnsmasq-full
  [ -f /etc/config/dhcp ] || cp /root/dhcp.backup /etc/config/dhcp
  rm -f /etc/resolv.conf; ln -s /tmp/resolv.conf /etc/resolv.conf            # вернуть штатную ссылку
  /etc/init.d/dnsmasq enable; /etc/init.d/dnsmasq restart
fi

# ключ подписи фида PassWall2 (ipk.pub). Файла passwall.pub в этом репозитории НЕТ - не использовать.
wget -q -T 30 -O /tmp/ipk.pub $B/ipk.pub
opkg-key add /tmp/ipk.pub

F=/etc/opkg/customfeeds.conf
grep -q "passwall2$"          $F || echo "src/gz passwall2 $B/releases/$REL/$ARCH/passwall2"          >> $F
grep -q "passwall_packages$"  $F || echo "src/gz passwall_packages $B/releases/$REL/$ARCH/passwall_packages" >> $F
opkg update

opkg install luci-app-passwall2 luci-i18n-passwall2-ru
opkg upgrade xray-core                          # версия из фида PassWall2 новее официальной (26.9.x против 24.12.x)
opkg install kmod-nft-tproxy kmod-nft-socket    # нужны для прозрачного прокси (UDP/TPROXY)

# перезапуск веб-части, чтобы появился раздел Services -> PassWall 2
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache
/etc/init.d/rpcd restart; /etc/init.d/uhttpd restart

xray -version | head -1
opkg list-installed | grep -E 'passwall|xray|geo|kmod-nft-(tproxy|socket)'

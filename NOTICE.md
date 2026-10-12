# Лицензии и источники

## Код и документация этого проекта
Лицензия **MIT** — файл [LICENSE](LICENSE). Автор: quantum-fox.

## Данные: база рекламы (`tools/router/data/geosite_ADS-GLOBAL.dat`, `geosite_ADS-RU.dat`)
Файлы собраны проектом [OpenWRT-VM-PROXY-ads](https://github.com/quantum-fox/OpenWRT-VM-PROXY-ads) из публичных источников: список `category-ads-all` из [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat) (GPL-3.0; построен на [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community), MIT), [AdGuard DNS filter](https://github.com/AdguardTeam/AdGuardSDNSFilter) (GPL-3.0), [Peter Lowe's Ad and tracking server list](https://pgl.yoyo.org/adservers/) (автор разрешает объединять и публиковать) и собственные дополнения. Поэтому файлы данных (как производные) распространяются на условиях **GPL-3.0**: текст лицензии - `tools/router/data/LICENSE-GPL-3.0.txt`, подробности по источникам - `NOTICE.md` репозитория `OpenWRT-VM-PROXY-ads`. Файлы данных - отдельные от кода объекты: их лицензия не распространяется на скрипты проекта (код остаётся под MIT).

## Используемые программы (не входят в поставку)
OpenWrt, PassWall2, Xray-core, VirtualBox устанавливаются из своих источников по своим лицензиям.

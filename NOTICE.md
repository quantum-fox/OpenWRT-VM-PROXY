# Лицензии и источники

## Код и документация этого проекта
Лицензия **MIT** — файл [LICENSE](LICENSE). Автор: quantum-fox.

## Данные: российская база рекламы (`tools/router/data/geosite_RU-ADS.dat`)
Файл получен вырезкой списка `category-ads-all` из базы [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat), которая собрана на основе [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community) (лицензия MIT). Репозиторий `runetfreedom/russia-v2ray-rules-dat` распространяется под **GNU GPL v3**, поэтому этот файл данных (как производный) также распространяется на условиях **GPL-3.0**: текст лицензии — `tools/router/data/LICENSE-GPL-3.0.txt`. Исходный список и способ получения файла — в скрипте `build-geosite-ru.py` владельца проекта (скачивание базы и вырезка списка, описание — в `docs/routing-rules.md`). Файл данных — отдельный от кода объект: его лицензия не распространяется на скрипты проекта (код остаётся под MIT).

## Используемые программы (не входят в поставку)
OpenWrt, PassWall2, Xray-core, VirtualBox устанавливаются из своих источников по своим лицензиям.

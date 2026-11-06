#!/bin/sh
# Запуск окна управления роутером (нужны python3, python3-tk и openssh-client)
cd "$(dirname "$0")" || exit 1
exec python3 pw2-gui.py "$@"

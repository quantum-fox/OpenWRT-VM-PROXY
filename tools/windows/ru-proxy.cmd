@echo off
rem Knopka: vse rossiyskie resursy CHEREZ PROKSI (pri belyh spiskah operatora)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ru-mode.ps1" proxy
pause

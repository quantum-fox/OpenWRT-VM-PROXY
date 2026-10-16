@echo off
rem usage: ru-mode.cmd [status^|direct^|proxy^|node ID]  (double click = status)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ru-mode.ps1" %*
pause

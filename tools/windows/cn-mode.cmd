@echo off
rem usage: cn-mode.cmd [status^|auto^|direct^|proxy]  (double click = status)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cn-mode.ps1" %*
pause

@echo off
rem Knopka: vse rossiyskie resursy CHEREZ CEPOCHKU (pul -> rossiyskiy server) pri belyh spiskah, kogda rossiyskiy server napryamuyu nedostupen
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ru-mode.ps1" chain
pause

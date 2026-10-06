@echo off
rem run gateway script elevated, bypassing ExecutionPolicy (double click); window stays open
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0gateway-off.ps1\"'"

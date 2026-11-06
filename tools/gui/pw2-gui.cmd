@echo off
rem Zapusk okna upravleniya routerom (nuzhen Python 3 s tkinter i klient ssh). Esli ne zapuskaetsya - sm. docs\gui.md
where pythonw >nul 2>nul
if %errorlevel%==0 (
  start "" pythonw "%~dp0pw2-gui.py"
  exit /b
)
where py >nul 2>nul
if %errorlevel%==0 (
  start "" py -3w "%~dp0pw2-gui.py"
  exit /b
)
echo Python 3 ne najden. Ustanovite Python s python.org (galochka "tcl/tk") ili ispolzujte gotovyj pw2-gui.exe iz relizov.
pause

@echo off
if /I "%~1"=="-h" goto help
if /I "%~1"=="--help" goto help
pwsh.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0desktop-run-core.ps1" %*
exit /b %ERRORLEVEL%

:help
pwsh.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0desktop-run-core.ps1" /h
exit /b %ERRORLEVEL%

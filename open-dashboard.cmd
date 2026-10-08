@echo off
set "EDGE_PWSH=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"
if not exist "%EDGE_PWSH%" set "EDGE_PWSH=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%EDGE_PWSH%" -NoProfile -File "%~dp0open-dashboard.ps1" -Restart
if errorlevel 1 pause

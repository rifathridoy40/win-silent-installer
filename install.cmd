@echo off
rem Double-click launcher: runs install.ps1 without changing the system execution policy.
rem Any arguments are passed through, e.g.  install.cmd -Config profiles\full-dev.json -Yes
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*

@echo off

rem $1 is the repository directory, not the game directory.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0PreSynchronize.ps1" -repo_path "%~1"
exit /b 0

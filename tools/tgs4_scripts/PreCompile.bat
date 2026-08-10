@echo off
cd /D "%~dp0"
set "RSC_DEPLOY_CONFIG=%~dp0..\GameStaticFiles\config\rsc_deploy.env"
set TG_BOOTSTRAP_CACHE=%cd%
rem TGS quotes an argument containing spaces, so always strip them with %~1.
IF NOT "%~1" == "" (
	rem TGS4: we are passed the game directory on the command line
	cd /D "%~1"
) ELSE IF EXIST "..\Game\B\tgstation.dmb" (
	rem TGS3: Game/B/tgstation.dmb exists, so build in Game/A
	cd ..\Game\A
) ELSE (
	rem TGS3: Otherwise build in Game/B
	cd ..\Game\B
)
set CBT_BUILD_MODE=TGS
rem Without "call", cmd hands control to build.bat and never comes back, so
rem everything below this line would silently never run.
call tools\build\build
if errorlevel 1 exit /b %errorlevel%
call tools\bootstrap\python.bat tools\rsc_deploy\rsc_deploy.py prepare --game-dir "%cd%" --revision "%~2" --config "%RSC_DEPLOY_CONFIG%"
exit /b %errorlevel%

@echo off
rem ===========================================================================
rem EPF Data Purge - Release builder launcher
rem ===========================================================================
rem Purpose : Starts make_release.ps1 in Windows PowerShell 5.1 with the given
rem           arguments and returns its exit code.
rem Usage   : make_release.bat [--force] [--version] [--help]
rem Exit    : 0 built, 1 refused or failed, 4 usage error.
rem ===========================================================================
setlocal
set "EPF_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%EPF_PS%" set "EPF_PS=powershell.exe"
"%EPF_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0make_release.ps1" %*
exit /b %ERRORLEVEL%

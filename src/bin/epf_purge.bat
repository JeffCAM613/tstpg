@echo off
rem ===========================================================================
rem EPF Data Purge - Launcher
rem ===========================================================================
rem Purpose : Starts the wrapper (lib\epf.ps1) in Windows PowerShell 5.1 with
rem           the given arguments and returns its exit code.
rem Usage   : epf_purge.bat [action] [options]      (epf_purge.bat --help)
rem Exit    : 0 PASS, 1 FAIL, 2 PASS WITH WARNINGS, 3 aborted or stopped,
rem           4 usage or configuration error.
rem ===========================================================================
setlocal
set "EPF_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%EPF_PS%" set "EPF_PS=powershell.exe"
"%EPF_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0lib\epf.ps1" %*
exit /b %ERRORLEVEL%

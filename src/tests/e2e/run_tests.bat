@echo off
rem ===========================================================================
rem EPF Data Purge - End-to-end test suite launcher
rem ===========================================================================
rem Purpose : Starts run_tests.ps1 in Windows PowerShell 5.1 with the given
rem           arguments and returns its exit code.
rem Usage   : run_tests.bat [--config FILE] [--only T03,T05] [--from T11] [--list] [--digest]
rem Exit    : 0 all tests passed, 1 a test failed, 4 configuration error.
rem ===========================================================================
setlocal
set "EPF_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%EPF_PS%" set "EPF_PS=powershell.exe"
"%EPF_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_tests.ps1" %*
exit /b %ERRORLEVEL%

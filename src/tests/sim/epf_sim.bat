@echo off
rem ===========================================================================
rem EPF Data Purge - simulator of the wrapper's screens and questions
rem ===========================================================================
rem Purpose : Starts epf_sim.ps1 in Windows PowerShell 5.1 with the given
rem           arguments and returns its exit code. No database is touched.
rem Usage   : epf_sim.bat [purge|reclaim|report|status|uninstall] [options]
rem           epf_sim.bat --help
rem Exit    : 0 done, 1 a run that failed (--sim fail), 3 stopped by the
rem           user, 4 usage error.
rem ===========================================================================
setlocal
set "EPF_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%EPF_PS%" set "EPF_PS=powershell.exe"
"%EPF_PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0epf_sim.ps1" %*
exit /b %ERRORLEVEL%

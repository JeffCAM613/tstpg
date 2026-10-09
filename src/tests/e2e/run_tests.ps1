# ============================================================================
# EPF Data Purge - End-to-end test suite
# ============================================================================
# Purpose : Runs every current test of the tool against one test database,
#           in order, without further input: installation, SQL entry scripts,
#           the wrapper (wizard answers are piped, the graceful stop is
#           requested with the stop action), purges of every module and mode,
#           a plan of smaller runs, compaction, redo log sizing, undo tuning,
#           the reclaim on a scratch tablespace, reports. Everything is
#           written to one log file with a check list and a summary.
# Usage   : run_tests.bat [--config FILE] [--only T03,T05] [--from T11] [--list] [--digest]
#             --config  test configuration (default src\tests\e2e\test.conf)
#             --only    run these tests (T01, the safety precheck, always runs)
#             --from    run this test and the ones after it
#             --list    print the tests and exit
#             --digest  print the short digest of the latest test session and
#                       of the runs in logs\ after it (logs\digest.txt, also
#                       copied to the clipboard), and exit; no database needed
# Requires: Windows PowerShell 5.1; sqlplus.exe in PATH or ORACLE_HOME\bin;
#           the TNS alias of the test database; its SYS password.
# Effects : DESTRUCTIVE. Purges every module of the test database (rows older
#           than RETENTION_DAYS), clears LOB values, compacts tables, enlarges
#           the online redo logs to 4 x 1 GB (permanent), lowers and restores
#           undo_retention, creates and removes the reclaim lab (tablespace
#           EPF_RT_DATA, accounts EPF_RT, EPF_RT_APP, EPF_RT_APP2, role
#           EPF_RT_WRITER; src/tests/verify/reclaim_lab.sql) and assesses the
#           application tablespaces for a reclaim (read-only). Refuses to start
#           unless DESTRUCTIVE_OK=YES and the database name equals EXPECTED_DB.
# Output  : logs\tests\<yyyy-MM-dd_HHmmss>_<EXPECTED_DB>\test.log (all output),
#           runs\ (the wrapper's run folders), epf_environment.txt (survey).
# Exit    : 0 all tests passed, 1 a test failed, 4 configuration error.
# ============================================================================

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CliArgs    = @($args)
$script:TestDir    = $PSScriptRoot
$script:SrcDir     = Split-Path -Parent (Split-Path -Parent $script:TestDir)
$script:RepoDir    = Split-Path -Parent $script:SrcDir
$script:Wrapper    = Join-Path $script:SrcDir 'bin\epf_purge.bat'
$script:RunSqlDir  = Join-Path $script:SrcDir 'sql\run'
$script:InstallDir = Join-Path $script:SrcDir 'sql\install'
$script:VerifyDir  = Join-Path $script:SrcDir 'tests\verify'

$script:LogFile     = $null
$script:SessionDir  = $null
$script:RunsDir     = $null
$script:WrapperConf = $null
$script:SqlPlus     = $null
$script:Tns         = ''
$script:ExpectedDb  = ''
$script:SysPw       = ''
$script:EpfPw       = ''
$script:Retention   = '30'
$script:StopAfter   = 3
$script:PayBatch    = ''
$script:Version     = ''
$script:Only        = @()
$script:From        = ''
$script:Current     = $null
$script:Results     = New-Object 'System.Collections.Generic.List[object]'
# The section of the preflight's questions (CHOICES and the database clock),
# matched case-sensitively: every preflight ends with a line ' Choices ...'.
$script:ChoicesSection = '(?m-i)^ CHOICES +\d\d:\d\d:\d\d'
$script:Aborted     = $false
$script:InHangReport = $false
# The process Invoke-Process runs now (the latest one when an $OnLine runs
# another): Stop-WrapperTree ends it.
$script:CurrentPid  = 0
# Seconds a sqlplus session may take to connect before it is ended and tried
# again (Invoke-Sql); about 15 s on the test network.
$script:ConnectTimeoutS = 120
$script:State       = @{ PreflightRun = ''; StoppedRun = ''; StopBatch = ''; UndoRetention = ''; StopCount = 0;
                         StopSent = $false; InPurge = $false; UndoFiles = @(); UndoBaseBytes = [decimal]0;
                         DryRun = ''; DryRunExpected = '' }

# Child processes read their standard input in the console code page. With a
# UTF-8 console .NET would begin every child's input with a byte order mark
# (the wrapper would read it as part of the first answer, sqlplus would reject
# the CONNECT line); the encoding is kept, without the mark.
try {
    if ([Console]::InputEncoding.CodePage -eq 65001 -and [Console]::InputEncoding.GetPreamble().Length -gt 0) {
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch {
    # No console attached: children then use the ANSI code page, which has no mark.
}

# Output that must never appear in any step.
$script:Forbidden = @('SP2-\d{4}', 'PLS-\d{5}', 'ORA-06550', 'ORA-00904', 'ORA-00942', 'ORA-01031', 'ORA-04063',
                      'ORA-06508', 'compilation errors', '(?m)^ Error: ', 'Enter value for')

# ----------------------------------------------------------------------------
# Log
# ----------------------------------------------------------------------------

function Write-TestLog {
    param([string]$Text = '', [string]$Color = '')
    if ($Color -ne '') { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
    if ($null -ne $script:LogFile) {
        [System.IO.File]::AppendAllText($script:LogFile, $Text + "`r`n", [System.Text.Encoding]::ASCII)
    }
}

function Exit-Suite {
    param([int]$Code, [string]$Message)
    Write-TestLog (' ' + $Message) 'Red'
    exit $Code
}

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------

function Read-Config {
    param([string]$Path)
    $values = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $text = $line.Trim()
        if ($text -eq '' -or $text.StartsWith('#')) { continue }
        $eq = $text.IndexOf('=')
        if ($eq -lt 1) { Exit-Suite 4 ('Invalid line in ' + $Path + ': ' + $text) }
        $values[$text.Substring(0, $eq).Trim().ToUpper()] = $text.Substring($eq + 1).Trim()
    }
    return $values
}

function Get-Value {
    param($Config, [string]$Key, [string]$Default = '')
    if ($Config.ContainsKey($Key) -and $Config[$Key] -ne '') { return [string]$Config[$Key] }
    return $Default
}

function Read-Password {
    param([string]$Prompt)
    $secure = Read-Host -Prompt (' ' + $Prompt) -AsSecureString
    return (New-Object System.Net.NetworkCredential('', $secure)).Password
}

function Find-SqlPlus {
    $command = Get-Command 'sqlplus.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) { return $command.Path }
    $oracleHome = [Environment]::GetEnvironmentVariable('ORACLE_HOME')
    if (-not [string]::IsNullOrEmpty($oracleHome)) {
        $candidate = Join-Path $oracleHome 'bin\sqlplus.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-ExpectedVersion {
    foreach ($line in (Get-Content -LiteralPath (Join-Path $script:InstallDir 'registry_data.sql'))) {
        if ($line -match "'tool_version'\s*,\s*'([^']+)'") { return $Matches[1] }
    }
    return ''
}

# ----------------------------------------------------------------------------
# Processes
# ----------------------------------------------------------------------------

function Join-Arguments {
    param([string[]]$List)
    $parts = foreach ($a in $List) { if ($a -match '[\s"]') { '"' + $a + '"' } else { $a } }
    return ($parts -join ' ')
}

function Stop-Tree {
    param([int]$ProcessId)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = 'taskkill.exe'
    $info.Arguments = '/PID ' + $ProcessId + ' /T /F'
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $kill = [System.Diagnostics.Process]::Start($info)
    $null = $kill.StandardOutput.ReadToEnd()
    $kill.WaitForExit()
}

function Format-Duration {
    param([int]$Seconds)
    $span = [TimeSpan]::FromSeconds($Seconds)
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

# Ends sqlplus processes started since $Since whose parent process has ended
# (left behind by a wrapper that exited). They would also keep the wrapper's
# output pipe open. Returns how many were ended.
function Stop-Orphans {
    param([datetime]$Since)
    $count = 0
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'sqlplus.exe'")) {
        if ($p.CreationDate -lt $Since) { continue }
        if ($null -ne (Get-Process -Id $p.ParentProcessId -ErrorAction SilentlyContinue)) { continue }
        Write-TestLog ('---- sqlplus left running (PID ' + $p.ProcessId + ', started ' +
                       $p.CreationDate.ToString('HH:mm:ss') + '): ended') 'Yellow'
        Stop-Tree ([int]$p.ProcessId)
        $count++
    }
    return $count
}

# On a timeout, before the process tree is ended: the processes the step
# started; what the database sessions of this machine, of the tool's runs
# and of any sqlplus are doing, read in a separate SYS session (one
# connection attempt, 3 minutes at most); and the answer of the listener
# (tnsping, when the client has it). Not for the report's own session.
function Write-HangReport {
    param([datetime]$Since)
    if ($script:InHangReport -or $script:SysPw -eq '') { return }
    $script:InHangReport = $true
    try {
        Write-TestLog '---- timeout: the processes of the step and the database sessions'
        foreach ($p in @(Get-CimInstance Win32_Process | Where-Object {
                             $_.CreationDate -ge $Since -and @('cmd.exe', 'powershell.exe', 'sqlplus.exe') -contains $_.Name
                         } | Sort-Object CreationDate)) {
            Write-TestLog ('  process ' + $p.Name + ' PID ' + $p.ProcessId + ', parent ' + $p.ParentProcessId + ', started ' +
                           $p.CreationDate.ToString('HH:mm:ss'))
        }
        $machine = ([string]$env:COMPUTERNAME).ToUpper()
        $null = Invoke-Sql 'SYS' @(
            'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 1000 TRIMOUT ON',
            "SELECT 'NOW|' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') || '|user sessions ' || COUNT(*) FROM v`$session WHERE type = 'USER';",
            ("SELECT 'SESSION|' || s.sid || ',' || s.serial# || '|' || s.username || '|' || s.status || '|' || s.machine || '|' || " +
             "s.program || '|' || s.client_identifier || '|' || s.state || '|' || s.event || '|' || s.seconds_in_wait || " +
             "' s|blocker ' || s.blocking_session || '|logon ' || TO_CHAR(s.logon_time, 'HH24:MI:SS') || '|' || " +
             "(SELECT SUBSTR(q.sql_text, 1, 120) FROM v`$sql q WHERE q.sql_id = s.sql_id AND ROWNUM = 1) " +
             "FROM v`$session s WHERE s.type = 'USER' AND s.sid <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID')) " +
             "AND (UPPER(s.machine) LIKE '%" + $machine + "' OR s.client_identifier LIKE 'EPF:%' " +
             "OR LOWER(s.program) LIKE 'sqlplus%') ORDER BY s.logon_time;"),
            'EXIT') -TimeoutMin 3 -Attempts 1 -Display 'sqlplus -S -L /nolog (SYS, sessions of this machine, of the runs and of sqlplus)'
        $tnsping = Join-Path (Split-Path -Parent $script:SqlPlus) 'tnsping.exe'
        if (Test-Path -LiteralPath $tnsping) {
            $null = Invoke-Process -File $tnsping -Arguments ($script:Tns + ' 3') -Display ('tnsping ' + $script:Tns + ' 3') -TimeoutMin 2
        }
    } catch {
        Write-TestLog ('  the report failed: ' + $_.Exception.Message) 'Yellow'
    } finally {
        $script:InHangReport = $false
    }
}

# Starts a process with the given standard input, writes every output line to
# the log as it arrives, calls $OnLine for each line, and ends it after the
# timeout (with $OnTimeout called first, and 15 more minutes, when given; a
# report of the processes and sessions first).
# With $ReadyMarker (a sqlplus session): only $FirstLines go first, with a
# PROMPT of the marker; sqlplus prints it once the CONNECT has finished, and
# only then are $InputLines sent. A marker that does not come within
# $script:ConnectTimeoutS seconds ends the process (ConnectHang): nothing
# else had been sent to it.
# Once the process has exited, its output is read for 15 more seconds at
# most: a process it left running can keep the pipe open.
function Invoke-Process {
    param([string]$File, [string]$Arguments, [string]$Display, [string[]]$InputLines = @(),
          [string[]]$InputDisplay = @(), [int]$TimeoutMin = 15, [scriptblock]$OnLine = $null,
          [scriptblock]$OnTimeout = $null, [string]$WorkDir = '', [string[]]$FirstLines = @(),
          [string]$ReadyMarker = '')
    if ($WorkDir -eq '') { $WorkDir = $script:SessionDir }
    Write-TestLog ('$ ' + $Display)
    foreach ($l in $InputDisplay) { Write-TestLog ('  < ' + $l) }
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $WorkDir
    $started = Get-Date
    $process = [System.Diagnostics.Process]::Start($info)
    $outerPid = $script:CurrentPid
    $script:CurrentPid = $process.Id
    $ready = ($ReadyMarker -eq '')
    if ($ready) {
        foreach ($l in $InputLines) { $process.StandardInput.WriteLine($l) }
        $process.StandardInput.Close()
    } else {
        foreach ($l in $FirstLines) { $process.StandardInput.WriteLine($l) }
        $process.StandardInput.WriteLine('PROMPT ' + $ReadyMarker)
        $process.StandardInput.Flush()
    }
    $readyBy = $started.AddSeconds($script:ConnectTimeoutS)
    $connectHang = $false
    $errors = $process.StandardError.ReadToEndAsync()
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $deadline = $started.AddMinutes($TimeoutMin)
    $timedOut = $false
    $graceUsed = $false
    $pending = $null
    $exitedAt = $null
    $orphans = 0
    while ($true) {
        if ($null -eq $pending) { $pending = $process.StandardOutput.ReadLineAsync() }
        if (-not $ready -and (Get-Date) -ge $readyBy) {
            $connectHang = $true
            $timedOut = $true
            Write-TestLog ('---- no answer to the connection within ' + $script:ConnectTimeoutS + ' s')
            Write-HangReport $started
            Write-TestLog '---- connection ended'
            Stop-Tree $process.Id
            break
        }
        $left = [int]($deadline - (Get-Date)).TotalMilliseconds
        if ($left -le 0) {
            if ($null -ne $OnTimeout -and -not $graceUsed) {
                $graceUsed = $true
                Write-TestLog ('---- timeout after ' + $TimeoutMin + ' min: requesting a graceful stop, 15 more minutes')
                $null = & $OnTimeout
                $deadline = (Get-Date).AddMinutes(15)
                continue
            }
            $timedOut = $true
            Write-HangReport $started
            Write-TestLog '---- timeout: process tree ended'
            Stop-Tree $process.Id
            break
        }
        if (-not $pending.Wait([Math]::Min($left, 5000))) {
            if ($process.HasExited) {
                if ($null -eq $exitedAt) {
                    $exitedAt = Get-Date
                } elseif (((Get-Date) - $exitedAt).TotalSeconds -ge 15) {
                    Write-TestLog '---- the process has exited but its output is still open'
                    $orphans = $orphans + (Stop-Orphans $started)
                    break
                }
            }
            continue
        }
        $line = $pending.Result
        $pending = $null
        if ($null -eq $line) { break }
        if (-not $ready -and $line -eq $ReadyMarker) {
            $ready = $true
            foreach ($l in $InputLines) { $process.StandardInput.WriteLine($l) }
            $process.StandardInput.Close()
            continue
        }
        $lines.Add($line)
        Write-TestLog $line
        if ($null -ne $OnLine) { $null = & $OnLine $line }
    }
    if (-not $process.WaitForExit(120000)) { Stop-Tree $process.Id }
    $process.WaitForExit()
    $errText = ''
    if ($errors.Wait(15000)) { $errText = $errors.Result }
    if (-not [string]::IsNullOrWhiteSpace($errText)) {
        foreach ($l in ($errText -split "`r?`n")) { if ($l -ne '') { $lines.Add($l); Write-TestLog ('stderr: ' + $l) } }
    }
    $code = $process.ExitCode
    if ($timedOut) { $code = -1 }
    $script:CurrentPid = $outerPid
    $seconds = [int]((Get-Date) - $started).TotalSeconds
    Write-TestLog ('exit ' + $code + ' (' + (Format-Duration $seconds) + ')')
    $orphans = $orphans + (Stop-Orphans $started)
    return [pscustomobject]@{ ExitCode = $code; Output = ($lines -join "`n"); TimedOut = $timedOut; Runs = @();
                              Orphans = $orphans; ConnectHang = $connectHang }
}

function Get-RunFolders {
    if (-not (Test-Path -LiteralPath $script:RunsDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $script:RunsDir -Directory | Select-Object -ExpandProperty Name)
}

function Read-Manifest {
    param([string]$Folder)
    $path = Join-Path (Join-Path $script:RunsDir $Folder) 'manifest.txt'
    $values = @{ folder = $Folder }
    if (-not (Test-Path -LiteralPath $path)) { return $values }
    Write-TestLog ('[manifest ' + $Folder + ']')
    foreach ($line in (Get-Content -LiteralPath $path)) {
        Write-TestLog ('  ' + $line)
        $eq = $line.IndexOf('=')
        if ($eq -gt 0) { $values[$line.Substring(0, $eq)] = $line.Substring($eq + 1) }
    }
    return $values
}

# Runs epf_purge.bat with the test database, the session's run folder and an
# empty wrapper configuration (so a local epf_purge.conf cannot change the
# prompts); returns the result with the manifests of the runs it created.
# With --verbose (every event and the whole report in the output), unless
# -Brief: the output a run shows by default.
function Invoke-Wrapper {
    param([string[]]$Arguments, [string[]]$Answers = @(), [int]$TimeoutMin = 15, [scriptblock]$OnLine = $null,
          [switch]$StopOnTimeout, [switch]$Brief)
    $list = @($Arguments) + @('--tns', $script:Tns, '--config', $script:WrapperConf, '--log-dir', $script:RunsDir, '--no-color')
    if (-not $Brief) { $list += '--verbose' }
    $before = Get-RunFolders
    $onTimeout = $null
    if ($StopOnTimeout) { $onTimeout = { $null = Invoke-Wrapper @('stop', '--non-interactive') } }
    $cmd = '/d /c ""' + $script:Wrapper + '" ' + (Join-Arguments $list) + '"'
    $result = Invoke-Process -File $env:ComSpec -Arguments $cmd -Display ('epf_purge.bat ' + (Join-Arguments $list)) `
                             -InputLines $Answers -InputDisplay $Answers -TimeoutMin $TimeoutMin -OnLine $OnLine `
                             -OnTimeout $onTimeout
    $runs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($folder in (Get-RunFolders | Sort-Object)) {
        if ($before -notcontains $folder) { $runs.Add((Read-Manifest $folder)) }
    }
    $result.Runs = $runs.ToArray()
    Test-Clean $result
    Add-Check ($result.Orphans -eq 0) ('no sqlplus session left running by the wrapper (' + $result.Orphans + ' ended)')
    return $result
}

# Runs sqlplus as SYS or EPFPG with the given commands after the CONNECT line
# (written to standard input; logged with the password masked). The commands
# are sent once the session has connected; a connection that hangs is ended
# and tried again, $Attempts in all (each one is in the log).
function Invoke-Sql {
    param([string]$User, [string[]]$Commands, [string[]]$CommandDisplay = @(), [int]$TimeoutMin = 15,
          [string]$Display = '', [int]$Attempts = 3)
    if ($User -eq 'SYS') {
        $connect = 'CONNECT sys/"' + $script:SysPw + '"@' + $script:Tns + ' AS SYSDBA'
        $shown = 'CONNECT sys/********@' + $script:Tns + ' AS SYSDBA'
    } else {
        $connect = 'CONNECT epfpg/"' + $script:EpfPw + '"@' + $script:Tns
        $shown = 'CONNECT epfpg/********@' + $script:Tns
    }
    if ($CommandDisplay.Count -eq 0) { $CommandDisplay = $Commands }
    if ($Display -eq '') { $Display = 'sqlplus -S -L /nolog (' + $User + ')' }
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        if ($attempt -gt 1) { Write-TestLog ('---- connection attempt ' + $attempt + ' of ' + $Attempts) 'Yellow' }
        $result = Invoke-Process -File $script:SqlPlus -Arguments '-S -L /nolog' -Display $Display `
                                 -FirstLines @($connect) -ReadyMarker 'EPF_TEST_CONNECTED' `
                                 -InputLines ($Commands + @('EXIT 9')) `
                                 -InputDisplay (@($shown) + $CommandDisplay) -TimeoutMin $TimeoutMin
        if (-not $result.ConnectHang) { break }
    }
    Test-Clean $result
    return $result
}

function Get-ScriptLine {
    param([string]$Path, [string[]]$Arguments = @())
    return ('@"' + $Path + '" ' + ($Arguments -join ' ')).TrimEnd()
}

# Datafiles of the undo tablespace (SYS): id, autoextend, growth limit, size.
function Get-UndoFiles {
    $r = Invoke-Sql 'SYS' @(
        'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMOUT ON',
        "SELECT 'UNDOFILE|' || file_id || '|' || autoextensible || '|' || maxbytes || '|' || bytes FROM dba_data_files WHERE tablespace_name = (SELECT UPPER(value) FROM v`$parameter WHERE name = 'undo_tablespace') ORDER BY file_id;",
        'EXIT')
    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in ($r.Output -split "`n")) {
        if ($line -match '^UNDOFILE\|(\d+)\|([A-Z]+)\|(\d+)\|(\d+)') {
            $files.Add([pscustomobject]@{ Id = $Matches[1]; Auto = $Matches[2]; Max = [decimal]$Matches[3]; Bytes = [decimal]$Matches[4] })
        }
    }
    return ,$files.ToArray()
}

# Every undo datafile has the growth limit it had before the tests.
function Assert-UndoLimits {
    if ($script:State.UndoFiles.Count -eq 0) { return }
    $now = Get-UndoFiles
    foreach ($base in $script:State.UndoFiles) {
        $match = @($now | Where-Object { $_.Id -eq $base.Id -and $_.Auto -eq $base.Auto -and $_.Max -eq $base.Max })
        Add-Check ($match.Count -eq 1) ('undo datafile ' + $base.Id + ' has its original growth limit (autoextend ' +
                                        $base.Auto + ', max ' + [Math]::Round($base.Max / 1MB) + ' MB)')
    }
}

# The reclaim lab (src/tests/verify/reclaim_lab.sql, SYS; -Layout 2:
# reclaim_lab2.sql) in mode SETUP, CHECK or CLEANUP (layout 2: QUOTA too). A
# CHECK reads the dictionary in seconds: one that does not answer within 5
# minutes fails a check and is tried once more, so that the checks after it
# still compare the lab.
function Invoke-Lab {
    param([string]$Mode, [int]$TimeoutMin = 15, [int]$Layout = 1)
    $path = Join-Path $script:VerifyDir 'reclaim_lab.sql'
    if ($Layout -eq 2) { $path = Join-Path $script:VerifyDir 'reclaim_lab2.sql' }
    if ($Mode -ne 'CHECK') { return (Invoke-Sql 'SYS' @((Get-ScriptLine $path @($Mode))) -TimeoutMin $TimeoutMin) }
    $r = Invoke-Sql 'SYS' @((Get-ScriptLine $path @($Mode))) -TimeoutMin 5
    Add-Check (-not $r.TimedOut) 'the lab check answered within 5 minutes'
    if ($r.TimedOut) { $r = Invoke-Sql 'SYS' @((Get-ScriptLine $path @($Mode))) -TimeoutMin 5 }
    return $r
}

# What reclaim run $Label leaves where it is (EPF_RECLAIM_OBJECT): the tables
# and segments that stay and the indexes left as found, as
# KEPT|<PIN or INDEX>|<owner.name>|<reason> lines.
function Get-ReclaimKept {
    param([string]$Label)
    $id = Get-RunNumber $Label
    return (Invoke-Sql 'EPFPG' @('SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 600 TRIMOUT ON',
                                 ("SELECT 'KEPT|' || unit_type || '|' || owner || '.' || object_name || '|' || " +
                                  "SUBSTR(detail, 1, 300) FROM epf_reclaim_object WHERE run_id = " + $id +
                                  " AND (unit_type = 'PIN' OR move_status = 'KEPT') ORDER BY owner, object_name;"),
                                 'EXIT'))
}

# Setting reclaim_test_pause_s: the next compaction pauses this many seconds
# after each table that moves (a known point to request a stop or end the
# worker session), and sets it back to 0 when it reads it.
function Set-TestPause {
    param([int]$Seconds)
    $r = Invoke-Sql 'EPFPG' @('SET HEADING OFF FEEDBACK OFF PAGESIZE 0',
                              ("UPDATE epf_setting SET value = '" + $Seconds + "' WHERE name = 'reclaim_test_pause_s';"),
                              'COMMIT;', "SELECT 'PAUSE|' || value FROM epf_setting WHERE name = 'reclaim_test_pause_s';",
                              'EXIT')
    Assert-Exit $r @(0)
    Assert-Match $r ('(?m)^PAUSE\|' + $Seconds + '\s*$')
}

# The value of setting reclaim_test_pause_s, '' when it cannot be read.
function Get-TestPause {
    $r = Invoke-Sql 'EPFPG' @('SET HEADING OFF FEEDBACK OFF PAGESIZE 0',
                              "SELECT 'PAUSE|' || value FROM epf_setting WHERE name = 'reclaim_test_pause_s';", 'EXIT')
    if ($r.Output -match '(?m)^PAUSE\|(\d+)') { return $Matches[1] }
    return ''
}

# Setting reclaim_test_park: Y makes the next compaction park the first table
# it picks (with --scratch), and it sets it back to N when it reads it.
function Set-TestPark {
    param([string]$Value)
    $r = Invoke-Sql 'EPFPG' @('SET HEADING OFF FEEDBACK OFF PAGESIZE 0',
                              ("UPDATE epf_setting SET value = '" + $Value + "' WHERE name = 'reclaim_test_park';"),
                              'COMMIT;', "SELECT 'PARK|' || value FROM epf_setting WHERE name = 'reclaim_test_park';",
                              'EXIT')
    Assert-Exit $r @(0)
    Assert-Match $r ('(?m)^PARK\|' + $Value + '\s*$')
}

# The value of setting reclaim_test_park, '' when it cannot be read.
function Get-TestPark {
    $r = Invoke-Sql 'EPFPG' @('SET HEADING OFF FEEDBACK OFF PAGESIZE 0',
                              "SELECT 'PARK|' || value FROM epf_setting WHERE name = 'reclaim_test_park';", 'EXIT')
    if ($r.Output -match '(?m)^PARK\|([YN])') { return $Matches[1] }
    return ''
}

# Ends, on this machine, the sqlplus of a reclaim's worker session (SYS, a
# run's client identifier; its process id in V$SESSION.PROCESS), as a lost
# connection does: the database session goes on with its call. Returns whether
# it ended one.
function Stop-WorkerClient {
    $k = Invoke-Sql 'SYS' @(
        'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMOUT ON',
        ("SELECT 'WORKER|' || s.process || '|' || s.sid || ',' || s.serial# FROM v`$session s WHERE s.username = 'SYS' " +
         "AND s.client_identifier LIKE 'EPF:%' AND s.sid <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'));"),
        'EXIT')
    foreach ($line in ($k.Output -split "`n")) {
        if ($line.Trim() -notmatch '^WORKER\|(\d+)[^|]*\|(\S+)') { continue }
        $session = $Matches[2]
        $p = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
        if ($null -eq $p -or $p.ProcessName -ne 'sqlplus') { continue }
        Stop-Process -Id $p.Id -Force
        Write-TestLog ('---- sqlplus PID ' + $p.Id + ' ended; its session ' + $session + ' goes on in the database')
        return $true
    }
    Write-TestLog '---- no sqlplus of a worker session found on this machine' 'Yellow'
    return $false
}

# Ends the process tree of the wrapper Invoke-Wrapper runs (cmd, powershell,
# every sqlplus), as a client that loses the network does: the database
# sessions waiting for their client end, a worker's call goes on. For its
# $OnLine. Returns whether it ended one.
function Stop-WrapperTree {
    if ($script:CurrentPid -eq 0) { return $false }
    Stop-Tree $script:CurrentPid
    Write-TestLog ('---- the wrapper (PID ' + $script:CurrentPid + ') and its sqlplus sessions ended')
    return $true
}

# Static checks of a PowerShell script: it parses, every command it calls is
# defined in it or known to PowerShell, and no "+" takes a list as its right
# operand ("a" + $x, 'b' is one string: the comma binds tighter than +).
function Test-Script {
    param([string]$Path)
    $name = Split-Path -Leaf $Path
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $first = ''
    if ($errors.Count -gt 0) { $first = ': line ' + $errors[0].Extent.StartLineNumber + ' ' + $errors[0].Message }
    Add-Check ($errors.Count -eq 0) ($name + ' parses' + $first)
    $defined = @{}
    foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        $defined[$f.Name.ToLower()] = $true
    }
    $missing = @()
    foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
        $command = $c.GetCommandName()
        if ($null -eq $command -or $defined.ContainsKey($command.ToLower())) { continue }
        if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) {
            $missing += ($command + ' (line ' + $c.Extent.StartLineNumber + ')')
        }
    }
    Add-Check ($missing.Count -eq 0) ($name + ' calls only defined commands' +
                                      $(if ($missing.Count -gt 0) { ': ' + ($missing -join ', ') } else { '' }))
    $traps = @()
    foreach ($e in $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and
                ($n.Operator -eq 'Plus' -or $n.Operator -eq 'Minus') -and
                $n.Right -is [System.Management.Automation.Language.ArrayLiteralAst]
            }, $true)) {
        $traps += ('line ' + $e.Extent.StartLineNumber)
    }
    Add-Check ($traps.Count -eq 0) ($name + ' has no + or - with a list on its right' +
                                    $(if ($traps.Count -gt 0) { ': ' + ($traps -join ', ') } else { '' }))
}

# The state of the lab in the LAB| lines of reclaim_lab.sql: datafile size and
# growth settings, index statuses, accounts, row counts, LOB attributes,
# recycle-bin objects.
function Read-Lab {
    param($Result)
    $lab = @{ FileBytes = [decimal]0; Growth = ''; Segments = [decimal]0; Indexes = @{}; Accounts = @{}; Rows = @{};
              Lobs = @{}; RecycleBin = 0 }
    foreach ($line in ($Result.Output -split "`n")) {
        $text = $line.Trim()
        if ($text -match '^LAB\|FILE\|(\d+)\|(\d+)\|([A-Z]+)\|(\d+)\|(\d+)\|') {
            $lab.FileBytes = $lab.FileBytes + [decimal]$Matches[2]
            $lab.Growth = $lab.Growth + 'file ' + $Matches[1] + ' autoextend ' + $Matches[3] + ' max ' + $Matches[4] +
                          ' next ' + $Matches[5] + '; '
        } elseif ($text -match '^LAB\|SEGMENTS\|(\d+)') {
            $lab.Segments = [decimal]$Matches[1]
        } elseif ($text -match '^LAB\|INDEX\|([^|]+)\|(.*)$') {
            $lab.Indexes[$Matches[1]] = $Matches[2]
        } elseif ($text -match '^LAB\|ACCOUNT\|([^|]+)\|(.*)$') {
            $lab.Accounts[$Matches[1]] = $Matches[2]
        } elseif ($text -match '^LAB\|ROWS\|([^|]+)\|(\d+)') {
            $lab.Rows[$Matches[1]] = $Matches[2]
        } elseif ($text -match '^LAB\|LOB\|([^|]+)\|(.*)$') {
            $lab.Lobs[$Matches[1]] = $Matches[2]
        } elseif ($text -match '^LAB\|RECYCLEBIN\|[A-Z]*\|(\d+)') {
            $lab.RecycleBin = [int]$Matches[1]
        }
    }
    return $lab
}

# Entries of hashtable $Before that differ in $After, as "key before->after".
function Compare-LabMap {
    param($Before, $After)
    $diff = @()
    foreach ($key in ($Before.Keys | Sort-Object)) {
        if ([string]$After[$key] -ne [string]$Before[$key]) { $diff += ($key + ' ' + $Before[$key] + '->' + $After[$key]) }
    }
    return ,$diff
}

# The lab is as it was: datafile growth settings, index statuses, accounts,
# row counts, LOB attributes; with -SameSize the datafile size too.
function Assert-LabSame {
    param($Before, $After, [switch]$SameSize)
    Add-Check ($After.Growth -eq $Before.Growth) ('datafile growth settings as before (' + $Before.Growth.Trim() + ')')
    if ($SameSize) {
        Add-Check ($After.FileBytes -eq $Before.FileBytes) ('datafile size unchanged (' + $Before.FileBytes + ' -> ' +
                                                             $After.FileBytes + ')')
    }
    foreach ($part in @(@('Indexes', 'index statuses'), @('Accounts', 'account statuses'), @('Rows', 'row counts'),
                        @('Lobs', 'LOB attributes'))) {
        $diff = Compare-LabMap $Before[$part[0]] $After[$part[0]]
        Add-Check ($diff.Count -eq 0 -and $Before[$part[0]].Count -gt 0) ($part[1] + ' as before (' +
                                                                         $Before[$part[0]].Count + ')' +
                                                                         ($(if ($diff.Count -gt 0) { ': ' + ($diff -join ', ') } else { '' })))
    }
}

# ----------------------------------------------------------------------------
# Tests and checks
# ----------------------------------------------------------------------------

function Add-Check {
    param([bool]$Ok, [string]$Text)
    if ($Ok) {
        Write-TestLog ('  check ' + $Text + ': ok') 'Green'
    } else {
        Write-TestLog ('  check ' + $Text + ': FAILED') 'Red'
        $script:Current.Failures.Add($Text)
    }
}

function Test-Clean {
    param($Result)
    foreach ($pattern in $script:Forbidden) {
        if ($Result.Output -match $pattern) { Add-Check $false ('output free of ' + $pattern + ' (found: ' + $Matches[0] + ')') }
    }
}

function Assert-Exit {
    param($Result, [int[]]$Allowed)
    Add-Check ($Allowed -contains $Result.ExitCode) ('exit code ' + $Result.ExitCode + ' in {' + ($Allowed -join ',') + '}')
}

function Assert-Match {
    param($Result, [string]$Pattern)
    Add-Check ($Result.Output -match $Pattern) ('output contains /' + $Pattern + '/')
}

function Assert-NoMatch {
    param($Result, [string]$Pattern)
    Add-Check (-not ($Result.Output -match $Pattern)) ('output does not contain /' + $Pattern + '/')
}

# Records whether the output contains a pattern, without failing the test.
function Write-Note {
    param($Result, [string]$Pattern, [string]$Text)
    if ($Result.Output -match $Pattern) { Write-TestLog ('  note ' + $Text + ': yes') }
    else { Write-TestLog ('  note ' + $Text + ': no') 'Yellow' }
}

function Get-Run {
    param($Result, [string]$Action)
    foreach ($run in $Result.Runs) {
        if ($run.ContainsKey('action') -and $run['action'] -eq $Action) { return $run }
    }
    Add-Check $false ('a ' + $Action + ' run folder with manifest.txt was written')
    return $null
}

function Assert-Manifest {
    param($Run, [string]$Key, [string]$Pattern)
    if ($null -eq $Run) { return }
    $value = ''
    if ($Run.ContainsKey($Key)) { $value = [string]$Run[$Key] }
    Add-Check ($value -match $Pattern) ('manifest ' + $Key + '=' + $value + ' matches /' + $Pattern + '/')
}

function Get-RunNumber {
    param([string]$Label)
    if ($Label -match '^R-0*(\d+)$') { return $Matches[1] }
    return $Label
}

function Test-Selected {
    param([string]$Id)
    if ($script:Only.Count -gt 0) { return ($script:Only -contains $Id) }
    if ($script:From -ne '') { return ([string]::CompareOrdinal($Id, $script:From) -ge 0) }
    return $true
}

# -Always: runs whatever the selection (the safety precheck). -Required: when
# it fails, the remaining tests are skipped.
function Invoke-Test {
    param([string]$Id, [string]$Title, [scriptblock]$Body, [switch]$Required, [switch]$Always)
    if (-not $Always -and -not (Test-Selected $Id)) { return }
    if ($script:Aborted) {
        $script:Results.Add([pscustomobject]@{ Id = $Id; Title = $Title; Status = 'SKIPPED'; Seconds = 0; Failures = @() })
        return
    }
    $script:Current = [pscustomobject]@{ Id = $Id; Failures = (New-Object 'System.Collections.Generic.List[string]') }
    $started = Get-Date
    Write-TestLog ''
    Write-TestLog ('==== ' + $Id + '  ' + $Title + '  (' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ')') 'White'
    try {
        $null = & $Body
    } catch {
        Add-Check $false ('no exception: ' + $_.Exception.Message)
    }
    $seconds = [int]((Get-Date) - $started).TotalSeconds
    $status = 'PASS'
    if ($script:Current.Failures.Count -gt 0) { $status = 'FAIL' }
    $color = 'Green'
    if ($status -ne 'PASS') { $color = 'Red' }
    Write-TestLog ('---- ' + $Id + ' ' + $status + ' (' + (Format-Duration $seconds) + ')') $color
    $script:Results.Add([pscustomobject]@{ Id = $Id; Title = $Title; Status = $status; Seconds = $seconds;
                                           Failures = $script:Current.Failures.ToArray() })
    if ($Required -and $status -ne 'PASS') {
        $script:Aborted = $true
        Write-TestLog ('---- ' + $Id + ' is required: the remaining tests are skipped.') 'Red'
    }
}

# ----------------------------------------------------------------------------
# Test list
# ----------------------------------------------------------------------------

$script:TestList = @(
    'T00  Static checks of the wrapper and of this suite (no database)',
    'T01  Precheck: database identity, non-CDB, redo logs, undo (SYS; safety gate)',
    'T02  Environment survey (src/tests/verify/environment.sql)',
    'T03  Install through the wrapper (install action)',
    'T04  Install again with install.sql (idempotent upgrade path)',
    'T05  Undo tuning left from earlier work restored; undo datafile limits recorded',
    'T06  Wrapper basics: --help, status, stop without an active run',
    'T07  Usage errors: exit 4, nothing changed',
    'T08  Preflight through the wrapper: the output by default, every line in console.log',
    'T08B Preflight with questions: choices saved, a dry run follows them',
    'T09  preflight.sql NEW',
    'T10  Dry run of all modules through the wrapper: simulation and expected outcome',
    'T10B Requirements gate: a purge without a backup choice does not start; S stops the preflight questions',
    'T11  PAYMENTS purge through the wizard with redo log sizing and undo tuning; graceful stop',
    'T12  State after the stop: undo restored, nothing pending',
    'T12B PAYMENTS dry run: the simulation T13 is compared with',
    'T13  PAYMENTS purge to the end, non-interactive, undo tuning; forecast against result',
    'T13B Plan of smaller runs: LOGS in steps (--max-redo); continue, refuse, rehearse, close',
    'T14  LOGS purge with compaction, non-interactive, undo growth confirmed',
    'T15  BANK_STATEMENTS LOB clearing (mode CLOB), non-interactive',
    'T16  BANK_STATEMENTS purge through the menu wizard (redo sizing already done)',
    'T17  Reports through the wrapper: latest, and the stopped run',
    'T18  SQL entry scripts: report.sql, status.sql, advice.sql',
    'T18A Reclaim lab: a scratch tablespace; its assessment (dry run) changes nothing',
    'T18B Reclaim lab: compaction in place; requirement gate, room making, R1-R9, everything restored',
    'T18C Reclaim lab: a stop during the compaction ends STOPPED with everything restored',
    'T18D Reclaim lab: a worker session killed during the compaction is restored in the same run',
    'T18H Reclaim lab: parking (--scratch): a table waits in a scratch tablespace and comes back; nothing left behind',
    'T18I Reclaim lab: a worker session killed while a table is parked: the table comes back in the same run',
    'T18J Reclaim lab: the worker''s connection lost during the compaction: the restore in the same run waits for its call; nothing left',
    'T18K Reclaim lab: the whole wrapper lost while a table is parked: a later reclaim --restore waits for the worker''s call; nothing left',
    'T18E Reclaim: assessment of the application tablespaces (dry run, read-only)',
    'T18F Reclaim lab removed',
    'T18G Reclaim lab 2: two datafiles, index and LOB tablespaces, a queue table, INITIAL of each kind, quota gate',
    'T19  Final state: redo logs, undo_retention, pending changes, runs'
)

function Invoke-Suite {
    Invoke-Test 'T00' 'Static checks of the wrapper and of this suite (no database)' {
        Test-Script (Join-Path $script:SrcDir 'bin\lib\epf.ps1')
        Test-Script (Join-Path $script:TestDir 'run_tests.ps1')
    }

    Invoke-Test 'T01' 'Precheck: database identity, non-CDB, redo logs, undo (SYS; safety gate)' -Required -Always {
        $r = Invoke-Sql 'SYS' @(
            'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMOUT ON',
            "SELECT 'DB|' || name || '|' || cdb || '|' || log_mode || '|' || open_mode || '|' || database_role FROM v`$database;",
            "SELECT 'CONTAINER|' || SYS_CONTEXT('USERENV', 'CON_NAME') FROM dual;",
            "SELECT 'VERSION|' || version_full FROM v`$instance;",
            "SELECT 'INSTANCES|' || COUNT(*) FROM gv`$instance;",
            "SELECT 'REDO|group ' || group# || '|' || ROUND(bytes / 1048576) || ' MB|' || members || ' members|' || status FROM v`$log ORDER BY group#;",
            "SELECT 'UNDO|' || name || '=' || value FROM v`$parameter WHERE name IN ('undo_tablespace', 'undo_retention') ORDER BY name;",
            "SELECT 'EPFPG_USER|' || COUNT(*) FROM dba_users WHERE username = 'EPFPG';",
            "SELECT 'STATS|' || owner || '.' || table_name || '|' || num_rows || ' rows|analyzed ' || TO_CHAR(last_analyzed, 'YYYY-MM-DD') FROM dba_tables WHERE (owner, table_name) IN (('OPPAYMENTS', 'BULK_PAYMENT'), ('OPPAYMENTS', 'FILE_INTEGRATION'), ('OPPAYMENTS', 'AUDIT_TRAIL'), ('OP', 'SPEC_TRT_LOG'), ('OPPAYMENTS', 'FILE_DISPATCHING')) ORDER BY 1;",
            'SET SERVEROUTPUT ON',
            "DECLARE l_v VARCHAR2(4000); BEGIN EXECUTE IMMEDIATE 'SELECT MAX(value) FROM epfpg.epf_setting WHERE name = ''tool_version''' INTO l_v; DBMS_OUTPUT.PUT_LINE('TOOL_VERSION|' || NVL(l_v, 'none')); EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('TOOL_VERSION|none'); END;",
            '/',
            "SELECT 'APPDATA|' || owner || '|' || ROUND(SUM(bytes) / 1048576) || ' MB' FROM dba_segments WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS') GROUP BY owner ORDER BY owner;",
            "DECLARE l_n NUMBER; l_d VARCHAR2(10); BEGIN EXECUTE IMMEDIATE 'SELECT COUNT(*), TO_CHAR(MAX(started_at), ''YYYY-MM-DD'') FROM epfpg.epf_run WHERE action = ''PURGE'' AND dry_run = ''N'' AND status IN (''SUCCESS'', ''WARNING'', ''STOPPED'')' INTO l_n, l_d; DBMS_OUTPUT.PUT_LINE('PURGED|' || l_n || '|' || l_d); EXCEPTION WHEN OTHERS THEN DBMS_OUTPUT.PUT_LINE('PURGED|0|'); END;",
            '/',
            'EXIT')
        Assert-Exit $r @(0)
        $db = ''
        $container = ''
        $cdb = ''
        $logMode = ''
        $instances = ''
        $installed = 'none'
        $apps = New-Object 'System.Collections.Generic.List[string]'
        $purged = 0
        $purgedLast = ''
        foreach ($line in ($r.Output -split "`n")) {
            if ($line -match '^APPDATA\|([^|]+)\|(.*)$') { $apps.Add($Matches[1].Trim() + ' ' + $Matches[2].Trim()) }
            if ($line -match '^PURGED\|(\d+)\|(.*)$') { $purged = [int]$Matches[1]; $purgedLast = $Matches[2].Trim() }
            if ($line -match '^DB\|([^|]*)\|([^|]*)\|([^|]*)\|') {
                $db = $Matches[1].Trim()
                $cdb = $Matches[2].Trim()
                $logMode = $Matches[3].Trim()
            }
            if ($line -match '^CONTAINER\|(.*)$') { $container = $Matches[1].Trim() }
            if ($line -match '^INSTANCES\|(\d+)') { $instances = $Matches[1] }
            if ($line -match '^UNDO\|undo_retention=(\d+)') { $script:State.UndoRetention = $Matches[1] }
            if ($line -match '^TOOL_VERSION\|(.*)$') { $installed = $Matches[1].Trim() }
        }
        $expected = $script:ExpectedDb.ToUpper()
        Add-Check ($db.ToUpper() -eq $expected -or $container.ToUpper() -eq $expected) ('database ' + $db + ' / container ' + $container + ' is EXPECTED_DB ' + $expected)
        Add-Check ($cdb -eq 'NO') ('non-CDB database (CDB=' + $cdb + '): redo log sizing and undo tuning need it')
        Add-Check ($instances -eq '1') ('single instance (' + $instances + ')')
        # Without T03 (the install) in this session, the tests run the tool as
        # installed: it must be the version of these scripts.
        if (-not (Test-Selected 'T03')) {
            $hint = ''
            if ($installed -ne $script:Version) {
                $hint = ': install it first (src\bin\epf_purge.bat install --tns ' + $script:Tns + '), or include T03'
            }
            Add-Check ($installed -eq $script:Version) ('installed tool version ' + $installed + ' is the version of these scripts, ' +
                                                        $script:Version + $hint)
        }
        if ($logMode -eq 'ARCHIVELOG') {
            Write-TestLog '  note ARCHIVELOG mode: the PAYMENTS purge writes about 90 GB of redo; the archive destination needs that space' 'Yellow'
        }
        # Whether the copy suits the tests of the application's purge: it holds
        # the application's data, and this tool has not purged it before
        # (T11 to T13 and T17 stop a purge after its third batch).
        if ($apps.Count -gt 0) {
            Write-TestLog ('  note application data: ' + ($apps -join ', '))
        } else {
            Write-TestLog '  note application data: none (no segment of OP, OPPAYMENTS or OPREPORTS): the purge tests and T18E cannot pass on this copy' 'Yellow'
        }
        if ($purged -gt 0) {
            Write-TestLog ('  note purges this tool already ran on this copy: ' + $purged + ', the last on ' + $purgedLast +
                           ': the purge tests may find little or nothing to purge, and T11 to T13 and T17 need a copy never purged') 'Yellow'
        }
    }

    Invoke-Test 'T02' 'Environment survey (src/tests/verify/environment.sql)' {
        $path = Join-Path $script:VerifyDir 'environment.sql'
        $r = Invoke-Sql 'SYS' @((Get-ScriptLine $path)) -TimeoutMin 30
        Assert-Exit $r @(0)
        $file = Join-Path $script:SessionDir 'epf_environment.txt'
        Add-Check (Test-Path -LiteralPath $file) 'epf_environment.txt written'
        if (Test-Path -LiteralPath $file) {
            Write-TestLog '[epf_environment.txt]'
            foreach ($line in (Get-Content -LiteralPath $file)) { Write-TestLog ('  ' + $line) }
        }
    }

    Invoke-Test 'T03' 'Install through the wrapper (install action)' -Required {
        $r = Invoke-Wrapper @('install', '--non-interactive') -TimeoutMin 30
        Assert-Exit $r @(0)
        Assert-Match $r ('EPFPG objects valid, tool version ' + [regex]::Escape($script:Version))
    }

    Invoke-Test 'T04' 'Install again with install.sql (idempotent upgrade path)' {
        $path = Join-Path $script:InstallDir 'install.sql'
        $r = Invoke-Sql 'SYS' @((Get-ScriptLine $path @('"' + $script:EpfPw + '"'))) `
                        -CommandDisplay @((Get-ScriptLine $path @('"********"'))) -TimeoutMin 30
        Assert-Exit $r @(0)
        Assert-Match $r 'present\s+table EPF_CHECK'
        Assert-Match $r 'present\s+tablespace EPFPG_DATA'
        Assert-Match $r ('EPFPG objects valid, tool version ' + [regex]::Escape($script:Version))
    }

    Invoke-Test 'T05' 'Undo tuning left from earlier work restored; undo datafile limits recorded' {
        $undo = Join-Path $script:RunSqlDir 'undo.sql'
        $r = Invoke-Sql 'SYS' @((Get-ScriptLine $undo @('RESTORE')))
        Assert-Exit $r @(0)
        $r = Invoke-Sql 'SYS' @((Get-ScriptLine $undo @('STATUS')))
        Assert-Exit $r @(0)
        Assert-NoMatch $r 'active change'
        foreach ($line in ($r.Output -split "`n")) {
            if ($line -match 'undo_retention (\d+) s') { $script:State.UndoRetention = $Matches[1] }
        }
        # Baseline of the undo datafiles: growth limits restored after every run.
        $script:State.UndoFiles = Get-UndoFiles
        $script:State.UndoBaseBytes = ($script:State.UndoFiles | Measure-Object -Property Bytes -Sum).Sum
        Add-Check ($script:State.UndoFiles.Count -gt 0) 'undo datafiles recorded'
        foreach ($f in $script:State.UndoFiles) {
            Write-TestLog ('  undo datafile ' + $f.Id + ': ' + [Math]::Round($f.Bytes / 1MB) + ' MB, autoextend ' + $f.Auto +
                           ', max ' + [Math]::Round($f.Max / 1MB) + ' MB')
        }
    }

    Invoke-Test 'T06' 'Wrapper basics: --help, status, stop without an active run' {
        $r = Invoke-Wrapper @('--help')
        Assert-Exit $r @(0)
        Assert-Match $r 'Usage: epf_purge.bat'
        $r = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Exit $r @(0)
        $r = Invoke-Wrapper @('stop', '--non-interactive')
        Assert-Exit $r @(1)
        Assert-Match $r 'No run is active'
    }

    Invoke-Test 'T07' 'Usage errors: exit 4, nothing changed' {
        foreach ($case in @(@('purge', '--bogus'), @('reclaim', '--non-interactive'),
                            @('reclaim', '--non-interactive', '--dry-run', '--restore'),
                            @('reclaim', '--non-interactive', '--dry-run', '--confirm', 'UNDO'),
                            @('reclaim', '--non-interactive', '--dry-run', '--tablespaces', 'A-B'),
                            @('reclaim', '--non-interactive', '--dry-run', '--scratch', 'lots'),
                            @('reclaim', '--non-interactive', '--restore', '--scratch', '1G'),
                            @('preflight', '--non-interactive', '--scratch', '1G'),
                            @('reclaim', '--non-interactive', '--dry-run', '--retention', '30'),
                            @('preflight', '--non-interactive', '--tablespaces', 'USERS'),
                            @('preflight', '--non-interactive', '--compact'),
                            @('plan', '--non-interactive', '--new'), @('status', '--non-interactive', '--close'),
                            @('purge', '--non-interactive', '--max-redo', '1G'),
                            @('preflight', '--non-interactive', '--max-redo', 'ten'),
                            @('purge', '--non-interactive', '--dry-run', '--compact'),
                            @('purge', '--non-interactive', '--batch-size', '50'),
                            @('purge', '--non-interactive', '--retention', $script:Retention, '--cutoff', '2025-01-01'),
                            @('purge', '--non-interactive', '--cutoff', '2025-13-01'),
                            @('purge', '--non-interactive', '--retention', $script:Retention, '--backup', 'maybe'),
                            @('purge', '--non-interactive', '--retention', $script:Retention, '--confirm', 'BACKUP'),
                            @('purge', '--non-interactive', '--retention', $script:Retention))) {
            $r = Invoke-Wrapper $case
            Assert-Exit $r @(4)
            Add-Check ($r.Runs.Count -eq 0) 'no run created'
        }
        Assert-Match $r '--yes is required with --non-interactive'
    }

    Invoke-Test 'T08' 'Preflight through the wrapper: the output by default, every line in console.log' {
        $r = Invoke-Wrapper @('preflight', '--non-interactive', '--retention', $script:Retention) -TimeoutMin 30 -Brief
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'REDO_LOGS'
        Assert-Match $r 'PREFLIGHT UNDO DONE'
        Assert-Match $r '(?m)^ SUMMARY +\d\d:\d\d:\d\d'
        Assert-Match $r 'ESTIMATE \(rows before the cutoff'
        Assert-Match $r 'REQUIREMENTS'
        Assert-Match $r ' RESULT  (READY|NOT READY)'
        Assert-Match $r '(?m)^ VERDICT  '
        Assert-NoMatch $r 'ROOTS_ELIGIBLE'
        Assert-NoMatch $r 'STEP_START'
        Assert-NoMatch $r 'RETENTION OPTIONS'
        Assert-NoMatch $r '(?m)^ STEPS'
        Assert-NoMatch $r '(?m)^EPF_REQ\|'
        Assert-NoMatch $r $script:ChoicesSection
        $run = Get-Run $r 'PREFLIGHT'
        if ($null -ne $run) {
            $log = Join-Path (Join-Path $script:RunsDir $run['folder']) 'console.log'
            $text = ''
            if (Test-Path -LiteralPath $log) { $text = [System.IO.File]::ReadAllText($log) }
            foreach ($pattern in @('ROOTS_ELIGIBLE', 'STEP_START', '(?m)^ REPORT +\d\d:\d\d:\d\d', 'RETENTION OPTIONS', '(?m)^ STEPS',
                                   ' RESULT  (READY|NOT READY)')) {
                Add-Check ($text -match $pattern) ('console.log contains /' + $pattern + '/')
            }
            Add-Check ($text -notmatch '(?m)^ SUMMARY ') 'console.log does not contain the summary'
        }
        Assert-Manifest $run 'check.P5' '^(PASS|WARN)'
        Assert-Manifest $run 'requirements_ready' '^(Y|N)$'
        foreach ($code in @('ARCHIVE', 'UNDO', 'TEMP', 'INDEX_SPACE', 'REDO_LOGS', 'BACKUP')) {
            Assert-Manifest $run ('req.' + $code) '^(MET|NOT_MET|NOT_APPLICABLE)\|[YN]\|'
        }
        if ($null -ne $run) { $script:State.PreflightRun = $run['run'] }
    }

    Invoke-Test 'T08B' 'Preflight with questions: choices saved, a dry run follows them' {
        # One day more than the suite's retention: no other purge of the
        # suite has this scope, so none follows these choices.
        $retention = [string]([int]$script:Retention + 1)
        # With these options every requirement is met: the only question is
        # the batch size.
        $r = Invoke-Wrapper @('preflight', '--retention', $retention, '--mode', 'LOGS', '--undo-tuning', '--redo-logs',
                              '--backup', 'none') -Answers @('200') -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        Assert-Match $r $script:ChoicesSection
        Assert-Match $r 'READY with these choices'
        Assert-Match $r 'Next    epf_purge.bat purge'
        $saved = ''
        $run = Get-Run $r 'PREFLIGHT'
        Assert-Manifest $run 'batch_size' '^200$'
        Assert-Manifest $run 'requirements_ready' '^Y$'
        Assert-Manifest $run 'step.PREFLIGHT.CHOICES.-' '^DONE'
        Assert-Manifest $run 'plan' '^P-\d+$'
        Assert-Manifest $run 'plan_steps' '^1$'
        if ($null -ne $run) { $saved = $run['run'] }
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--retention', $retention, '--mode', 'LOGS', '--dry-run') -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        Assert-Match $r ('Choices saved with the preflight ' + [regex]::Escape($saved))
        Assert-Match $r 'counted by R-\d+'
        Assert-NoMatch $r 'REDO LOGS \(SYS\)'
        $run = Get-Run $r 'PURGE'
        Assert-Manifest $run 'dry_run' '^Y$'
        Assert-Manifest $run 'batch_size' '^200$'
        Assert-Manifest $run 'backup' '^NONE$'
        Assert-Manifest $run 'undo_tuning' '^Y$'
        Assert-Manifest $run 'redo_logs' '^Y$'
        Assert-Manifest $run 'preflight_run' ('^' + [regex]::Escape($saved) + '$')
        Assert-Manifest $run 'requirements_ready' '^Y$'
        Assert-Manifest $run 'plan_step' '^1$'
    }

    Invoke-Test 'T09' 'preflight.sql NEW' {
        $r = Invoke-Sql 'EPFPG' @((Get-ScriptLine (Join-Path $script:RunSqlDir 'preflight.sql') @('NEW'))) -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'RUN_END'
    }

    Invoke-Test 'T10' 'Dry run of all modules through the wrapper: simulation and expected outcome' {
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--retention', $script:Retention, '--dry-run') -TimeoutMin 60
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'SIMULATION \(dry run'
        Assert-Match $r 'RETENTION OPTIONS'
        Assert-Match $r 'REQUIREMENTS'
        Assert-Match $r 'EXPECTED  (WOULD COMPLETE|WOULD FAIL|MAY FAIL)'
        Assert-Match $r 'Held back'
        $run = Get-Run $r 'PURGE'
        Assert-Manifest $run 'dry_run' '^Y$'
        Assert-Manifest $run 'step.PURGE.FORECAST.-' '^DONE'
        Assert-Manifest $run 'expected' '^(COMPLETE|FAIL|MAY_FAIL)\|'
        foreach ($check in @('P1', 'P2', 'P3', 'P4', 'P6', 'P8')) { Assert-Manifest $run ('check.' + $check) '^SKIP' }
        Assert-Manifest $run 'check.P5' '^(PASS|WARN)'
    }

    Invoke-Test 'T10B' 'Requirements gate: a purge without a backup choice does not start; S stops the preflight questions' {
        # With backup_max_age_h 0 no RMAN backup counts as recent; the
        # original value is put back whatever happens.
        $setting = ''
        $r = Invoke-Sql 'EPFPG' @('SET HEADING OFF FEEDBACK OFF PAGESIZE 0',
                                  "SELECT 'SETTING|' || value FROM epf_setting WHERE name = 'backup_max_age_h';",
                                  "UPDATE epf_setting SET value = '0' WHERE name = 'backup_max_age_h';", 'COMMIT;', 'EXIT')
        Assert-Exit $r @(0)
        foreach ($line in ($r.Output -split "`n")) {
            if ($line -match '^SETTING\|(\d+)') { $setting = $Matches[1] }
        }
        Add-Check ($setting -ne '') ('backup_max_age_h read (' + $setting + ')')
        if ($setting -eq '') { $setting = '24' }
        try {
            $r = Invoke-Wrapper @('purge', '--non-interactive', '--yes', '--retention', $script:Retention, '--mode', 'LOGS') -TimeoutMin 30
            Assert-Exit $r @(1)
            Assert-Match $r 'Blocking requirements not met: [A-Z_, ]*BACKUP'
            Assert-Match $r 'REQUIREMENTS_NOT_MET'
            Assert-Match $r 'NOT READY'
            Assert-NoMatch $r 'BATCH_PROGRESS'
            $run = Get-Run $r 'PURGE'
            Assert-Manifest $run 'status' '^FAILED$'
            Assert-Manifest $run 'req.BACKUP' '^NOT_MET\|Y\|'
            Assert-Manifest $run 'requirements_ready' '^N$'
            Assert-Manifest $run 'step.PURGE.PREPARE.-' '^SKIPPED'
            # The preflight's questions: S at the first one stops; nothing is
            # saved and the exit code is 3.
            $r = Invoke-Wrapper @('preflight', '--retention', $script:Retention, '--mode', 'LOGS') -Answers @('S', 'S', 'S') -TimeoutMin 30
            Assert-Exit $r @(3)
            Assert-Match $r $script:ChoicesSection
            Assert-Match $r 'Stopped: '
            Assert-NoMatch $r 'Checking again with these choices'
            # A preflight that did not end leaves no plan to follow.
            Assert-Manifest (Get-Run $r 'PREFLIGHT') 'plan_status' '^CLOSED$'
        } finally {
            # The statement in parentheses: the comma binds tighter than +.
            $r = Invoke-Sql 'EPFPG' @('SET HEADING OFF FEEDBACK OFF PAGESIZE 0',
                                      ("UPDATE epf_setting SET value = '" + $setting + "' WHERE name = 'backup_max_age_h';"),
                                      'COMMIT;', "SELECT 'SETTING|' || value FROM epf_setting WHERE name = 'backup_max_age_h';",
                                      'EXIT')
            Assert-Exit $r @(0)
            Assert-Match $r ('(?m)^SETTING\|' + $setting + '\s*$')
        }
    }

    Invoke-Test 'T11' 'PAYMENTS purge through the wizard with redo log sizing and undo tuning; graceful stop' {
        $script:State.StopCount = 0
        $script:State.StopSent = $false
        $script:State.InPurge = $false
        # Batches are counted from the PURGE section on (not in the wizard's preflight run).
        $onLine = {
            param($line)
            if ($line -match '^ PURGE  depth=') { $script:State.InPurge = $true }
            if ($script:State.InPurge -and $line -match 'BATCH_PROGRESS') { $script:State.StopCount = $script:State.StopCount + 1 }
            if (-not $script:State.StopSent -and $script:State.StopCount -ge $script:StopAfter) {
                $script:State.StopSent = $true
                Write-TestLog ('---- ' + $script:State.StopCount + ' BATCH_PROGRESS lines seen: requesting a graceful stop')
                $s = Invoke-Wrapper @('stop', '--non-interactive')
                Assert-Exit $s @(0)
                Assert-Match $s 'Stop requested'
            }
        }
        # Wizard answers: retention, mode, dry run, compact; in the preflight's
        # CHOICES the batch size (Enter: the recommendation for 1 GB logs);
        # final confirmation. --redo-logs, --undo-tuning and --backup none meet
        # the requirements, so no other question is asked.
        $answers = @($script:Retention, 'FULL', 'N', 'N', '', 'yes')
        $r = Invoke-Wrapper @('purge', '--depth', 'PAYMENTS', '--redo-logs', '--undo-tuning', '--backup', 'none') -Answers $answers `
                            -TimeoutMin 120 -OnLine $onLine -StopOnTimeout
        Add-Check $script:State.StopSent ('stop requested after ' + $script:StopAfter + ' BATCH_PROGRESS lines')
        Assert-Exit $r @(3)
        Assert-Match $r 'CHECKING THE DATABASE'
        # The wizard's preflight asks its questions (here only the batch size)
        # and checks again with the answers.
        Assert-Match $r $script:ChoicesSection
        Assert-Match $r 'READY with these choices'
        Assert-Match $r 'Recommended batch size with 1 GB online logs'
        # The purge checks the requirements again with the wizard's choices,
        # reusing the root counts of the wizard's preflight.
        Assert-Match $r 'PREFLIGHT  with the choices above; root counts of R-\d+'
        Assert-Match $r 'counted by R-\d+'
        Assert-Match $r 'REDO LOGS \(SYS\)'
        Assert-Match $r 'UNDO TUNING \(SYS\)'
        Assert-Match $r 'STOP_HONORED'
        Assert-Match $r 'UNDO TUNING RESTORE \(SYS\)'
        Assert-Match $r 'UNDO_RETENTION_RESTORED'
        Assert-Match $r 'UNDO_CAP'
        Assert-Match $r 'UNDO_GROWTH_LIMITED|UNDO_GROWTH_KEPT'
        Write-Note $r 'UNDO_GROWTH_RESTORED' 'undo growth limit restored'
        $null = Get-Run $r 'PREFLIGHT'
        $run = Get-Run $r 'PURGE'
        Assert-Manifest $run 'status' '^STOPPED$'
        Assert-Manifest $run 'exit_code' '^3$'
        Assert-Manifest $run 'redo_logs' '^Y$'
        Assert-Manifest $run 'undo_tuning' '^Y$'
        Assert-Manifest $run 'backup' '^NONE$'
        Assert-Manifest $run 'requirements_ready' '^Y$'
        Assert-Manifest $run 'preflight_run' '^R-\d+$'
        # The wizard's preflight planned the purge; the stopped step stays to do.
        Assert-Manifest $run 'plan_step' '^1$'
        Assert-Manifest $run 'plan_status' '^IN_PROGRESS$'
        Assert-Manifest $run 'plan_done' '^0$'
        Assert-Manifest $run 'check.P3' '^PASS'
        Assert-Manifest $run 'check.P4' '^(PASS|WARN)'
        Assert-Manifest $run 'check.P6' '^PASS'
        if ($null -ne $run) {
            $script:State.StoppedRun = $run['run']
            $script:State.StopBatch = $run['batch_size']
        }
    }

    Invoke-Test 'T12' 'State after the stop: undo restored, nothing pending' {
        $r = Invoke-Sql 'SYS' @((Get-ScriptLine (Join-Path $script:RunSqlDir 'undo.sql') @('STATUS')))
        Assert-Exit $r @(0)
        Assert-NoMatch $r 'active change'
        if ($script:State.UndoRetention -ne '') { Assert-Match $r ('undo_retention ' + $script:State.UndoRetention + ' s') }
        Assert-UndoLimits
        $r = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Exit $r @(0)
        Assert-Match $r 'status STOPPED'
        Assert-Match $r 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    Invoke-Test 'T12B' 'PAYMENTS dry run: the simulation T13 is compared with' {
        $batch = $script:State.StopBatch
        if ($batch -eq '' -or $batch -eq '-') { $batch = $script:PayBatch }
        $list = @('purge', '--non-interactive', '--retention', $script:Retention, '--depth', 'PAYMENTS', '--dry-run',
                  '--undo-tuning', '--backup', 'none')
        if ($batch -ne '') { $list += @('--batch-size', $batch) }
        $r = Invoke-Wrapper $list -TimeoutMin 120 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'SIMULATION \(dry run'
        Assert-Match $r 'EXPECTED  '
        Write-Note $r 'EXPECTED  WOULD COMPLETE' 'the simulation expects the purge to complete'
        Assert-NoMatch $r 'UNDO TUNING \(SYS\)'
        $run = Get-Run $r 'PURGE'
        Assert-Manifest $run 'dry_run' '^Y$'
        Assert-Manifest $run 'undo_tuning' '^Y$'
        Assert-Manifest $run 'expected' '^(COMPLETE|FAIL|MAY_FAIL)\|'
        # It rehearses the step T11 left to do (when T11 ran in this session).
        if ($script:State.StoppedRun -ne '') { Assert-Manifest $run 'plan_step' '^1$' }
        if ($null -ne $run) {
            $script:State.DryRun = $run['run']
            if ($run.ContainsKey('expected')) { $script:State.DryRunExpected = ([string]$run['expected']).Split('|')[0] }
        }
    }

    Invoke-Test 'T13' 'PAYMENTS purge to the end, non-interactive, undo tuning; forecast against result' {
        $batch = $script:State.StopBatch
        if ($batch -eq '' -or $batch -eq '-') { $batch = $script:PayBatch }
        $list = @('purge', '--non-interactive', '--yes', '--retention', $script:Retention, '--depth', 'PAYMENTS', '--undo-tuning',
                  '--backup', 'none')
        if ($batch -ne '') { $list += @('--batch-size', $batch) }
        $r = Invoke-Wrapper $list -TimeoutMin 240 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'PREFLIGHT'
        Assert-Match $r 'undo tuning planned for this purge'
        Assert-Match $r 'FORECAST AND RESULT'
        Assert-Match $r 'UNDO_CAP'
        Assert-Match $r 'UNDO_GROWTH_LIMITED|UNDO_GROWTH_KEPT'
        Assert-Match $r 'UNDO TUNING RESTORE \(SYS\)'
        Write-Note $r 'UNDO_GROWTH_RESTORED' 'undo growth limit restored'
        # The undo tablespace stayed within the growth limit: the larger of its
        # size before the tests and undo_cap_mb (4 GB), plus rounding.
        $files = Get-UndoFiles
        $bytes = ($files | Measure-Object -Property Bytes -Sum).Sum
        $limit = [Math]::Max([double]$script:State.UndoBaseBytes, 4GB) + 64MB
        Add-Check ($bytes -le $limit) ('undo tablespace ' + [Math]::Round($bytes / 1MB) + ' MB after the purge, within ' +
                                        [Math]::Round($limit / 1MB) + ' MB')
        Assert-UndoLimits
        $run = Get-Run $r 'PURGE'
        Assert-Manifest $run 'status' '^(SUCCESS|WARNING)$'
        foreach ($check in @('P1', 'P3', 'P6', 'P7')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        Assert-Manifest $run 'check.P2' '^(PASS|WARN)'
        Assert-Manifest $run 'check.P4' '^(PASS|WARN)'
        # It carries out the step T11 left to do, the last of its plan.
        if ($script:State.StoppedRun -ne '') {
            Assert-Manifest $run 'plan_step' '^1$'
            Assert-Manifest $run 'plan_status' '^DONE$'
            Assert-Match $r 'is done: every step ran'
        }
        # Forecast against result: rows exactly as the dry run counted them;
        # redo, undo, deleting time and space freed logged with their error.
        if ($null -ne $run) {
            Add-Check ($run.ContainsKey('forecast.PAYMENTS.ROWS')) 'manifest has forecast.PAYMENTS.ROWS'
            if ($script:State.DryRun -ne '') {
                Assert-Manifest $run 'forecast.PAYMENTS.ROWS' ('\|' + [regex]::Escape($script:State.DryRun) + '\|DRY_RUN$')
            }
            foreach ($measure in @('ROWS', 'REDO', 'UNDO', 'SECONDS', 'FREED')) {
                $key = 'forecast.PAYMENTS.' + $measure
                if (-not $run.ContainsKey($key)) { continue }
                $parts = ([string]$run[$key]).Split('|')
                if ($parts.Count -lt 4) { continue }
                $forecast = [double]0
                $actual = [double]0
                $text = $measure + ': forecast ' + $parts[0] + ', actual ' + $parts[1] + ' (' + $parts[3] + ' ' + $parts[2] + ')'
                if ([double]::TryParse($parts[0], [ref]$forecast) -and [double]::TryParse($parts[1], [ref]$actual) -and $actual -ne 0) {
                    $text = $text + ', error ' + [Math]::Round(100 * ($forecast - $actual) / $actual, 1) + '%'
                }
                if ($measure -eq 'ROWS') {
                    Add-Check ($parts[0] -ne '' -and $parts[0] -eq $parts[1]) ('rows forecast = rows deleted: ' + $text)
                } else {
                    Write-TestLog ('  forecast accuracy ' + $text)
                }
            }
        }
        if ($script:State.DryRunExpected -ne '') {
            Add-Check ($script:State.DryRunExpected -ne 'FAIL') ('the dry run did not predict a failure (' + $script:State.DryRunExpected + ')')
        }
    }

    Invoke-Test 'T13B' 'Plan of smaller runs: LOGS in steps (--max-redo); continue, refuse, rehearse, close' {
        # Older LOGS rows only (twice the suite's retention), so T14 still
        # finds rows to purge. No plan is open to start with.
        $retention = [string]([int]$script:Retention * 2)
        $options = @('--retention', $retention, '--mode', 'LOGS', '--backup', 'none', '--confirm', 'UNDO')
        $r = Invoke-Wrapper @('plan', '--close', '--non-interactive', '--yes')
        Assert-Exit $r @(0)
        $r = Invoke-Wrapper (@('preflight', '--non-interactive') + $options) -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        $run = Get-Run $r 'PREFLIGHT'
        Assert-Manifest $run 'plan' '^P-\d+$'
        Assert-Manifest $run 'plan_status' '^READY$'
        Assert-Manifest $run 'plan_steps' '^1$'
        Assert-Manifest $run 'step.PREFLIGHT.PLAN.-' '^DONE'
        if ($null -eq $run -or -not $run.ContainsKey('plan')) { return }
        $label = [string]$run['plan']
        $planId = $label -replace '^P-0*', ''
        Add-Check (Test-Path -LiteralPath (Join-Path (Join-Path $script:RunsDir $run['folder']) 'plan.txt')) 'plan.txt written'
        Add-Check (Test-Path -LiteralPath (Join-Path (Join-Path $script:RunsDir $run['folder']) 'requirements.txt')) 'requirements.txt written'

        # The redo of the plan and its months with roots: a limit of 60% of
        # the redo needs at least two runs.
        $q = Invoke-Sql 'EPFPG' @('SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMOUT ON',
            ("SELECT 'PLANREDO|' || NVL(SUM(redo_bytes), 0) FROM epf_plan_step WHERE plan_id = " + $planId + ';'),
            ("SELECT 'PLANMONTHS|' || COUNT(DISTINCT rm.month_start) FROM epf_root_month rm JOIN epf_plan p" +
             " ON p.preflight_run_id = rm.run_id WHERE p.plan_id = " + $planId + ' AND rm.roots > 0;'),
            'EXIT')
        Assert-Exit $q @(0)
        $redo = [double]0
        $months = 0
        foreach ($line in ($q.Output -split "`n")) {
            if ($line -match '^PLANREDO\|(\d+)') { $redo = [double]$Matches[1] }
            if ($line -match '^PLANMONTHS\|(\d+)') { $months = [int]$Matches[1] }
        }
        Write-TestLog ('  note plan ' + $label + ': redo estimate ' + $redo + ' bytes, ' + $months + ' months with roots')
        if ($redo -le 0 -or $months -lt 2) {
            Write-TestLog '  note fewer than 2 months of LOGS rows (or no redo estimate): the steps are not tested' 'Yellow'
            $r = Invoke-Wrapper @('plan', '--close', '--non-interactive', '--yes')
            Assert-Exit $r @(0)
            return
        }
        $limit = [string][long][Math]::Ceiling($redo * 0.6)

        # The same scope with --max-redo: the plan is checked again and split.
        $r = Invoke-Wrapper (@('preflight', '--non-interactive', '--max-redo', $limit) + $options) -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        Assert-Match $r ' Plan       runs of at most '
        Assert-Match $r 'CHANGES SINCE R-\d+'
        Assert-Match $r ('Next    epf_purge\.bat purge carries out step 1 of \d+ of plan ' + [regex]::Escape($label))
        $run = Get-Run $r 'PREFLIGHT'
        Assert-Manifest $run 'plan' ('^' + [regex]::Escape($label) + '$')
        Assert-Manifest $run 'plan_steps' '^([2-9]|\d\d+)$'
        Assert-Manifest $run 'max_redo' ('^' + $limit + '$')
        $steps = 0
        if ($null -ne $run -and $run.ContainsKey('plan_steps')) { $steps = [int]$run['plan_steps'] }
        if ($steps -lt 2) { return }

        # purge without scope options carries out step 1 with the plan's choices.
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--yes') -TimeoutMin 90 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r ('Plan ' + [regex]::Escape($label) + ': this run carries out step 1 of ' + $steps)
        Assert-Match $r 'Choices saved with the preflight R-\d+'
        Assert-Match $r ('Plan    ' + [regex]::Escape($label) + ': 1 of ' + $steps + ' steps done')
        $run = Get-Run $r 'PURGE'
        Assert-Manifest $run 'mode' '^LOGS$'
        Assert-Manifest $run 'backup' '^NONE$'
        Assert-Manifest $run 'confirmed' '^UNDO$'
        Assert-Manifest $run 'check.P1' '^PASS'
        Assert-Manifest $run 'plan_step' '^1$'
        Assert-Manifest $run 'plan_done' '^1$'
        Assert-Manifest $run 'plan_status' '^IN_PROGRESS$'

        # Other options while the plan is in progress: refused, nothing run.
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--yes', '--retention', $script:Retention, '--mode', 'LOGS',
                              '--backup', 'none')
        Assert-Exit $r @(4)
        Assert-Match $r 'is in progress and the options given differ'
        Add-Check ($r.Runs.Count -eq 0) 'no run created'

        # A dry run rehearses step 2; the plan does not change.
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--dry-run') -TimeoutMin 60
        Assert-Exit $r @(0, 2)
        Assert-Match $r ('this run rehearses step 2 of ' + $steps)
        $run = Get-Run $r 'PURGE'
        Assert-Manifest $run 'dry_run' '^Y$'
        Assert-Manifest $run 'plan_step' '^2$'
        Assert-Manifest $run 'plan_done' '^1$'

        # plan shows it; plan --close closes it, the step done stays done.
        $r = Invoke-Wrapper @('plan', '--non-interactive')
        Assert-Exit $r @(0)
        Assert-Match $r ('PLAN ' + [regex]::Escape($label) + '  IN_PROGRESS: 1 of ' + $steps + ' steps done')
        Assert-Match $r 'done by R-\d+'
        $r = Invoke-Wrapper @('plan', '--close', '--non-interactive', '--yes')
        Assert-Exit $r @(0)
        Assert-Match $r ('Plan ' + [regex]::Escape($label) + ' closed; the steps done stay done')
        $r = Invoke-Wrapper @('plan', '--non-interactive')
        Assert-Exit $r @(0)
        Assert-Match $r 'No open plan\. The latest plan:'
        Assert-Match $r ('PLAN ' + [regex]::Escape($label) + '  CLOSED: 1 of ' + $steps + ' steps done')
    }

    Invoke-Test 'T14' 'LOGS purge with compaction, non-interactive, undo growth confirmed' {
        # --confirm UNDO: no undo tuning (no SYS); the undo tablespace may grow.
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--yes', '--retention', $script:Retention, '--mode', 'LOGS',
                              '--compact', '--backup', 'none', '--confirm', 'UNDO') -TimeoutMin 90 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'PURGE COMPACT DONE'
        Write-Note $r 'COMPACTED' 'tables compacted (none when an earlier run already compacted them)'
        $run = Get-Run $r 'PURGE'
        foreach ($check in @('P1', 'P3', 'P6')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        Assert-Manifest $run 'check.P8' '^(PASS|WARN)'
        Assert-Manifest $run 'compact' '^Y$'
        Assert-Manifest $run 'confirmed' '^UNDO$'
        Assert-Manifest $run 'req.UNDO' '^MET\|Y\|(ROOM|CONFIRMED)$'
    }

    Invoke-Test 'T15' 'BANK_STATEMENTS LOB clearing (mode CLOB), non-interactive' {
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--yes', '--retention', $script:Retention, '--mode', 'CLOB',
                              '--depth', 'BANK_STATEMENTS', '--backup', 'none') -TimeoutMin 120 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'LOB values cleared'
        $run = Get-Run $r 'PURGE'
        foreach ($check in @('P1', 'P3', 'P6')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        Write-Note $r 'BASICFILE LOB segments' 'BASICFILE LOB note in the report'
    }

    Invoke-Test 'T16' 'BANK_STATEMENTS purge through the menu wizard (redo sizing already done)' {
        # Menu answers: 1 Purge, retention, mode, dry run, compact, batch size (in
        # the preflight's CHOICES), confirmation.
        $answers = @('1', $script:Retention, 'FULL', 'N', 'N', '', 'yes')
        $r = Invoke-Wrapper @('--depth', 'BANK_STATEMENTS', '--redo-logs', '--undo-tuning', '--backup', 'none') -Answers $answers `
                            -TimeoutMin 120 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'REDO_UNCHANGED|REDO_ENLARGED'
        Write-Note $r 'REDO_UNCHANGED' 'redo logs already enlarged by T11 (sizing is idempotent)'
        Assert-Match $r 'UNDO TUNING RESTORE \(SYS\)'
        $run = Get-Run $r 'PURGE'
        foreach ($check in @('P1', 'P3', 'P6')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        Write-Note $r 'BASICFILE LOB segments' 'BASICFILE LOB note in the report'
    }

    Invoke-Test 'T17' 'Reports through the wrapper: latest, and the stopped run' {
        $r = Invoke-Wrapper @('report', '--non-interactive')
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'EPF_VERDICT\|'
        if ($script:State.StoppedRun -ne '') {
            $r = Invoke-Wrapper @('report', '--non-interactive', '--run', $script:State.StoppedRun)
            Assert-Exit $r @(3)
            Assert-Match $r 'status STOPPED'
        } else {
            Write-TestLog '  note report of the stopped run skipped: T11 did not run in this session' 'Yellow'
        }
    }

    Invoke-Test 'T18' 'SQL entry scripts: report.sql, status.sql, advice.sql' {
        $r = Invoke-Sql 'EPFPG' @((Get-ScriptLine (Join-Path $script:RunSqlDir 'report.sql') @('LATEST')))
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'EPF_CHECK\|'
        $r = Invoke-Sql 'EPFPG' @((Get-ScriptLine (Join-Path $script:RunSqlDir 'status.sql')))
        Assert-Exit $r @(0)
        if ($script:State.PreflightRun -ne '') {
            $id = Get-RunNumber $script:State.PreflightRun
            $r = Invoke-Sql 'EPFPG' @((Get-ScriptLine (Join-Path $script:RunSqlDir 'advice.sql') @($id)))
            Assert-Exit $r @(0)
            Assert-Match $r 'EPF_ADVICE\|BATCH_SIZE'
            Assert-Match $r 'EPF_ADVICE\|REDO_PER_ROOT'
            Assert-Match $r 'EPF_ADVICE\|READY\|[YN]'
            Assert-Match $r 'EPF_ADVICE\|REQ\|BACKUP\|'
        }
    }

    Invoke-Test 'T18A' 'Reclaim lab: a scratch tablespace; its assessment (dry run) changes nothing' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 10
        Assert-Exit $lab @(0)
        Assert-Match $lab 'LAB\|SETUP\|DONE'
        $before = Read-Lab $lab
        $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--dry-run', '--tablespaces', 'EPF_RT_DATA') -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'reclaim_mode' '^ASSESS$'
        Assert-Manifest $run 'tablespace.EPF_RT_DATA' '^ASSESSED\|'
        foreach ($k in 1..9) { Assert-Manifest $run ('check.R' + $k) '^SKIP' }
        Assert-Manifest $run 'check.P5' '^(PASS|WARN)'
        # What moves, what stays and why, who is locked.
        Assert-Match $r 'TS_ASSESSED'
        Assert-Match $r 'SEGMENTS THAT STAY'
        Assert-Match $r 'RT_LONG[^\n]*LONG column'
        Assert-Match $r 'RT_PART[^\n]*partitioned'
        Assert-Match $r 'EPF_RT\.RT_TOP'
        foreach ($account in @('EPF_RT', 'EPF_RT_APP', 'EPF_RT_APP2')) { Assert-Match $r ('ACCOUNT_IN_SCOPE +' + $account + ' ') }
        if ($before.RecycleBin -gt 0) {
            Assert-Manifest $run 'req.RECYCLEBIN' '^NOT_MET\|Y\|'
        } else {
            Write-TestLog '  note the recycle bin is off: RT_BIN was dropped for good; RECYCLEBIN is met' 'Yellow'
        }
        $after = Read-Lab (Invoke-Lab 'CHECK')
        Assert-LabSame $before $after -SameSize
    }

    Invoke-Test 'T18B' 'Reclaim lab: compaction in place; requirement gate, room making, R1-R9, everything restored' {
        $before = Read-Lab (Invoke-Lab 'CHECK')
        if ($before.RecycleBin -gt 0) {
            # The recycle-bin object is not confirmed: nothing starts.
            $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA') -TimeoutMin 30
            Assert-Exit $r @(1)
            Assert-Match $r 'REQUIREMENTS_NOT_MET'
            Assert-LabSame $before (Read-Lab (Invoke-Lab 'CHECK')) -SameSize
        }
        $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN') `
                            -TimeoutMin 60 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        # Confirmed: the recycle-bin object is purged before the datafile
        # stops growing.
        if ($before.RecycleBin -gt 0) { Assert-Match $r 'RECYCLEBIN_PURGED' }
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'reclaim_mode' '^COMPACT$'
        Assert-Manifest $run 'status' '^(SUCCESS|WARNING)$'
        foreach ($check in @('R1', 'R2', 'R3', 'R4', 'R9')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        foreach ($check in @('R5', 'R6', 'R7', 'R8', 'P5')) { Assert-Manifest $run ('check.' + $check) '^(PASS|WARN)' }
        Assert-Manifest $run 'tablespace.EPF_RT_DATA' '^(COMPACTED|PARTIAL)\|'
        # The lab is built so that RT_TOP does not fit at first (RT_FAT moves
        # first), and the copy of a table that moves lands lower in the file.
        Assert-Match $r 'MAKING_ROOM'
        Assert-Match $r 'UNIT_MOVED +EPF_RT\.RT_TOP'
        # RT_FAT's INITIAL (40 MB) is more than it needs: its move sets 64 KB.
        Assert-Match $r 'INITIAL_RESET +EPF_RT\.RT_FAT'
        foreach ($step in @('LOCK_ACCOUNTS', 'RELEASE_INDEXES', 'FREEZE_FILES', 'REBUILD_INDEXES', 'RESTORE_FILES', 'RESIZE',
                            'VERIFY', 'UNLOCK_ACCOUNTS')) {
            Assert-Manifest $run ('step.RECLAIM.' + $step + '.-') '^DONE\|'
        }
        $after = Read-Lab (Invoke-Lab 'CHECK')
        Assert-LabSame $before $after
        Add-Check ($after.FileBytes -lt $before.FileBytes) ('EPF_RT_DATA datafile shrank: ' + $before.FileBytes + ' -> ' +
                                                         $after.FileBytes + ' bytes (segments ' + $after.Segments + ')')
        Add-Check ($after.RecycleBin -eq 0) ('no recycle-bin object left in EPF_RT_DATA (' + $after.RecycleBin + ')')
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Exit $s @(0)
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    # T18C and T18D: the compaction pauses after each table that moves
    # (setting reclaim_test_pause_s), so that the stop request or the end of
    # the worker session, which take a connection of their own, arrive while
    # it runs.
    Invoke-Test 'T18C' 'Reclaim lab: a stop during the compaction ends STOPPED with everything restored' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 10
        Assert-Exit $lab @(0)
        $before = Read-Lab $lab
        $script:State.StopSent = $false
        $onLine = {
            param($line)
            if (-not $script:State.StopSent -and $line -match 'TEST_PAUSE') {
                $script:State.StopSent = $true
                Write-TestLog '---- a table moved and the compaction pauses: requesting a graceful stop'
                $s = Invoke-Wrapper @('stop', '--non-interactive')
                Assert-Exit $s @(0)
            }
        }
        try {
            Set-TestPause 120
            $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN') `
                                -TimeoutMin 60 -OnLine $onLine -StopOnTimeout
            Add-Check ((Get-TestPause) -eq '0') 'the compaction set reclaim_test_pause_s back to 0'
        } finally {
            Set-TestPause 0
        }
        Add-Check $script:State.StopSent 'stop requested after the first table moved'
        Assert-Exit $r @(3)
        Assert-Match $r 'STOP_HONORED'
        Assert-Match $r 'RECYCLEBIN_PURGED'
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'status' '^STOPPED$'
        foreach ($check in @('R1', 'R2', 'R3', 'R4', 'R9')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        Assert-Manifest $run 'check.R8' '^WARN'
        Assert-Manifest $run 'tablespace.EPF_RT_DATA' '^PARTIAL\|'
        Assert-LabSame $before (Read-Lab (Invoke-Lab 'CHECK'))
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    Invoke-Test 'T18D' 'Reclaim lab: a worker session killed during the compaction is restored in the same run' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 10
        Assert-Exit $lab @(0)
        $before = Read-Lab $lab
        $script:State.StopSent = $false
        $onLine = {
            param($line)
            if (-not $script:State.StopSent -and $line -match 'TEST_PAUSE') {
                $script:State.StopSent = $true
                Write-TestLog '---- a table moved and the compaction pauses: killing the worker session (SYS)'
                $k = Invoke-Sql 'SYS' @(
                    'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 SERVEROUTPUT ON',
                    "BEGIN FOR s IN (SELECT sid, serial# FROM v`$session WHERE username = 'SYS' AND client_identifier LIKE 'EPF:%' AND sid <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))) LOOP EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.serial# || ''' IMMEDIATE'; DBMS_OUTPUT.PUT_LINE('KILLED|' || s.sid); END LOOP; END;",
                    '/',
                    'EXIT')
                Assert-Match $k 'KILLED\|\d+'
            }
        }
        try {
            Set-TestPause 120
            $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN') `
                                -TimeoutMin 60 -OnLine $onLine -StopOnTimeout
            Add-Check ((Get-TestPause) -eq '0') 'the compaction set reclaim_test_pause_s back to 0'
        } finally {
            Set-TestPause 0
        }
        Add-Check $script:State.StopSent 'worker session killed after the first table moved'
        Assert-Exit $r @(1)
        Assert-Match $r 'The worker session ended before the reclaim finished'
        Assert-Match $r 'RECLAIM  RESTORE'
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'status' '^FAILED$'
        Assert-Manifest $run 'check.R1' '^PASS'
        Assert-Manifest $run 'check.R9' '^PASS'
        Assert-LabSame $before (Read-Lab (Invoke-Lab 'CHECK'))
        # Nothing is left for a restore run to do.
        $r = Invoke-Wrapper @('reclaim', '--restore', '--non-interactive') -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'reclaim_mode' '^RESTORE$'
        foreach ($check in @('R1', 'R6', 'R9')) { Assert-Manifest $run ('check.' + $check) '^(PASS|SKIP)' }
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    # T18H and T18I: parking (--scratch). Setting reclaim_test_park makes the
    # compaction park the first table it picks, RT_TOP (it holds the top of
    # the lab's datafile), whatever Oracle does with the copies.
    Invoke-Test 'T18H' 'Reclaim lab: parking (--scratch): a table waits in a scratch tablespace and comes back; nothing left behind' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 10
        Assert-Exit $lab @(0)
        $before = Read-Lab $lab
        # The assessment with scratch space: requirement SCRATCH met.
        $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--dry-run', '--tablespaces', 'EPF_RT_DATA', '--scratch', '512M') `
                            -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        Assert-Manifest (Get-Run $r 'RECLAIM') 'req.SCRATCH' '^MET\|N\|'
        try {
            Set-TestPark 'Y'
            $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN',
                                  '--scratch', '512M') -TimeoutMin 60 -StopOnTimeout
            Add-Check ((Get-TestPark) -eq 'N') 'the compaction set reclaim_test_park back to N'
        } finally {
            Set-TestPark 'N'
        }
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'SCRATCH_CREATED +EPF_PARK_\d+'
        Assert-Match $r 'UNIT_PARKED +EPF_RT\.RT_TOP'
        Assert-Match $r 'UNIT_RETURNED +EPF_RT\.RT_TOP'
        Assert-Match $r 'SCRATCH_DROPPED +EPF_PARK_\d+'
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'status' '^(SUCCESS|WARNING)$'
        foreach ($check in @('R1', 'R2', 'R3', 'R4', 'R9')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        foreach ($check in @('R5', 'R6', 'R7', 'R8', 'P5')) { Assert-Manifest $run ('check.' + $check) '^(PASS|WARN)' }
        Assert-Manifest $run 'step.RECLAIM.RETURN_PARKED.-' '^DONE\|'
        $after = Read-Lab (Invoke-Lab 'CHECK')
        Assert-LabSame $before $after
        Add-Check ($after.FileBytes -lt $before.FileBytes) ('EPF_RT_DATA datafile shrank: ' + $before.FileBytes + ' -> ' +
                                                         $after.FileBytes + ' bytes (segments ' + $after.Segments + ')')
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Exit $s @(0)
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    Invoke-Test 'T18I' 'Reclaim lab: a worker session killed while a table is parked: the table comes back in the same run' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 10
        Assert-Exit $lab @(0)
        $before = Read-Lab $lab
        $script:State.StopSent = $false
        $onLine = {
            param($line)
            if (-not $script:State.StopSent -and $line -match 'TEST_PAUSE') {
                $script:State.StopSent = $true
                Write-TestLog '---- the first table is parked and the compaction pauses: killing the worker session (SYS)'
                $k = Invoke-Sql 'SYS' @(
                    'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 SERVEROUTPUT ON',
                    "BEGIN FOR s IN (SELECT sid, serial# FROM v`$session WHERE username = 'SYS' AND client_identifier LIKE 'EPF:%' AND sid <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))) LOOP EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.serial# || ''' IMMEDIATE'; DBMS_OUTPUT.PUT_LINE('KILLED|' || s.sid); END LOOP; END;",
                    '/',
                    'EXIT')
                Assert-Match $k 'KILLED\|\d+'
            }
        }
        try {
            Set-TestPark 'Y'
            Set-TestPause 120
            $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN',
                                  '--scratch', '512M') -TimeoutMin 60 -OnLine $onLine -StopOnTimeout
        } finally {
            Set-TestPause 0
            Set-TestPark 'N'
        }
        Add-Check $script:State.StopSent 'worker session killed while the first table was parked'
        Assert-Exit $r @(1)
        Assert-Match $r 'UNIT_PARKED +EPF_RT\.RT_TOP'
        Assert-Match $r 'The worker session ended before the reclaim finished'
        Assert-Match $r 'RECLAIM  RESTORE'
        Assert-Match $r 'UNIT_RETURNED +EPF_RT\.RT_TOP'
        Assert-Match $r 'SCRATCH_DROPPED +EPF_PARK_\d+'
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'status' '^FAILED$'
        Assert-Manifest $run 'check.R1' '^PASS'
        Assert-Manifest $run 'check.R6' '^(PASS|WARN)'
        Assert-Manifest $run 'check.R9' '^PASS'
        Assert-LabSame $before (Read-Lab (Invoke-Lab 'CHECK'))
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    # T18J and T18K: the connection lost instead of the session killed. The
    # worker's sqlplus ends on this machine; its call goes on in the database
    # (the compaction, then its own restore path). The restore of the wrapper
    # (T18J), or a later reclaim --restore after the whole wrapper was lost
    # (T18K), waits for that session (WORKER_RUNNING) before it changes
    # anything. A database that ends such a session at once is noted: the
    # restore then puts everything back itself.
    Invoke-Test 'T18J' 'Reclaim lab: the worker''s connection lost during the compaction: the restore in the same run waits for its call; nothing left' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 10
        Assert-Exit $lab @(0)
        $before = Read-Lab $lab
        $script:State.StopSent = $false
        $script:State.ClientEnded = $false
        $onLine = {
            param($line)
            if (-not $script:State.StopSent -and $line -match 'TEST_PAUSE') {
                $script:State.StopSent = $true
                Write-TestLog '---- a table moved and the compaction pauses: ending the worker''s sqlplus on this machine'
                $script:State.ClientEnded = Stop-WorkerClient
            }
        }
        try {
            Set-TestPause 120
            $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN') `
                                -TimeoutMin 60 -OnLine $onLine -StopOnTimeout
        } finally {
            Set-TestPause 0
        }
        Add-Check $script:State.ClientEnded 'the worker''s sqlplus ended while its session went on'
        Assert-Exit $r @(1)
        Assert-Match $r 'The worker session ended before the reclaim finished'
        Assert-Match $r 'RECLAIM  RESTORE'
        Write-Note $r 'WORKER_RUNNING' 'the restore waited for the worker whose client was gone'
        Write-Note $r 'WORKER_ENDED' 'the worker''s call ended, then the restore went on'
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'status' '^FAILED$'
        Assert-Manifest $run 'check.R1' '^PASS'
        Assert-Manifest $run 'check.R9' '^PASS'
        Assert-LabSame $before (Read-Lab (Invoke-Lab 'CHECK'))
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    Invoke-Test 'T18K' 'Reclaim lab: the whole wrapper lost while a table is parked: a later reclaim --restore waits for the worker''s call; nothing left' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 10
        Assert-Exit $lab @(0)
        $before = Read-Lab $lab
        $script:State.StopSent = $false
        $script:State.ClientEnded = $false
        $onLine = {
            param($line)
            if (-not $script:State.StopSent -and $line -match 'TEST_PAUSE') {
                $script:State.StopSent = $true
                Write-TestLog '---- the first table is parked and the compaction pauses: ending the wrapper and its sqlplus sessions'
                $script:State.ClientEnded = Stop-WrapperTree
            }
        }
        try {
            Set-TestPark 'Y'
            Set-TestPause 120
            $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN',
                                  '--scratch', '512M') -TimeoutMin 60 -OnLine $onLine -StopOnTimeout
            Add-Check $script:State.ClientEnded 'the wrapper ended while the first table was parked'
            Assert-Match $r 'UNIT_PARKED +EPF_RT\.RT_TOP'
            # The run lost with the wrapper is ended (ABANDONED) by the next
            # one, once the database has ended the monitor's session.
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $r = Invoke-Wrapper @('reclaim', '--restore', '--non-interactive') -TimeoutMin 60
                if ($r.ExitCode -ne 4 -or $r.Output -notmatch 'Another run is active') { break }
                Write-TestLog '---- the lost run still holds the run lock: trying again in 30 s' 'Yellow'
                Start-Sleep -Seconds 30
            }
        } finally {
            Set-TestPause 0
            Set-TestPark 'N'
        }
        Assert-Exit $r @(0, 2)
        Write-Note $r 'WORKER_RUNNING' 'the restore waited for the worker whose client was gone'
        Write-Note $r 'UNIT_RETURNED' 'the restore moved RT_TOP back itself (the worker''s call had ended)'
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'reclaim_mode' '^RESTORE$'
        foreach ($check in @('R1', 'R6', 'R9')) { Assert-Manifest $run ('check.' + $check) '^(PASS|SKIP)' }
        Assert-LabSame $before (Read-Lab (Invoke-Lab 'CHECK'))
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    Invoke-Test 'T18E' 'Reclaim: assessment of the application tablespaces (dry run, read-only)' {
        $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--dry-run') -TimeoutMin 60
        Assert-Exit $r @(0, 2)
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'reclaim_mode' '^ASSESS$'
        if ($null -ne $run) {
            $spaces = @($run.Keys | Where-Object { $_ -like 'tablespace.*' })
            Add-Check ($spaces.Count -gt 0) ('tablespaces assessed: ' + ($spaces -join ', '))
        }
        Write-Note $r 'Next +epf_purge\.bat reclaim' 'the assessment finds the compaction ready'
    }

    Invoke-Test 'T18F' 'Reclaim lab removed' {
        $lab = Invoke-Lab 'CLEANUP'
        Assert-Exit $lab @(0)
        Assert-Match $lab 'LAB\|CLEANUP\|DONE'
        $lab = Invoke-Lab 'CLEANUP' -Layout 2
        Assert-Exit $lab @(0)
        Assert-Match $lab 'LAB\|CLEANUP\|DONE'
    }

    # T18G: the second lab layout (reclaim_lab2.sql). Every table that moves
    # there has segments with an INITIAL larger than it needs, of each kind;
    # its owner starts above its quota on EPF_RT2_DATA. The lab removes itself
    # at the end (T18F removes one left by an earlier session).
    Invoke-Test 'T18G' 'Reclaim lab 2: two datafiles, index and LOB tablespaces, a queue table, INITIAL of each kind, quota gate' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 10 -Layout 2
        Assert-Exit $lab @(0)
        Assert-Match $lab 'LAB\|SETUP\|DONE'
        $before = Read-Lab $lab
        $initial = @()
        foreach ($line in ($lab.Output -split "`n")) {
            if ($line.Trim() -match '^LAB\|INITIAL\|([^|]+)\|') { $initial += $Matches[1] }
        }
        Write-TestLog ('  note segments with an INITIAL above 1 MB: ' + ($initial -join ', '))
        foreach ($label in @('RT2_HEAP', 'RT2_HEAP_PK', 'RT2_IOT_PK', 'RT2_IOT.OVERFLOW', 'RT2_BLOB.B')) {
            Add-Check ($initial -contains $label) ($label + ' has an INITIAL above 1 MB before the compaction')
        }
        $spaces = 'EPF_RT2_DATA,EPF_RT2_INDX,EPF_RT2_SIDE'
        # Assessment: the owner is above its quota on EPF_RT2_DATA.
        $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--dry-run', '--tablespaces', $spaces) -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'reclaim_mode' '^ASSESS$'
        Assert-Manifest $run 'req.QUOTA' '^NOT_MET\|Y\|'
        foreach ($ts in @('EPF_RT2_DATA', 'EPF_RT2_INDX', 'EPF_RT2_SIDE')) { Assert-Manifest $run ('tablespace.' + $ts) '^ASSESSED\|' }
        Assert-Match $r 'INITIAL_OVERSIZED'
        Assert-Match $r 'EPF_RT2 uses [^\n]*EPF_RT2_DATA, above its quota'
        if ($null -ne $run) {
            $k = Get-ReclaimKept $run['run']
            Assert-Exit $k @(0)
            Assert-Match $k 'KEPT\|PIN\|EPF_RT2\.RT2_LONG\|LONG column'
            Assert-Match $k 'KEPT\|PIN\|EPF_RT2\.RT2_QT\|queue table'
            Write-Note $k 'KEPT\|PIN\|EPF_RT2\.AQ\$_RT2_QT_[A-Z]+\|table of queue table RT2_QT' 'tables Oracle keeps for the queue table stay'
            Write-Note $k 'KEPT\|INDEX\|EPF_RT2\.[^|]+\|on a (queue table|table of queue table)' 'indexes of the queue tables left as found'
            Assert-NoMatch $k 'KEPT\|[A-Z]+\|EPF_RT2\.RT2_(HEAP|IOT|SLOB|BLOB|TOP)'
        }
        Assert-LabSame $before (Read-Lab (Invoke-Lab 'CHECK' -Layout 2)) -SameSize
        # Quota raised: the compaction runs.
        $q = Invoke-Lab 'QUOTA' -Layout 2
        Assert-Exit $q @(0)
        Assert-Match $q 'LAB\|QUOTA\|DONE'
        $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', $spaces) -TimeoutMin 60 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        $run = Get-Run $r 'RECLAIM'
        Assert-Manifest $run 'reclaim_mode' '^COMPACT$'
        Assert-Manifest $run 'status' '^(SUCCESS|WARNING)$'
        Assert-Manifest $run 'req.QUOTA' '^MET\|'
        foreach ($check in @('R1', 'R2', 'R3', 'R4', 'R9')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        foreach ($check in @('R5', 'R6', 'R7', 'R8', 'P5')) { Assert-Manifest $run ('check.' + $check) '^(PASS|WARN)' }
        # Every table of the lab moves (V15): none stays below where a
        # datafile stopped.
        Assert-Manifest $run 'check.R8' '^PASS\|5 of 5 moved$'
        Assert-Manifest $run 'tablespace.EPF_RT2_DATA' '^(COMPACTED|PARTIAL)\|'
        foreach ($step in @('LOCK_ACCOUNTS', 'RELEASE_INDEXES', 'FREEZE_FILES', 'REBUILD_INDEXES', 'RESTORE_FILES', 'RESIZE',
                            'VERIFY', 'UNLOCK_ACCOUNTS')) {
            Assert-Manifest $run ('step.RECLAIM.' + $step + '.-') '^DONE\|'
        }
        # Each kind of segment: its move or rebuild set INITIAL 64 KB.
        Assert-Match $r 'INITIAL_RESET +EPF_RT2\.RT2_HEAP:[^\n]*table '
        Assert-Match $r 'INITIAL_RESET +EPF_RT2\.RT2_IOT:[^\n]*index '
        Assert-Match $r 'INITIAL_RESET +EPF_RT2\.RT2_BLOB:[^\n]*LOB B '
        if ($initial -contains 'RT2_SLOB.C') {
            Assert-Match $r 'INITIAL_RESET +EPF_RT2\.RT2_SLOB:[^\n]*LOB C '
        } else {
            Write-TestLog '  note the SECUREFILE LOB segment was not created with its INITIAL of 8 MB: nothing to reset' 'Yellow'
        }
        $check = Invoke-Lab 'CHECK' -Layout 2
        $left = @()
        foreach ($line in ($check.Output -split "`n")) {
            if ($line.Trim() -match '^LAB\|INITIAL\|([^|]+)\|') { $left += $Matches[1] }
        }
        # A segment whose INITIAL Oracle kept passes only when the run says so
        # (INITIAL_KEPT, with the part of its table). The IOT overflow keeps
        # its INITIAL: a MOVE ignores STORAGE for it (probes A to F), so the
        # reclaim does not ask.
        $parts = @{ 'RT2_HEAP' = 'RT2_HEAP:[^\n]*table'; 'RT2_HEAP_PK' = 'RT2_HEAP_PK:'; 'RT2_IOT_PK' = 'RT2_IOT:[^\n]*index';
                    'RT2_BLOB.B' = 'RT2_BLOB:[^\n]*LOB B'; 'RT2_SLOB.C' = 'RT2_SLOB:[^\n]*LOB C' }
        $reset = @($initial | Where-Object { $parts.ContainsKey($_) })
        $done = @($reset | Where-Object { $left -notcontains $_ })
        Add-Check ($reset.Count -gt 0) ('segments with an oversized INITIAL before the compaction: ' + ($reset -join ', '))
        Write-TestLog ('  note INITIAL 64 KB now for: ' + ($done -join ', '))
        foreach ($label in @($reset | Where-Object { $left -contains $_ })) {
            Add-Check ($r.Output -match ('INITIAL_KEPT +EPF_RT2\.' + $parts[$label])) ($label + ' kept its INITIAL, and the run says so (INITIAL_KEPT)')
        }
        $other = @($left | Where-Object { $reset -notcontains $_ })
        if ($other.Count -gt 0) { Write-TestLog ('  note other segments with an INITIAL above 1 MB: ' + ($other -join ', ')) 'Yellow' }
        $after = Read-Lab $check
        Assert-LabSame $before $after
        Add-Check ($after.FileBytes -lt $before.FileBytes) ('the lab datafiles shrank: ' + $before.FileBytes + ' -> ' +
                                                         $after.FileBytes + ' bytes (segments ' + $after.Segments + ')')
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Exit $s @(0)
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
        # What Oracle does with STORAGE in a MOVE (recorded): A to F, an IOT
        # overflow; G, a heap table given INITIAL 128 MB in a wholly free
        # datafile that cannot grow, as while the reclaim compacts, which must
        # come out as two extents of 64 MB (the reclaim moves a large table, and
        # one that came back to the top, with extents of 64 MB); H, the same
        # in EPF_RT2_SIDE as the compaction left it (recorded only).
        $p = Invoke-Lab 'PROBE' -Layout 2
        Assert-Exit $p @(0)
        foreach ($line in ($p.Output -split "`n")) {
            if ($line.Trim() -match '^LAB\|PROBE\|([A-Z])\|(.*)$') { Write-TestLog ('  note probe ' + $Matches[1] + ': ' + $Matches[2]) }
        }
        Assert-Match $p 'LAB\|PROBE\|G\|ok\|2 extents: 2 x 64 MB\|'
        $lab = Invoke-Lab 'CLEANUP' -Layout 2
        Assert-Exit $lab @(0)
        Assert-Match $lab 'LAB\|CLEANUP\|DONE'
    }

    Invoke-Test 'T19' 'Final state: redo logs, undo_retention, pending changes, runs' {
        $r = Invoke-Sql 'SYS' @(
            'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMOUT ON',
            "SELECT 'REDO|group ' || group# || '|' || ROUND(bytes / 1048576) || ' MB|' || status FROM v`$log ORDER BY group#;",
            "SELECT 'UNDO|' || name || '=' || value FROM v`$parameter WHERE name IN ('undo_tablespace', 'undo_retention') ORDER BY name;",
            "SELECT 'INSTANCE_CHANGES_ACTIVE|' || COUNT(*) FROM epfpg.epf_instance_change WHERE restored_at IS NULL;",
            "SELECT 'RECLAIM_ACCOUNTS_LOCKED|' || COUNT(*) FROM epfpg.epf_account_action WHERE locked_at IS NOT NULL AND unlocked_at IS NULL;",
            "SELECT 'RECLAIM_INDEXES_UNUSABLE|' || COUNT(*) FROM epfpg.epf_reclaim_object o WHERE o.unit_type = 'INDEX' AND o.move_status IN ('RELEASED', 'FAILED') AND EXISTS (SELECT 1 FROM dba_indexes i WHERE i.owner = o.owner AND i.index_name = o.object_name AND i.status = 'UNUSABLE');",
            "SELECT 'TEMP_INDEX_LEFT|' || COUNT(*) FROM epfpg.epf_temp_index t WHERE t.dropped_at IS NULL AND EXISTS (SELECT 1 FROM dba_indexes i WHERE i.owner = t.owner AND i.index_name = t.index_name);",
            "SELECT 'RUN|' || run_id || '|' || action || '|' || purge_mode || '|' || depth || '|' || dry_run || '|' || status || '|' || verdict || '|exit ' || exit_code || '|' || TO_CHAR(started_at, 'HH24:MI:SS') || '-' || TO_CHAR(ended_at, 'HH24:MI:SS') FROM epfpg.epf_run ORDER BY run_id;",
            'EXIT')
        Assert-Exit $r @(0)
        Assert-Match $r 'INSTANCE_CHANGES_ACTIVE\|0'
        Assert-Match $r 'RECLAIM_ACCOUNTS_LOCKED\|0'
        Assert-Match $r 'RECLAIM_INDEXES_UNUSABLE\|0'
        Assert-Match $r 'TEMP_INDEX_LEFT\|0'
        Assert-NoMatch $r 'RUN\|[^\n]*\|(RUNNING|CREATED)\|'
        if ($script:State.UndoRetention -ne '') { Assert-Match $r ('undo_retention=' + $script:State.UndoRetention) }
        Assert-UndoLimits
    }
}

# ----------------------------------------------------------------------------
# Digest (--digest): what to send back after a test session, instead of its
# full log, in as few lines as a diagnosis needs. The summary; the notes and
# failed checks of the reclaim tests and of every test that failed, with the
# lines naming an error; then, for each compaction of the session, each run of
# a test that failed and each run in logs\ started after the session (a
# reclaim of an application tablespace): a line for the run, one for its
# checks, and its key events, one line each (a move with where its copy went,
# where each datafile stopped, the result per tablespace, steps of 30 s or
# more, every warning and error). Written to logs\digest.txt and copied to the
# clipboard; the full logs stay as they are.
# ----------------------------------------------------------------------------

# Event codes of a run's console.log that the digest keeps, besides every
# warning and error and the steps of 30 s or more: of an assessment, and of a
# compaction.
$script:DigestAssess = @('TS_ASSESSED', 'INITIAL_OVERSIZED', 'NO_TARGET')
$script:DigestCompact = @('INITIAL_RESET', 'INITIAL_KEPT', 'MAKING_ROOM', 'UNIT_MOVED', 'MOVE_PLACEMENT',
                          'MOVE_AGAIN_NOT_DONE', 'ROOM_MOVE_NO_ROOM', 'FILE_GROWN', 'FILE_DONE', 'RECLAIM_RESULT',
                          'STOP_HONORED', 'NO_TARGET', 'SCRATCH_CREATED', 'UNIT_PARKED', 'PARK_SKIPPED', 'PARK_FAILED',
                          'PARK_UNAVAILABLE', 'PARK_UNDONE', 'UNIT_RETURNED', 'RETURN_GREW', 'RETURN_FAILED',
                          'SCRATCH_DROPPED', 'SCRATCH_KEPT')
# The wrapper's lines that say why a run failed (Add-DigestRun): errors of
# its sessions, lost connections, the monitor, an early end and its restore.
$script:DigestTrouble = 'ORA-\d{5}|TNS-\d{5}|SP2-\d{4}|did not answer|did not finish|ended before|could not|' +
                        'no longer in the database|monitor|SUSPENDED|attach:|NOT restored'

function Get-FileLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path)
}

# An event's text for the digest: datafile paths without their directory,
# runs of spaces as one, and the wording of a move shortened.
function Format-DigestText {
    param([string]$Text)
    $t = $Text -replace '(?:[A-Za-z]:)?[\\/][^\s:;,()]*[\\/]([^\\/\s:;,()]+)', '$1'
    $t = $t -replace ' \(it made room for the table at the top\)', ' (room maker)'
    $t = $t -replace ' \(its copy holds the top again\)', ' (BACK AT THE TOP)'
    $t = $t -replace ' \(datafiles first grew by ([^)]+) to fit it\)', ' (files grew $1)'
    $t = $t -replace '^(\S+): INITIAL larger than needed \((.*)\); the move set it to 64 KB$', '$1 INITIAL 64 KB (was: $2)'
    return ($t -replace '\s{2,}', ' ').Trim()
}

# Bytes of a size as the tool prints it ("12.0 MB"); 0 when it is not one.
function ConvertTo-Bytes {
    param([string]$Text)
    if ($Text -notmatch '^([\d.]+) (B|KB|MB|GB|TB)$') { return [double]0 }
    $power = @{ 'B' = 0; 'KB' = 1; 'MB' = 2; 'GB' = 3; 'TB' = 4 }[$Matches[2]]
    return [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * [Math]::Pow(1024, $power)
}

# A size as the tool prints it.
function Format-Size {
    param([double]$Bytes)
    foreach ($unit in @(@('TB', 4), @('GB', 3), @('MB', 2), @('KB', 1))) {
        $value = $Bytes / [Math]::Pow(1024, $unit[1])
        if ($value -ge 1) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0} {1}', $value, $unit[0]) }
    }
    return ([string][int64]$Bytes + ' B')
}

function Format-Extents {
    param([string]$Count, [string]$Min, [string]$Max)
    if ($Min -eq $Max) { return $Count + ' x ' + $Min }
    return $Count + ' x ' + $Min + '..' + $Max
}

# A move's placement (MOVE_PLACEMENT) in short: where its segments lay before
# and after (extents), and the free space before the move. NULL when the
# text has another form.
function Format-Placement {
    param([string]$Text)
    $p = '^\S+ in \S+: was .+? in (\d+) extents of (.+?) to (.+?), from (.+?) to (.+?); now .+? in (\d+) extents of ' +
         '(.+?) to (.+?), from (.+?) to (.+?); before the move (.+?) free, (.+?) of it in stretches of 8 MB or more' +
         '(?: \(the lowest at (.+?)\))?, (.+?) in whole 64 MB stretches(?: \(the lowest at (.+?)\))?$'
    if ($Text -notmatch $p) { return $null }
    $m = $Matches
    $low8 = ''
    if ($m[13]) { $low8 = ' from ' + $m[13] }
    $low64 = ''
    if ($m[15]) { $low64 = ' from ' + $m[15] }
    return ('was ' + $m[4] + '-' + $m[5] + ' (' + (Format-Extents $m[1] $m[2] $m[3]) + '), now ' + $m[9] + '-' + $m[10] +
            ' (' + (Format-Extents $m[6] $m[7] $m[8]) + '); free before ' + $m[11] + ', 8M+ ' + $m[12] + $low8 +
            ', 64M ' + $m[14] + $low64)
}

# Adds run folder $Folder to the digest: a line from its manifest (action,
# mode, tablespaces, status, verdict, exit code, duration), its checks in one
# line (the ones that did not pass, and R7 and R8, with their detail), and its
# key events, one line each; a move (UNIT_MOVED) with its placement
# (MOVE_PLACEMENT). Of the moves, the first 10 and the last 40 when there are
# more. $Brief (a run of a test that passed): of the events only where each
# datafile stopped, the result per tablespace, a stop, warnings and errors.
function Add-DigestRun {
    param($Out, [string]$Folder, [string]$Test, [bool]$Brief = $false)
    $manifest = @{}
    $checks = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in (Get-FileLines (Join-Path $Folder 'manifest.txt'))) {
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $manifest[$line.Substring(0, $eq)] = $line.Substring($eq + 1)
        if ($line.StartsWith('check.')) { $checks.Add($line.Substring(6)) }
    }
    $duration = ''
    foreach ($line in (Get-FileLines (Join-Path $Folder 'report.txt'))) {
        if ($line -match 'duration (\d+:\d\d:\d\d)') { $duration = $Matches[1]; break }
    }
    $mode = [string]$manifest['reclaim_mode'] + [string]$manifest['mode']
    $head = '-- ' + (Split-Path -Leaf $Folder)
    if ($Test -ne '') { $head = $head + ' (' + $Test + ')' }
    $head = $head + ' ' + [string]$manifest['action'] + ' ' + $mode
    if ([string]$manifest['tablespaces'] -ne '') { $head = $head + ' ' + [string]$manifest['tablespaces'] }
    $head = $head + ': ' + [string]$manifest['status'] + ', ' + [string]$manifest['verdict'] + ', exit '
    $head = $head + [string]$manifest['exit_code'] + ', ' + $duration
    $Out.Add('')
    $Out.Add($head)
    $detail = New-Object 'System.Collections.Generic.List[string]'
    $plain = @{}
    $statuses = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in $checks) {
        if ($c -notmatch '^(\w+)=(\w+)\|?(.*)$') { continue }
        $code = $Matches[1]
        $status = $Matches[2]
        $text = $Matches[3]
        if (($status -eq 'PASS' -or $status -eq 'SKIP') -and $code -ne 'R7' -and $code -ne 'R8') {
            if (-not $plain.ContainsKey($status)) { $plain[$status] = New-Object 'System.Collections.Generic.List[string]'; $statuses.Add($status) }
            $plain[$status].Add($code)
        } else {
            $detail.Add($code + ' ' + $status + ' ' + $text)
        }
    }
    foreach ($status in $statuses) { $detail.Add($status + ' ' + ($plain[$status] -join ' ')) }
    if ($detail.Count -gt 0) { $Out.Add(' checks: ' + ($detail -join '; ')) }
    # A run that failed: the wrapper's own messages while it was shown and the
    # errors of its sqlplus sessions (a lost connection shows there, not in
    # the events).
    if ([string]$manifest['status'] -eq 'FAILED') {
        $said = @{}
        foreach ($line in (Get-FileLines (Join-Path $Folder 'console.log'))) {
            if ($line -match '^ REPORT +\d\d:\d\d:\d\d$') { break }
            if ($line -match '^\s\d\d:\d\d:\d\d \[' -or $line -notmatch $script:DigestTrouble) { continue }
            $text = Format-DigestText $line
            if ($said.ContainsKey($text)) { continue }
            $said[$text] = $true
            $Out.Add(' wrapper: ' + $text)
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $Folder -Filter 'sqlplus_*.log' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $errors = @(Get-FileLines $file.FullName | Where-Object { $_ -match 'ORA-\d{5}|TNS-\d{5}|SP2-\d{4}' } |
                        ForEach-Object { Format-DigestText $_ } | Select-Object -Unique)
            foreach ($text in ($errors | Select-Object -First 8)) { $Out.Add(' ' + $file.Name + ': ' + $text) }
            if ($errors.Count -gt 8) { $Out.Add(' ' + $file.Name + ': ... ' + ($errors.Count - 8) + ' more error lines') }
        }
    }
    $codes = $script:DigestCompact
    if ($mode -eq 'ASSESS') { $codes = $script:DigestAssess }
    if ($Brief) {
        $codes = @('FILE_DONE', 'RECLAIM_RESULT', 'STOP_HONORED', 'UNIT_PARKED', 'UNIT_RETURNED', 'PARK_FAILED',
                   'PARK_UNAVAILABLE', 'RETURN_GREW', 'RETURN_FAILED', 'SCRATCH_KEPT')
    }
    # The key events as entries: a move with its placement; a run of growths
    # of one datafile as one; a room making said again left out.
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $pendingUnit = ''
    $lastRoom = ''
    foreach ($line in (Get-FileLines (Join-Path $Folder 'console.log'))) {
        if ($line -notmatch '^\s(\d\d:\d\d:\d\d) \[(.{4})\] (\S+)\s+(.*)$') { continue }
        $time = $Matches[1]
        $tag = $Matches[2]
        $code = $Matches[3]
        $text = Format-DigestText $Matches[4]
        # The end of the run is in its header line already.
        $keep = (($tag -eq 'WARN' -or $tag -eq 'FAIL' -or $codes -contains $code) -and $code -ne 'RUN_END')
        if (-not $keep -and -not $Brief -and $code -eq 'STEP_END' -and $text -match ' in (\d+):(\d\d):(\d\d)') {
            $keep = ([int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]) -ge 30
        }
        if (-not $keep) { continue }
        if ($code -eq 'MOVE_PLACEMENT' -and $pendingUnit -ne '' -and $text.StartsWith($pendingUnit + ' in ')) {
            $short = Format-Placement $text
            if ($null -eq $short) { $short = $text }
            $entries[$entries.Count - 1].Text = $entries[$entries.Count - 1].Text + ' | ' + $short
            $pendingUnit = ''
            continue
        }
        $pendingUnit = ''
        if ($code -eq 'MAKING_ROOM') {
            if ($text -eq $lastRoom) { continue }
            $lastRoom = $text
        }
        $e = New-Object psobject -Property @{ Time = $time; Last = $time; Tag = $tag; Code = $code; Text = $text;
                                               Unit = ''; Small = $false; Absorbed = $false; Room = $false;
                                               Init = 0; Ts = ''; From = ''; To = ''; Bytes = [double]0; Count = 1 }
        if ($code -eq 'UNIT_MOVED') {
            $e.Text = $text -replace ' \(\d+:\d\d:\d\d\)$', ''
            $e.Unit = ($text -split ':')[0]
            $pendingUnit = $e.Unit
            if ($e.Text -match '^\S+: (\S+ \S+) -> (\S+ \S+); (\S+) (\S+ \S+) -> (\S+ \S+)(.*)$') {
                $flags = $Matches[6]
                $e.Ts = $Matches[3]
                $e.From = $Matches[4]
                $e.To = $Matches[5]
                $e.Bytes = [Math]::Max((ConvertTo-Bytes $Matches[1]), (ConvertTo-Bytes $Matches[2]))
                $e.Room = ($flags -match 'room maker')
                # A small move: below 64 MB and 2 % of its tablespace, none of
                # the marks of a move that matters on its own.
                $e.Small = ($e.Bytes -lt 64MB -and $e.Bytes -lt 0.02 * (ConvertTo-Bytes $e.From) -and
                            $flags -notmatch 'moved again|BACK AT THE TOP|with 64 MB extents|files grew')
            }
            if ($e.Small) {
                # The INITIAL resets just before a small move go with it.
                for ($k = $entries.Count - 1; $k -ge 0; $k--) {
                    $p = $entries[$k]
                    if ($p.Code -ne 'INITIAL_RESET' -or -not $p.Text.StartsWith($e.Unit + ' ')) { break }
                    $p.Absorbed = $true
                    $e.Init++
                }
            }
        } elseif ($code -eq 'FILE_GROWN' -and $text -match '^(File \d+ of \S+): (\S+ \S+) -> (\S+ \S+)') {
            $e.Unit = $Matches[1]
            $e.From = $Matches[2]
            $e.To = $Matches[3]
            # Growths that continue each other (no resize down between them).
            if ($entries.Count -gt 0 -and $entries[$entries.Count - 1].Code -eq 'FILE_GROWN' -and
                $entries[$entries.Count - 1].Unit -eq $e.Unit -and $entries[$entries.Count - 1].To -eq $e.From) {
                $prev = $entries[$entries.Count - 1]
                $prev.Count++
                $prev.To = $e.To
                $prev.Last = $time
                continue
            }
        }
        $entries.Add($e)
    }
    # One line per entry; consecutive small moves of one tablespace as one.
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $isMove = New-Object 'System.Collections.Generic.List[bool]'
    $i = 0
    while ($i -lt $entries.Count) {
        $e = $entries[$i]
        if ($e.Absorbed) { $i++; continue }
        if ($e.Small) {
            $group = New-Object 'System.Collections.Generic.List[object]'
            $j = $i
            while ($j -lt $entries.Count -and ($entries[$j].Absorbed -or ($entries[$j].Small -and $entries[$j].Ts -eq $e.Ts))) {
                if (-not $entries[$j].Absorbed) { $group.Add($entries[$j]) }
                $j++
            }
            if ($group.Count -eq 1) {
                $lines.Add($e.Time + ' MOVED ' + ($e.Text -replace ' \| .*$', ''))
            } else {
                $lastMove = $group[$group.Count - 1]
                $text = $e.Time + '-' + $lastMove.Time + ' MOVED ' + $group.Count + ' small tables ('
                $text = $text + (Format-Size ($group | Measure-Object -Property Bytes -Minimum).Minimum) + '..'
                $text = $text + (Format-Size ($group | Measure-Object -Property Bytes -Maximum).Maximum) + ' each'
                $rooms = @($group | Where-Object { $_.Room }).Count
                if ($rooms -gt 0) { $text = $text + ', ' + $rooms + ' to make room' }
                $inits = [int]($group | Measure-Object -Property Init -Sum).Sum
                if ($inits -gt 0) { $text = $text + ', ' + $inits + ' INITIAL reset' }
                $lines.Add($text + '): ' + $e.Ts + ' ' + $e.From + ' -> ' + $lastMove.To)
            }
            $isMove.Add($true)
            $i = $j
            continue
        }
        $prefix = $e.Time
        if ($e.Count -gt 1) { $prefix = $e.Time + '-' + $e.Last }
        $prefix = $prefix + ' '
        if ($e.Tag -eq 'WARN' -or $e.Tag -eq 'FAIL') { $prefix = $prefix + $e.Tag + ' ' }
        if ($e.Code -eq 'UNIT_MOVED') {
            $lines.Add($prefix + 'MOVED ' + $e.Text)
        } elseif ($e.Code -eq 'FILE_GROWN' -and $e.Count -gt 1) {
            $grown = $prefix + 'FILE_GROWN x' + $e.Count + ' ' + $e.Unit + ': ' + $e.From + ' -> ' + $e.To + ' '
            $lines.Add($grown + ($e.Text -replace '^File \d+ of \S+: \S+ \S+ -> \S+ \S+ ', ''))
        } else {
            $lines.Add($prefix + $e.Code + ' ' + $e.Text)
        }
        $isMove.Add(($e.Code -eq 'UNIT_MOVED' -or $e.Code -eq 'INITIAL_RESET' -or $e.Code -eq 'INITIAL_KEPT'))
        $i++
    }
    $moves = @($isMove | Where-Object { $_ }).Count
    $seen = 0
    $skipped = 0
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($isMove[$i]) {
            $seen++
            if ($moves -gt 50 -and $seen -gt 10 -and $seen -le $moves - 40) { $skipped++; continue }
        }
        if ($skipped -gt 0) { $Out.Add(' ... ' + $skipped + ' more lines of moves in console.log'); $skipped = 0 }
        $Out.Add(' ' + $lines[$i])
    }
    if ($skipped -gt 0) { $Out.Add(' ... ' + $skipped + ' more lines of moves in console.log') }
}

function Invoke-Digest {
    $logs = Join-Path $script:RepoDir 'logs'
    $out = New-Object 'System.Collections.Generic.List[string]'
    $session = $null
    if (Test-Path -LiteralPath (Join-Path $logs 'tests')) {
        $session = Get-ChildItem -LiteralPath (Join-Path $logs 'tests') -Directory | Sort-Object Name | Select-Object -Last 1
    }
    $since = ''
    if ($null -ne $session) {
        $since = $session.Name.Substring(0, [Math]::Min(17, $session.Name.Length))
        $out.Add('EPF digest of test session ' + $session.Name + ' (' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ')')
        $log = Get-FileLines (Join-Path $session.FullName 'test.log')
        $current = ''
        $order = New-Object 'System.Collections.Generic.List[string]'
        $lines = @{}
        $status = @{}
        $runOf = @{}
        $summary = $false
        foreach ($line in $log) {
            if ($line -match '^ SUMMARY\s*$') { $summary = $true; $current = ''; continue }
            if ($summary) {
                if ($line.Trim() -ne '' -and $line.Trim() -notmatch '^=+$') { $out.Add($line.TrimEnd()) }
                continue
            }
            if ($line -match '^==== (T\w+) ') {
                $current = $Matches[1]
                $order.Add($current)
                $lines[$current] = New-Object 'System.Collections.Generic.List[string]'
                continue
            }
            if ($line -match '^---- (T\w+) (PASS|FAIL|SKIPPED)') { $status[$Matches[1]] = $Matches[2]; continue }
            if ($current -eq '') { continue }
            if ($line -match 'Run folder .*[\\/]([^\\/]+_R-\d+)\s*$') { $runOf[$Matches[1]] = $current }
            $lines[$current].Add($line.TrimEnd())
        }
        foreach ($id in $order) {
            $failed = ([string]$status[$id] -eq 'FAIL')
            if (-not $failed -and -not $id.StartsWith('T18') -and $id -ne 'T01') { continue }
            $kept = New-Object 'System.Collections.Generic.List[string]'
            foreach ($line in $lines[$id]) {
                if (($line -match '^\s+note ' -and $line -notmatch '^\s+note probe [A-F]:') -or $line -match ': FAILED\s*$' -or
                    ($failed -and $line -match 'ORA-\d{5}|SP2-\d{4}|PLS-\d{5}|Suite error' -and
                     $line -notmatch '^\s\d\d:\d\d:\d\d \[')) {
                    $kept.Add($line)
                }
            }
            if ($kept.Count -eq 0) { continue }
            $out.Add('')
            $out.Add('-- ' + $id + ' ' + [string]$status[$id])
            $shown = 0
            foreach ($line in $kept) {
                $shown++
                if ($shown -gt 40) { $out.Add('   ... ' + ($kept.Count - 40) + ' more lines in test.log'); break }
                $out.Add($line)
            }
        }
        $runs = Join-Path $session.FullName 'runs'
        if (Test-Path -LiteralPath $runs) {
            foreach ($run in (Get-ChildItem -LiteralPath $runs -Directory | Where-Object { $_.Name -match '_R-\d+$' } | Sort-Object Name)) {
                $test = [string]$runOf[$run.Name]
                $compact = @(Get-FileLines (Join-Path $run.FullName 'manifest.txt') | Where-Object { $_ -eq 'reclaim_mode=COMPACT' }).Count -gt 0
                $failed = ($test -ne '' -and [string]$status[$test] -eq 'FAIL')
                if ($compact -and -not $failed) {
                    # A compaction that a passing test expected to stop before any
                    # change (a requirement not met) is left out.
                    $compact = @(Get-FileLines (Join-Path $run.FullName 'console.log') | Where-Object { $_ -match 'RECLAIM_RESULT' }).Count -gt 0
                }
                if ($compact -or $failed) { Add-DigestRun $out $run.FullName $test (-not $failed) }
            }
        }
    } else {
        $out.Add('EPF digest (' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + '): no test session in ' + (Join-Path $logs 'tests'))
    }
    $later = @()
    if (Test-Path -LiteralPath $logs) {
        $later = @(Get-ChildItem -LiteralPath $logs -Directory | Where-Object {
                       $_.Name -match '^\d{4}-\d\d-\d\d_\d{6}_R-\d+$' -and $_.Name.Substring(0, 17).CompareTo($since) -gt 0 } |
                   Sort-Object Name)
    }
    foreach ($run in $later) { Add-DigestRun $out $run.FullName '' }
    if ($later.Count -eq 0) {
        $out.Add('')
        $out.Add('-- no run in ' + $logs + ' started after the test session')
    }
    $text = $out -join "`r`n"
    if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
    $path = Join-Path $logs 'digest.txt'
    [System.IO.File]::WriteAllText($path, $text + "`r`n", [System.Text.Encoding]::ASCII)
    Write-Host $text
    $copied = ''
    try { Set-Clipboard -Value $text; $copied = '; copied to the clipboard' } catch { $copied = '' }
    Write-Host ''
    Write-Host ('Digest: ' + $out.Count + ' lines, ' + $text.Length + ' characters, in ' + $path + $copied) -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

function Invoke-Main {
    $configPath = Join-Path $script:TestDir 'test.conf'
    $i = 0
    while ($i -lt $script:CliArgs.Count) {
        $arg = [string]$script:CliArgs[$i]
        switch ($arg.ToLower()) {
            '--config' { $i++; $configPath = [string]$script:CliArgs[$i] }
            '--only'   { $i++; $script:Only = @(([string]$script:CliArgs[$i]).ToUpper().Split(',') | ForEach-Object { $_.Trim() }) }
            '--from'   { $i++; $script:From = ([string]$script:CliArgs[$i]).ToUpper().Trim() }
            '--list'   { $script:TestList | ForEach-Object { Write-Host $_ }; exit 0 }
            '--digest' { Invoke-Digest; exit 0 }
            default    { Exit-Suite 4 ('Unknown argument ' + $arg + '. Usage: run_tests.bat [--config FILE] [--only T03,T05] [--from T11] [--list] [--digest]') }
        }
        $i++
    }
    if (-not (Test-Path -LiteralPath $configPath)) {
        Exit-Suite 4 ('Configuration file not found: ' + $configPath + ' (copy test.conf.example to test.conf).')
    }
    $config = Read-Config $configPath
    $script:Tns = Get-Value $config 'TNS'
    $script:ExpectedDb = Get-Value $config 'EXPECTED_DB'
    $script:Retention = Get-Value $config 'RETENTION_DAYS' '30'
    $script:StopAfter = [int](Get-Value $config 'STOP_AFTER_BATCHES' '3')
    $script:PayBatch = Get-Value $config 'PAYMENTS_BATCH_SIZE'
    $script:ConnectTimeoutS = [int](Get-Value $config 'CONNECT_TIMEOUT_S' '120')
    if ($script:Tns -eq '' -or $script:ExpectedDb -eq '') { Exit-Suite 4 'TNS and EXPECTED_DB must be set in the configuration.' }
    if ((Get-Value $config 'DESTRUCTIVE_OK').ToUpper() -ne 'YES') {
        Exit-Suite 4 ('DESTRUCTIVE_OK is not YES: the tests purge ' + $script:ExpectedDb + ' and enlarge its redo logs. Set it in ' + $configPath + '.')
    }
    $script:SqlPlus = Find-SqlPlus
    if ($null -eq $script:SqlPlus) { Exit-Suite 4 'sqlplus.exe was not found in PATH or in ORACLE_HOME\bin.' }
    $script:Version = Get-ExpectedVersion

    $script:SysPw = Get-Value $config 'SYS_PASSWORD'
    if ($script:SysPw -eq '') { $script:SysPw = Read-Password ('SYS password of ' + $script:ExpectedDb) }
    $script:EpfPw = Get-Value $config 'EPFPG_PASSWORD'
    if ($script:EpfPw -eq '') { $script:EpfPw = Read-Password 'EPFPG password (set by the install)' }
    if ($script:EpfPw.Contains('"') -or $script:EpfPw.Contains("'") -or $script:SysPw.Contains('"')) {
        Exit-Suite 4 'The passwords must not contain quotes.'
    }

    $script:SessionDir = Join-Path (Join-Path (Join-Path $script:RepoDir 'logs') 'tests') ((Get-Date -Format 'yyyy-MM-dd_HHmmss') + '_' + $script:ExpectedDb)
    $script:RunsDir = Join-Path $script:SessionDir 'runs'
    New-Item -ItemType Directory -Path $script:RunsDir -Force | Out-Null
    $script:LogFile = Join-Path $script:SessionDir 'test.log'
    $script:WrapperConf = Join-Path $script:SessionDir 'wrapper.conf'
    [System.IO.File]::WriteAllText($script:WrapperConf, ("# Wrapper configuration of the tests: every other value comes from the command line.`r`n" +
                                                         'CONNECT_TIMEOUT_S=' + $script:ConnectTimeoutS + "`r`n"), [System.Text.Encoding]::ASCII)

    $selection = 'all'
    if ($script:Only.Count -gt 0) { $selection = 'only ' + ($script:Only -join ',') }
    elseif ($script:From -ne '') { $selection = 'from ' + $script:From }
    Write-TestLog '============================================================================'
    Write-TestLog ' EPF Data Purge - end-to-end tests'
    Write-TestLog '============================================================================'
    Write-TestLog (' Started      ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' on ' + $env:COMPUTERNAME + ' as ' + $env:USERNAME)
    Write-TestLog (' Database     ' + $script:ExpectedDb + ' (TNS ' + $script:Tns + ')')
    Write-TestLog (' Scripts      ' + $script:RepoDir + ', tool version ' + $script:Version)
    Write-TestLog (' sqlplus      ' + $script:SqlPlus)
    Write-TestLog (' Retention    ' + $script:Retention + ' days; stop after ' + $script:StopAfter + ' BATCH_PROGRESS lines')
    Write-TestLog (' Selection    ' + $selection)
    Write-TestLog (' Log          ' + $script:LogFile)

    $env:EPF_PASSWORD = $script:EpfPw
    $env:EPF_SYS_PASSWORD = $script:SysPw
    $started = Get-Date
    try {
        Invoke-Suite
    } finally {
        Remove-Item Env:EPF_PASSWORD -ErrorAction SilentlyContinue
        Remove-Item Env:EPF_SYS_PASSWORD -ErrorAction SilentlyContinue
    }

    Write-TestLog ''
    Write-TestLog '============================================================================'
    Write-TestLog ' SUMMARY'
    Write-TestLog '============================================================================'
    $failed = 0
    foreach ($t in $script:Results) {
        $color = 'Green'
        if ($t.Status -eq 'FAIL') { $color = 'Red'; $failed++ }
        if ($t.Status -eq 'SKIPPED') { $color = 'Yellow' }
        Write-TestLog (' {0}  {1,-7} {2}  {3}' -f $t.Id, $t.Status, (Format-Duration $t.Seconds), $t.Title) $color
        foreach ($f in $t.Failures) { Write-TestLog ('       failed: ' + $f) 'Red' }
    }
    $total = [int]((Get-Date) - $started).TotalSeconds
    $passed = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
    $skipped = @($script:Results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
    Write-TestLog ''
    Write-TestLog (' RESULT  ' + $passed + ' passed, ' + $failed + ' failed, ' + $skipped + ' skipped; total ' + (Format-Duration $total))
    Write-TestLog (' Log     ' + $script:LogFile)
    if ($failed -gt 0) { exit 1 }
    exit 0
}

try {
    Invoke-Main
} catch {
    Write-TestLog (' Suite error: ' + $_.Exception.Message) 'Red'
    exit 1
}

# ============================================================================
# EPF Data Purge - End-to-end test suite
# ============================================================================
# Purpose : Runs every current test of the tool against one test database,
#           in order, without further input: installation, SQL entry scripts,
#           the wrapper (wizard answers are piped, the graceful stop is
#           requested with the stop action), purges of every module and mode,
#           compaction, redo log sizing, undo tuning, reports. Everything is
#           written to one log file with a check list and a summary.
# Usage   : run_tests.bat [--config FILE] [--only T03,T05] [--from T11] [--list]
#             --config  test configuration (default src\tests\e2e\test.conf)
#             --only    run these tests (T01, the safety precheck, always runs)
#             --from    run this test and the ones after it
#             --list    print the tests and exit
# Requires: Windows PowerShell 5.1; sqlplus.exe in PATH or ORACLE_HOME\bin;
#           the TNS alias of the test database; its SYS password.
# Effects : DESTRUCTIVE. Purges every module of the test database (rows older
#           than RETENTION_DAYS), clears LOB values, compacts tables, enlarges
#           the online redo logs to 4 x 1 GB (permanent), lowers and restores
#           undo_retention. Refuses to start unless DESTRUCTIVE_OK=YES and the
#           database name equals EXPECTED_DB.
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
$script:Aborted     = $false
$script:State       = @{ PreflightRun = ''; StoppedRun = ''; StopBatch = ''; UndoRetention = ''; StopCount = 0;
                         StopSent = $false; InPurge = $false; UndoFiles = @(); UndoBaseBytes = [decimal]0 }

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

# Starts a process with the given standard input, writes every output line to
# the log as it arrives, calls $OnLine for each line, and ends it after the
# timeout (with $OnTimeout called first, and 15 more minutes, when given).
# Once the process has exited, its output is read for 15 more seconds at
# most: a process it left running can keep the pipe open.
function Invoke-Process {
    param([string]$File, [string]$Arguments, [string]$Display, [string[]]$InputLines = @(),
          [string[]]$InputDisplay = @(), [int]$TimeoutMin = 15, [scriptblock]$OnLine = $null,
          [scriptblock]$OnTimeout = $null, [string]$WorkDir = '')
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
    foreach ($l in $InputLines) { $process.StandardInput.WriteLine($l) }
    $process.StandardInput.Close()
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
    $seconds = [int]((Get-Date) - $started).TotalSeconds
    Write-TestLog ('exit ' + $code + ' (' + (Format-Duration $seconds) + ')')
    $orphans = $orphans + (Stop-Orphans $started)
    return [pscustomobject]@{ ExitCode = $code; Output = ($lines -join "`n"); TimedOut = $timedOut; Runs = @();
                              Orphans = $orphans }
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
function Invoke-Wrapper {
    param([string[]]$Arguments, [string[]]$Answers = @(), [int]$TimeoutMin = 15, [scriptblock]$OnLine = $null,
          [switch]$StopOnTimeout)
    $list = @($Arguments) + @('--tns', $script:Tns, '--config', $script:WrapperConf, '--log-dir', $script:RunsDir, '--no-color')
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
# (written to standard input; logged with the password masked).
function Invoke-Sql {
    param([string]$User, [string[]]$Commands, [string[]]$CommandDisplay = @(), [int]$TimeoutMin = 15,
          [string]$Display = '')
    if ($User -eq 'SYS') {
        $connect = 'CONNECT sys/"' + $script:SysPw + '"@' + $script:Tns + ' AS SYSDBA'
        $shown = 'CONNECT sys/********@' + $script:Tns + ' AS SYSDBA'
    } else {
        $connect = 'CONNECT epfpg/"' + $script:EpfPw + '"@' + $script:Tns
        $shown = 'CONNECT epfpg/********@' + $script:Tns
    }
    if ($CommandDisplay.Count -eq 0) { $CommandDisplay = $Commands }
    if ($Display -eq '') { $Display = 'sqlplus -S -L /nolog (' + $User + ')' }
    $result = Invoke-Process -File $script:SqlPlus -Arguments '-S -L /nolog' -Display $Display `
                             -InputLines (@($connect) + $Commands + @('EXIT 9')) `
                             -InputDisplay (@($shown) + $CommandDisplay) -TimeoutMin $TimeoutMin
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
    'T01  Precheck: database identity, non-CDB, redo logs, undo (SYS; safety gate)',
    'T02  Environment survey (src/tests/verify/environment.sql)',
    'T03  Install through the wrapper (install action)',
    'T04  Install again with install.sql (idempotent upgrade path)',
    'T05  Undo tuning left from earlier work restored; undo datafile limits recorded',
    'T06  Wrapper basics: --help, status, stop without an active run',
    'T07  Usage errors: exit 4, nothing changed',
    'T08  Preflight through the wrapper',
    'T09  preflight.sql NEW',
    'T10  Dry run of all modules through the wrapper',
    'T11  PAYMENTS purge through the wizard with redo log sizing and undo tuning; graceful stop',
    'T12  State after the stop: undo restored, nothing pending',
    'T13  PAYMENTS purge to the end, non-interactive, undo tuning',
    'T14  LOGS purge with compaction, non-interactive',
    'T15  BANK_STATEMENTS LOB clearing (mode CLOB), non-interactive',
    'T16  BANK_STATEMENTS purge through the menu wizard (redo sizing already done)',
    'T17  Reports through the wrapper: latest, and the stopped run',
    'T18  SQL entry scripts: report.sql, status.sql, advice.sql',
    'T19  Final state: redo logs, undo_retention, pending changes, runs'
)

function Invoke-Suite {
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
            'EXIT')
        Assert-Exit $r @(0)
        $db = ''
        $container = ''
        $cdb = ''
        $logMode = ''
        $instances = ''
        foreach ($line in ($r.Output -split "`n")) {
            if ($line -match '^DB\|([^|]*)\|([^|]*)\|([^|]*)\|') {
                $db = $Matches[1].Trim()
                $cdb = $Matches[2].Trim()
                $logMode = $Matches[3].Trim()
            }
            if ($line -match '^CONTAINER\|(.*)$') { $container = $Matches[1].Trim() }
            if ($line -match '^INSTANCES\|(\d+)') { $instances = $Matches[1] }
            if ($line -match '^UNDO\|undo_retention=(\d+)') { $script:State.UndoRetention = $Matches[1] }
        }
        $expected = $script:ExpectedDb.ToUpper()
        Add-Check ($db.ToUpper() -eq $expected -or $container.ToUpper() -eq $expected) ('database ' + $db + ' / container ' + $container + ' is EXPECTED_DB ' + $expected)
        Add-Check ($cdb -eq 'NO') ('non-CDB database (CDB=' + $cdb + '): redo log sizing and undo tuning need it')
        Add-Check ($instances -eq '1') ('single instance (' + $instances + ')')
        if ($logMode -eq 'ARCHIVELOG') {
            Write-TestLog '  note ARCHIVELOG mode: the PAYMENTS purge writes about 90 GB of redo; the archive destination needs that space' 'Yellow'
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
        foreach ($case in @(@('purge', '--bogus'), @('reclaim'), @('preflight', '--non-interactive', '--compact'),
                            @('purge', '--non-interactive', '--dry-run', '--compact'),
                            @('purge', '--non-interactive', '--batch-size', '50'),
                            @('purge', '--non-interactive', '--retention', $script:Retention))) {
            $r = Invoke-Wrapper $case
            Assert-Exit $r @(4)
            Add-Check ($r.Runs.Count -eq 0) 'no run created'
        }
        Assert-Match $r '--yes is required with --non-interactive'
    }

    Invoke-Test 'T08' 'Preflight through the wrapper' {
        $r = Invoke-Wrapper @('preflight', '--non-interactive', '--retention', $script:Retention) -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'ROOTS_ELIGIBLE'
        Assert-Match $r 'REDO_LOGS'
        Assert-Match $r 'UNDO_ESTIMATE|No rows before the cutoff'
        $run = Get-Run $r 'PREFLIGHT'
        Assert-Manifest $run 'check.P5' '^(PASS|WARN)'
        if ($null -ne $run) { $script:State.PreflightRun = $run['run'] }
    }

    Invoke-Test 'T09' 'preflight.sql NEW' {
        $r = Invoke-Sql 'EPFPG' @((Get-ScriptLine (Join-Path $script:RunSqlDir 'preflight.sql') @('NEW'))) -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'RUN_END'
    }

    Invoke-Test 'T10' 'Dry run of all modules through the wrapper' {
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--retention', $script:Retention, '--dry-run') -TimeoutMin 60
        Assert-Exit $r @(0, 2)
        $run = Get-Run $r 'PURGE'
        Assert-Manifest $run 'dry_run' '^Y$'
        foreach ($check in @('P1', 'P2', 'P3', 'P4', 'P6', 'P8')) { Assert-Manifest $run ('check.' + $check) '^SKIP' }
        Assert-Manifest $run 'check.P5' '^(PASS|WARN)'
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
        # Wizard answers: retention, mode, dry run, compact, batch size (Enter: the
        # recommendation for 1 GB logs), final confirmation.
        $answers = @($script:Retention, 'FULL', 'N', 'N', '', 'yes')
        $r = Invoke-Wrapper @('purge', '--depth', 'PAYMENTS', '--redo-logs', '--undo-tuning') -Answers $answers `
                            -TimeoutMin 120 -OnLine $onLine -StopOnTimeout
        Add-Check $script:State.StopSent ('stop requested after ' + $script:StopAfter + ' BATCH_PROGRESS lines')
        Assert-Exit $r @(3)
        Assert-Match $r 'CHECKING THE DATABASE'
        Assert-Match $r 'Recommended batch size with 1 GB online logs'
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
        Assert-Manifest $run 'preflight_run' '^R-\d+$'
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
        Assert-Match $r 'no temporary index, undo tuning or locked account pending'
    }

    Invoke-Test 'T13' 'PAYMENTS purge to the end, non-interactive, undo tuning' {
        $batch = $script:State.StopBatch
        if ($batch -eq '' -or $batch -eq '-') { $batch = $script:PayBatch }
        $list = @('purge', '--non-interactive', '--yes', '--retention', $script:Retention, '--depth', 'PAYMENTS', '--undo-tuning')
        if ($batch -ne '') { $list += @('--batch-size', $batch) }
        $r = Invoke-Wrapper $list -TimeoutMin 240 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'PREFLIGHT'
        Assert-Match $r 'undo tuning planned for this purge'
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
    }

    Invoke-Test 'T14' 'LOGS purge with compaction, non-interactive' {
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--yes', '--retention', $script:Retention, '--mode', 'LOGS',
                              '--compact') -TimeoutMin 90 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'PURGE COMPACT DONE'
        Write-Note $r 'COMPACTED' 'tables compacted (none when an earlier run already compacted them)'
        $run = Get-Run $r 'PURGE'
        foreach ($check in @('P1', 'P3', 'P6')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        Assert-Manifest $run 'check.P8' '^(PASS|WARN)'
        Assert-Manifest $run 'compact' '^Y$'
    }

    Invoke-Test 'T15' 'BANK_STATEMENTS LOB clearing (mode CLOB), non-interactive' {
        $r = Invoke-Wrapper @('purge', '--non-interactive', '--yes', '--retention', $script:Retention, '--mode', 'CLOB',
                              '--depth', 'BANK_STATEMENTS') -TimeoutMin 120 -StopOnTimeout
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'LOB values cleared'
        $run = Get-Run $r 'PURGE'
        foreach ($check in @('P1', 'P3', 'P6')) { Assert-Manifest $run ('check.' + $check) '^PASS' }
        Write-Note $r 'BASICFILE LOB segments' 'BASICFILE LOB note in the report'
    }

    Invoke-Test 'T16' 'BANK_STATEMENTS purge through the menu wizard (redo sizing already done)' {
        # Menu answers: 1 Purge, retention, mode, dry run, compact, batch size, confirmation.
        $answers = @('1', $script:Retention, 'FULL', 'N', 'N', '', 'yes')
        $r = Invoke-Wrapper @('--depth', 'BANK_STATEMENTS', '--redo-logs', '--undo-tuning') -Answers $answers `
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
        }
    }

    Invoke-Test 'T19' 'Final state: redo logs, undo_retention, pending changes, runs' {
        $r = Invoke-Sql 'SYS' @(
            'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMOUT ON',
            "SELECT 'REDO|group ' || group# || '|' || ROUND(bytes / 1048576) || ' MB|' || status FROM v`$log ORDER BY group#;",
            "SELECT 'UNDO|' || name || '=' || value FROM v`$parameter WHERE name IN ('undo_tablespace', 'undo_retention') ORDER BY name;",
            "SELECT 'UNDO_ACTIVE|' || COUNT(*) FROM epfpg.epf_instance_change WHERE restored_at IS NULL;",
            "SELECT 'TEMP_INDEX_LEFT|' || COUNT(*) FROM epfpg.epf_temp_index t WHERE t.dropped_at IS NULL AND EXISTS (SELECT 1 FROM dba_indexes i WHERE i.owner = t.owner AND i.index_name = t.index_name);",
            "SELECT 'RUN|' || run_id || '|' || action || '|' || purge_mode || '|' || depth || '|' || dry_run || '|' || status || '|' || verdict || '|exit ' || exit_code || '|' || TO_CHAR(started_at, 'HH24:MI:SS') || '-' || TO_CHAR(ended_at, 'HH24:MI:SS') FROM epfpg.epf_run ORDER BY run_id;",
            'EXIT')
        Assert-Exit $r @(0)
        Assert-Match $r 'UNDO_ACTIVE\|0'
        Assert-Match $r 'TEMP_INDEX_LEFT\|0'
        Assert-NoMatch $r 'RUN\|[^\n]*\|(RUNNING|CREATED)\|'
        if ($script:State.UndoRetention -ne '') { Assert-Match $r ('undo_retention=' + $script:State.UndoRetention) }
        Assert-UndoLimits
    }
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
            default    { Exit-Suite 4 ('Unknown argument ' + $arg + '. Usage: run_tests.bat [--config FILE] [--only T03,T05] [--from T11] [--list]') }
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
    [System.IO.File]::WriteAllText($script:WrapperConf, "# Empty wrapper configuration: every value comes from the command line.`r`n", [System.Text.Encoding]::ASCII)

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

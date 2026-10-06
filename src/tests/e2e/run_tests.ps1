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

# The reclaim lab (src/tests/verify/reclaim_lab.sql, SYS) in mode SETUP, CHECK
# or CLEANUP.
function Invoke-Lab {
    param([string]$Mode, [int]$TimeoutMin = 15)
    $path = Join-Path $script:VerifyDir 'reclaim_lab.sql'
    return (Invoke-Sql 'SYS' @((Get-ScriptLine $path @($Mode))) -TimeoutMin $TimeoutMin)
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
    'T01  Precheck: database identity, non-CDB, redo logs, undo (SYS; safety gate)',
    'T02  Environment survey (src/tests/verify/environment.sql)',
    'T03  Install through the wrapper (install action)',
    'T04  Install again with install.sql (idempotent upgrade path)',
    'T05  Undo tuning left from earlier work restored; undo datafile limits recorded',
    'T06  Wrapper basics: --help, status, stop without an active run',
    'T07  Usage errors: exit 4, nothing changed',
    'T08  Preflight through the wrapper',
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
    'T18E Reclaim: assessment of the application tablespaces (dry run, read-only)',
    'T18F Reclaim lab removed',
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
        foreach ($case in @(@('purge', '--bogus'), @('reclaim', '--non-interactive'),
                            @('reclaim', '--non-interactive', '--dry-run', '--restore'),
                            @('reclaim', '--non-interactive', '--dry-run', '--confirm', 'UNDO'),
                            @('reclaim', '--non-interactive', '--dry-run', '--tablespaces', 'A-B'),
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

    Invoke-Test 'T08' 'Preflight through the wrapper' {
        $r = Invoke-Wrapper @('preflight', '--non-interactive', '--retention', $script:Retention) -TimeoutMin 30
        Assert-Exit $r @(0, 2)
        Assert-Match $r 'ROOTS_ELIGIBLE'
        Assert-Match $r 'REDO_LOGS'
        Assert-Match $r 'PREFLIGHT UNDO DONE'
        Assert-Match $r 'ESTIMATE \(rows before the cutoff'
        Assert-Match $r 'RETENTION OPTIONS'
        Assert-Match $r 'REQUIREMENTS'
        Assert-Match $r ' RESULT  (READY|NOT READY)'
        Assert-NoMatch $r '(?m)^EPF_REQ\|'
        Assert-NoMatch $r $script:ChoicesSection
        $run = Get-Run $r 'PREFLIGHT'
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
            $r = Invoke-Sql 'EPFPG' @("UPDATE epf_setting SET value = '" + $setting + "' WHERE name = 'backup_max_age_h';", 'COMMIT;', 'EXIT')
            Assert-Exit $r @(0)
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
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 30
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
        foreach ($step in @('LOCK_ACCOUNTS', 'RELEASE_INDEXES', 'FREEZE_FILES', 'REBUILD_INDEXES', 'RESTORE_FILES', 'RESIZE',
                            'VERIFY', 'UNLOCK_ACCOUNTS')) {
            Assert-Manifest $run ('step.RECLAIM.' + $step + '.-') '^DONE\|'
        }
        $after = Read-Lab (Invoke-Lab 'CHECK')
        Assert-LabSame $before $after
        Add-Check ($after.FileBytes -lt $before.FileBytes) ('EPF_RT_DATA datafile shrank: ' + $before.FileBytes + ' -> ' +
                                                         $after.FileBytes + ' bytes (segments ' + $after.Segments + ')')
        $s = Invoke-Wrapper @('status', '--non-interactive')
        Assert-Exit $s @(0)
        Assert-Match $s 'no temporary index, undo tuning, reclaim change or locked account pending'
    }

    Invoke-Test 'T18C' 'Reclaim lab: a stop during the compaction ends STOPPED with everything restored' {
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 30
        Assert-Exit $lab @(0)
        $before = Read-Lab $lab
        $script:State.StopSent = $false
        $onLine = {
            param($line)
            if (-not $script:State.StopSent -and $line -match 'UNIT_MOVED') {
                $script:State.StopSent = $true
                Write-TestLog '---- a table moved: requesting a graceful stop'
                $s = Invoke-Wrapper @('stop', '--non-interactive')
                Assert-Exit $s @(0)
            }
        }
        $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN') `
                            -TimeoutMin 60 -OnLine $onLine -StopOnTimeout
        Add-Check $script:State.StopSent 'stop requested after the first table moved'
        Assert-Exit $r @(3)
        Assert-Match $r 'STOP_HONORED'
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
        $lab = Invoke-Lab 'SETUP' -TimeoutMin 30
        Assert-Exit $lab @(0)
        $before = Read-Lab $lab
        $script:State.StopSent = $false
        $onLine = {
            param($line)
            if (-not $script:State.StopSent -and $line -match 'UNIT_MOVED') {
                $script:State.StopSent = $true
                Write-TestLog '---- a table moved: killing the worker session (SYS)'
                $k = Invoke-Sql 'SYS' @(
                    'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 SERVEROUTPUT ON',
                    "BEGIN FOR s IN (SELECT sid, serial# FROM v`$session WHERE username = 'SYS' AND client_identifier LIKE 'EPF:%' AND sid <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))) LOOP EXECUTE IMMEDIATE 'ALTER SYSTEM KILL SESSION ''' || s.sid || ',' || s.serial# || ''' IMMEDIATE'; DBMS_OUTPUT.PUT_LINE('KILLED|' || s.sid); END LOOP; END;",
                    '/',
                    'EXIT')
                Assert-Match $k 'KILLED\|\d+'
            }
        }
        $r = Invoke-Wrapper @('reclaim', '--non-interactive', '--yes', '--tablespaces', 'EPF_RT_DATA', '--confirm', 'RECYCLEBIN') `
                            -TimeoutMin 60 -OnLine $onLine -StopOnTimeout
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

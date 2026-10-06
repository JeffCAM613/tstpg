# ============================================================================
# EPF Data Purge - Command line, wizard and live view
# ============================================================================
# Purpose : Implementation of epf_purge.bat. Reads the command line and the
#           configuration file, collects every input before the first change
#           (wizard), runs the entry scripts of src\sql\run in sqlplus sessions
#           fed through standard input (passwords are never placed on a
#           command line, in a file or in a child environment), shows the run
#           live, writes the run folder and returns the exit code.
# Usage   : epf_purge.bat [action] [options]      (epf_purge.bat --help)
# Requires: Windows PowerShell 5.1; sqlplus.exe in PATH or in ORACLE_HOME\bin.
# Exit    : 0 PASS, 1 FAIL, 2 PASS WITH WARNINGS, 3 aborted or stopped,
#           4 usage or configuration error.
# ============================================================================

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CliArgs     = @($args)
$script:SrcDir      = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:RepoDir     = Split-Path -Parent $script:SrcDir
$script:RunSqlDir   = Join-Path $script:SrcDir 'sql\run'
$script:InstallDir  = Join-Path $script:SrcDir 'sql\install'
$script:UseColor    = $true
$script:Interactive = $true
$script:LogFile     = $null
$script:Buffered    = New-Object 'System.Collections.Generic.List[string]'
$script:SqlPlus     = $null
$script:Cli         = $null
$script:Config      = @{}
$script:Database    = $null
$script:ClockOffset = [TimeSpan]::Zero
$script:Children    = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'

$script:ExitPass    = 0
$script:ExitFail    = 1
$script:ExitWarn    = 2
$script:ExitAborted = 3
$script:ExitUsage   = 4

$script:Modes = @('FULL', 'CLOB', 'LOGS', 'CLOB_N_LOGS')
$script:Width = 80
# Seconds a sqlplus session may take to connect before it is ended and
# started again (configuration key CONNECT_TIMEOUT_S), and the line it
# prints once connected (Start-Session).
$script:ConnectTimeoutS = 120
$script:ReadyMarker = 'EPF_SESSION_READY'

# sqlplus sessions read their standard input in the console code page. With a
# UTF-8 console (code page 65001) .NET would begin every session's input with
# a byte order mark, and sqlplus would reject the CONNECT line; the encoding
# is kept, without the mark.
try {
    if ([Console]::InputEncoding.CodePage -eq 65001 -and [Console]::InputEncoding.GetPreamble().Length -gt 0) {
        [Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
} catch {
    # No console attached: sessions then use the ANSI code page, which has no mark.
}

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

# Appends a line to console.log of the run folder; lines written before the
# folder exists are kept and written when it is created.
function Write-Log {
    param([string]$Text)
    if ($null -ne $script:LogFile) {
        [System.IO.File]::AppendAllText($script:LogFile, $Text + "`r`n", [System.Text.Encoding]::ASCII)
    } else {
        $script:Buffered.Add($Text)
    }
}

# Writes a line to the console (in colour unless --no-color) and to the log.
function Write-Out {
    param([string]$Text = '', [string]$Color = '', [switch]$NoLog)
    if ($script:UseColor -and $Color -ne '') {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
    if (-not $NoLog) { Write-Log $Text }
}

# Section header with the database clock (the clock of the event times).
function Write-Section {
    param([string]$Title)
    $clock = (Get-Date).Add($script:ClockOffset).ToString('HH:mm:ss')
    Write-Out ''
    Write-Out (' ' + $Title.PadRight($script:Width - $clock.Length - 1) + $clock) 'White'
}

# Writes script output line by line without its trailing blank lines; errors
# in red, warnings in yellow, a passing verdict in green. -HideMachine leaves
# the machine-readable EPF_ lines out of the console (the log keeps them).
function Show-Lines {
    param([string]$Text, [switch]$Indent, [switch]$HideMachine)
    $lines = @($Text -split "`r?`n")
    $last = $lines.Count - 1
    while ($last -ge 0 -and $lines[$last].Trim() -eq '') { $last-- }
    for ($i = 0; $i -le $last; $i++) {
        $line = $lines[$i].TrimEnd()
        if ($HideMachine -and $line -match '^EPF_[A-Z_]+\|') {
            Write-Log $line
            continue
        }
        if ($Indent) { $line = '  ' + $line }
        $color = ''
        if ($line -match 'ORA-\d{5}|SP2-\d{4}|\[FAIL\]| FAIL |VERDICT  FAIL') { $color = 'Red' }
        elseif ($line -match '\[WARN\]| WARN |PASS WITH WARNINGS') { $color = 'Yellow' }
        elseif ($line -match 'VERDICT  PASS') { $color = 'Green' }
        Write-Out $line $color
    }
}

function Exit-Tool {
    param([int]$Code, [string]$Message = '')
    if ($Message -ne '') {
        if ($Code -eq 0) { Write-Out (' ' + $Message) } else { Write-Out (' ' + $Message) 'Red' }
    }
    exit $Code
}

function Show-Help {
    $text = @'
EPF Data Purge

Usage: epf_purge.bat [action] [options]

Actions
  (none)       interactive wizard
  purge        purge: preflight, purge, report
  preflight    read-only checks and estimates, and the plan of the purge;
               changes no data
  plan         the open plan with its steps (or the latest plan)
               --close closes the open plan
  report       report of a run                          --run <id|LATEST>
  reclaim      give the space a purge freed back to the disk: the tables of
               the application's tablespaces move within them so that their
               datafiles shrink (SYS; the application accounts are locked
               meanwhile). --dry-run assesses only; --restore restores what
               a reclaim that did not finish left pending
  status       state of the active or latest run, pending temporary indexes,
               undo tuning, and what a reclaim left pending
  stop         request a graceful stop of the active run
  install      install or upgrade the database objects (SYS)
  uninstall    remove the database objects (SYS)

Options
  --config FILE        configuration file (default src\config\epf_purge.conf);
                       command line values override file values
  --tns NAME           TNS alias or EZConnect string (PDB service in multitenant)
  --retention DAYS     default 30
  --cutoff YYYY-MM-DD  purge rows dated before this day, instead of --retention
                       (keeps the cutoff of an earlier preflight or dry run)
  --depth LIST         ALL, or modules separated by commas
                       (PAYMENTS,LOGS,BANK_STATEMENTS); not used in LOGS mode
  --mode MODE          FULL | CLOB | LOGS | CLOB_N_LOGS
  --batch-size N       root rows per transaction, 100-100000; the wizard
                       offers the preflight's recommendation
  --dry-run            simulation: exact counts, forecast and expected outcome;
                       nothing is deleted (reclaim: the assessment only)
  --backup CHOICE      when no recent RMAN backup is found: confirmed (a backup
                       was made another way) or none (purge without a backup)
  --confirm LIST       requirements the DBA confirms are handled although the
                       preflight finds them not met: ARCHIVE, UNDO, TEMP
                       separated by commas (reclaim: ARCHIVE, TEMP, RECYCLEBIN)
  --tablespaces LIST   reclaim: tablespaces separated by commas (default: every
                       tablespace holding segments of the application schemas)
  --restore            reclaim: rebuild the indexes, restore the datafile
                       growth settings and unlock the accounts a reclaim that
                       did not finish left pending
  --compact            shrink the purged tables afterwards (purge only)
  --redo-logs          enlarge the online redo logs first (4 x 1 GB,
                       permanent; SYS)
  --undo-tuning        lower undo_retention and limit undo growth (4 GB by
                       default) for the purge; restored at the end (SYS)
                       With preflight or --dry-run, --redo-logs and
                       --undo-tuning are checked as planned; nothing is
                       changed
  --max-redo SIZE      the most redo one run of the plan may write, such as
                       500M or 20G (preflight, and the wizard's purge): the
                       plan splits the purge into runs of at most that much,
                       older data first
  --new                start over: close the open plan (preflight: plan
                       again; purge: run the options given)
  --close              with plan: close the open plan
  --run ID             run for report (default LATEST) and stop (default:
                       the active run); 124 or R-000124
  --yes                skip the final confirmation (required with
                       --non-interactive for a purge that deletes, a reclaim,
                       and uninstall)
  --non-interactive    never prompt; missing input is an error (exit 4)
  --log-dir DIR        run folders (default: logs in the tool folder)
  --no-color           plain output
  --help

Requirements and choices
  The preflight checks six requirements: archive space, undo, TEMP, index
  space, redo logs and backup. Run it without --non-interactive and it asks,
  for each one not met, how to meet it (undo tuning, larger redo logs, the
  backup choice, a confirmation by the DBA, or stop), then the batch size,
  and checks again. The answers are saved with the preflight and its plan:
  the purges of the plan follow them. Options on the command line
  (--batch-size, --backup, --confirm, --undo-tuning, --redo-logs) are choices
  too. A purge does not start while a blocking requirement (archive, undo,
  TEMP, backup) is not met. A dry run simulates the purge and predicts its
  outcome.

Plan of smaller runs
  The preflight also plans the purge: one run, or several when the archive
  space (ARCHIVELOG) or --max-redo cannot take its redo at once, older data
  first. purge without --retention, --cutoff, --mode or --depth carries out
  the next step of the open plan with its choices (--dry-run rehearses it);
  preflight checks the plan again, and the wizard does so first when the
  last check is older than 8 hours or found requirements not met. A purge
  with other options is refused while a plan is in progress (the wizard
  asks); --new starts over. A plan with no step run yet is replaced by a
  run with other options. Between runs in ARCHIVELOG the DBA backs up and
  deletes the archived logs.

Reclaim
  A purge frees space inside the tables; the datafiles keep their size. The
  reclaim gives that space back in place: the indexes of the tables that move
  are released, the datafiles stop growing, the table holding the highest
  block of a datafile moves into the free space below it and the file is
  resized down, until a segment that cannot move (listed in the report) holds
  the top; then the indexes are rebuilt, the growth settings restored and the
  accounts unlocked. No datafile grows above its size at the start. With
  prompts, the reclaim shows its assessment and asks before anything moves.
  Ctrl+C stops after the current table; what was changed is restored either
  way, and a later reclaim continues from there.

Environment
  EPF_PASSWORD         EPFPG password
  EPF_SYS_PASSWORD     SYS password (install, uninstall, reclaim, --redo-logs,
                       --undo-tuning)

While a run is shown, Ctrl+C requests a graceful stop: the purge stops after
its current batch (a reclaim after its current table) and the run ends with
its report.

Exit codes: 0 PASS, 1 FAIL, 2 PASS WITH WARNINGS, 3 aborted or stopped,
4 usage or configuration error.
'@
    Write-Host $text
}

# ----------------------------------------------------------------------------
# Command line and configuration
# ----------------------------------------------------------------------------

function Read-Arguments {
    param([object[]]$List)
    $result = @{ Action = $null; Options = @{}; Flags = @{} }
    $valueOptions = @('config', 'tns', 'retention', 'cutoff', 'depth', 'mode', 'batch-size', 'backup', 'confirm',
                      'log-dir', 'run', 'tablespaces', 'long-conversion', 'max-redo')
    $flagOptions = @('dry-run', 'compact', 'redo-logs', 'undo-tuning', 'yes', 'non-interactive', 'no-color',
                     'help', 'reclaim', 'resume', 'new', 'close', 'restore')
    $i = 0
    while ($i -lt $List.Count) {
        $arg = [string]$List[$i]
        if ($arg.StartsWith('--')) {
            $name = $arg.Substring(2)
            $value = $null
            $eq = $name.IndexOf('=')
            if ($eq -gt 0) {
                $value = $name.Substring($eq + 1)
                $name = $name.Substring(0, $eq)
            }
            $name = $name.ToLower()
            if ($valueOptions -contains $name) {
                if ($null -eq $value) {
                    $i++
                    if ($i -ge $List.Count) { Exit-Tool $script:ExitUsage ('Option --' + $name + ' needs a value.') }
                    $value = [string]$List[$i]
                }
                $result.Options[$name] = $value
            } elseif ($flagOptions -contains $name) {
                $result.Flags[$name] = $true
            } else {
                Exit-Tool $script:ExitUsage ('Unknown option --' + $name + '. See epf_purge.bat --help.')
            }
        } elseif ($null -eq $result.Action) {
            $result.Action = $arg.ToLower()
        } else {
            Exit-Tool $script:ExitUsage ('Unexpected argument ' + $arg + '. See epf_purge.bat --help.')
        }
        $i++
    }
    return $result
}

function Read-ConfigFile {
    param([string]$Path)
    $values = @{}
    foreach ($line in (Get-Content -LiteralPath $Path)) {
        $text = $line.Trim()
        if ($text -eq '' -or $text.StartsWith('#')) { continue }
        $eq = $text.IndexOf('=')
        if ($eq -lt 1) { Exit-Tool $script:ExitUsage ('Invalid line in ' + $Path + ': ' + $text) }
        $values[$text.Substring(0, $eq).Trim().ToUpper()] = $text.Substring($eq + 1).Trim()
    }
    return $values
}

# Value of an option: command line, then configuration file, then default.
function Get-Option {
    param([string]$Name, [string]$Key, [string]$Default = '')
    if ($script:Cli.Options.ContainsKey($Name)) { return [string]$script:Cli.Options[$Name] }
    if ($script:Config.ContainsKey($Key) -and $script:Config[$Key] -ne '') { return [string]$script:Config[$Key] }
    return $Default
}

function Test-ConfigYes {
    param([string]$Key)
    return ($script:Config.ContainsKey($Key) -and (@('Y', 'YES', 'TRUE', '1') -contains $script:Config[$Key].ToUpper()))
}

# ----------------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------------

# Returns the normalised value, or $null when it is not valid.
function Test-Value {
    param([string]$Value, [string[]]$Allowed = @(), [int]$Min = 0, [int]$Max = 0, [string]$Pattern = '')
    $text = $Value.Trim()
    if ($text -eq '') { return $null }
    if ($Allowed.Count -gt 0) {
        if (-not ($Allowed -contains $text.ToUpper())) { return $null }
        return $text.ToUpper()
    }
    if ($Min -gt 0) {
        $number = 0
        if (-not [int]::TryParse($text, [ref]$number)) { return $null }
        if ($number -lt $Min -or ($Max -gt 0 -and $number -gt $Max)) { return $null }
        return [string]$number
    }
    if ($Pattern -ne '' -and $text.ToUpper() -notmatch $Pattern) { return $null }
    return $text
}

function Get-Hint {
    param([string[]]$Allowed = @(), [int]$Min = 0, [int]$Max = 0, [string]$Hint = '')
    if ($Allowed.Count -gt 0) { return 'valid values: ' + ($Allowed -join ', ') }
    if ($Min -gt 0 -and $Max -gt 0) { return 'a whole number from ' + $Min + ' to ' + $Max }
    if ($Min -gt 0) { return 'a whole number of at least ' + $Min }
    return $Hint
}

# Prompts until a valid value is entered; Enter takes the default. Without
# prompts the default must be valid.
function Read-Value {
    param([string]$Prompt, [string]$Default = '', [string[]]$Allowed = @(), [int]$Min = 0, [int]$Max = 0,
          [string]$Pattern = '', [string]$Hint = 'a value is required')
    if (-not $script:Interactive) {
        $value = Test-Value $Default $Allowed $Min $Max $Pattern
        if ($null -eq $value) {
            Exit-Tool $script:ExitUsage ($Prompt + ': missing or invalid value (' + (Get-Hint $Allowed $Min $Max $Hint) + ').')
        }
        return $value
    }
    $label = $Prompt
    if ($Default -ne '') { $label = $label + ' [' + $Default + ']' }
    while ($true) {
        $answer = Read-Host -Prompt (' ' + $label)
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        $value = Test-Value $answer $Allowed $Min $Max $Pattern
        if ($null -ne $value) {
            Write-Log (' ' + $label + ': ' + $value)
            return $value
        }
        Write-Out ('   ' + (Get-Hint $Allowed $Min $Max $Hint)) 'Yellow' -NoLog
    }
}

# Value of an option that may be prompted for: a command line value skips the
# prompt; a configuration value is the prompt's default.
function Get-Input {
    param([string]$Name, [string]$Key, [string]$Prompt, [string]$Default = '', [string[]]$Allowed = @(),
          [int]$Min = 0, [int]$Max = 0, [string]$Pattern = '', [string]$Hint = 'a value is required')
    if ($script:Cli.Options.ContainsKey($Name)) {
        $value = Test-Value ([string]$script:Cli.Options[$Name]) $Allowed $Min $Max $Pattern
        if ($null -eq $value) {
            Exit-Tool $script:ExitUsage ('--' + $Name + ': invalid value (' + (Get-Hint $Allowed $Min $Max $Hint) + ').')
        }
        return $value
    }
    $initial = Get-Option $Name $Key $Default
    return (Read-Value -Prompt $Prompt -Default $initial -Allowed $Allowed -Min $Min -Max $Max -Pattern $Pattern -Hint $Hint)
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    if (-not $script:Interactive) { return $Default }
    $text = 'N'
    if ($Default) { $text = 'Y' }
    $answer = Read-Value -Prompt ($Prompt + ' (Y/N)') -Default $text -Allowed @('Y', 'N', 'YES', 'NO')
    return ($answer -eq 'Y' -or $answer -eq 'YES')
}

# A yes/no option: a command line flag sets it; otherwise the configuration
# value is the answer, or the default of the prompt with -Ask.
function Get-Choice {
    param([string]$Name, [string]$Key, [string]$Prompt, [switch]$Ask)
    if ($script:Cli.Flags.ContainsKey($Name)) { return $true }
    $default = Test-ConfigYes $Key
    if ($Ask) { return (Read-YesNo $Prompt $default) }
    return $default
}

function ConvertFrom-Secure {
    param([System.Security.SecureString]$Secure)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# Password from the environment, the configuration file or a masked prompt
# (entered twice with -Twice), kept as a SecureString.
function Read-Secret {
    param([string]$Prompt, [string]$EnvName, [string]$ConfigKey, [switch]$Twice)
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrEmpty($fromEnv)) { return (ConvertTo-SecureString $fromEnv -AsPlainText -Force) }
    if ($script:Config.ContainsKey($ConfigKey) -and $script:Config[$ConfigKey] -ne '') {
        return (ConvertTo-SecureString $script:Config[$ConfigKey] -AsPlainText -Force)
    }
    if (-not $script:Interactive) {
        Exit-Tool $script:ExitUsage ('Missing ' + $Prompt + ': set ' + $EnvName + ' (non-interactive).')
    }
    while ($true) {
        $first = Read-Host -Prompt (' ' + $Prompt) -AsSecureString
        if ($first.Length -eq 0) { Write-Out '   a value is required' 'Yellow' -NoLog; continue }
        if (-not $Twice) { return $first }
        $second = Read-Host -Prompt (' ' + $Prompt + ' (again)') -AsSecureString
        if ((ConvertFrom-Secure $first) -ceq (ConvertFrom-Secure $second)) { return $first }
        Write-Out '   the two entries differ' 'Yellow' -NoLog
    }
}

# Final confirmation of a destructive action: typed "yes", or --yes.
function Read-Typed {
    param([string]$Prompt)
    if ($script:Cli.Flags.ContainsKey('yes')) { return }
    if (-not $script:Interactive) {
        Exit-Tool $script:ExitUsage ($Prompt + ': --yes is required with --non-interactive.')
    }
    $answer = Read-Host -Prompt (' ' + $Prompt + '. Type yes to proceed')
    Write-Log (' ' + $Prompt + '. Type yes to proceed: ' + $answer)
    if ($answer -ne 'yes') { Exit-Tool $script:ExitAborted 'Aborted.' }
}

# ----------------------------------------------------------------------------
# sqlplus sessions
# ----------------------------------------------------------------------------

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

function New-Login {
    param([string]$User, [System.Security.SecureString]$Secret, [string]$Tns, [switch]$Sysdba)
    return [pscustomobject]@{ User = $User; Secret = $Secret; Tns = $Tns; Sysdba = [bool]$Sysdba }
}

# CONNECT line written to the standard input of a sqlplus session.
function Get-ConnectLine {
    param($Login)
    $line = 'CONNECT ' + $Login.User + '/"' + (ConvertFrom-Secure $Login.Secret) + '"'
    if (-not [string]::IsNullOrWhiteSpace($Login.Tns)) { $line = $line + '@' + $Login.Tns }
    if ($Login.Sysdba) { $line = $line + ' AS SYSDBA' }
    return $line
}

function Start-SqlProcess {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:SqlPlus
    $info.Arguments = '-S -L /nolog'
    $info.UseShellExecute = $false
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $info.WorkingDirectory = $script:RepoDir
    # Passwords reach sqlplus only on standard input: the ones the operator
    # set in the environment for --non-interactive are not passed on.
    foreach ($name in @('EPF_PASSWORD', 'EPF_SYS_PASSWORD')) { $info.EnvironmentVariables.Remove($name) }
    $process = [System.Diagnostics.Process]::Start($info)
    $script:Children.Add($process)
    return $process
}

# Ends every sqlplus session this wrapper started that is still running, so
# none outlives the wrapper (on any exit path).
function Stop-Children {
    foreach ($child in $script:Children) {
        try {
            if (-not $child.HasExited) {
                $child.Kill()
                Write-Out (' Ended a sqlplus session left running (PID ' + $child.Id + ').') 'Yellow'
            }
        } catch {
            Write-Out (' A sqlplus session could not be ended (PID ' + $child.Id + '): ' + $_.Exception.Message) 'Yellow'
        }
    }
}

function Get-ScriptLine {
    param([string]$Script, [string[]]$Arguments = @())
    $line = '@"' + $Script + '"'
    foreach ($a in $Arguments) { $line = $line + ' ' + $a }
    return $line
}

function Test-SessionFailure {
    param([string]$Text)
    return ($Text -match 'SP2-0640|SP2-0310|ORA-01017|ORA-12154|ORA-12514|ORA-12541|ORA-12170|ORA-28000|ORA-01045|ORA-01034')
}

# A sqlplus session for $Login. Only the CONNECT line goes first, with a
# marker after it: sqlplus prints the marker once the CONNECT has finished,
# whether it succeeded or not. A session whose marker does not come within
# $script:ConnectTimeoutS seconds hangs in the connection; nothing else has
# been sent to it, so it is ended and a new one started, 3 attempts in all.
# With a run state the live view goes on meanwhile. Returns Process, Errors
# (standard error, being read), Lines (printed before the marker, such as a
# connection error), Ready and TimedOut.
function Start-Session {
    param($Login, $State = $null)
    $lines = New-Object 'System.Collections.Generic.List[string]'
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $process = Start-SqlProcess
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine((Get-ConnectLine $Login))
        $process.StandardInput.WriteLine('PROMPT ' + $script:ReadyMarker)
        $process.StandardInput.Flush()
        $lines.Clear()
        $deadline = (Get-Date).AddSeconds($script:ConnectTimeoutS)
        $pending = $null
        while ($true) {
            if ($null -eq $pending) { $pending = $process.StandardOutput.ReadLineAsync() }
            if ($pending.Wait(1000)) {
                $line = $pending.Result
                $pending = $null
                if ($null -eq $line) {
                    # sqlplus ended before the marker: its output says why.
                    return [pscustomobject]@{ Process = $process; Errors = $errors; Lines = $lines; Ready = $false;
                                              TimedOut = $false }
                }
                if ($line -eq $script:ReadyMarker) {
                    return [pscustomobject]@{ Process = $process; Errors = $errors; Lines = $lines; Ready = $true;
                                              TimedOut = $false }
                }
                $lines.Add($line)
                continue
            }
            if ($null -ne $State) {
                Test-StopKey $State
                Update-LiveView $State
            }
            if ((Get-Date) -ge $deadline) { break }
        }
        try {
            if (-not $process.HasExited) { $process.Kill() }
        } catch {
            Write-Out (' ' + $_.Exception.Message) 'Yellow'
        }
        Write-Out (' No answer from ' + $Login.Tns + ' as ' + $Login.User + ' within ' + $script:ConnectTimeoutS +
                   ' s (connection attempt ' + $attempt + ' of 3).') 'Yellow'
    }
    return [pscustomobject]@{ Process = $null; Errors = $null; Lines = $lines; Ready = $false; TimedOut = $true }
}

# Connection test (the only statement the wrapper sends itself): container
# name and, for EPFPG, the installed tool version. TimedOut: the database did
# not answer the connection (Start-Session) or the query.
function Test-DbConnection {
    param($Login, [switch]$WithVersion)
    $session = Start-Session $Login
    if (-not $session.Ready) {
        $text = ($session.Lines -join "`r`n")
        if ($null -ne $session.Process) {
            $session.Process.WaitForExit()
            $text = $text + "`r`n" + $session.Errors.Result
        }
        return [pscustomobject]@{ Ok = $false; Container = ''; Version = ''; Output = $text; TimedOut = $session.TimedOut }
    }
    $process = $session.Process
    $in = $process.StandardInput
    $in.WriteLine('SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF')
    if ($WithVersion) {
        $in.WriteLine("SELECT 'EPF_CONNECTED|' || SYS_CONTEXT('USERENV', 'CON_NAME') || '|' || value || '|' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') FROM epfpg.epf_setting WHERE name = 'tool_version';")
    } else {
        $in.WriteLine("SELECT 'EPF_CONNECTED|' || SYS_CONTEXT('USERENV', 'CON_NAME') || '||' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') FROM dual;")
    }
    $in.WriteLine('EXIT')
    $in.Close()
    $out = $process.StandardOutput.ReadToEndAsync()
    if (-not $process.WaitForExit($script:ConnectTimeoutS * 1000)) {
        try { $process.Kill() } catch { Write-Out (' ' + $_.Exception.Message) 'Yellow' }
        Write-Out (' No answer to the connection test from ' + $Login.Tns + ' within ' + $script:ConnectTimeoutS + ' s.') 'Yellow'
        return [pscustomobject]@{ Ok = $false; Container = ''; Version = ''; Output = ''; TimedOut = $true }
    }
    $process.WaitForExit()
    $text = ($session.Lines -join "`r`n") + "`r`n" + $out.Result + $session.Errors.Result
    $received = Get-Date
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^EPF_CONNECTED\|([^|]*)\|([^|]*)\|(.*)$') {
            $container = $Matches[1]
            $version = $Matches[2].Trim()
            $dbTime = [datetime]::ParseExact($Matches[3].Trim(), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            # Database clock minus this machine's clock, to the minute.
            $script:ClockOffset = [TimeSpan]::FromMinutes([Math]::Round(($dbTime - $received).TotalMinutes))
            return [pscustomobject]@{ Ok = $true; Container = $container; Version = $version; Output = $text; TimedOut = $false }
        }
    }
    return [pscustomobject]@{ Ok = $false; Container = ''; Version = ''; Output = $text; TimedOut = $false }
}

# "+06:00" for a clock offset; empty when the clocks agree.
function Format-Offset {
    param([TimeSpan]$Offset)
    if ([Math]::Abs($Offset.TotalMinutes) -lt 1) { return '' }
    $sign = '+'
    if ($Offset.TotalMinutes -lt 0) { $sign = '-' }
    $abs = $Offset.Duration()
    return ($sign + ('{0:00}:{1:00}' -f [Math]::Floor($abs.TotalHours), $abs.Minutes))
}

# Runs one entry script in its own sqlplus session and waits for it. The
# script is sent once the session has connected (Start-Session). With a run
# state, the live view is refreshed every 2 seconds meanwhile and Ctrl+C
# requests a graceful stop. The raw output goes to $LogName in the run folder.
function Invoke-SqlScript {
    param($Login, [string]$Script, [string[]]$Arguments = @(), $State = $null, [string]$LogName = '')
    $session = Start-Session $Login $State
    $text = ($session.Lines -join "`r`n")
    if ($session.Ready) {
        $process = $session.Process
        $in = $process.StandardInput
        $in.WriteLine((Get-ScriptLine $Script $Arguments))
        $in.WriteLine('EXIT 9')
        $in.Close()
        $out = $process.StandardOutput.ReadToEndAsync()
        while (-not $process.WaitForExit(2000)) {
            if ($null -ne $State) {
                Test-StopKey $State
                Update-LiveView $State
            }
        }
        $process.WaitForExit()
        if ($text -ne '') { $text = $text + "`r`n" }
        $text = $text + $out.Result + $session.Errors.Result
        $code = $process.ExitCode
        if ($code -eq 0 -and (Test-SessionFailure $text)) { $code = $script:ExitFail }
    } else {
        if ($session.TimedOut) {
            $text = 'The database did not answer the connection as ' + $Login.User + ' (3 attempts of ' +
                    $script:ConnectTimeoutS + ' s); ' + (Split-Path -Leaf $Script) + ' did not run.'
        } else {
            $session.Process.WaitForExit()
            $text = $text + "`r`n" + $session.Errors.Result
        }
        $code = $script:ExitFail
    }
    if ($LogName -ne '' -and $null -ne $State -and $null -ne $State.Folder) {
        [System.IO.File]::WriteAllText((Join-Path $State.Folder $LogName), $text, [System.Text.Encoding]::ASCII)
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

# The monitor: one sqlplus session kept open for the whole run. It creates
# (or attaches) the run and so holds the run lock, polls the live view and
# ends the run. Throws a TimeoutException when the session does not connect
# (Start-Session).
function Open-Monitor {
    param($Login)
    $session = Start-Session $Login
    if (-not $session.Ready) {
        $message = 'The monitor session did not connect'
        if ($session.TimedOut) {
            $message = $message + ': no answer from the database (3 attempts of ' + $script:ConnectTimeoutS + ' s).'
        } else {
            $message = $message + ': ' + (@($session.Lines) -join ' | ')
        }
        throw (New-Object System.TimeoutException($message))
    }
    return [pscustomobject]@{ Process = $session.Process; Pending = $null; Errors = $session.Errors }
}

# Sends one command to the monitor and returns the lines it printed up to an
# end marker. Throws a TimeoutException when no answer arrives in time or the
# session has ended.
function Invoke-MonitorCommand {
    param($Monitor, [string]$Command, [int]$TimeoutMs = 60000)
    if ($Monitor.Process.HasExited) { throw (New-Object System.TimeoutException('The monitor session has ended.')) }
    $marker = 'EPF_END_' + [Guid]::NewGuid().ToString('N')
    $in = $Monitor.Process.StandardInput
    $in.WriteLine($Command)
    $in.WriteLine('PROMPT ' + $marker)
    $in.Flush()
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    while ($true) {
        if ($null -eq $Monitor.Pending) { $Monitor.Pending = $Monitor.Process.StandardOutput.ReadLineAsync() }
        $left = [int]($deadline - (Get-Date)).TotalMilliseconds
        if ($left -le 0 -or -not $Monitor.Pending.Wait($left)) {
            $message = 'The monitor session did not answer within ' + [int]($TimeoutMs / 1000) + ' s.'
            if ($lines.Count -gt 0) {
                $message = $message + ' It printed: ' + (@($lines | Select-Object -Last 10) -join ' | ')
            }
            throw (New-Object System.TimeoutException($message))
        }
        $line = $Monitor.Pending.Result
        $Monitor.Pending = $null
        if ($null -eq $line) { throw (New-Object System.TimeoutException('The monitor session has ended.')) }
        if ($line -eq $marker) { break }
        $lines.Add($line)
    }
    return ,$lines.ToArray()
}

function Close-Monitor {
    param($Monitor)
    if ($null -eq $Monitor) { return }
    try {
        if (-not $Monitor.Process.HasExited) {
            $Monitor.Process.StandardInput.WriteLine('EXIT')
            $Monitor.Process.StandardInput.Close()
            if (-not $Monitor.Process.WaitForExit(10000)) { $Monitor.Process.Kill() }
        }
    } catch {
        Write-Out (' The monitor session could not be closed cleanly: ' + $_.Exception.Message) 'Yellow'
    }
}

# Replaces a monitor session that stopped answering and attaches the run
# again (the run lock is released when the old session ends).
function Reset-Monitor {
    param($State)
    Write-Out ' ..       restarting the monitor session' 'Yellow'
    try {
        if (-not $State.Monitor.Process.HasExited) { $State.Monitor.Process.Kill() }
    } catch {
        Write-Out (' ..       ' + $_.Exception.Message) 'Yellow'
    }
    $attach = Get-ScriptLine (Join-Path $script:RunSqlDir 'attach.sql') @([string]$State.RunId)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $State.Monitor = $null
        try {
            $State.Monitor = Open-Monitor $State.Cred
            $lines = Invoke-MonitorCommand $State.Monitor $attach 60000
            if (($lines -join "`n") -match 'EPF_ATTACHED=') { return }
            Write-Out (' ..       attach: ' + (@($lines | Where-Object { $_ -match 'ORA-' }) -join ' ')) 'Yellow'
        } catch {
            Write-Out (' ..       attach: ' + $_.Exception.Message) 'Yellow'
        }
        Close-Monitor $State.Monitor
        Start-Sleep -Seconds 5
    }
    throw (New-Object System.TimeoutException('The run could not be attached again after the monitor session was restarted.'))
}

# ----------------------------------------------------------------------------
# Live view
# ----------------------------------------------------------------------------

function Format-Seconds {
    param([string]$Value)
    $seconds = 0
    if (-not [int]::TryParse($Value, [ref]$seconds)) { return $Value }
    $span = [TimeSpan]::FromSeconds($seconds)
    return ('{0:00}:{1:00}:{2:00}' -f [Math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds)
}

# Detail events that go to console.log only when they are INFO: the report
# carries their substance.
$script:DetailEvents = @('IDX_MISSING', 'REDO_ESTIMATE', 'UNDO_ESTIMATE', 'TABLE_ELIGIBLE', 'TEMP_INDEX_CREATED',
                         'TEMP_INDEX_DROPPED', 'PIN', 'UNIT_MOVED', 'INDEX_REBUILT', 'FILE_GROWTH_OFF', 'FILE_KEPT')

# EV|event_id|HH24:MI:SS|severity|phase|event_code|owner.object|message
function Show-Event {
    param([string[]]$Field)
    $tag = '[ .. ]'
    $color = 'Cyan'
    switch ($Field[3]) {
        'OK'    { $tag = '[ OK ]'; $color = 'Green' }
        'INFO'  { $tag = '[INFO]'; $color = '' }
        'WARN'  { $tag = '[WARN]'; $color = 'Yellow' }
        'ERROR' { $tag = '[FAIL]'; $color = 'Red' }
    }
    $text = ' {0} {1} {2,-20} {3}' -f $Field[2], $tag, $Field[5], $Field[7]
    if ($Field[6] -ne '' -and $Field[7].IndexOf($Field[6]) -lt 0) { $text = $text + '  [' + $Field[6] + ']' }
    if ($Field[3] -eq 'INFO' -and $script:DetailEvents -contains $Field[5]) {
        Write-Log $text
        return
    }
    Write-Out $text $color
}

# HB|sid|status|action|event|seconds|wait_class|blocking_sid|blocker|sql_id|pct|left|operation|suspended
function Show-Heartbeat {
    param([string[]]$Field)
    $text = ' ..       ' + $Field[3] + ' . ' + $Field[4] + ' ' + $Field[5] + 's'
    if ($Field[7] -ne '') { $text = $text + ' . blocked by session ' + $Field[7] + ' (' + $Field[8] + ')' }
    if ($Field[10] -ne '') { $text = $text + ' . ' + $Field[12] + ' ' + $Field[10] + '% (' + (Format-Seconds $Field[11]) + ' left)' }
    if ($Field[13] -ne '') {
        Write-Out ($text + ' . SUSPENDED: ' + $Field[13]) 'Yellow'
    } else {
        Write-Out $text 'DarkGray' -NoLog
    }
}

# One poll: prints the new events, and the heartbeat of the worker session when
# no event arrived for 15 seconds. A poll that fails or does not answer within
# 60 seconds restarts the monitor session; when that fails too, the live view
# stops and the worker is still waited for.
function Update-LiveView {
    param($State)
    if (-not $State.Live) { return }
    $command = Get-ScriptLine (Join-Path $script:RunSqlDir 'poll.sql') @([string]$State.RunId, [string]$State.LastEvent)
    try {
        $lines = Invoke-MonitorCommand $State.Monitor $command 60000
    } catch {
        Write-Out (' ..       monitor: ' + $_.Exception.Message) 'Yellow'
        try {
            Reset-Monitor $State
        } catch {
            $State.Live = $false
            Write-Out (' ' + $_.Exception.Message + ' The live view stops; the worker session continues.') 'Red'
        }
        return
    }
    $beats = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in $lines) {
        if ($line.StartsWith('EV|')) {
            $field = $line.Split([char[]]@('|'), 8)
            if ($field.Count -lt 8) { continue }
            $State.LastEvent = [long]$field[1]
            $State.LastOutput = Get-Date
            Show-Event $field
        } elseif ($line.StartsWith('HB|')) {
            $field = $line.Split([char[]]@('|'), 14)
            if ($field.Count -eq 14) { $beats.Add($field) }
        } elseif ($line.StartsWith('RUN|')) {
            $State.RunStatus = $line.Split('|')[1]
        } elseif ($line -match 'ORA-\d{5}|SP2-\d{4}') {
            Write-Out (' ..       monitor: ' + $line) 'Yellow'
        }
    }
    if ($beats.Count -gt 0 -and ((Get-Date) - $State.LastOutput).TotalSeconds -ge 15) {
        foreach ($beat in $beats) { Show-Heartbeat $beat }
        $State.LastOutput = Get-Date
    }
}

# Ctrl+C while a run is shown: requests a graceful stop (stop.sql in its own
# session); the purge stops after its current batch.
function Test-StopKey {
    param($State)
    if (-not $State.StopKeys) { return }
    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -ne [ConsoleKey]::C -or -not ($key.Modifiers -band [ConsoleModifiers]::Control)) { continue }
        if ($State.StopRequested) {
            Write-Out ' Stop already requested; the run stops after the current batch or table.' 'Yellow'
        } else {
            $State.StopRequested = $true
            Write-Out ' Ctrl+C: requesting a graceful stop' 'Yellow'
            $result = Invoke-SqlScript $State.Cred (Join-Path $script:RunSqlDir 'stop.sql') @([string]$State.RunId)
            Show-Lines $result.Output -Indent
        }
    }
}

# Ctrl+C becomes a key the live view reads, so it cannot end the wrapper while
# a worker session is running (also with --non-interactive). Only when the
# console input is a keyboard.
function Enable-StopKey {
    if ([Console]::IsInputRedirected) { return $false }
    [Console]::TreatControlCAsInput = $true
    return $true
}

function Disable-StopKey {
    param($State)
    if ($State.StopKeys) { [Console]::TreatControlCAsInput = $false }
}

# ----------------------------------------------------------------------------
# Runs
# ----------------------------------------------------------------------------

function Get-RunLabel {
    param([long]$RunId)
    return 'R-' + $RunId.ToString('000000')
}

function Get-YN {
    param([bool]$Value)
    if ($Value) { return 'Y' }
    return 'N'
}

function New-RunFolder {
    param([long]$RunId)
    $base = Get-Option 'log-dir' 'LOG_DIR' (Join-Path $script:RepoDir 'logs')
    $folder = Join-Path $base ((Get-Date -Format 'yyyy-MM-dd_HHmmss') + '_' + (Get-RunLabel $RunId))
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $script:LogFile = Join-Path $folder 'console.log'
    foreach ($line in $script:Buffered) {
        [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", [System.Text.Encoding]::ASCII)
    }
    $script:Buffered.Clear()
    return $folder
}

# Creates the run in a new monitor session, which attaches it and so holds
# its lock (begin_run.sql with $Begin), and the run folder. Ends the tool
# when no run could be created.
function Open-Run {
    param($State, [string[]]$Begin)
    try {
        $State.Monitor = Open-Monitor $State.Cred
    } catch {
        Exit-Tool $script:ExitFail ($_.Exception.Message + ' No run was created.')
    }
    try {
        $lines = Invoke-MonitorCommand $State.Monitor (Get-ScriptLine (Join-Path $script:RunSqlDir 'begin_run.sql') $Begin) 120000
    } catch {
        # No run was created (or none is known): end the session, then show
        # the tool's sessions and runs as the database sees them.
        Write-Out (' ' + $_.Exception.Message) 'Red'
        try { $State.Monitor.Process.Kill() } catch { Write-Out (' ' + $_.Exception.Message) 'Yellow' }
        Write-Out ' State of the tool in the database (status):' 'Yellow'
        $diagnosis = Invoke-SqlScript $State.Cred (Join-Path $script:RunSqlDir 'status.sql') @()
        Show-Lines $diagnosis.Output -Indent
        Exit-Tool $script:ExitFail 'The run could not be created: the monitor session did not answer.'
    }
    foreach ($line in $lines) {
        if ($line -match '^EPF_RUN_ID=(\d+)$') { $State.RunId = [long]$Matches[1] }
    }
    if ($State.RunId -eq 0) {
        Show-Lines ($lines -join "`n") -Indent
        Close-Monitor $State.Monitor
        # The tool's own refusals (ORA-20xxx: parameters, another active run)
        # are usage errors; anything else is a failure.
        $code = $script:ExitFail
        if (($lines -join "`n") -match 'ORA-20\d{3}') { $code = $script:ExitUsage }
        Exit-Tool $code 'The run could not be created (see the messages above).'
    }
    $State.Folder = New-RunFolder $State.RunId
}

# Ends the run in the monitor session with $Status (finish.sql: checks and
# verdict) and closes the monitor; a monitor that stopped answering is
# replaced first. Returns the exit code of the verdict, $null when the run
# could not be ended.
function Close-Run {
    param($State, [string]$Status)
    $closeCode = $null
    try {
        if (-not $State.Live) {
            Reset-Monitor $State
            $State.Live = $true
        }
        Update-LiveView $State
        $finish = Get-ScriptLine (Join-Path $script:RunSqlDir 'finish.sql') @([string]$State.RunId, $Status)
        $lines = Invoke-MonitorCommand $State.Monitor $finish 600000
        foreach ($line in $lines) {
            if ($line -match '^EPF_EXIT=(\d+)$') { $closeCode = [int]$Matches[1] }
        }
        if ($null -eq $closeCode) { Show-Lines ($lines -join "`n") -Indent }
        Update-LiveView $State
    } catch {
        Write-Out (' The run could not be ended: ' + $_.Exception.Message) 'Red'
    }
    Close-Monitor $State.Monitor
    return $closeCode
}

# Runs PREFLIGHT or PURGE as one run: the monitor creates the run and holds its
# lock; worker sessions run the steps while the monitor shows them live; the
# monitor ends the run with the report's verdict; the report goes to the
# console and to the run folder. SYS steps (redo logs, undo tuning) run in
# their own sessions; undo tuning is restored on every exit path.
function Invoke-ToolRun {
    param($Ctx, [string]$Action, [switch]$FromWizard)
    $state = [pscustomobject]@{
        Cred = $Ctx.Cred; Monitor = $null; RunId = [long]0; LastEvent = [long]0; LastOutput = (Get-Date);
        RunStatus = ''; Folder = $null; Live = $true; StopKeys = $false; StopRequested = $false; Started = (Get-Date);
        Stopped = $false
    }
    $dry = 'N'
    if ($Ctx.DryRun) { $dry = 'Y' }
    $compact = 'N'
    if ($Ctx.Compact -and $Action -eq 'PURGE') { $compact = 'Y' }
    $batch = 'default'
    $batchArg = '-'
    if ($Ctx.BatchSize -ne '') {
        $batch = $Ctx.BatchSize
        $batchArg = $Ctx.BatchSize
    }

    # Undo tuning and redo log sizing are planned for the run (the preflight
    # checks the requirements with them); only a purge that deletes applies
    # them.
    $undo = Get-YN $Ctx.UndoTuning
    $redo = Get-YN $Ctx.RedoLogs
    $retentionArg = $Ctx.Retention
    $cutoffArg = '-'
    if ($Ctx.Cutoff -ne '') {
        $retentionArg = '-'
        $cutoffArg = $Ctx.Cutoff
    }
    $backupArg = '-'
    if ($Ctx.Backup -ne '') { $backupArg = $Ctx.Backup }
    $confirmArg = '-'
    if ($Ctx.Confirm -ne '') { $confirmArg = $Ctx.Confirm }
    $maxRedoArg = '-'
    if ($Ctx.MaxRedo -ne '') { $maxRedoArg = $Ctx.MaxRedo }
    # A purge carries out (a dry run rehearses) the plan step; a preflight
    # plans, or checks the open plan again.
    $planIdArg = '-'
    $planStepArg = '-'
    if ($Action -eq 'PURGE' -and $Ctx.PlanId -ne '') {
        $planIdArg = $Ctx.PlanId
        $planStepArg = $Ctx.PlanStep
    }

    $begin = @($Action, $retentionArg, $Ctx.Depth, $Ctx.Mode, $batchArg, $dry, 'N', $compact, $undo, $backupArg,
               $cutoffArg, $confirmArg, $redo, $maxRedoArg, (Get-YN $Ctx.NewPlan), $planIdArg, $planStepArg)
    Open-Run $state $begin
    $label = Get-RunLabel $state.RunId

    Write-Out ''
    Write-Out (' EPF Data Purge'.PadRight($script:Width - $label.Length - 4) + 'run ' + $label) 'White'
    Write-Out (' ' + ('-' * ($script:Width - 1)))
    Write-Out (' Database   ' + $script:Database.Container + ', tool version ' + $script:Database.Version +
               ', ' + $Ctx.Cred.Tns)
    $offset = Format-Offset $script:ClockOffset
    if ($offset -ne '') {
        Write-Out (' Times      database clock (' + $offset + ' from this machine)')
    }
    Write-Out (' Run folder ' + $state.Folder)
    $period = 'retention ' + $Ctx.Retention + ' days'
    if ($Ctx.Cutoff -ne '') { $period = 'cutoff ' + $Ctx.Cutoff }
    if ($Action -eq 'PURGE') {
        Write-Out (' Purge      mode ' + $Ctx.Mode + ', depth ' + $Ctx.Depth + ', ' + $period +
                   ', batch ' + $batch + ', dry run ' + $dry + ', compact ' + $compact)
    } else {
        Write-Out (' Preflight  mode ' + $Ctx.Mode + ', depth ' + $Ctx.Depth + ', ' + $period + ', batch ' + $batch)
    }
    $choices = Format-Choices '' $Ctx.UndoTuning $Ctx.RedoLogs $Ctx.Backup $Ctx.Confirm
    if ($choices -ne 'none') { Write-Out (' Choices    ' + $choices) }
    if ($Action -eq 'PURGE' -and $Ctx.PlanId -ne '') {
        $what = 'step '
        if ($Ctx.DryRun) { $what = 'rehearsal of step ' }
        Write-Out (' Plan       ' + $Ctx.PlanLabel + ', ' + $what + $Ctx.PlanStep + ' of ' + $Ctx.Plan.Steps)
    } elseif ($Action -eq 'PREFLIGHT' -and $Ctx.MaxRedo -ne '') {
        Write-Out (' Plan       runs of at most ' + (Format-Bytes ([double]$Ctx.MaxRedo)) + ' of redo')
    }

    $status = 'FAILED'
    $undoApplied = $false
    $closeCode = $null
    $state.StopKeys = Enable-StopKey
    if ($state.StopKeys) { Write-Out ' Ctrl+C requests a graceful stop.' -NoLog }
    try {
        if ($Action -eq 'PURGE' -and -not $Ctx.DryRun -and $Ctx.RedoLogs) {
            Write-Section 'REDO LOGS (SYS)'
            $result = Invoke-SqlScript $Ctx.SysCred (Join-Path $script:RunSqlDir 'redo_logs.sql') @('-', '-') $state 'sqlplus_redo_logs.log'
            Show-Lines $result.Output -Indent
            if ($result.ExitCode -ne 0) { throw 'Redo log sizing failed; the purge was not started.' }
        }

        # Every run checks the requirements with its own choices. After the
        # wizard's preflight run, its root counts are reused (no second scan).
        $preflightOk = $true
        $reuse = '-'
        $title = 'PREFLIGHT'
        if ($Ctx.PreflightRun -ne '') {
            $reuse = $Ctx.PreflightRun -replace '^R-0*', ''
            $title = 'PREFLIGHT  with the choices above; root counts of ' + $Ctx.PreflightRun
        }
        Write-Section $title
        $result = Invoke-SqlScript $Ctx.Cred (Join-Path $script:RunSqlDir 'preflight.sql') @([string]$state.RunId, $reuse) $state 'sqlplus_preflight.log'
        Update-LiveView $state
        if ($result.ExitCode -eq 0) {
            $status = 'SUCCESS'
        } elseif ($result.ExitCode -eq 2) {
            $status = 'WARNING'
        } else {
            $preflightOk = $false
            $status = 'FAILED'
            if (Test-SessionFailure $result.Output) { Show-Lines $result.Output -Indent }
            Write-Out ' The preflight found errors; nothing was changed.' 'Red'
        }

        # A preflight with prompts: the operator's choices for each
        # requirement not met, saved with the run (Ctrl+C is a normal key
        # meanwhile). Stopped at a question, the preflight did not end: it
        # ends STOPPED, which closes the plan it made (no plan to follow).
        if ($Action -eq 'PREFLIGHT' -and $preflightOk -and $script:Interactive -and -not $state.StopRequested) {
            Disable-StopKey $state
            try {
                $state.Stopped = -not (Invoke-Choices $Ctx $state)
            } finally {
                $state.StopKeys = Enable-StopKey
            }
            if ($state.Stopped) { $status = 'STOPPED' }
        }

        if ($Action -eq 'PURGE' -and $preflightOk) {
            # A purge that deletes starts only when every blocking requirement
            # is met; otherwise the purge step records the refusal
            # (REQUIREMENTS_NOT_MET) and changes nothing.
            $ready = $true
            if (-not $Ctx.DryRun) {
                $unmet = Get-Unmet (Read-Advice $Ctx.Cred $state.RunId)
                if ($unmet.Count -gt 0) {
                    $ready = $false
                    Write-Out (' Blocking requirements not met: ' + ($unmet -join ', ') + '. The purge does not start;') 'Red'
                    Write-Out ' REQUIREMENTS in the report lists the ways to meet them.' 'Red'
                }
            }
            if ($state.StopRequested) {
                $status = 'STOPPED'
            } elseif (-not $ready) {
                Write-Section 'PURGE  not started (requirements)'
                $result = Invoke-SqlScript $Ctx.Cred (Join-Path $script:RunSqlDir 'purge.sql') @([string]$state.RunId, '-', '-', '-', '-', '-', '-') $state 'sqlplus_purge.log'
                Update-LiveView $state
                if ($result.Output -match 'ORA-\d{5}|SP2-\d{4}') { Show-Lines $result.Output -Indent }
                $status = 'FAILED'
            } else {
                if ($Ctx.UndoTuning -and -not $Ctx.DryRun) {
                    Write-Section 'UNDO TUNING (SYS)'
                    $undoApplied = $true
                    # The growth limit is sized from this run's batch size and the
                    # undo per root estimated by its own preflight.
                    $applyArgs = @('APPLY', [string]$state.RunId, [string]$state.RunId)
                    $result = Invoke-SqlScript $Ctx.SysCred (Join-Path $script:RunSqlDir 'undo.sql') $applyArgs $state 'sqlplus_undo_apply.log'
                    Show-Lines $result.Output -Indent
                    if ($result.ExitCode -ne 0) { throw 'Undo tuning could not be applied; the purge was not started.' }
                }
                Write-Section ('PURGE  depth=' + $Ctx.Depth + '  mode=' + $Ctx.Mode + '  batch=' + $batch)
                $result = Invoke-SqlScript $Ctx.Cred (Join-Path $script:RunSqlDir 'purge.sql') @([string]$state.RunId, '-', '-', '-', '-', '-', '-') $state 'sqlplus_purge.log'
                Update-LiveView $state
                switch ($result.ExitCode) {
                    0       { $status = 'SUCCESS' }
                    2       { $status = 'WARNING' }
                    3       { $status = 'STOPPED' }
                    default {
                        $status = 'FAILED'
                        if ($result.Output -match 'ORA-\d{5}|SP2-\d{4}') { Show-Lines $result.Output -Indent }
                    }
                }
            }
        }
    } catch {
        Write-Out (' ' + $_.Exception.Message) 'Red'
        $status = 'FAILED'
    } finally {
        Disable-StopKey $state
        if ($undoApplied) {
            Write-Section 'UNDO TUNING RESTORE (SYS)'
            $restore = Invoke-SqlScript $Ctx.SysCred (Join-Path $script:RunSqlDir 'undo.sql') @('RESTORE')
            [System.IO.File]::WriteAllText((Join-Path $state.Folder 'sqlplus_undo_restore.log'), $restore.Output, [System.Text.Encoding]::ASCII)
            Show-Lines $restore.Output -Indent
            if ($restore.ExitCode -ne 0) {
                Write-Out ' Undo tuning was NOT restored: run src\sql\run\undo.sql RESTORE as SYS.' 'Red'
            }
        }
        $closeCode = Close-Run $state $status
    }

    Write-Section 'REPORT'
    $report = Invoke-SqlScript $Ctx.Cred (Join-Path $script:RunSqlDir 'report.sql') @([string]$state.RunId)
    [System.IO.File]::WriteAllText((Join-Path $state.Folder 'report.txt'), $report.Output, [System.Text.Encoding]::ASCII)
    Show-Lines $report.Output -HideMachine
    # The requirements and the plan of the run, each in its own file.
    foreach ($part in @(@('REQUIREMENTS', 'requirements.txt'), @('PLAN', 'plan.txt'))) {
        $text = Get-ReportSection $report.Output $part[0]
        if ($text -ne '') {
            [System.IO.File]::WriteAllText((Join-Path $state.Folder $part[1]), $text, [System.Text.Encoding]::ASCII)
        }
    }
    $planAfter = Read-PlanLines $report.Output

    $exitCode = $closeCode
    if ($null -eq $exitCode) { $exitCode = $script:ExitFail }
    if ($status -eq 'STOPPED') { $exitCode = $script:ExitAborted }
    $verdict = Write-Manifest $state $Ctx $Action $status $exitCode $report.Output
    $total = Format-Seconds ([string][int]((Get-Date) - $state.Started).TotalSeconds)
    $color = 'Green'
    if ($exitCode -eq $script:ExitWarn -or $exitCode -eq $script:ExitAborted) { $color = 'Yellow' }
    if ($exitCode -eq $script:ExitFail) { $color = 'Red' }
    $result = (' RESULT  ' + $verdict + '  (' + $status + ')').PadRight($script:Width - 25)
    Write-Out ''
    Write-Out ($result + 'total ' + $total + ' . exit ' + $exitCode) $color
    Write-Out (' Report  ' + (Join-Path $state.Folder 'report.txt'))
    if ($Action -eq 'PREFLIGHT' -and -not $FromWizard -and -not $state.Stopped -and $status -ne 'FAILED') {
        Show-PreflightNext $Ctx $state $report.Output
    }
    if ($Action -eq 'PURGE' -and $Ctx.PlanId -ne '' -and -not $Ctx.DryRun -and $null -ne $planAfter) {
        if ($planAfter.Status -eq 'DONE') {
            Write-Out (' Plan    ' + $planAfter.Label + ' is done: every step ran.') 'Green'
        } elseif ($planAfter.NextStep -ne '-') {
            Write-Out (' Plan    ' + $planAfter.Label + ': ' + $planAfter.Done + ' of ' + $planAfter.Steps +
                       ' steps done. Next: epf_purge.bat purge (step ' + $planAfter.NextStep + ', rows before ' +
                       $planAfter.NextCutoff + ')')
        }
    }
    return [pscustomobject]@{ RunId = $state.RunId; ExitCode = $exitCode; Status = $status; Folder = $state.Folder;
                              Stopped = $state.Stopped }
}

# After a preflight: whether a purge can start, and how it follows the plan
# and the choices saved with this preflight.
function Show-PreflightNext {
    param($Ctx, $State, [string]$Report)
    $unmet = @()
    foreach ($line in ($Report -split "`r?`n")) {
        if ($line -match '^EPF_REQ\|[^|]*\|([^|]*)\|NOT_MET\|Y\|') { $unmet += $Matches[1] }
    }
    $scope = '--mode ' + $Ctx.Mode + ' --depth ' + $Ctx.Depth
    if ($Ctx.Cutoff -ne '') { $scope = $scope + ' --cutoff ' + $Ctx.Cutoff } else { $scope = $scope + ' --retention ' + $Ctx.Retention }
    $plan = Read-PlanLines $Report
    Write-Out (' Choices ' + (Format-Choices $Ctx.BatchSize $Ctx.UndoTuning $Ctx.RedoLogs $Ctx.Backup $Ctx.Confirm) +
               ' (saved with ' + (Get-RunLabel $State.RunId) + ')')
    if ($Report -match '(?m)^EPF_PLAN_KEPT\|(P-\d+)') {
        Write-Out (' Next    plan ' + $Matches[1] + ' of another scope is in progress: epf_purge.bat purge continues it;' +
                   ' preflight --new starts over with these options') 'Yellow'
    } elseif ($unmet.Count -gt 0) {
        Write-Out (' Next    not ready (' + ($unmet -join ', ') + '): meet them or choose how, then run the preflight again') 'Yellow'
    } elseif ($null -ne $plan -and $plan.NextStep -ne '-' -and $plan.Steps -gt 1) {
        Write-Out (' Next    epf_purge.bat purge carries out step ' + $plan.NextStep + ' of ' + $plan.Steps + ' of plan ' +
                   $plan.Label + ' (rows before ' + $plan.NextCutoff + '); add --dry-run to rehearse it') 'Green'
    } elseif ($null -ne $plan) {
        Write-Out (' Next    epf_purge.bat purge follows these choices (plan ' + $plan.Label + '); add --dry-run to simulate it first') 'Green'
    } else {
        Write-Out (' Next    epf_purge.bat purge ' + $scope + ' follows these choices; add --dry-run to simulate it first') 'Green'
    }
}

# manifest.txt: key=value summary of the run for review. Returns the verdict.
function Write-Manifest {
    param($State, $Ctx, [string]$Action, [string]$Status, [int]$ExitCode, [string]$Report)
    $verdict = '-'
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $lines.Add('run=' + (Get-RunLabel $State.RunId))
    $lines.Add('action=' + $Action)
    $lines.Add('written_at=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines.Add('database=' + $script:Database.Container)
    $lines.Add('tool_version=' + $script:Database.Version)
    $lines.Add('tns=' + $Ctx.Cred.Tns)
    if ($Action -eq 'RECLAIM') {
        # reclaim_mode=ASSESS|COMPACT|RESTORE; tablespaces empty: every candidate
        $lines.Add('reclaim_mode=' + $Ctx.Mode)
        $lines.Add('dry_run=' + (Get-YN ($Ctx.Mode -eq 'ASSESS')))
        $lines.Add('tablespaces=' + $Ctx.Tablespaces)
        $lines.Add('confirmed=' + $Ctx.Confirm)
        if ($Ctx.AssessRun -ne '') { $lines.Add('assessment_run=' + $Ctx.AssessRun) }
    } else {
        $lines.Add('retention_days=' + $Ctx.Retention)
        if ($Ctx.Cutoff -ne '') { $lines.Add('cutoff=' + $Ctx.Cutoff) }
        $lines.Add('depth=' + $Ctx.Depth)
        $lines.Add('mode=' + $Ctx.Mode)
        $lines.Add('batch_size=' + $Ctx.BatchSize)
        $lines.Add('dry_run=' + (Get-YN $Ctx.DryRun))
        $lines.Add('compact=' + (Get-YN $Ctx.Compact))
        $lines.Add('redo_logs=' + (Get-YN $Ctx.RedoLogs))
        $lines.Add('undo_tuning=' + (Get-YN $Ctx.UndoTuning))
        $lines.Add('backup=' + $Ctx.Backup)
        $lines.Add('confirmed=' + $Ctx.Confirm)
        if ($Ctx.PreflightRun -ne '') { $lines.Add('preflight_run=' + $Ctx.PreflightRun) }
        if ($Ctx.MaxRedo -ne '') { $lines.Add('max_redo=' + $Ctx.MaxRedo) }
        if ($Ctx.PlanId -ne '' -and $Action -eq 'PURGE') { $lines.Add('plan_step=' + $Ctx.PlanStep) }
        $plan = Read-PlanLines $Report
        if ($null -ne $plan) {
            # plan=<plan> and its state as the report shows it after the run
            $lines.Add('plan=' + $plan.Label)
            $lines.Add('plan_status=' + $plan.Status)
            $lines.Add('plan_steps=' + $plan.Steps)
            $lines.Add('plan_done=' + $plan.Done)
            $lines.Add('plan_next=' + $plan.NextStep)
        }
    }
    $lines.Add('stop_requested=' + (Get-YN $State.StopRequested))
    $lines.Add('status=' + $Status)
    $ready = '-'
    foreach ($line in ($Report -split "`r?`n")) {
        if ($line -match '^EPF_STEP\|[^|]*\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$') {
            $lines.Add('step.' + $Matches[1] + '.' + $Matches[2] + '.' + $Matches[3] + '=' + $Matches[4] + '|' + $Matches[5])
        } elseif ($line -match '^EPF_CHECK\|[^|]*\|([^|]*)\|([^|]*)\|([^|]*)\|') {
            $lines.Add('check.' + $Matches[1] + '=' + $Matches[2] + '|' + $Matches[3])
        } elseif ($line -match '^EPF_VERDICT\|[^|]*\|([^|]*)\|') {
            $verdict = $Matches[1]
        } elseif ($line -match '^EPF_REQ\|[^|]*\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$') {
            # req.<requirement>=<status>|<blocking>|<met by>
            $lines.Add('req.' + $Matches[1] + '=' + $Matches[2] + '|' + $Matches[3] + '|' + $Matches[4].Trim())
            if ($ready -eq '-') { $ready = 'Y' }
            if ($Matches[2] -eq 'NOT_MET' -and $Matches[3] -eq 'Y') { $ready = 'N' }
        } elseif ($line -match '^EPF_EXPECTED\|[^|]*\|(.*)$') {
            # expected=<COMPLETE|FAIL|MAY_FAIL>|<deleting s>|<bytes freed>|<redo bytes>
            $lines.Add('expected=' + $Matches[1].Trim())
        } elseif ($line -match '^EPF_FORECAST\|[^|]*\|([^|]*)\|([^|]*)\|(.*)$') {
            # forecast.<module>.<measure>=<forecast>|<actual>|<forecast run>|<origin>
            $lines.Add('forecast.' + $Matches[1] + '.' + $Matches[2] + '=' + $Matches[3].Trim())
        } elseif ($line -match '^EPF_RECLAIM_TS\|[^|]*\|([^|]*)\|(.*)$') {
            # tablespace.<name>=<status>|<start>|<end>|<peak>|<forecast>|<tables>|<indexes>|<moved>|<pins> (bytes)
            $lines.Add('tablespace.' + $Matches[1] + '=' + $Matches[2].Trim())
        }
    }
    $lines.Add('requirements_ready=' + $ready)
    $lines.Add('verdict=' + $verdict)
    $lines.Add('exit_code=' + $ExitCode)
    [System.IO.File]::WriteAllLines((Join-Path $State.Folder 'manifest.txt'), $lines.ToArray(), [System.Text.Encoding]::ASCII)
    return $verdict
}

# ----------------------------------------------------------------------------
# Connections and parameters
# ----------------------------------------------------------------------------

function Get-ExpectedVersion {
    foreach ($line in (Get-Content -LiteralPath (Join-Path $script:InstallDir 'registry_data.sql'))) {
        if ($line -match "'tool_version'\s*,\s*'([^']+)'") { return $Matches[1] }
    }
    return ''
}

function Get-Tns {
    return (Get-Input -Name 'tns' -Key 'TNS' -Prompt 'TNS alias or EZConnect (PDB service)' -Hint 'a TNS alias or host:port/service')
}

# Connection as EPFPG. -Soft (the wizard's menu): a failed connection
# returns $null instead of ending the tool.
function Connect-Tool {
    param([switch]$Soft)
    $tns = Get-Tns
    $secret = Read-Secret -Prompt 'EPFPG password' -EnvName 'EPF_PASSWORD' -ConfigKey 'EPF_PASSWORD'
    $login = New-Login -User 'epfpg' -Secret $secret -Tns $tns
    $test = Test-DbConnection $login -WithVersion
    if ($test.TimedOut) {
        Exit-Tool $script:ExitFail ('The database did not answer the connection as EPFPG (3 attempts of ' +
                                    $script:ConnectTimeoutS + ' s): check the network and the listener, then try again.')
    }
    if (-not $test.Ok) {
        Show-Lines $test.Output -Indent
        if ($Soft) {
            Write-Out ' The connection as EPFPG failed: if the tool is not installed yet, choose Install.' 'Yellow'
            return $null
        }
        Exit-Tool $script:ExitUsage 'The connection as EPFPG failed. If the tool is not installed yet, run epf_purge.bat install.'
    }
    if ($test.Container -eq 'CDB$ROOT') { Exit-Tool $script:ExitUsage 'Connected to CDB$ROOT: use the PDB service.' }
    $script:Database = [pscustomobject]@{ Container = $test.Container; Version = $test.Version }
    Write-Out (' Connected to ' + $test.Container + ', tool version ' + $test.Version)
    $expected = Get-ExpectedVersion
    if ($expected -ne '' -and $test.Version -ne $expected) {
        Write-Out (' The database has tool version ' + $test.Version + ' and these scripts are version ' +
                   $expected + ': run epf_purge.bat install first.') 'Yellow'
        if (-not (Read-YesNo 'Continue with the installed version' $false)) { Exit-Tool $script:ExitAborted 'Aborted.' }
    }
    return $login
}

function Connect-Sys {
    param([string]$Tns)
    $secret = Read-Secret -Prompt 'SYS password' -EnvName 'EPF_SYS_PASSWORD' -ConfigKey 'SYS_PASSWORD'
    $sys = New-Login -User 'sys' -Secret $secret -Tns $Tns -Sysdba
    $test = Test-DbConnection $sys
    if ($test.TimedOut) {
        Exit-Tool $script:ExitFail ('The database did not answer the connection as SYS (3 attempts of ' +
                                    $script:ConnectTimeoutS + ' s): check the network and the listener, then try again.')
    }
    if (-not $test.Ok) {
        Show-Lines $test.Output -Indent
        Exit-Tool $script:ExitUsage 'The connection as SYS failed.'
    }
    if ($test.Container -eq 'CDB$ROOT') { Exit-Tool $script:ExitUsage 'Connected to CDB$ROOT: use the PDB service.' }
    if ($null -eq $script:Database) { $script:Database = [pscustomobject]@{ Container = $test.Container; Version = '-' } }
    return $sys
}

# Parameters of a purge or preflight. With $Plan, the run follows the plan:
# its mode, depth and cutoff (Set-PlanScope) instead of the options and
# prompts.
function Get-PurgeContext {
    param($Login, [string]$Action, $Plan = $null)
    $ctx = [pscustomobject]@{
        Cred = $Login; SysCred = $null; Retention = ''; Cutoff = ''; Depth = ''; Mode = ''; BatchSize = '';
        DryRun = $false; Compact = $false; RedoLogs = $false; UndoTuning = $false; Backup = ''; Confirm = '';
        PreflightRun = ''; MaxRedo = ''; NewPlan = $false; PlanId = ''; PlanStep = ''; PlanLabel = ''; Plan = $null
    }
    if ($Action -ne 'PURGE') {
        foreach ($name in @('dry-run', 'compact')) {
            if ($script:Cli.Flags.ContainsKey($name)) { Exit-Tool $script:ExitUsage ('--' + $name + ' applies to purge only.') }
        }
    }
    # A cutoff date instead of the retention: a purge on a later day keeps the
    # cutoff of its preflight or dry run. Retention then shows the days to it.
    if ($script:Cli.Options.ContainsKey('cutoff') -and $script:Cli.Options.ContainsKey('retention')) {
        Exit-Tool $script:ExitUsage 'Give --retention or --cutoff, not both.'
    }
    $cutoff = ''
    if (-not $script:Cli.Options.ContainsKey('retention')) { $cutoff = Get-Option 'cutoff' 'CUTOFF' '' }
    if ($null -ne $Plan) {
        Set-PlanScope $ctx $Plan $Action
    } elseif ($cutoff -ne '') {
        $day = [datetime]::MinValue
        $today = (Get-Date).Add($script:ClockOffset).Date
        if (-not [datetime]::TryParseExact($cutoff.Trim(), 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
                                           [Globalization.DateTimeStyles]::None, [ref]$day)) {
            Exit-Tool $script:ExitUsage ('--cutoff: a date as YYYY-MM-DD, got ' + $cutoff + '.')
        }
        if ($day -ge $today) { Exit-Tool $script:ExitUsage ('--cutoff: a day before today, got ' + $cutoff + '.') }
        $ctx.Cutoff = $day.ToString('yyyy-MM-dd')
        $ctx.Retention = [string][int]($today - $day).TotalDays
    } else {
        $ctx.Retention = Get-Input -Name 'retention' -Key 'RETENTION_DAYS' -Prompt 'Retention in days' -Default '30' -Min 1
    }
    $backup = Get-Option 'backup' 'BACKUP' ''
    if ($backup -ne '') {
        $ctx.Backup = Test-Value $backup -Allowed @('CONFIRMED', 'NONE')
        if ($null -eq $ctx.Backup) { Exit-Tool $script:ExitUsage ('--backup: confirmed or none, got ' + $backup + '.') }
    }
    $confirmList = Get-Option 'confirm' 'CONFIRM' ''
    if ($confirmList -ne '') {
        $codes = @($confirmList.ToUpper().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        foreach ($code in $codes) {
            if (@('ARCHIVE', 'UNDO', 'TEMP') -notcontains $code) {
                Exit-Tool $script:ExitUsage ('--confirm: ARCHIVE, UNDO, TEMP separated by commas, got ' + $confirmList + '.')
            }
        }
        $ctx.Confirm = (@($codes | Select-Object -Unique) -join ',')
    }
    if ($null -eq $Plan) {
        $ctx.Mode = Get-Input -Name 'mode' -Key 'MODE' -Prompt 'Mode (FULL, CLOB, LOGS, CLOB_N_LOGS)' -Default 'FULL' -Allowed $script:Modes
        if ($ctx.Mode -eq 'LOGS') {
            $ctx.Depth = 'LOGS'
        } else {
            $ctx.Depth = (Get-Input -Name 'depth' -Key 'DEPTH' -Prompt 'Depth (ALL, or modules such as PAYMENTS,LOGS,BANK_STATEMENTS)' `
                                    -Default 'ALL' -Pattern '^[A-Z_]+(,[A-Z_]+)*$' -Hint 'ALL, or module names separated by commas').ToUpper()
        }
    }
    $maxRedo = Get-Option 'max-redo' 'MAX_REDO' ''
    if ($maxRedo -ne '') {
        $bytes = ConvertTo-Bytes $maxRedo
        if ($null -eq $bytes) { Exit-Tool $script:ExitUsage ('--max-redo: a size such as 500M or 20G, got ' + $maxRedo + '.') }
        $ctx.MaxRedo = ([long]$bytes).ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    $batch = Get-Option 'batch-size' 'BATCH_SIZE' ''
    if ($batch -ne '') {
        $ctx.BatchSize = Test-Value $batch -Min 100 -Max 100000
        if ($null -eq $ctx.BatchSize) { Exit-Tool $script:ExitUsage 'Batch size: a whole number from 100 to 100000.' }
    }
    if ($Action -eq 'PURGE') {
        $ask = $script:Interactive -and -not $script:Cli.Flags.ContainsKey('dry-run')
        $ctx.DryRun = Get-Choice 'dry-run' 'DRY_RUN' 'Dry run (simulation with the expected outcome, nothing is deleted)' -Ask:$ask
        if ($ctx.DryRun) {
            if ($script:Cli.Flags.ContainsKey('compact')) { Exit-Tool $script:ExitUsage '--compact does not apply to a dry run.' }
        } else {
            $ask = $script:Interactive -and -not $script:Cli.Flags.ContainsKey('compact')
            $ctx.Compact = Get-Choice 'compact' 'COMPACT' 'Compact the purged tables afterwards (returns the freed space to the tablespace)' -Ask:$ask
        }
    }
    # Applied by a purge that deletes; a preflight or dry run checks the
    # requirements as if they were applied.
    $ctx.RedoLogs = Get-Choice 'redo-logs' 'REDO_LOGS' ''
    $ctx.UndoTuning = Get-Choice 'undo-tuning' 'UNDO_TUNING' ''
    return $ctx
}

# ----------------------------------------------------------------------------
# Plans
# ----------------------------------------------------------------------------

# Size such as 500M, 20G or 1.5T (binary units), or bytes; $null when not
# valid.
function ConvertTo-Bytes {
    param([string]$Text)
    if ($Text -match '^\s*(\d+(?:\.\d+)?)\s*([KMGT]?)B?\s*$') {
        $value = [double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture)
        $power = @{ '' = 0; 'K' = 1; 'M' = 2; 'G' = 3; 'T' = 4 }[$Matches[2].ToUpper()]
        $bytes = [Math]::Floor($value * [Math]::Pow(1024, $power))
        if ($bytes -ge 1) { return $bytes }
    }
    return $null
}

function Format-Bytes {
    param([double]$Bytes)
    $units = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes = $Bytes / 1024; $i++ }
    if ($i -eq 0) { return ([string][long]$Bytes + ' B') }
    return ($Bytes.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' ' + $units[$i])
}

# The plan in the output of plan.sql or of a report (EPF_PLAN and
# EPF_PLAN_STEP lines), or $null.
function Read-PlanLines {
    param([string]$Text)
    $plan = $null
    $steps = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^EPF_PLAN\|(.*)$') {
            $f = $Matches[1].Trim().Split('|')
            if ($f.Count -lt 23) { continue }
            $plan = [pscustomobject]@{
                Label = $f[0]; Id = $f[1]; Status = $f[2]; Mode = $f[3]; Depth = $f[4]; Cutoff = $f[5];
                Retention = $f[6]; Steps = [int]$f[7]; Done = [int]$f[8]; NextStep = $f[9]; NextCutoff = $f[10];
                PreflightRun = $f[11]; CheckedAt = $f[12]; Minutes = $f[13]; Batch = $f[14]; Undo = ($f[15] -eq 'Y');
                Redo = ($f[16] -eq 'Y'); Backup = $f[17]; Confirm = $f[18]; Ready = $f[19]; CreatedBy = $f[20];
                MaxRedo = $f[21]; Recent = $f[22]; StepList = $steps
            }
            if ($plan.Backup -eq '-') { $plan.Backup = '' }
            if ($plan.Confirm -eq '-') { $plan.Confirm = '' }
            if ($plan.MaxRedo -eq '-') { $plan.MaxRedo = '' }
        } elseif ($line -match '^EPF_PLAN_STEP\|(.*)$') {
            $f = $Matches[1].Trim().Split('|')
            if ($f.Count -lt 9) { continue }
            $steps.Add([pscustomobject]@{ Step = $f[1]; Cutoff = $f[2]; Roots = $f[3]; Rows = $f[4]; Redo = $f[5];
                                          Status = $f[6]; Fits = $f[7]; LastRun = $f[8] })
        }
    }
    return $plan
}

# The open plan (READY or IN_PROGRESS), or $null.
function Get-OpenPlan {
    param($Login)
    $result = Invoke-SqlScript $Login (Join-Path $script:RunSqlDir 'plan.sql') @('SHOW', 'OPEN')
    $plan = Read-PlanLines $result.Output
    if ($null -ne $plan -and @('READY', 'IN_PROGRESS') -contains $plan.Status) { return $plan }
    return $null
}

# The plan: its state and next step, its scope and last check, and with
# -Choices the choices its purges follow.
function Show-PlanSummary {
    param($Plan, [switch]$Choices)
    $next = 'no step left'
    if ($Plan.NextStep -ne '-') { $next = 'next: step ' + $Plan.NextStep + ', rows before ' + $Plan.NextCutoff }
    Write-Out (' Plan ' + $Plan.Label + '  ' + $Plan.Status + ': ' + $Plan.Done + ' of ' + $Plan.Steps + ' steps done, ' + $next) 'White'
    Write-Out ('   mode ' + $Plan.Mode + ', depth ' + $Plan.Depth + ', rows before ' + $Plan.Cutoff + ' when it ends; checked by ' +
               $Plan.PreflightRun + ' at ' + $Plan.CheckedAt + ' (' + $Plan.CreatedBy + ')')
    if ($Choices) { Write-Out ('   choices ' + (Format-Choices $Plan.Batch $Plan.Undo $Plan.Redo $Plan.Backup $Plan.Confirm)) }
}

# Scope options given on the command line (the configuration file only
# gives defaults).
function Test-ScopeGiven {
    foreach ($name in @('retention', 'cutoff', 'mode', 'depth')) {
        if ($script:Cli.Options.ContainsKey($name)) { return $true }
    }
    return $false
}

function Get-DepthKey {
    param([string]$Depth, [string]$Mode)
    $items = @($Depth.ToUpper().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($items -contains 'ALL') { return 'ALL' }
    if ($Mode -eq 'CLOB_N_LOGS' -and $items -notcontains 'LOGS') { $items += 'LOGS' }
    return ((@($items | Sort-Object -Unique)) -join ',')
}

# Every scope option given equals the plan's: mode, depth (not used with
# --mode LOGS, which purges the LOGS module), and the cutoff (a retention
# matches the plan's retention or its cutoff counted from today).
function Test-PlanScope {
    param($Plan)
    $mode = $Plan.Mode
    $modeGiven = $script:Cli.Options.ContainsKey('mode')
    if ($modeGiven) {
        $mode = ([string]$script:Cli.Options['mode']).Trim().ToUpper()
        if ($mode -ne $Plan.Mode) { return $false }
    }
    if ($script:Cli.Options.ContainsKey('depth') -and -not ($modeGiven -and $mode -eq 'LOGS')) {
        if ((Get-DepthKey ([string]$script:Cli.Options['depth']) $mode) -ne (Get-DepthKey $Plan.Depth $mode)) { return $false }
    }
    if ($script:Cli.Options.ContainsKey('cutoff')) {
        if (([string]$script:Cli.Options['cutoff']).Trim() -ne $Plan.Cutoff) { return $false }
    }
    if ($script:Cli.Options.ContainsKey('retention')) {
        $days = 0
        if (-not [int]::TryParse(([string]$script:Cli.Options['retention']).Trim(), [ref]$days)) { return $false }
        $cutoff = (Get-Date).Add($script:ClockOffset).Date.AddDays(-1 * $days).ToString('yyyy-MM-dd')
        if ([string]$days -ne $Plan.Retention -and $cutoff -ne $Plan.Cutoff) { return $false }
    }
    return $true
}

# The run follows the plan: its mode and depth, and the cutoff of its next
# step (a purge, or a dry run rehearsing it) or of the whole plan (a
# preflight checking it again).
function Set-PlanScope {
    param($Ctx, $Plan, [string]$Action)
    $Ctx.Mode = $Plan.Mode
    $Ctx.Depth = $Plan.Depth
    $cutoff = $Plan.Cutoff
    $Ctx.PlanId = ''
    $Ctx.PlanStep = ''
    if ($Action -eq 'PURGE' -and $Plan.NextStep -ne '-') {
        $cutoff = $Plan.NextCutoff
        $Ctx.PlanId = $Plan.Id
        $Ctx.PlanStep = $Plan.NextStep
    }
    $Ctx.PlanLabel = $Plan.Label
    $Ctx.Plan = $Plan
    $Ctx.Cutoff = $cutoff
    $day = [datetime]::ParseExact($cutoff, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $Ctx.Retention = [string][int]((Get-Date).Add($script:ClockOffset).Date - $day).TotalDays
}

# The choices of the plan (saved with its latest preflight): values given on
# the command line win; undo tuning, redo log sizing and confirmations add
# up.
function Use-PlanChoices {
    param($Ctx, $Plan)
    if ($Ctx.BatchSize -eq '') { $Ctx.BatchSize = $Plan.Batch }
    if ($Ctx.Backup -eq '') { $Ctx.Backup = $Plan.Backup }
    $Ctx.UndoTuning = $Ctx.UndoTuning -or $Plan.Undo
    $Ctx.RedoLogs = $Ctx.RedoLogs -or $Plan.Redo
    foreach ($code in @($Plan.Confirm.Split(',') | Where-Object { $_ -ne '' })) { Add-Confirm $Ctx $code }
    if ($Ctx.MaxRedo -eq '') { $Ctx.MaxRedo = $Plan.MaxRedo }
}

# Wizard, before the next step of a plan that is not ready, was checked
# more than preflight_valid_h hours ago or gets another --max-redo: a
# preflight with the plan's scope and choices (and its questions) checks it
# again, counting the roots anew. Returns the plan as it then stands; ends
# the tool when the check fails, is stopped or leaves the requirements not
# met.
function Invoke-PlanCheck {
    param($Ctx, $Plan)
    $check = $Ctx.PSObject.Copy()
    $check.PreflightRun = ''
    $check.Cutoff = $Plan.Cutoff
    $day = [datetime]::ParseExact($Plan.Cutoff, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $check.Retention = [string][int]((Get-Date).Add($script:ClockOffset).Date - $day).TotalDays
    $check.PlanId = ''
    $check.PlanStep = ''
    $check.DryRun = $false
    $check.Compact = $false
    $check.NewPlan = $false
    Write-Section 'CHECKING THE PLAN AGAIN (read-only preflight)'
    $advice = Get-Advice $check
    if ($advice.Run.Stopped) { Exit-Tool $script:ExitAborted 'Nothing was changed.' }
    if ($advice.ERRORS -ne '0' -or $advice.Run.ExitCode -eq $script:ExitFail) {
        Exit-Tool $script:ExitFail ('The preflight ' + (Get-RunLabel $advice.Run.RunId) + ' found errors (see the report above); nothing was changed.')
    }
    $unmet = Get-Unmet $advice
    if ($unmet.Count -gt 0 -and -not $Ctx.DryRun) {
        Exit-Tool $script:ExitAborted ('Not ready: ' + ($unmet -join ', ') + ' (REQUIREMENTS above). Meet them, then continue the plan; nothing was changed.')
    }
    foreach ($name in @('BatchSize', 'UndoTuning', 'RedoLogs', 'Backup', 'Confirm', 'MaxRedo')) { $Ctx.$name = $check.$name }
    $fresh = Get-OpenPlan $Ctx.Cred
    if ($null -eq $fresh -or $fresh.NextStep -eq '-') {
        Exit-Tool $script:ExitAborted 'After the check the plan has no step left; nothing was changed.'
    }
    $Ctx.PreflightRun = $fresh.PreflightRun
    return $fresh
}

# Lines of one report section, from its title to the next title.
function Get-ReportSection {
    param([string]$Report, [string]$Title)
    $lines = @($Report -split "`r?`n")
    $out = New-Object 'System.Collections.Generic.List[string]'
    $inside = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $isTitle = ($i + 1 -lt $lines.Count) -and ($lines[$i + 1] -match '^ -{20,}') -and ($lines[$i] -match '^ [A-Z]')
        if ($isTitle) {
            if ($inside) { break }
            if ($lines[$i] -match ('^ ' + [regex]::Escape($Title) + '(\s|$)')) { $inside = $true }
        }
        if ($inside -and $lines[$i] -notmatch '^EPF_[A-Z_]+\|') { $out.Add($lines[$i]) }
    }
    if ($out.Count -eq 0) { return '' }
    return (($out.ToArray()) -join "`r`n") + "`r`n"
}

# plan: the open plan (or the latest), or --close.
function Invoke-PlanAction {
    $login = Connect-Tool
    if ($script:Cli.Flags.ContainsKey('close')) {
        $plan = Get-OpenPlan $login
        if ($null -eq $plan) {
            Write-Out ' No open plan.'
            exit $script:ExitPass
        }
        Show-PlanSummary $plan -Choices
        if (-not $script:Cli.Flags.ContainsKey('yes')) {
            if (-not $script:Interactive) { Exit-Tool $script:ExitUsage 'Closing a plan: --yes is required with --non-interactive.' }
            if (-not (Read-YesNo ('Close plan ' + $plan.Label + ' (its completed steps stay done)') $false)) {
                Exit-Tool $script:ExitAborted 'Nothing was changed.'
            }
        }
        $result = Invoke-SqlScript $login (Join-Path $script:RunSqlDir 'plan.sql') @('CLOSE', '-')
        Show-Lines $result.Output -HideMachine
        exit $result.ExitCode
    }
    $result = Invoke-SqlScript $login (Join-Path $script:RunSqlDir 'plan.sql') @('SHOW', 'CURRENT')
    Show-Lines $result.Output -HideMachine
    exit $result.ExitCode
}

# Wizard step: a read-only PREFLIGHT run with the chosen parameters. Its
# findings (recommended batch size, redo and undo warnings) set the defaults of
# the remaining questions, and the purge run refers to it instead of running
# the same checks again.
function Get-Advice {
    param($Ctx)
    $run = Invoke-ToolRun $Ctx 'PREFLIGHT' -FromWizard
    $script:LogFile = $null
    $advice = Read-Advice $Ctx.Cred $run.RunId
    $advice['Run'] = $run
    return $advice
}

# EPF_ADVICE lines of a run (advice.sql): single values by name, and the
# requirements in Req (code -> Status, Blocking, MetBy).
function Read-Advice {
    param($Login, [long]$RunId)
    $advice = @{ BATCH_SIZE = ''; REDO_PER_ROOT = ''; REDO_WARN = 'N'; UNDO_WARN = 'N'; UNDO_ACTIVE = 'N'; ERRORS = '0';
                 WARNINGS = '0'; READY = '-'; UNDO_MAX_BATCH = ''; RUN_BATCH = '' }
    $requirements = [ordered]@{}
    $details = @{}
    $result = Invoke-SqlScript $Login (Join-Path $script:RunSqlDir 'advice.sql') @([string]$RunId)
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^EPF_ADVICE\|REQ\|([A-Z_]+)\|([A-Z_]+)\|([YN])\|(.*)$') {
            $requirements[$Matches[1]] = [pscustomobject]@{ Status = $Matches[2]; Blocking = $Matches[3]; MetBy = $Matches[4].Trim();
                                                            Title = $Matches[1]; Measured = '' }
        } elseif ($line -match '^EPF_ADVICE\|REQTEXT\|([A-Z_]+)\|([^|]*)\|(.*)$') {
            if ($requirements.Contains($Matches[1])) {
                $requirements[$Matches[1]].Title = $Matches[2].Trim()
                $requirements[$Matches[1]].Measured = $Matches[3].Trim()
            }
        } elseif ($line -match '^EPF_ADVICE\|OPT\|([A-Z_]+)\|([A-Z_0-9]+)\|([YN])\|(.*)$') {
            $details[$Matches[1] + '.' + $Matches[2]] = $Matches[4].Trim()
        } elseif ($line -match '^EPF_ADVICE\|([A-Z_]+)\|([^|]*)$') {
            $advice[$Matches[1]] = $Matches[2].Trim()
        }
    }
    $advice['Req'] = $requirements
    $advice['Details'] = $details
    return $advice
}

# Requirements not met, in the preflight's order: the blocking ones, and
# with -All the ones that only slow the purge after them.
function Get-Unmet {
    param($Advice, [switch]$All)
    $codes = @()
    foreach ($blocking in @('Y', 'N')) {
        if ($blocking -eq 'N' -and -not $All) { continue }
        foreach ($code in $Advice.Req.Keys) {
            $item = $Advice.Req[$code]
            if ($item.Status -eq 'NOT_MET' -and $item.Blocking -eq $blocking) { $codes += $code }
        }
    }
    return ,$codes
}

# Batch size that keeps one batch within half of an online log of $LogBytes
# (as the preflight's recommendation): two significant digits, 100-100000.
function Get-BatchForLog {
    param([double]$PerRoot, [double]$LogBytes)
    $value = 0.5 * $LogBytes / $PerRoot
    if ($value -le 100) { return 100 }
    if ($value -ge 100000) { return 100000 }
    $scale = [Math]::Pow(10, [Math]::Floor([Math]::Log10($value)) - 1)
    return [int]([Math]::Floor($value / $scale) * $scale)
}

# Batch size offered: the preflight's recommendation (for 1 GB online logs
# when the logs are to be enlarged), at most what the undo tablespace holds
# 4 times.
function Get-BatchDefault {
    param($Ctx, $Advice)
    $default = 1000
    $recommended = 0
    $perRoot = [double]0
    if ($Ctx.RedoLogs -and [double]::TryParse($Advice.REDO_PER_ROOT, [ref]$perRoot) -and $perRoot -gt 0) {
        $default = Get-BatchForLog $perRoot 1073741824
        Write-Out (' Recommended batch size with 1 GB online logs: ' + $default + ' root rows.')
    } elseif ([int]::TryParse($Advice.BATCH_SIZE, [ref]$recommended) -and $recommended -gt 0) {
        $default = [Math]::Min(100000, [Math]::Max(100, $recommended))
        Write-Out (' Recommended batch size: ' + $default + ' root rows (REDO_SUMMARY above).')
    }
    $undoMax = 0
    if ([int]::TryParse($Advice.UNDO_MAX_BATCH, [ref]$undoMax) -and $undoMax -gt 0 -and $undoMax -lt $default) {
        $default = [Math]::Max(100, [int]([Math]::Floor($undoMax / 100) * 100))
        Write-Out (' Batch size limited to ' + $default + ' root rows: the undo tablespace holds 4 batches of that size.')
    }
    return [string]$default
}

# One numbered line per option, S to stop; returns the answer.
function Read-Option {
    param([string[]]$Options, [string]$Stop = '', [string]$Default = '1')
    $allowed = @()
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Out ('   ' + ($i + 1) + '  ' + $Options[$i])
        $allowed += [string]($i + 1)
    }
    if ($Stop -ne '') {
        Write-Out ('   S  ' + $Stop)
        $allowed += 'S'
    }
    return (Read-Value -Prompt '  Choice' -Default $Default -Allowed $allowed)
}

function Add-Confirm {
    param($Ctx, [string]$Code)
    $codes = @($Ctx.Confirm.Split(',') | Where-Object { $_ -ne '' }) + @($Code)
    $Ctx.Confirm = (@(@('ARCHIVE', 'UNDO', 'TEMP', 'RECYCLEBIN') | Where-Object { $codes -contains $_ }) -join ',')
}

# The question for one requirement not met. Sets the answer on $Ctx and
# returns CHANGED, SAME, or STOP:<what to do next>.
function Read-Requirement {
    param($Ctx, $Advice, [string]$Code)
    $item = $Advice.Req[$Code]
    $label = 'NOT MET'
    if ($item.Blocking -ne 'Y') { $label = 'NOT MET (slower only)' }
    Write-Out ''
    Write-Out (' ' + $Code.PadRight(12) + $item.Title + '  ' + $label) 'Yellow'
    if ($item.Measured -ne '') { Write-Out ('   ' + $item.Measured) }
    switch ($Code) {
        'ARCHIVE' {
            $fit = ''
            $detail = [string]$Advice.Details['ARCHIVE.SMALLER_RUNS']
            if ($detail -match 'cutoff (\d{4}-\d{2}-\d{2})') { $fit = $Matches[1] }
            $options = @('The DBA confirms the archive destination has room for this purge')
            if ($fit -ne '') { $options += ('Purge older data first: ' + $detail) }
            $answer = Read-Option $options 'Stop here: free archive space (or the DBA switches to NOARCHIVELOG), then run the preflight again' 'S'
            if ($answer -eq '1') { Add-Confirm $Ctx 'ARCHIVE'; return 'CHANGED' }
            if ($answer -eq '2') { return ('STOP:run the preflight again with --cutoff ' + $fit + ', then purge the rest in a later run.') }
            return 'STOP:free archive space or have the DBA switch to NOARCHIVELOG, then run the preflight again.'
        }
        'UNDO' {
            $undoMax = 0
            $batch = 0
            if ([int]::TryParse($Advice.UNDO_MAX_BATCH, [ref]$undoMax) -and [int]::TryParse($Advice.RUN_BATCH, [ref]$batch) -and
                $undoMax -gt 0 -and $undoMax -lt $batch) {
                Write-Out ('   A batch of ' + $batch + ' needs more undo than the tablespace holds 4 times; the batch size question offers a smaller one.')
            }
            $answer = Read-Option @('Undo tuning for the purge: undo kept 60 s and its growth capped, restored after (SYS)',
                                    'Accept the growth: the DBA confirms the disk has room for it') `
                                  'Stop here: make room in the undo tablespace, then run the preflight again' '1'
            if ($answer -eq '1') { $Ctx.UndoTuning = $true; return 'CHANGED' }
            if ($answer -eq '2') { Add-Confirm $Ctx 'UNDO'; return 'CHANGED' }
            return 'STOP:make room in the undo tablespace, then run the preflight again.'
        }
        'TEMP' {
            $answer = Read-Option @('The DBA confirms TEMP has room for the work keys') `
                                  'Stop here: add room to TEMP, then run the preflight again' 'S'
            if ($answer -eq '1') { Add-Confirm $Ctx 'TEMP'; return 'CHANGED' }
            return 'STOP:add room to TEMP, then run the preflight again.'
        }
        'BACKUP' {
            $answer = Read-Option @('A backup was made another way (storage snapshot, export)', 'Purge without a backup') `
                                  'Stop here: take a backup, then run the preflight again' 'S'
            if ($answer -eq '1') { $Ctx.Backup = 'CONFIRMED'; return 'CHANGED' }
            if ($answer -eq '2') { $Ctx.Backup = 'NONE'; return 'CHANGED' }
            return 'STOP:take a backup, then run the preflight again.'
        }
        'INDEX_SPACE' {
            $answer = Read-Option @('Continue: a table without its temporary index is scanned once per batch (slower)') `
                                  'Stop here: add room to the tool tablespace, then run the preflight again' '1'
            if ($answer -eq '1') { return 'SAME' }
            return 'STOP:add room to the tool tablespace, then run the preflight again.'
        }
        'REDO_LOGS' {
            $answer = Read-Option @('Enlarge the online logs to 4 x 1 GB when the purge starts (SYS, permanent)',
                                    'Leave them: the batch size below keeps one batch within half a log (slower)') '' '1'
            if ($answer -eq '1') { $Ctx.RedoLogs = $true; return 'CHANGED' }
            return 'SAME'
        }
    }
    return 'SAME'
}

# Interactive preflight: one question per requirement not met, then the batch
# size. The answers are saved with the run and the requirements checked again
# (choices.sql, no table is scanned) until they are met or the operator keeps
# the answers. Returns $false when the operator stopped.
function Invoke-Choices {
    param($Ctx, $State)
    $advice = Read-Advice $Ctx.Cred $State.RunId
    if ($advice.Req.Count -eq 0) { return $true }
    $askBatch = ($Ctx.BatchSize -eq '')
    # The run holds the choices it was started with until they are saved.
    $held = Format-Choices '' $Ctx.UndoTuning $Ctx.RedoLogs $Ctx.Backup $Ctx.Confirm
    Write-Section 'CHOICES'
    if ($advice.UNDO_ACTIVE -eq 'Y' -and -not $Ctx.UndoTuning) {
        Write-Out ' Undo tuning from an earlier run is still active.' 'Yellow'
        $Ctx.UndoTuning = Read-YesNo 'Keep it for this purge and restore it at the end (SYS)' $true
    }
    while ($true) {
        $unmet = Get-Unmet $advice -All
        if ($unmet.Count -eq 0) {
            Write-Out ' Every requirement is met.' 'Green'
        } else {
            Write-Out (' Not met: ' + ($unmet -join ', ') + '. One question each; S stops here.')
        }
        foreach ($code in $unmet) {
            $answer = Read-Requirement $Ctx $advice $code
            if ($answer.StartsWith('STOP:')) {
                Write-Out ''
                Write-Out (' Stopped: ' + $answer.Substring(5)) 'Yellow'
                return $false
            }
        }
        if ($askBatch) {
            Write-Out ''
            $Ctx.BatchSize = Read-Value -Prompt 'Batch size (root rows per transaction)' -Default (Get-BatchDefault $Ctx $advice) -Min 100 -Max 100000
        }
        $now = Format-Choices '' $Ctx.UndoTuning $Ctx.RedoLogs $Ctx.Backup $Ctx.Confirm
        $changed = ($now -ne $held) -or ($Ctx.BatchSize -ne '' -and $Ctx.BatchSize -ne $advice.RUN_BATCH)
        if (-not $changed) { return $true }
        Write-Out ''
        Write-Out ' Checking again with these choices ...'
        $batchArg = '-'
        if ($Ctx.BatchSize -ne '') { $batchArg = $Ctx.BatchSize }
        $backupArg = '-'
        if ($Ctx.Backup -ne '') { $backupArg = $Ctx.Backup }
        $confirmArg = '-'
        if ($Ctx.Confirm -ne '') { $confirmArg = $Ctx.Confirm }
        $choiceArgs = @([string]$State.RunId, $batchArg, (Get-YN $Ctx.UndoTuning), (Get-YN $Ctx.RedoLogs), $backupArg, $confirmArg)
        $result = Invoke-SqlScript $Ctx.Cred (Join-Path $script:RunSqlDir 'choices.sql') $choiceArgs $State 'sqlplus_choices.log'
        Update-LiveView $State
        if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 2) {
            Show-Lines $result.Output -Indent
            throw 'The choices could not be saved with the run.'
        }
        $held = $now
        $advice = Read-Advice $Ctx.Cred $State.RunId
        $blocking = Get-Unmet $advice
        if ($blocking.Count -eq 0) {
            Write-Out ' READY with these choices.' 'Green'
            return $true
        }
        Write-Out (' Still not met: ' + ($blocking -join ', ') + '.') 'Yellow'
        if (-not (Read-YesNo 'Answer again' $true)) { return $true }
    }
}

# Choices as one line: batch size, undo tuning, redo logs, backup,
# confirmations.
function Format-Choices {
    param([string]$Batch, [bool]$Undo, [bool]$Redo, [string]$Backup, [string]$Confirm)
    $parts = @()
    if ($Batch -ne '') { $parts += ('batch ' + $Batch) }
    if ($Undo) { $parts += 'undo tuning' }
    if ($Redo) { $parts += 'redo logs enlarged when the purge starts' }
    if ($Backup -eq 'NONE') { $parts += 'no backup' }
    if ($Backup -eq 'CONFIRMED') { $parts += 'backup made another way' }
    if ($Confirm -ne '') { $parts += ('confirmed by the DBA: ' + $Confirm) }
    if ($parts.Count -eq 0) { return 'none' }
    return ($parts -join ', ')
}

function Show-Review {
    param($Ctx, [string]$Action)
    Write-Section 'REVIEW'
    $cutoff = $Ctx.Cutoff
    if ($cutoff -eq '') { $cutoff = (Get-Date).Add($script:ClockOffset).Date.AddDays(-1 * [int]$Ctx.Retention).ToString('yyyy-MM-dd') }
    $batch = $Ctx.BatchSize
    if ($batch -eq '') { $batch = 'default setting' }
    $backupText = 'a recent RMAN backup (checked by the preflight)'
    if ($Ctx.Backup -eq 'CONFIRMED') { $backupText = 'made another way (confirmed)' }
    if ($Ctx.Backup -eq 'NONE') { $backupText = 'none (purge without a backup)' }
    Write-Out ('  Action        ' + $Action)
    Write-Out ('  Database      ' + $script:Database.Container + ' (' + $Ctx.Cred.Tns + ')')
    Write-Out ('  Retention     ' + $Ctx.Retention + ' days (rows before ' + $cutoff + ')')
    Write-Out ('  Mode, depth   ' + $Ctx.Mode + ', ' + $Ctx.Depth)
    Write-Out ('  Batch size    ' + $batch)
    if ($Ctx.DryRun) {
        Write-Out '  Dry run       yes (simulation: nothing is deleted)'
        if ($Ctx.UndoTuning) { Write-Out '  Undo tuning   planned (checked as applied, nothing is changed)' }
        if ($Ctx.RedoLogs) { Write-Out '  Redo logs     enlargement planned (checked as done, nothing is changed)' }
    } else {
        Write-Out '  Dry run       no'
        Write-Out ('  Compact       ' + (Get-YN $Ctx.Compact))
        Write-Out ('  Redo logs     ' + (Get-YN $Ctx.RedoLogs) + '   (enlarge to 4 x 1 GB before the purge; permanent)')
        Write-Out ('  Undo tuning   ' + (Get-YN $Ctx.UndoTuning) + '   (undo_retention lowered and undo growth limited for the purge, restored at the end)')
        Write-Out ('  Backup        ' + $backupText)
        if ($Ctx.Confirm -ne '') { Write-Out ('  Confirmed     ' + $Ctx.Confirm + '   (handled by the DBA although the preflight finds them not met)') }
    }
    if ($Ctx.PreflightRun -ne '') { Write-Out ('  Preflight     ' + $Ctx.PreflightRun + ' (the purge checks the requirements again with these choices)') }
    if ($Ctx.PlanId -ne '') {
        $what = 'step '
        if ($Ctx.DryRun) { $what = 'rehearsal of step ' }
        Write-Out ('  Plan          ' + $Ctx.PlanLabel + ', ' + $what + $Ctx.PlanStep + ' of ' + $Ctx.Plan.Steps +
                   ' (the plan ends with rows before ' + $Ctx.Plan.Cutoff + ')')
    }
}

# ----------------------------------------------------------------------------
# Actions
# ----------------------------------------------------------------------------

# purge and preflight. -OpenPlan with -PlanKnown: the open plan the wizard
# has already read.
function Invoke-PurgeAction {
    param([string]$Action, [switch]$Wizard, $Login = $null, [switch]$FollowPlan, $OpenPlan = $null, [switch]$PlanKnown)
    $dry = ($Action -eq 'PURGE' -and $script:Cli.Flags.ContainsKey('dry-run'))
    $newPlan = $script:Cli.Flags.ContainsKey('new')
    if ($script:Cli.Options.ContainsKey('max-redo') -and $Action -eq 'PURGE' -and (-not $Wizard -or $dry)) {
        Exit-Tool $script:ExitUsage '--max-redo applies to preflight and to the wizard''s purge (its preflight plans the runs).'
    }
    $login = $Login
    if ($null -eq $login) { $login = Connect-Tool }

    # The open plan: a purge carries out its next step (a dry run rehearses
    # it), a preflight checks it again. Scope options that differ from it
    # replace a plan with no step run yet. A plan in progress goes on: a
    # purge of another scope is refused (the wizard asks) unless the
    # operator starts over (--new); a preflight or dry run of another scope
    # leaves it as it is.
    $plan = $null
    if (-not $newPlan) {
        if ($PlanKnown) { $plan = $OpenPlan } else { $plan = Get-OpenPlan $login }
    }
    $follow = $false
    if ($null -ne $plan) {
        $follow = $FollowPlan -or (-not (Test-ScopeGiven)) -or (Test-PlanScope $plan)
        if (-not $follow -and -not $dry) {
            if ($plan.Status -eq 'READY') {
                Write-Out (' The open plan ' + $plan.Label + ' has no step run yet; this ' + $Action.ToLower() +
                           ' with other options replaces it.') 'Yellow'
            } elseif ($Action -eq 'PREFLIGHT') {
                Write-Out (' Plan ' + $plan.Label + ' of another scope is in progress: this preflight plans nothing' +
                           ' (preflight --new starts over).') 'Yellow'
            } else {
                Write-Out ''
                Show-PlanSummary $plan
                $hint = 'Run purge without --retention, --cutoff, --mode or --depth to continue it, or add --new to start over.'
                if (-not $script:Interactive) {
                    Exit-Tool $script:ExitUsage ('Plan ' + $plan.Label + ' is in progress and the options given differ from it. ' + $hint)
                }
                Write-Out (' The options given differ from plan ' + $plan.Label + ', which is in progress.') 'Yellow'
                $continue = 'Continue the plan'
                if ($plan.NextStep -ne '-') { $continue = $continue + ' (step ' + $plan.NextStep + ' of ' + $plan.Steps + ': rows before ' + $plan.NextCutoff + ')' }
                $answer = Read-Option @(($continue + '; the options given are not used'),
                                        'Start over with the options given: the plan is closed, its completed steps stay done') `
                                      'Cancel' '1'
                if ($answer -eq 'S') { Exit-Tool $script:ExitAborted 'Cancelled; nothing was changed.' }
                if ($answer -eq '1') { $follow = $true } else { $newPlan = $true }
            }
        }
        if (-not $follow) { $plan = $null }
    }
    if ($follow -and $Action -eq 'PURGE' -and $plan.NextStep -eq '-') {
        Exit-Tool $script:ExitUsage ('Plan ' + $plan.Label + ' has no step left.')
    }

    $ctx = Get-PurgeContext $login $Action $plan
    $ctx.NewPlan = $newPlan

    if ($follow -and $Action -eq 'PREFLIGHT') {
        Write-Out ''
        Show-PlanSummary $plan
        $text = Format-Choices $plan.Batch $plan.Undo $plan.Redo $plan.Backup $plan.Confirm
        if (Read-YesNo ('Check the plan again with its choices (' + $text + ')') $true) { Use-PlanChoices $ctx $plan }
    } elseif ($follow) {
        # The purge follows the plan's choices and reuses the root counts of
        # its preflight while they are valid (same cutoff, recent, nothing
        # purged since).
        $replan = $Wizard -and $ctx.MaxRedo -ne '' -and $ctx.MaxRedo -ne $plan.MaxRedo
        Use-PlanChoices $ctx $plan
        $ctx.PreflightRun = $plan.PreflightRun
        Write-Out ''
        if ($plan.Steps -gt 1) {
            $verb = 'carries out'
            if ($ctx.DryRun) { $verb = 'rehearses' }
            Write-Out (' Plan ' + $plan.Label + ': this run ' + $verb + ' step ' + $plan.NextStep + ' of ' + $plan.Steps +
                       ', rows before ' + $plan.NextCutoff + ' (' + $plan.Done + ' done; the plan ends with rows before ' +
                       $plan.Cutoff + ').')
        }
        Write-Out (' Choices saved with the preflight ' + $plan.PreflightRun + ' (' + $plan.CheckedAt + '): ' +
                   (Format-Choices $plan.Batch $plan.Undo $plan.Redo $plan.Backup $plan.Confirm))
        if ($Wizard -and ($plan.Ready -ne 'Y' -or $plan.Recent -ne 'Y' -or $replan)) {
            if ($replan) {
                Write-Out (' The plan is checked again first, with runs of at most ' + (Format-Bytes ([double]$ctx.MaxRedo)) +
                           ' of redo (--max-redo).') 'Yellow'
            } elseif ($plan.Ready -ne 'Y') {
                Write-Out ' The plan''s last check found requirements not met: it is checked again first.' 'Yellow'
            } else {
                Write-Out ' The plan was last checked more than preflight_valid_h hours ago: it is checked again first.' 'Yellow'
            }
            $plan = Invoke-PlanCheck $ctx $plan
            Set-PlanScope $ctx $plan 'PURGE'
        }
    } elseif ($Action -eq 'PURGE' -and $Wizard) {
        # No plan to follow: the wizard checks the database first (a read-only
        # preflight with its questions). That preflight plans the purge, and
        # this run carries out the plan's first step.
        Write-Section 'CHECKING THE DATABASE (read-only preflight)'
        $advice = Get-Advice $ctx
        $ctx.PreflightRun = Get-RunLabel $advice.Run.RunId
        $ctx.NewPlan = $false
        if ($advice.Run.Stopped) { Exit-Tool $script:ExitAborted 'Nothing was changed.' }
        if ($advice.ERRORS -ne '0' -or $advice.Run.ExitCode -eq $script:ExitFail) {
            Exit-Tool $script:ExitFail ('The preflight ' + $ctx.PreflightRun + ' found errors (see the report above); nothing was changed.')
        }
        $unmet = Get-Unmet $advice
        if ($unmet.Count -gt 0 -and -not $ctx.DryRun) {
            Exit-Tool $script:ExitAborted ('Not ready: ' + ($unmet -join ', ') + ' (REQUIREMENTS above). Meet them, then run the purge again; nothing was changed.')
        }
        $plan = Get-OpenPlan $ctx.Cred
        if ($null -ne $plan -and $plan.PreflightRun -eq $ctx.PreflightRun -and $plan.NextStep -ne '-') {
            Set-PlanScope $ctx $plan 'PURGE'
            if ($plan.Steps -gt 1) {
                Write-Out (' The preflight planned the purge in ' + $plan.Steps + ' runs, older data first; this run carries out step ' +
                           $plan.NextStep + ': rows before ' + $plan.NextCutoff + '.') 'Yellow'
            }
        }
    }

    if ($Action -eq 'PURGE' -and -not $ctx.DryRun -and ($ctx.RedoLogs -or $ctx.UndoTuning)) {
        $ctx.SysCred = Connect-Sys $login.Tns
    }
    if ($Action -eq 'PURGE') {
        Show-Review $ctx $Action
        if (-not $ctx.DryRun) {
            Read-Typed 'Rows before the cutoff will be deleted, or their LOB values cleared'
        } elseif ($script:Interactive -and -not $script:Cli.Flags.ContainsKey('yes')) {
            if (-not (Read-YesNo 'Proceed' $true)) { Exit-Tool $script:ExitAborted 'Aborted.' }
        }
    }
    $run = Invoke-ToolRun $ctx $Action
    if ($run.Stopped) { exit $script:ExitAborted }
    exit $run.ExitCode
}

# ----------------------------------------------------------------------------
# Reclaim
# ----------------------------------------------------------------------------

# Options of reclaim, checked before any connection or prompt: the mode
# (ASSESS with --dry-run, RESTORE with --restore, otherwise COMPACT), the
# tablespaces and the requirements the DBA confirms (RECLAIM_TABLESPACES and
# RECLAIM_CONFIRM in the configuration file).
function Read-ReclaimOptions {
    foreach ($name in @('retention', 'cutoff', 'depth', 'mode', 'batch-size', 'backup')) {
        if ($script:Cli.Options.ContainsKey($name)) { Exit-Tool $script:ExitUsage ('--' + $name + ' applies to purge and preflight.') }
    }
    foreach ($name in @('compact', 'redo-logs', 'undo-tuning')) {
        if ($script:Cli.Flags.ContainsKey($name)) { Exit-Tool $script:ExitUsage ('--' + $name + ' applies to purge and preflight.') }
    }
    $ctx = [pscustomobject]@{ Cred = $null; SysCred = $null; Mode = 'COMPACT'; Tablespaces = ''; Confirm = ''; AssessRun = '' }
    $dry = $script:Cli.Flags.ContainsKey('dry-run')
    $restore = $script:Cli.Flags.ContainsKey('restore')
    if ($dry -and $restore) { Exit-Tool $script:ExitUsage '--dry-run and --restore cannot be combined.' }
    if ($restore) {
        foreach ($name in @('tablespaces', 'confirm')) {
            if ($script:Cli.Options.ContainsKey($name)) {
                Exit-Tool $script:ExitUsage ('--' + $name + ' does not apply to --restore, which restores everything a reclaim left pending.')
            }
        }
        $ctx.Mode = 'RESTORE'
        return $ctx
    }
    if ($dry) { $ctx.Mode = 'ASSESS' }
    $list = Get-Option 'tablespaces' 'RECLAIM_TABLESPACES' ''
    if ($list -ne '') {
        $ctx.Tablespaces = Test-Tablespaces $list
        if ($null -eq $ctx.Tablespaces) { Exit-Tool $script:ExitUsage ('--tablespaces: tablespace names separated by commas, got ' + $list + '.') }
    }
    $confirmList = Get-Option 'confirm' 'RECLAIM_CONFIRM' ''
    if ($confirmList -ne '') {
        $codes = @($confirmList.ToUpper().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        foreach ($code in $codes) {
            if (@('ARCHIVE', 'TEMP', 'RECYCLEBIN') -notcontains $code) {
                Exit-Tool $script:ExitUsage ('--confirm: ARCHIVE, TEMP, RECYCLEBIN separated by commas for a reclaim, got ' + $confirmList + '.')
            }
        }
        $ctx.Confirm = (@(@('ARCHIVE', 'TEMP', 'RECYCLEBIN') | Where-Object { $codes -contains $_ }) -join ',')
    }
    return $ctx
}

# Tablespace names separated by commas, in capitals without duplicates; $null
# when not valid.
function Test-Tablespaces {
    param([string]$List)
    $names = @($List.ToUpper().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    if ($names.Count -eq 0) { return $null }
    foreach ($name in $names) {
        if ($name -notmatch '^[A-Z][A-Z0-9_$#]{0,127}$') { return $null }
    }
    return (@($names | Select-Object -Unique) -join ',')
}

# Number in a machine-readable line; 0 when empty or not a number.
function ConvertTo-Number {
    param([string]$Text)
    $value = [double]0
    if ([double]::TryParse($Text.Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture,
                           [ref]$value)) {
        return $value
    }
    return [double]0
}

# The tablespaces of a reclaim run in the EPF_RECLAIM_TS lines of its report.
function Read-ReclaimTs {
    param([string]$Report)
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in ($Report -split "`r?`n")) {
        if ($line -match '^EPF_RECLAIM_TS\|(.*)$') {
            $f = $Matches[1].Trim().Split('|')
            if ($f.Count -lt 11) { continue }
            $list.Add([pscustomobject]@{
                Name = $f[1]; Status = $f[2]; Start = (ConvertTo-Number $f[3]); End = (ConvertTo-Number $f[4]);
                Peak = (ConvertTo-Number $f[5]); Forecast = (ConvertTo-Number $f[6]); Tables = (ConvertTo-Number $f[7]);
                Indexes = (ConvertTo-Number $f[8]); Moved = (ConvertTo-Number $f[9]); Pins = (ConvertTo-Number $f[10])
            })
        }
    }
    return ,$list.ToArray()
}

# One reclaim run in mode $Mode (ASSESS, COMPACT or RESTORE): the monitor
# (EPFPG) creates the run and holds its lock; the worker session (SYS) runs
# src\sql\run\reclaim.sql while the monitor shows it live. When the worker
# session of a compaction or restore ends before the run is finished (killed,
# connection lost), what it changed is restored in the same run, in a new SYS
# session. The monitor ends the run with the report's verdict; the report goes
# to the console and to the run folder.
function Invoke-ReclaimRun {
    param($Ctx, [string]$Mode)
    $state = [pscustomobject]@{
        Cred = $Ctx.Cred; Monitor = $null; RunId = [long]0; LastEvent = [long]0; LastOutput = (Get-Date);
        RunStatus = ''; Folder = $null; Live = $true; StopKeys = $false; StopRequested = $false; Started = (Get-Date);
        Stopped = $false
    }
    $confirmArg = '-'
    $scopeArg = '-'
    if ($Mode -ne 'RESTORE') {
        if ($Ctx.Confirm -ne '') { $confirmArg = $Ctx.Confirm }
        if ($Ctx.Tablespaces -ne '') { $scopeArg = $Ctx.Tablespaces }
    }
    Open-Run $state @('RECLAIM', '-', '-', '-', '-', (Get-YN ($Mode -eq 'ASSESS')), 'N', 'N', 'N', '-', '-', $confirmArg,
                      'N', '-', 'N', '-', '-')
    $label = Get-RunLabel $state.RunId
    $what = @{ 'ASSESS' = 'assessment (read-only)'; 'COMPACT' = 'compaction in place';
               'RESTORE' = 'restore of what reclaims left pending' }[$Mode]

    Write-Out ''
    Write-Out (' EPF Data Purge - reclaim'.PadRight($script:Width - $label.Length - 4) + 'run ' + $label) 'White'
    Write-Out (' ' + ('-' * ($script:Width - 1)))
    Write-Out (' Database   ' + $script:Database.Container + ', tool version ' + $script:Database.Version +
               ', ' + $Ctx.Cred.Tns)
    $offset = Format-Offset $script:ClockOffset
    if ($offset -ne '') {
        Write-Out (' Times      database clock (' + $offset + ' from this machine)')
    }
    Write-Out (' Run folder ' + $state.Folder)
    if ($Mode -eq 'RESTORE') {
        Write-Out (' Reclaim    ' + $what)
    } elseif ($scopeArg -eq '-') {
        Write-Out (' Reclaim    ' + $what + ', every candidate tablespace')
    } else {
        Write-Out (' Reclaim    ' + $what + ', tablespaces ' + ($Ctx.Tablespaces -replace ',', ', '))
    }
    if ($confirmArg -ne '-') { Write-Out (' Choices    confirmed by the DBA: ' + $Ctx.Confirm) }
    if ($Mode -eq 'COMPACT' -and $Ctx.AssessRun -ne '') { Write-Out (' Assessed   ' + $Ctx.AssessRun) }

    $status = 'FAILED'
    $closeCode = $null
    $state.StopKeys = Enable-StopKey
    if ($state.StopKeys -and $Mode -eq 'COMPACT') {
        Write-Out ' Ctrl+C requests a graceful stop: the compaction ends after the current table, then the indexes, datafiles and accounts are restored.' -NoLog
    }
    try {
        Write-Section ('RECLAIM  ' + $what.ToUpper())
        $result = Invoke-SqlScript $Ctx.SysCred (Join-Path $script:RunSqlDir 'reclaim.sql') @([string]$state.RunId, $Mode, $scopeArg) $state 'sqlplus_reclaim.log'
        Update-LiveView $state
        switch ($result.ExitCode) {
            0       { $status = 'SUCCESS' }
            2       { $status = 'WARNING' }
            3       { $status = 'STOPPED' }
            default { $status = 'FAILED' }
        }
        if ($result.Output -match 'ORA-\d{5}|SP2-\d{4}') { Show-Lines $result.Output -Indent }
        if ($Mode -ne 'ASSESS' -and $result.Output -notmatch 'EPF_RECLAIM_STATUS=') {
            # The worker session ended before the run was finished: what it
            # changed is restored now, in the same run.
            $status = 'FAILED'
            Write-Out ' The worker session ended before the reclaim finished: what it changed is restored now (SYS).' 'Red'
            Write-Section 'RECLAIM  RESTORE'
            $restore = Invoke-SqlScript $Ctx.SysCred (Join-Path $script:RunSqlDir 'reclaim.sql') @([string]$state.RunId, 'RESTORE', '-') $state 'sqlplus_reclaim_restore.log'
            Update-LiveView $state
            if ($restore.Output -notmatch 'EPF_RECLAIM_STATUS=') {
                Show-Lines $restore.Output -Indent
                Write-Out ' The restore did not finish either: run epf_purge.bat reclaim --restore.' 'Red'
            }
        }
    } catch {
        Write-Out (' ' + $_.Exception.Message) 'Red'
        $status = 'FAILED'
    } finally {
        Disable-StopKey $state
        $closeCode = Close-Run $state $status
    }

    Write-Section 'REPORT'
    $report = Invoke-SqlScript $Ctx.Cred (Join-Path $script:RunSqlDir 'report.sql') @([string]$state.RunId)
    [System.IO.File]::WriteAllText((Join-Path $state.Folder 'report.txt'), $report.Output, [System.Text.Encoding]::ASCII)
    Show-Lines $report.Output -HideMachine
    $text = Get-ReportSection $report.Output 'REQUIREMENTS'
    if ($text -ne '') {
        [System.IO.File]::WriteAllText((Join-Path $state.Folder 'requirements.txt'), $text, [System.Text.Encoding]::ASCII)
    }
    $exitCode = $closeCode
    if ($null -eq $exitCode) { $exitCode = $script:ExitFail }
    if ($status -eq 'STOPPED') { $exitCode = $script:ExitAborted }
    $verdict = Write-Manifest $state $Ctx 'RECLAIM' $status $exitCode $report.Output
    $total = Format-Seconds ([string][int]((Get-Date) - $state.Started).TotalSeconds)
    $color = 'Green'
    if ($exitCode -eq $script:ExitWarn -or $exitCode -eq $script:ExitAborted) { $color = 'Yellow' }
    if ($exitCode -eq $script:ExitFail) { $color = 'Red' }
    $line = (' RESULT  ' + $verdict + '  (' + $status + ')').PadRight($script:Width - 25)
    Write-Out ''
    Write-Out ($line + 'total ' + $total + ' . exit ' + $exitCode) $color
    Write-Out (' Report  ' + (Join-Path $state.Folder 'report.txt'))
    return [pscustomobject]@{ RunId = $state.RunId; ExitCode = $exitCode; Status = $status; Folder = $state.Folder;
                              Report = $report.Output }
}

# The question for each blocking requirement the assessment found not met:
# the DBA confirms it (--confirm), or the reclaim stops. A requirement that
# is advice (BACKUP) is shown. Returns $false when the operator stopped.
function Invoke-ReclaimChoices {
    param($Ctx, $Advice)
    $unmet = Get-Unmet $Advice -All
    if ($unmet.Count -eq 0) { return $true }
    Write-Section 'CHOICES'
    foreach ($code in $unmet) {
        $item = $Advice.Req[$code]
        $label = 'NOT MET'
        if ($item.Blocking -ne 'Y') { $label = 'NOT MET (advice)' }
        Write-Out ''
        Write-Out (' ' + $code.PadRight(12) + $item.Title + '  ' + $label) 'Yellow'
        if ($item.Measured -ne '') { Write-Out ('   ' + $item.Measured) }
        if ($item.Blocking -ne 'Y') { continue }
        $option = ''
        $stop = 'the requirement is not met'
        switch ($code) {
            'RECYCLEBIN' {
                $option = 'They may be lost: the compaction purges them first (FLASHBACK TABLE ... TO BEFORE DROP can then no longer restore them)'
                $stop = 'the DBA purges them (PURGE TABLESPACE <name>), then run the reclaim again'
            }
            'ARCHIVE' {
                $option = 'The DBA confirms the archive destination has room for the redo of the moves and rebuilds'
                $stop = 'free archive space (back up and delete archived logs), then run the reclaim again'
            }
            'TEMP' {
                $option = 'The DBA confirms TEMP has room for the index rebuilds'
                $stop = 'add room to TEMP, then run the reclaim again'
            }
        }
        if ($option -eq '') {
            Write-Out (' Stopped: ' + $stop + '.') 'Yellow'
            return $false
        }
        $answer = Read-Option @($option) ('Stop here: ' + $stop) 'S'
        if ($answer -ne '1') {
            Write-Out ''
            Write-Out (' Stopped: ' + $stop + '.') 'Yellow'
            return $false
        }
        Add-Confirm $Ctx $code
    }
    return $true
}

function Show-ReclaimReview {
    param($Ctx, [object[]]$Spaces)
    Write-Section 'REVIEW'
    $start = [double]0
    $forecast = [double]0
    $tables = [double]0
    $indexes = [double]0
    $names = @()
    foreach ($t in $Spaces) {
        $start += $t.Start
        $forecast += $t.Forecast
        $tables += $t.Tables
        $indexes += $t.Indexes
        $names += $t.Name
    }
    Write-Out '  Action        reclaim: compaction in place (SYS)'
    Write-Out ('  Database      ' + $script:Database.Container + ' (' + $Ctx.Cred.Tns + ')')
    Write-Out ('  Tablespaces   ' + ($names -join ', '))
    Write-Out ('  Datafiles     ' + (Format-Bytes $start) + ' now; forecast ' + (Format-Bytes $forecast) + ' at the end (' +
               (Format-Bytes ([Math]::Max($start - $forecast, 0))) + ' given back)')
    Write-Out ('  Work          ' + $tables + ' tables move, ' + $indexes + ' indexes are released and rebuilt')
    Write-Out '  Accounts      the accounts in ACCOUNTS above are locked, and their sessions disconnected, until the end'
    Write-Out '  Disk          no datafile grows above its size at the start (setting reclaim_growth_mb)'
    if ($Ctx.Confirm -ne '') { Write-Out ('  Confirmed     ' + $Ctx.Confirm + '   (handled by the DBA although the assessment finds them not met)') }
    Write-Out ('  Assessment    ' + $Ctx.AssessRun)
}

# After a reclaim run: what can follow.
function Show-ReclaimNext {
    param($Ctx, $Run)
    if ($Run.Status -eq 'STOPPED') { return }
    if ($Ctx.Mode -eq 'ASSESS') {
        if ($Run.Status -eq 'FAILED') { return }
        $unmet = @()
        foreach ($line in ($Run.Report -split "`r?`n")) {
            if ($line -match '^EPF_REQ\|[^|]*\|([^|]*)\|NOT_MET\|Y\|') { $unmet += $Matches[1] }
        }
        $scope = ''
        if ($Ctx.Tablespaces -ne '') { $scope = ' --tablespaces ' + $Ctx.Tablespaces }
        $confirm = ''
        if ($Ctx.Confirm -ne '') { $confirm = ' --confirm ' + $Ctx.Confirm }
        if ((Read-ReclaimTs $Run.Report).Count -eq 0) {
            Write-Out ' Next    nothing to reclaim.'
        } elseif ($unmet.Count -gt 0) {
            Write-Out (' Next    not ready (' + ($unmet -join ', ') + '): meet them, or the DBA confirms them (--confirm), ' +
                       'then run the reclaim') 'Yellow'
        } else {
            Write-Out (' Next    epf_purge.bat reclaim' + $scope + $confirm + ' compacts them (SYS; the accounts listed ' +
                       'are locked meanwhile)') 'Green'
        }
    } elseif ($Run.Status -eq 'FAILED') {
        Write-Out ' Next    epf_purge.bat status shows what is pending; epf_purge.bat reclaim --restore restores it' 'Yellow'
    }
}

# reclaim: --dry-run assesses, --restore restores what reclaims left
# pending, otherwise the compaction. With prompts the compaction is assessed
# first: the report, a question for each blocking requirement not met, the
# review and a typed confirmation.
function Invoke-ReclaimAction {
    param($Login = $null)
    $ctx = Read-ReclaimOptions
    $confirmed = $script:Cli.Flags.ContainsKey('yes')
    if ($ctx.Mode -eq 'COMPACT' -and -not $script:Interactive -and -not $confirmed) {
        Exit-Tool $script:ExitUsage 'The tables will move: --yes is required with --non-interactive.'
    }
    $login = $Login
    if ($null -eq $login) { $login = Connect-Tool }
    $ctx.Cred = $login
    if ($ctx.Mode -ne 'RESTORE' -and $ctx.Tablespaces -eq '' -and $script:Interactive -and -not $confirmed -and
        -not $script:Cli.Options.ContainsKey('tablespaces')) {
        while ($true) {
            $answer = (Read-Host -Prompt ' Tablespaces to reclaim, separated by commas (Enter: every candidate)').Trim()
            Write-Log (' Tablespaces to reclaim: ' + $answer)
            if ($answer -eq '') { break }
            $ctx.Tablespaces = Test-Tablespaces $answer
            if ($null -ne $ctx.Tablespaces) { break }
            $ctx.Tablespaces = ''
            Write-Out '   tablespace names separated by commas, or Enter for every candidate' 'Yellow' -NoLog
        }
    }
    $ctx.SysCred = Connect-Sys $login.Tns

    if ($ctx.Mode -eq 'RESTORE') {
        if ($script:Interactive -and -not $confirmed) {
            $pending = Invoke-SqlScript $login (Join-Path $script:RunSqlDir 'status.sql') @()
            Show-Lines $pending.Output -Indent
            if (-not (Read-YesNo 'Restore what reclaims left pending (indexes, datafile growth settings, accounts)' $true)) {
                Exit-Tool $script:ExitAborted 'Nothing was changed.'
            }
        }
        $run = Invoke-ReclaimRun $ctx 'RESTORE'
        Show-ReclaimNext $ctx $run
        exit $run.ExitCode
    }
    if ($ctx.Mode -eq 'ASSESS') {
        $run = Invoke-ReclaimRun $ctx 'ASSESS'
        Show-ReclaimNext $ctx $run
        exit $run.ExitCode
    }
    if ($script:Interactive -and -not $confirmed) {
        # The assessment first, in its own read-only run.
        $assess = Invoke-ReclaimRun $ctx 'ASSESS'
        $script:LogFile = $null
        $ctx.AssessRun = Get-RunLabel $assess.RunId
        if ($assess.Status -eq 'STOPPED') { Exit-Tool $script:ExitAborted 'Nothing was changed.' }
        if ($assess.Status -eq 'FAILED') {
            Exit-Tool $script:ExitFail ('The assessment ' + $ctx.AssessRun + ' failed (see the report above); nothing was changed.')
        }
        $spaces = Read-ReclaimTs $assess.Report
        if ($spaces.Count -eq 0) { Exit-Tool $script:ExitPass 'No tablespace to reclaim; nothing was changed.' }
        $advice = Read-Advice $ctx.Cred $assess.RunId
        if (-not (Invoke-ReclaimChoices $ctx $advice)) { Exit-Tool $script:ExitAborted 'Nothing was changed.' }
        Show-ReclaimReview $ctx $spaces
    }
    Read-Typed 'The tables will move and their indexes will be rebuilt; the accounts listed are locked meanwhile'
    $run = Invoke-ReclaimRun $ctx 'COMPACT'
    Show-ReclaimNext $ctx $run
    exit $run.ExitCode
}

function Get-RunArgument {
    param([string]$Default)
    $value = Get-Option 'run' 'RUN' $Default
    if ($value -match '^(?i)R-?0*(\d+)$') { return $Matches[1] }
    if ($value -match '^\d+$' -or $value -match '^(?i)(LATEST|ACTIVE)$') { return $value.ToUpper() }
    Exit-Tool $script:ExitUsage ('--run: a run id such as 124 or R-000124, got ' + $value + '.')
}

function Invoke-SimpleScript {
    param([string]$Script, [string[]]$Arguments, $Login = $null)
    $login = $Login
    if ($null -eq $login) { $login = Connect-Tool }
    $result = Invoke-SqlScript $login (Join-Path $script:RunSqlDir $Script) $Arguments
    Show-Lines $result.Output
    exit $result.ExitCode
}

function Invoke-InstallAction {
    param([switch]$Uninstall)
    $tns = Get-Tns
    $sys = Connect-Sys $tns
    if ($Uninstall) {
        Read-Typed 'The EPFPG schema and the EPFPG_DATA tablespace will be removed'
        $result = Invoke-SqlScript $sys (Join-Path $script:InstallDir 'uninstall.sql')
    } else {
        $password = ConvertFrom-Secure (Read-Secret -Prompt 'EPFPG password to set' -EnvName 'EPF_PASSWORD' -ConfigKey 'EPF_PASSWORD' -Twice)
        if ($password.Contains('"') -or $password.Contains("'")) {
            Exit-Tool $script:ExitUsage 'The EPFPG password must not contain quotes.'
        }
        $result = Invoke-SqlScript $sys (Join-Path $script:InstallDir 'install.sql') @('"' + $password + '"')
    }
    Show-Lines $result.Output
    exit $result.ExitCode
}

# The menu. With an open plan it shows the plan and offers to continue it,
# check it again, rehearse its next step or start over; without one, a
# purge (the wizard's preflight plans it first) or a preflight. Reclaim is
# offered in both.
function Start-Wizard {
    Write-Out ''
    Write-Out ' EPF Data Purge' 'White'
    Write-Out (' ' + ('-' * ($script:Width - 1)))
    $login = Connect-Tool -Soft
    $plan = $null
    $known = $false
    if ($null -ne $login) {
        $plan = Get-OpenPlan $login
        $known = $true
    }
    if ($null -ne $plan) {
        Write-Out ''
        Show-PlanSummary $plan
        Write-Out ''
        $next = ''
        if ($plan.NextStep -ne '-') { $next = ' (step ' + $plan.NextStep + ' of ' + $plan.Steps + ': rows before ' + $plan.NextCutoff + ')' }
        Write-Out ('  1  Continue the plan' + $next)
        Write-Out '  2  Check the plan again (read-only preflight with its choices)'
        Write-Out '  3  Rehearse the next step (dry run)'
        Write-Out '  4  Start over (a new preflight; the plan is closed, its completed steps stay done)'
        Write-Out '  5  Reclaim disk space (SYS; assessed first)'
        Write-Out '  6  Report of a run'
        Write-Out '  7  Status'
        Write-Out '  8  Install or upgrade (SYS)'
        Write-Out '  9  Uninstall (SYS)'
        $choice = Read-Value -Prompt 'Choice' -Default '1' -Allowed @('1', '2', '3', '4', '5', '6', '7', '8', '9')
        switch ($choice) {
            '1' { Invoke-PurgeAction 'PURGE' -Wizard -Login $login -FollowPlan -OpenPlan $plan -PlanKnown }
            '2' { Invoke-PurgeAction 'PREFLIGHT' -Login $login -FollowPlan -OpenPlan $plan -PlanKnown }
            '3' {
                $script:Cli.Flags['dry-run'] = $true
                Invoke-PurgeAction 'PURGE' -Wizard -Login $login -FollowPlan -OpenPlan $plan -PlanKnown
            }
            '4' {
                $script:Cli.Flags['new'] = $true
                Invoke-PurgeAction 'PREFLIGHT' -Login $login
            }
            '5' { Invoke-ReclaimAction $login }
            '6' {
                $script:Cli.Options['run'] = Read-Value -Prompt 'Run (id or LATEST)' -Default 'LATEST' -Pattern '^(LATEST|R?-?\d+)$' -Hint 'a run id such as 124, or LATEST'
                Invoke-SimpleScript 'report.sql' @(Get-RunArgument 'LATEST') $login
            }
            '7' { Invoke-SimpleScript 'status.sql' @() $login }
            '8' { Invoke-InstallAction }
            '9' { Invoke-InstallAction -Uninstall }
        }
        return
    }
    Write-Out '  1  Purge (a read-only preflight checks the database and plans the purge first)'
    Write-Out '  2  Preflight only (read-only)'
    Write-Out '  3  Reclaim disk space (SYS; assessed first)'
    Write-Out '  4  Report of a run'
    Write-Out '  5  Status'
    Write-Out '  6  Install or upgrade (SYS)'
    Write-Out '  7  Uninstall (SYS)'
    $choice = Read-Value -Prompt 'Choice' -Default '1' -Allowed @('1', '2', '3', '4', '5', '6', '7')
    switch ($choice) {
        '1' { Invoke-PurgeAction 'PURGE' -Wizard -Login $login -PlanKnown:$known }
        '2' { Invoke-PurgeAction 'PREFLIGHT' -Login $login -PlanKnown:$known }
        '3' { Invoke-ReclaimAction $login }
        '4' {
            $script:Cli.Options['run'] = Read-Value -Prompt 'Run (id or LATEST)' -Default 'LATEST' -Pattern '^(LATEST|R?-?\d+)$' -Hint 'a run id such as 124, or LATEST'
            Invoke-SimpleScript 'report.sql' @(Get-RunArgument 'LATEST') $login
        }
        '5' { Invoke-SimpleScript 'status.sql' @() $login }
        '6' { Invoke-InstallAction }
        '7' { Invoke-InstallAction -Uninstall }
    }
}

function Invoke-Main {
    $script:Cli = Read-Arguments $script:CliArgs
    if ($script:Cli.Flags.ContainsKey('help') -or $script:Cli.Action -eq 'help') {
        Show-Help
        exit $script:ExitPass
    }
    if ($script:Cli.Flags.ContainsKey('no-color')) { $script:UseColor = $false }
    if ($script:Cli.Flags.ContainsKey('non-interactive')) { $script:Interactive = $false }

    $configPath = Join-Path $script:SrcDir 'config\epf_purge.conf'
    if ($script:Cli.Options.ContainsKey('config')) {
        $configPath = $script:Cli.Options['config']
        if (-not (Test-Path -LiteralPath $configPath)) { Exit-Tool $script:ExitUsage ('Configuration file not found: ' + $configPath) }
    }
    if (Test-Path -LiteralPath $configPath) { $script:Config = Read-ConfigFile $configPath }
    if (Test-ConfigYes 'NO_COLOR') { $script:UseColor = $false }
    $timeout = Get-Option 'connect-timeout' 'CONNECT_TIMEOUT_S' ''
    if ($timeout -ne '') {
        $seconds = Test-Value $timeout -Min 10 -Max 3600
        if ($null -eq $seconds) { Exit-Tool $script:ExitUsage ('CONNECT_TIMEOUT_S: a whole number of seconds from 10 to 3600, got ' + $timeout + '.') }
        $script:ConnectTimeoutS = [int]$seconds
    }

    if ($script:Cli.Flags.ContainsKey('reclaim')) {
        Exit-Tool $script:ExitUsage '--reclaim is not available in this version: run epf_purge.bat reclaim after the purge.'
    }
    if ($script:Cli.Flags.ContainsKey('resume')) {
        Exit-Tool $script:ExitUsage '--resume is not needed: a new reclaim continues from the current state of the datafiles.'
    }
    if ($script:Cli.Options.ContainsKey('long-conversion')) {
        Exit-Tool $script:ExitUsage '--long-conversion is not available in this version: tables with a LONG column stay where they are.'
    }

    $script:SqlPlus = Find-SqlPlus
    if ($null -eq $script:SqlPlus) { Exit-Tool $script:ExitUsage 'sqlplus.exe was not found in PATH or in ORACLE_HOME\bin.' }

    $action = $script:Cli.Action
    if ($script:Cli.Flags.ContainsKey('close') -and $action -ne 'plan') { Exit-Tool $script:ExitUsage '--close applies to plan.' }
    if ($null -ne $action -and $action -ne 'reclaim') {
        if ($script:Cli.Options.ContainsKey('tablespaces')) { Exit-Tool $script:ExitUsage '--tablespaces applies to reclaim.' }
        if ($script:Cli.Flags.ContainsKey('restore')) { Exit-Tool $script:ExitUsage '--restore applies to reclaim.' }
    }
    if ($script:Cli.Flags.ContainsKey('new') -and @('purge', 'preflight') -notcontains $action) {
        Exit-Tool $script:ExitUsage '--new applies to purge and preflight (the wizard''s menu offers to start over).'
    }
    if ($script:Cli.Options.ContainsKey('max-redo')) {
        if ($null -ne $action -and @('purge', 'preflight') -notcontains $action) {
            Exit-Tool $script:ExitUsage '--max-redo applies to preflight and to the wizard''s purge.'
        }
        if ($null -eq (ConvertTo-Bytes ([string]$script:Cli.Options['max-redo']))) {
            Exit-Tool $script:ExitUsage ('--max-redo: a size such as 500M or 20G, got ' + $script:Cli.Options['max-redo'] + '.')
        }
    }
    if ($null -eq $action) {
        if (-not $script:Interactive) { Exit-Tool $script:ExitUsage 'An action is required with --non-interactive.' }
        Start-Wizard
        return
    }
    switch ($action) {
        'purge'     { Invoke-PurgeAction 'PURGE' -Wizard:$script:Interactive }
        'preflight' { Invoke-PurgeAction 'PREFLIGHT' }
        'plan'      { Invoke-PlanAction }
        'report'    { Invoke-SimpleScript 'report.sql' @(Get-RunArgument 'LATEST') }
        'status'    { Invoke-SimpleScript 'status.sql' @() }
        'stop'      { Invoke-SimpleScript 'stop.sql' @(Get-RunArgument 'ACTIVE') }
        'install'   { Invoke-InstallAction }
        'uninstall' { Invoke-InstallAction -Uninstall }
        'reclaim'   { Invoke-ReclaimAction }
        default     { Exit-Tool $script:ExitUsage ('Unknown action ' + $action + '. See epf_purge.bat --help.') }
    }
}

try {
    Invoke-Main
} catch {
    Write-Out (' Error: ' + $_.Exception.Message) 'Red'
    exit $script:ExitAborted
} finally {
    Stop-Children
}

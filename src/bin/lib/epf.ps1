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
# in red, warnings in yellow, a passing verdict in green.
function Show-Lines {
    param([string]$Text, [switch]$Indent)
    $lines = @($Text -split "`r?`n")
    $last = $lines.Count - 1
    while ($last -ge 0 -and $lines[$last].Trim() -eq '') { $last-- }
    for ($i = 0; $i -le $last; $i++) {
        $line = $lines[$i].TrimEnd()
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
  preflight    read-only checks and estimates; changes nothing
  report       report of a run                          --run <id|LATEST>
  status       state of the active or latest run, pending temporary indexes,
               undo tuning and locked accounts
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
                       nothing is deleted
  --backup CHOICE      when no recent RMAN backup is found: confirmed (a backup
                       was made another way) or none (purge without a backup)
  --confirm LIST       requirements the DBA confirms are handled although the
                       preflight finds them not met: ARCHIVE, UNDO, TEMP
                       separated by commas
  --compact            shrink the purged tables afterwards (purge only)
  --redo-logs          enlarge the online redo logs first (4 x 1 GB,
                       permanent; SYS)
  --undo-tuning        lower undo_retention and limit undo growth (4 GB by
                       default) for the purge; restored at the end (SYS).
                       With preflight or --dry-run: checked as planned, nothing
                       is applied
  --run ID             run for report (default LATEST) and stop (default:
                       the active run); 124 or R-000124
  --yes                skip the final confirmation (required with
                       --non-interactive for a purge that deletes, and for
                       uninstall)
  --non-interactive    never prompt; missing input is an error (exit 4)
  --log-dir DIR        run folders (default: logs in the tool folder)
  --no-color           plain output
  --help

Requirements
  Before a purge the preflight checks six requirements: archive space, undo,
  TEMP, index space, redo logs and backup. The report lists each one with the
  ways to meet it. A purge does not start while a blocking one (archive, undo,
  TEMP, backup) is not met: meet it and run again, or use --backup, --confirm
  or --undo-tuning. A dry run simulates the purge and predicts its outcome.

Environment
  EPF_PASSWORD         EPFPG password
  EPF_SYS_PASSWORD     SYS password (install, uninstall, --redo-logs,
                       --undo-tuning)

While a run is shown, Ctrl+C requests a graceful stop: the purge stops after
its current batch and the run ends with its report.

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
                      'log-dir', 'run', 'tablespaces', 'long-conversion')
    $flagOptions = @('dry-run', 'compact', 'redo-logs', 'undo-tuning', 'yes', 'non-interactive', 'no-color',
                     'help', 'reclaim', 'resume')
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

# Connection test (the only statement the wrapper sends itself): container
# name and, for EPFPG, the installed tool version.
function Test-DbConnection {
    param($Login, [switch]$WithVersion)
    $process = Start-SqlProcess
    $in = $process.StandardInput
    $in.WriteLine('SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF')
    $in.WriteLine((Get-ConnectLine $Login))
    if ($WithVersion) {
        $in.WriteLine("SELECT 'EPF_CONNECTED|' || SYS_CONTEXT('USERENV', 'CON_NAME') || '|' || value || '|' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') FROM epfpg.epf_setting WHERE name = 'tool_version';")
    } else {
        $in.WriteLine("SELECT 'EPF_CONNECTED|' || SYS_CONTEXT('USERENV', 'CON_NAME') || '||' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') FROM dual;")
    }
    $in.WriteLine('EXIT')
    $in.Close()
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $text = $out.Result + $err.Result
    $received = Get-Date
    foreach ($line in ($text -split "`r?`n")) {
        if ($line -match '^EPF_CONNECTED\|([^|]*)\|([^|]*)\|(.*)$') {
            $container = $Matches[1]
            $version = $Matches[2].Trim()
            $dbTime = [datetime]::ParseExact($Matches[3].Trim(), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            # Database clock minus this machine's clock, to the minute.
            $script:ClockOffset = [TimeSpan]::FromMinutes([Math]::Round(($dbTime - $received).TotalMinutes))
            return [pscustomobject]@{ Ok = $true; Container = $container; Version = $version; Output = $text }
        }
    }
    return [pscustomobject]@{ Ok = $false; Container = ''; Version = ''; Output = $text }
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

# Runs one entry script in its own sqlplus session and waits for it. With a
# run state, the live view is refreshed every 2 seconds meanwhile and Ctrl+C
# requests a graceful stop. The raw output goes to $LogName in the run folder.
function Invoke-SqlScript {
    param($Login, [string]$Script, [string[]]$Arguments = @(), $State = $null, [string]$LogName = '')
    $process = Start-SqlProcess
    $in = $process.StandardInput
    $in.WriteLine((Get-ConnectLine $Login))
    $in.WriteLine((Get-ScriptLine $Script $Arguments))
    $in.WriteLine('EXIT 9')
    $in.Close()
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit(2000)) {
        if ($null -ne $State) {
            Test-StopKey $State
            Update-LiveView $State
        }
    }
    $process.WaitForExit()
    $text = $out.Result + $err.Result
    $code = $process.ExitCode
    if ($code -eq 0 -and (Test-SessionFailure $text)) { $code = $script:ExitFail }
    if ($LogName -ne '' -and $null -ne $State -and $null -ne $State.Folder) {
        [System.IO.File]::WriteAllText((Join-Path $State.Folder $LogName), $text, [System.Text.Encoding]::ASCII)
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

# The monitor: one sqlplus session kept open for the whole run. It creates
# (or attaches) the run and so holds the run lock, polls the live view and
# ends the run.
function Open-Monitor {
    param($Login)
    $process = Start-SqlProcess
    $process.StandardInput.WriteLine((Get-ConnectLine $Login))
    $errors = $process.StandardError.ReadToEndAsync()
    return [pscustomobject]@{ Process = $process; Pending = $null; Errors = $errors }
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
        $State.Monitor = Open-Monitor $State.Cred
        try {
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
            Write-Out ' Stop already requested; the run stops after the current batch.' 'Yellow'
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

# Runs PREFLIGHT or PURGE as one run: the monitor creates the run and holds its
# lock; worker sessions run the steps while the monitor shows them live; the
# monitor ends the run with the report's verdict; the report goes to the
# console and to the run folder. SYS steps (redo logs, undo tuning) run in
# their own sessions; undo tuning is restored on every exit path.
function Invoke-ToolRun {
    param($Ctx, [string]$Action)
    $state = [pscustomobject]@{
        Cred = $Ctx.Cred; Monitor = $null; RunId = [long]0; LastEvent = [long]0; LastOutput = (Get-Date);
        RunStatus = ''; Folder = $null; Live = $true; StopKeys = $false; StopRequested = $false; Started = (Get-Date)
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

    # Undo tuning is planned for the run (the preflight checks the
    # requirements with it); only a purge that deletes applies it.
    $undo = 'N'
    if ($Ctx.UndoTuning) { $undo = 'Y' }
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

    $state.Monitor = Open-Monitor $Ctx.Cred
    $begin = @($Action, $retentionArg, $Ctx.Depth, $Ctx.Mode, $batchArg, $dry, 'N', $compact, $undo, $backupArg,
               $cutoffArg, $confirmArg)
    try {
        $lines = Invoke-MonitorCommand $state.Monitor (Get-ScriptLine (Join-Path $script:RunSqlDir 'begin_run.sql') $begin) 120000
    } catch {
        # No run was created (or none is known): end the session, then show
        # the tool's sessions and runs as the database sees them.
        Write-Out (' ' + $_.Exception.Message) 'Red'
        try { $state.Monitor.Process.Kill() } catch { Write-Out (' ' + $_.Exception.Message) 'Yellow' }
        Write-Out ' State of the tool in the database (status):' 'Yellow'
        $diagnosis = Invoke-SqlScript $Ctx.Cred (Join-Path $script:RunSqlDir 'status.sql') @()
        Show-Lines $diagnosis.Output -Indent
        Exit-Tool $script:ExitFail 'The run could not be created: the monitor session did not answer.'
    }
    foreach ($line in $lines) {
        if ($line -match '^EPF_RUN_ID=(\d+)$') { $state.RunId = [long]$Matches[1] }
    }
    if ($state.RunId -eq 0) {
        Show-Lines ($lines -join "`n") -Indent
        Close-Monitor $state.Monitor
        # The tool's own refusals (ORA-20xxx: parameters, another active run)
        # are usage errors; anything else is a failure.
        $code = $script:ExitFail
        if (($lines -join "`n") -match 'ORA-20\d{3}') { $code = $script:ExitUsage }
        Exit-Tool $code 'The run could not be created (see the messages above).'
    }
    $label = Get-RunLabel $state.RunId
    $state.Folder = New-RunFolder $state.RunId

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
    $choices = @()
    if ($Ctx.UndoTuning) { $choices += 'undo tuning' }
    if ($Ctx.Backup -ne '') { $choices += ('backup ' + $Ctx.Backup.ToLower()) }
    if ($Ctx.Confirm -ne '') { $choices += ('confirmed ' + $Ctx.Confirm) }
    if ($choices.Count -gt 0) { Write-Out (' Choices    ' + ($choices -join ', ')) }

    $status = 'FAILED'
    $undoApplied = $false
    $closeCode = $null
    $state.StopKeys = Enable-StopKey
    if ($state.StopKeys) { Write-Out ' Ctrl+C requests a graceful stop.' -NoLog }
    try {
        if ($Action -eq 'PURGE' -and $Ctx.RedoLogs) {
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
        try {
            if (-not $state.Live) {
                Reset-Monitor $state
                $state.Live = $true
            }
            Update-LiveView $state
            $finish = Get-ScriptLine (Join-Path $script:RunSqlDir 'finish.sql') @([string]$state.RunId, $status)
            $lines = Invoke-MonitorCommand $state.Monitor $finish 600000
            foreach ($line in $lines) {
                if ($line -match '^EPF_EXIT=(\d+)$') { $closeCode = [int]$Matches[1] }
            }
            if ($null -eq $closeCode) { Show-Lines ($lines -join "`n") -Indent }
            Update-LiveView $state
        } catch {
            Write-Out (' The run could not be ended: ' + $_.Exception.Message) 'Red'
        }
        Close-Monitor $state.Monitor
    }

    Write-Section 'REPORT'
    $report = Invoke-SqlScript $Ctx.Cred (Join-Path $script:RunSqlDir 'report.sql') @([string]$state.RunId)
    [System.IO.File]::WriteAllText((Join-Path $state.Folder 'report.txt'), $report.Output, [System.Text.Encoding]::ASCII)
    Show-Lines $report.Output

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
    return [pscustomobject]@{ RunId = $state.RunId; ExitCode = $exitCode; Status = $status; Folder = $state.Folder }
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

function Connect-Tool {
    $tns = Get-Tns
    $secret = Read-Secret -Prompt 'EPFPG password' -EnvName 'EPF_PASSWORD' -ConfigKey 'EPF_PASSWORD'
    $login = New-Login -User 'epfpg' -Secret $secret -Tns $tns
    $test = Test-DbConnection $login -WithVersion
    if (-not $test.Ok) {
        Show-Lines $test.Output -Indent
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
    if (-not $test.Ok) {
        Show-Lines $test.Output -Indent
        Exit-Tool $script:ExitUsage 'The connection as SYS failed.'
    }
    if ($test.Container -eq 'CDB$ROOT') { Exit-Tool $script:ExitUsage 'Connected to CDB$ROOT: use the PDB service.' }
    if ($null -eq $script:Database) { $script:Database = [pscustomobject]@{ Container = $test.Container; Version = '-' } }
    return $sys
}

function Get-PurgeContext {
    param($Login, [string]$Action)
    $ctx = [pscustomobject]@{
        Cred = $Login; SysCred = $null; Retention = ''; Cutoff = ''; Depth = ''; Mode = ''; BatchSize = '';
        DryRun = $false; Compact = $false; RedoLogs = $false; UndoTuning = $false; Backup = ''; Confirm = '';
        PreflightRun = ''
    }
    if ($Action -ne 'PURGE') {
        foreach ($name in @('dry-run', 'compact', 'redo-logs')) {
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
    if ($cutoff -ne '') {
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
    $ctx.Mode = Get-Input -Name 'mode' -Key 'MODE' -Prompt 'Mode (FULL, CLOB, LOGS, CLOB_N_LOGS)' -Default 'FULL' -Allowed $script:Modes
    if ($ctx.Mode -eq 'LOGS') {
        $ctx.Depth = 'LOGS'
    } else {
        $ctx.Depth = (Get-Input -Name 'depth' -Key 'DEPTH' -Prompt 'Depth (ALL, or modules such as PAYMENTS,LOGS,BANK_STATEMENTS)' `
                                -Default 'ALL' -Pattern '^[A-Z_]+(,[A-Z_]+)*$' -Hint 'ALL, or module names separated by commas').ToUpper()
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
            foreach ($name in @('compact', 'redo-logs')) {
                if ($script:Cli.Flags.ContainsKey($name)) { Exit-Tool $script:ExitUsage ('--' + $name + ' does not apply to a dry run.') }
            }
        } else {
            $ask = $script:Interactive -and -not $script:Cli.Flags.ContainsKey('compact')
            $ctx.Compact = Get-Choice 'compact' 'COMPACT' 'Compact the purged tables afterwards (returns the freed space to the tablespace)' -Ask:$ask
            $ctx.RedoLogs = Get-Choice 'redo-logs' 'REDO_LOGS' ''
        }
    }
    # Applied by a purge that deletes; a preflight or dry run checks the
    # requirements as if it were applied.
    $ctx.UndoTuning = Get-Choice 'undo-tuning' 'UNDO_TUNING' ''
    return $ctx
}

# Wizard step: a read-only PREFLIGHT run with the chosen parameters. Its
# findings (recommended batch size, redo and undo warnings) set the defaults of
# the remaining questions, and the purge run refers to it instead of running
# the same checks again.
function Get-Advice {
    param($Ctx)
    $run = Invoke-ToolRun $Ctx 'PREFLIGHT'
    $script:LogFile = $null
    $advice = Read-Advice $Ctx.Cred $run.RunId
    $advice['Run'] = $run
    return $advice
}

# EPF_ADVICE lines of a run (advice.sql): single values by name, and the
# requirements in Req (code -> Status, Blocking, MetBy).
function Read-Advice {
    param($Cred, [long]$RunId)
    $advice = @{ BATCH_SIZE = ''; REDO_PER_ROOT = ''; REDO_WARN = 'N'; UNDO_WARN = 'N'; UNDO_ACTIVE = 'N'; ERRORS = '0';
                 WARNINGS = '0'; READY = '-'; UNDO_MAX_BATCH = '' }
    $requirements = [ordered]@{}
    $result = Invoke-SqlScript $Cred (Join-Path $script:RunSqlDir 'advice.sql') @([string]$RunId)
    foreach ($line in ($result.Output -split "`r?`n")) {
        if ($line -match '^EPF_ADVICE\|REQ\|([A-Z_]+)\|([A-Z_]+)\|([YN])\|(.*)$') {
            $requirements[$Matches[1]] = [pscustomobject]@{ Status = $Matches[2]; Blocking = $Matches[3]; MetBy = $Matches[4].Trim() }
        } elseif ($line -match '^EPF_ADVICE\|([A-Z_]+)\|([^|]*)$') {
            $advice[$Matches[1]] = $Matches[2].Trim()
        }
    }
    $advice['Req'] = $requirements
    return $advice
}

# Blocking requirements not met, in the preflight's order.
function Get-Unmet {
    param($Advice)
    $codes = @()
    foreach ($code in $Advice.Req.Keys) {
        $item = $Advice.Req[$code]
        if ($item.Status -eq 'NOT_MET' -and $item.Blocking -eq 'Y') { $codes += $code }
    }
    return ,$codes
}

# Wizard, after the preflight: the blocking requirements it found not met.
# BACKUP: a backup made another way, or none. ARCHIVE, UNDO, TEMP: the DBA
# confirms them as handled, or the wizard stops so they can be met first (a
# new preflight then checks them again). UNDO is left to the purge's own
# preflight when undo tuning was chosen.
function Resolve-Requirements {
    param($Ctx, $Advice)
    $requirements = $Advice.Req
    if ($requirements.Count -eq 0) { return }
    if ($requirements.Contains('BACKUP') -and $requirements['BACKUP'].Status -eq 'NOT_MET' -and $Ctx.Backup -eq '') {
        Write-Out ''
        Write-Out ' No recent database backup was found (BACKUP above). A purge cannot be undone.' 'Yellow'
        Write-Out '   1  Stop here: take a backup, then run the purge again'
        Write-Out '   2  A backup was made another way (storage snapshot, export)'
        Write-Out '   3  Purge without a backup'
        $answer = Read-Value -Prompt 'Backup' -Default '1' -Allowed @('1', '2', '3')
        switch ($answer) {
            '1' { Exit-Tool $script:ExitAborted 'Stopped: take a backup, then run the purge again.' }
            '2' { $Ctx.Backup = 'CONFIRMED' }
            '3' { $Ctx.Backup = 'NONE' }
        }
    }
    foreach ($code in @('ARCHIVE', 'UNDO', 'TEMP')) {
        if (-not $requirements.Contains($code) -or $requirements[$code].Status -ne 'NOT_MET') { continue }
        if ($code -eq 'UNDO' -and $Ctx.UndoTuning) { continue }
        if ((',' + $Ctx.Confirm + ',').Contains(',' + $code + ',')) { continue }
        Write-Out ''
        Write-Out (' Requirement ' + $code + ' is not met: REQUIREMENTS above shows why and the ways to meet it.') 'Yellow'
        Write-Out '   1  Stop here: meet it, then run the purge again (its preflight checks again)'
        Write-Out '   2  The DBA confirms it is handled: purge anyway'
        $answer = Read-Value -Prompt $code -Default '1' -Allowed @('1', '2')
        if ($answer -eq '1') { Exit-Tool $script:ExitAborted ('Stopped: meet ' + $code + ', then run the purge again.') }
        if ($Ctx.Confirm -eq '') { $Ctx.Confirm = $code } else { $Ctx.Confirm = $Ctx.Confirm + ',' + $code }
    }
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
    } else {
        Write-Out '  Dry run       no'
        Write-Out ('  Compact       ' + (Get-YN $Ctx.Compact))
        Write-Out ('  Redo logs     ' + (Get-YN $Ctx.RedoLogs) + '   (enlarge to 4 x 1 GB before the purge; permanent)')
        Write-Out ('  Undo tuning   ' + (Get-YN $Ctx.UndoTuning) + '   (undo_retention lowered and undo growth limited for the purge, restored at the end)')
        Write-Out ('  Backup        ' + $backupText)
        if ($Ctx.Confirm -ne '') { Write-Out ('  Confirmed     ' + $Ctx.Confirm + '   (handled by the DBA although the preflight finds them not met)') }
    }
    if ($Ctx.PreflightRun -ne '') { Write-Out ('  Preflight     ' + $Ctx.PreflightRun + ' (the purge checks the requirements again with these choices)') }
}

# ----------------------------------------------------------------------------
# Actions
# ----------------------------------------------------------------------------

function Invoke-PurgeAction {
    param([string]$Action, [switch]$Wizard)
    $login = Connect-Tool
    $ctx = Get-PurgeContext $login $Action

    if ($Action -eq 'PURGE' -and $Wizard) {
        Write-Section 'CHECKING THE DATABASE (read-only preflight)'
        $advice = Get-Advice $ctx
        $ctx.PreflightRun = Get-RunLabel $advice.Run.RunId
        if ($advice.ERRORS -ne '0' -or $advice.Run.ExitCode -eq $script:ExitFail) {
            Exit-Tool $script:ExitFail ('The preflight ' + $ctx.PreflightRun + ' found errors (see the report above); nothing was changed.')
        }
        if (-not $ctx.DryRun) {
            if ($advice.REDO_WARN -eq 'Y' -and -not $ctx.RedoLogs) {
                Write-Out ' One batch writes more redo than half of the smallest online redo log (REDO_SUMMARY above).' 'Yellow'
                $ctx.RedoLogs = Read-YesNo 'Enlarge the online redo logs to 4 x 1 GB before the purge (SYS, permanent)' $true
            }
            if ($advice.UNDO_ACTIVE -eq 'Y' -and -not $ctx.UndoTuning) {
                Write-Out ' Undo tuning from an earlier run is still active.' 'Yellow'
                $ctx.UndoTuning = Read-YesNo 'Keep it for this purge and restore it at the end (SYS)' $true
            } elseif ($advice.UNDO_WARN -eq 'Y' -and -not $ctx.UndoTuning) {
                Write-Out ' The undo tablespace is expected to grow during the purge (UNDO_ESTIMATE above).' 'Yellow'
                $ctx.UndoTuning = Read-YesNo 'Lower undo_retention and limit undo growth for the purge, restored at the end (SYS)' $true
            }
            Resolve-Requirements $ctx $advice
        }
        if ($ctx.BatchSize -eq '') {
            $default = 1000
            $recommended = 0
            $perRoot = [double]0
            if ($ctx.RedoLogs -and [double]::TryParse($advice.REDO_PER_ROOT, [ref]$perRoot) -and $perRoot -gt 0) {
                $default = Get-BatchForLog $perRoot 1073741824
                Write-Out (' Recommended batch size with 1 GB online logs: ' + $default + ' root rows.')
            } elseif ([int]::TryParse($advice.BATCH_SIZE, [ref]$recommended) -and $recommended -gt 0) {
                $default = [Math]::Min(100000, [Math]::Max(100, $recommended))
                Write-Out (' Recommended batch size: ' + $default + ' root rows (REDO_SUMMARY above).')
            }
            # Requirement UNDO: the undo tablespace holds 4 batches.
            $undoMax = 0
            if ([int]::TryParse($advice.UNDO_MAX_BATCH, [ref]$undoMax) -and $undoMax -gt 0 -and $undoMax -lt $default) {
                $default = [Math]::Max(100, [int]([Math]::Floor($undoMax / 100) * 100))
                Write-Out (' Batch size limited to ' + $default + ' root rows: the undo tablespace holds 4 batches of that size (UNDO above).')
            }
            $ctx.BatchSize = Read-Value -Prompt 'Batch size (root rows per transaction)' -Default ([string]$default) -Min 100 -Max 100000
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
    param([string]$Script, [string[]]$Arguments)
    $login = Connect-Tool
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

function Start-Wizard {
    Write-Out ''
    Write-Out ' EPF Data Purge' 'White'
    Write-Out (' ' + ('-' * ($script:Width - 1)))
    Write-Out '  1  Purge'
    Write-Out '  2  Preflight only (read-only)'
    Write-Out '  3  Report of a run'
    Write-Out '  4  Status'
    Write-Out '  5  Install or upgrade (SYS)'
    Write-Out '  6  Uninstall (SYS)'
    $choice = Read-Value -Prompt 'Choice' -Default '1' -Allowed @('1', '2', '3', '4', '5', '6')
    switch ($choice) {
        '1' { Invoke-PurgeAction 'PURGE' -Wizard }
        '2' { Invoke-PurgeAction 'PREFLIGHT' }
        '3' {
            $script:Cli.Options['run'] = Read-Value -Prompt 'Run (id or LATEST)' -Default 'LATEST' -Pattern '^(LATEST|R?-?\d+)$' -Hint 'a run id such as 124, or LATEST'
            Invoke-SimpleScript 'report.sql' @(Get-RunArgument 'LATEST')
        }
        '4' { Invoke-SimpleScript 'status.sql' @() }
        '5' { Invoke-InstallAction }
        '6' { Invoke-InstallAction -Uninstall }
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

    foreach ($name in @('reclaim', 'resume')) {
        if ($script:Cli.Flags.ContainsKey($name)) { Exit-Tool $script:ExitUsage ('--' + $name + ' is not available in this version.') }
    }
    foreach ($name in @('tablespaces', 'long-conversion')) {
        if ($script:Cli.Options.ContainsKey($name)) { Exit-Tool $script:ExitUsage ('--' + $name + ' is not available in this version.') }
    }

    $script:SqlPlus = Find-SqlPlus
    if ($null -eq $script:SqlPlus) { Exit-Tool $script:ExitUsage 'sqlplus.exe was not found in PATH or in ORACLE_HOME\bin.' }

    $action = $script:Cli.Action
    if ($null -eq $action) {
        if (-not $script:Interactive) { Exit-Tool $script:ExitUsage 'An action is required with --non-interactive.' }
        Start-Wizard
        return
    }
    switch ($action) {
        'purge'     { Invoke-PurgeAction 'PURGE' -Wizard:$script:Interactive }
        'preflight' { Invoke-PurgeAction 'PREFLIGHT' }
        'report'    { Invoke-SimpleScript 'report.sql' @(Get-RunArgument 'LATEST') }
        'status'    { Invoke-SimpleScript 'status.sql' @() }
        'stop'      { Invoke-SimpleScript 'stop.sql' @(Get-RunArgument 'ACTIVE') }
        'install'   { Invoke-InstallAction }
        'uninstall' { Invoke-InstallAction -Uninstall }
        'reclaim'   { Exit-Tool $script:ExitUsage 'The reclaim action is not available in this version.' }
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

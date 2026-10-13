# ============================================================================
# EPF Data Purge - simulator of the wrapper's screens and questions
# ============================================================================
# Purpose : Plays the flow proposed for the wrapper (get ready, check, ask,
#           run, report) with scripted figures, to try its questions and its
#           screens before they are built. It connects to nothing and changes
#           nothing: every figure comes from this file.
# Usage   : epf_sim.bat [action] [options]
#             (none)            the menu
#             purge             a purge; --dry-run simulates it only
#             reclaim           a reclaim; --dry-run assesses only
#             report | status | uninstall | help
#           Options
#             --dry-run         nothing is changed (shown as such)
#             --retention DAYS  the days of data kept: older rows are purged;
#                               or --cutoff YYYY-MM-DD
#             --tns NAME        the database, by its alias; asked for when it
#                               is not given
#             --redo-logs       larger online redo logs for the purge, without
#                               the question
#             --non-interactive no question is asked: one command that a
#                               scheduler of the user's can run
#             --config FILE     TNS, EPF_PASSWORD, SYS_PASSWORD, RETENTION_DAYS
#                               or CUTOFF, REDO_LOGS, UNINSTALL_AFTER as
#                               KEY=VALUE
#             --sim STATE       the state the database is found in:
#                               slow (default: small online logs, optional),
#                               ready, nobackup, blocked (no room in TEMP),
#                               firstrun (tool not installed), compact
#                               (reclaim: nothing to give back), fail (the
#                               connection is lost during the run)
#             --fast            no pauses
#             --no-open         the HTML report is written, not opened
#             --no-color
# Requires: Windows PowerShell 5.1. No database, no sqlplus.
# Output  : logs\sim\<yyyy-MM-dd_HHmmss>_<run>\report.html
# ============================================================================

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CliArgs = @($args)
$script:RepoDir = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
$script:Version = '0.9.6'
$script:Inv = [Globalization.CultureInfo]::InvariantCulture
$script:Opt = @{ Action = ''; DryRun = $false; Cutoff = ''; Retention = ''; Tns = ''; Interactive = $true;
                 Config = ''; Sim = 'slow'; Fast = $false; Open = $true; Color = $true; Yes = $false; Redo = $false }
# The online redo logs are enlarged for this purge (the question, --redo-logs
# or REDO_LOGS=Y).
$script:RedoApplied = $false
$script:Conf = @{}
$script:Live = $true
try { $script:Live = -not [Console]::IsOutputRedirected } catch { $script:Live = $false }
$script:Dir = '/files2/oradata19/'
$script:Run = 0

# ----------------------------------------------------------------------------
# Output and questions
# ----------------------------------------------------------------------------

function Out-Line {
    param([string]$Text = '', [string]$Color = '')
    if ($script:Opt.Color -and $Color -ne '') { Write-Host $Text -ForegroundColor $Color } else { Write-Host $Text }
}

function Wait-Sim {
    param([double]$Seconds)
    if (-not $script:Opt.Fast) { Start-Sleep -Milliseconds ([int]($Seconds * 1000)) }
}

function Format-Int {
    param([double]$Value)
    return [string]::Format($script:Inv, '{0:N0}', [Math]::Round($Value))
}

function Format-Gb {
    param([double]$Gb)
    if ($Gb -lt 1) { return [string]::Format($script:Inv, '{0:N0} MB', [Math]::Round($Gb * 1024)) }
    return [string]::Format($script:Inv, '{0:N1} GB', $Gb)
}

function Format-Time {
    param([double]$Seconds)
    $s = [int][Math]::Round($Seconds)
    if ($s -ge 3600) { return ('{0}:{1:00}:{2:00}' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60), ($s % 60)) }
    return ('{0}:{1:00}' -f [Math]::Floor($s / 60), ($s % 60))
}

# "about 8 minutes", "about 50 minutes", "about 1 h 20 min".
function Format-About {
    param([double]$Seconds)
    $m = [int][Math]::Max(1, [Math]::Round($Seconds / 60))
    if ($m -ge 90) { return ('about ' + [Math]::Floor($m / 60) + ' h ' + ($m % 60) + ' min') }
    if ($m -eq 1) { return 'about 1 minute' }
    return ('about ' + $m + ' minutes')
}

function Read-Answer {
    param([string]$Prompt, [string]$Default = '')
    if (-not $script:Opt.Interactive) { return $Default }
    $label = ' ' + $Prompt
    if ($Default -ne '') { $label = $label + ' [' + $Default + ']' }
    $answer = Read-Host -Prompt $label
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer.Trim()
}

# A yes or no question. Without questions (--non-interactive) the answer is
# $Auto: what a scheduled run does.
function Read-YesNo {
    param([string]$Prompt, [bool]$Default, [bool]$Auto)
    if (-not $script:Opt.Interactive) { return $Auto }
    $d = 'N'
    if ($Default) { $d = 'Y' }
    while ($true) {
        $a = (Read-Answer ($Prompt + ' (Y/N)') $d).ToUpper()
        if ($a -eq 'Y' -or $a -eq 'YES') { return $true }
        if ($a -eq 'N' -or $a -eq 'NO') { return $false }
        Out-Line '   Y or N.' 'Yellow'
    }
}

# A password: from the configuration file or the environment, otherwise asked
# for (any answer does: nothing is connected).
function Read-Password {
    param([string]$Prompt, [string]$Key)
    if ($script:Conf.ContainsKey($Key) -and $script:Conf[$Key] -ne '') {
        Out-Line ('   ' + $Prompt + ': from the configuration file') 'DarkGray'
        return
    }
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($Key))) {
        Out-Line ('   ' + $Prompt + ': from the environment (' + $Key + ')') 'DarkGray'
        return
    }
    if (-not $script:Opt.Interactive) {
        Out-Line (' ' + $Prompt + ' is needed: set ' + $Key + ' in the configuration file or the environment for a run without questions.') 'Red'
        exit 4
    }
    $null = Read-Host -Prompt (' ' + $Prompt)
}

function Out-Rule { Out-Line (' ' + ('=' * 79)) 'White' }

# A text wrapped at 78 columns: its first line after $First, the others
# under it, or indented by $Indent.
function Out-Wrapped {
    param([string]$First, [string]$Text, [string]$Color = '', [int]$Indent = -1)
    $pad = ' ' * $First.Length
    if ($Indent -ge 0) { $pad = ' ' * $Indent }
    $line = $First
    foreach ($word in ($Text -split ' ')) {
        if ($line.Length + $word.Length + 1 -gt 80 -and $line.Trim() -ne '') {
            Out-Line $line.TrimEnd() $Color
            $line = $pad
        }
        $line = $line + $word + ' '
    }
    if ($line.Trim() -ne '') { Out-Line $line.TrimEnd() $Color }
}

function Out-Head {
    param([string]$What)
    $left = ' EPF Data Purge ' + $script:Version
    $right = $script:Opt.Tns + ' . ' + $What
    Out-Line ''
    Out-Line ($left + $right.PadLeft([Math]::Max(1, 80 - $left.Length))) 'White'
    Out-Line (' ' + ('-' * 79))
    Out-Line ' SIMULATION: no database is touched; every figure is scripted.' 'Magenta'
}

# The line of a step: " 2 of 4  Protecting the undo tablespace      done   0:02".
function Out-Step {
    param([int]$N, [int]$Of, [string]$Text, [string]$State, [string]$Time = '')
    $line = (' ' + $N + ' of ' + $Of + '  ' + $Text).PadRight(66) + $State.PadRight(7) + $Time.PadLeft(6)
    $color = 'Green'
    if ($State -eq 'waiting') { $color = 'DarkGray' }
    if ($State -eq '') { $color = 'White' }
    if ($State -eq 'FAILED') { $color = 'Red' }
    Out-Line $line $color
}

# A step that takes a moment: its line is shown as running, then done.
function Invoke-Step {
    param([int]$N, [int]$Of, [string]$Text, [double]$Seconds, [double]$Pause = 1.2)
    if ($script:Live) { [Console]::Write((' ' + $N + ' of ' + $Of + '  ' + $Text).PadRight(66) + 'running') }
    Wait-Sim $Pause
    if ($script:Live) { [Console]::Write("`r" + (' ' * 79) + "`r") }
    Out-Step $N $Of $Text 'done' (Format-Time $Seconds)
}

function Get-Bar {
    param([double]$Pct, [int]$Width = 20)
    $full = [int][Math]::Floor($Width * [Math]::Min(100, $Pct) / 100)
    return '[' + ('#' * $full) + ('.' * ($Width - $full)) + ']'
}

# A line rewritten in place while something progresses, then left as done.
function Show-Progress {
    param([string]$Label, [double]$Total, [string]$Unit, [double]$Seconds, [double]$Rate, [int]$Ticks = 12)
    for ($i = 1; $i -le $Ticks; $i++) {
        $pct = 100.0 * $i / $Ticks
        $left = $Seconds * ($Ticks - $i) / $Ticks
        $text = '         ' + $Label.PadRight(16) + ' ' + (Get-Bar $pct) + ' ' + ('{0,3}%' -f [int]$pct) + '   ' +
                (Format-Int ($Total * $i / $Ticks)) + ' of ' + (Format-Int $Total) + ' ' + $Unit
        if ($Rate -gt 0) { $text = $text + ' . ' + (Format-Int $Rate) + ' rows a second' }
        $text = $text + ' . ' + (Format-Time $left) + ' left'
        if ($script:Live) { [Console]::Write("`r" + $text.PadRight(118).Substring(0, 118)) }
        Wait-Sim 0.35
    }
    if ($script:Live) { [Console]::Write("`r" + (' ' * 118) + "`r") }
    Out-Line ('         ' + $Label.PadRight(16) + ' ' + (Get-Bar 100) + ' 100%   ' + (Format-Int $Total).PadLeft(11) + ' ' + $Unit + '   ' + (Format-Time $Seconds).PadLeft(7)) 'Green'
}

# ----------------------------------------------------------------------------
# The scripted database (set Q's figures: SONEPARUAT, DATA 41.7 GB)
# ----------------------------------------------------------------------------

# Rows older than $Days days, between scripted points: 365 days gives the
# purge of set Q.
function Get-RowsOlder {
    param([double]$Days)
    $points = @(@(4000, 0), @(565, 15604000), @(365, 19279194), @(165, 24112000), @(30, 41870000), @(0, 96248377))
    $prev = $points[0]
    foreach ($p in $points) {
        if ($Days -ge $p[0]) {
            if ($p[0] -eq $prev[0]) { return [double]$p[1] }
            return [double]$prev[1] + ([double]$p[1] - [double]$prev[1]) * ($prev[0] - $Days) / ($prev[0] - $p[0])
        }
        $prev = $p
    }
    return [double]$points[$points.Count - 1][1]
}

function Get-Scope {
    $today = [datetime]::ParseExact('2026-10-13', 'yyyy-MM-dd', $script:Inv)
    $cutoff = $script:Opt.Cutoff
    $days = $script:Opt.Retention
    if ($cutoff -eq '' -and $days -eq '') {
        if ($script:Conf.ContainsKey('CUTOFF')) { $cutoff = $script:Conf['CUTOFF'] }
        elseif ($script:Conf.ContainsKey('RETENTION_DAYS')) { $days = $script:Conf['RETENTION_DAYS'] }
    }
    while ($cutoff -eq '' -and $days -eq '') {
        $a = Read-Answer 'Days of data to keep; older rows are purged (or a date as YYYY-MM-DD)' '30'
        if ($a -match '^\d{4}-\d\d-\d\d$') { $cutoff = $a } elseif ($a -match '^\d+$') { $days = $a }
        else { Out-Line '   A number of days such as 365, or a date such as 2025-10-13.' 'Yellow' }
    }
    $how = '--retention ' + $days
    if ($cutoff -ne '') { $how = '--cutoff ' + $cutoff }
    if ($cutoff -ne '') {
        $day = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($cutoff, 'yyyy-MM-dd', $script:Inv, [Globalization.DateTimeStyles]::None, [ref]$day)) {
            Out-Line (' --cutoff: a date as YYYY-MM-DD, got ' + $cutoff + '.') 'Red'
            exit 4
        }
    } else {
        $day = $today.AddDays(-[int]$days)
    }
    $kept = [int]($today - $day).TotalDays
    $rows = Get-RowsOlder $kept
    $scope = @{ Day = $day; Text = $day.ToString('d MMMM yyyy', $script:Inv); Iso = $day.ToString('yyyy-MM-dd'); Rows = $rows
                Kept = $kept; How = $how }
    $scope.Modules = @(
        @{ Name = 'PAYMENTS';        Rows = [Math]::Round($rows * 18218547 / 19279194); Share = 0.943 },
        @{ Name = 'LOGS';            Rows = [Math]::Round($rows * 125517 / 19279194); Share = 0.003 },
        @{ Name = 'BANK_STATEMENTS'; Rows = [Math]::Round($rows * 935130 / 19279194); Share = 0.054 })
    $scope.Gb = $rows * 390.0 / 1073741824
    $scope.Seconds = $rows * 0.0000255 + 60
    return $scope
}

# The requirements as the checks find them in state --sim.
function Get-Requirements {
    param([string]$Kind)
    $sim = $script:Opt.Sim
    $list = New-Object 'System.Collections.Generic.List[object]'
    if ($Kind -eq 'PURGE') {
        $list.Add(@{ Name = 'Undo space'; Need = 'required'; Met = $true; Now = 'the tool keeps undo under 4.0 GB during the purge' })
        if ($sim -eq 'blocked') {
            $list.Add(@{ Name = 'Temporary space'; Need = 'required'; Met = $false; Ask = $false
                         Now = 'the purge needs about 1.1 GB in TEMP; 200 MB is free and the file cannot grow'
                         Risk = 'the purge would stop with an error when TEMP is full (what it deleted until then stays deleted)'
                         Do = 'let ' + $script:Dir + $script:Opt.Tns + '/temp01.dbf grow, or add a temporary file (the DBA), then run again' })
        } else {
            $list.Add(@{ Name = 'Temporary space'; Need = 'required'; Met = $true; Now = 'about 1.1 GB needed, 3.0 GB free in TEMP' })
        }
        $list.Add(@{ Name = 'Room for the archived logs'; Need = 'required'; Met = $true; Now = 'NOARCHIVELOG: nothing is archived' })
        if ($sim -eq 'nobackup') {
            $list.Add(@{ Name = 'Backup'; Need = 'required'; Met = $false; Ask = $true
                         Now = 'no RMAN backup of this database is recorded'
                         Risk = 'a purge cannot be undone; a backup taken just before it is the only way back'
                         Do = 'take an RMAN backup; or answer the question below if a backup exists elsewhere or the data can be lost' })
        } else {
            $list.Add(@{ Name = 'Backup'; Need = 'required'; Met = $true; Now = 'RMAN backup of 12 October 2026, 02:00' })
        }
        $list.Add(@{ Name = 'Room for the temporary indexes'; Need = 'optional'; Met = $true; Now = '12 indexes, about 1.4 GB; the tool tablespace can grow' })
        if ($sim -eq 'ready') {
            $list.Add(@{ Name = 'Online redo logs'; Need = 'optional'; Met = $true; Now = '4 x 1 GB: large enough' })
        } else {
            $list.Add(@{ Name = 'Online redo logs'; Need = 'optional'; Met = $false; Ask = $false; Redo = $true
                         Now = '3 x 150 MB: smaller than what one batch writes'
                         Risk = 'the purge works, but spends about a quarter of its time waiting for them'
                         Do = 'the tool can enlarge them for the purge: 4 logs of 1 GB in ' + $script:Dir + $script:Opt.Tns + ' (3.6 GB more disk while the purge runs), and the present 3 x 150 MB put back under the same names at its end. Needs SYS' })
        }
    } else {
        $list.Add(@{ Name = 'Recycle bin empty'; Need = 'required'; Met = $true; Now = 'no dropped object in DATA' })
        $list.Add(@{ Name = 'Temporary space'; Need = 'required'; Met = $true; Now = 'the largest index needs about 500 MB, 3.0 GB free in TEMP' })
        $list.Add(@{ Name = 'Room for the archived logs'; Need = 'required'; Met = $true; Now = 'NOARCHIVELOG: nothing is archived' })
        $list.Add(@{ Name = 'Space quotas of the owners'; Need = 'required'; Met = $true; Now = 'unlimited in their tablespaces' })
        if ($sim -eq 'nobackup') {
            $list.Add(@{ Name = 'Backup'; Need = 'optional'; Met = $false; Ask = $false
                         Now = 'no RMAN backup of this database is recorded'
                         Risk = 'a reclaim changes no data, but it writes most of the tablespace again: a backup is the way back from a disk failure meanwhile'
                         Do = 'take a backup first when the data matters' })
        } else {
            $list.Add(@{ Name = 'Backup'; Need = 'optional'; Met = $true; Now = 'RMAN backup of 12 October 2026, 02:00' })
        }
    }
    return ,$list.ToArray()
}

# ----------------------------------------------------------------------------
# The steps every run begins with
# ----------------------------------------------------------------------------

# sqlplus, the connection, the tool's objects (installed or upgraded when
# needed). Returns $false when the user stops.
function Invoke-Ready {
    param([bool]$NeedSys)
    Out-Line ''
    Out-Line ' Getting ready' 'White'
    Wait-Sim 0.4
    Out-Line '   sqlplus            found: C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe'
    Wait-Sim 0.6
    Out-Line ('   Database           ' + $script:Opt.Tns + ' answers (alias of tnsnames.ora): Oracle 19.24, NOARCHIVELOG, one instance')
    Wait-Sim 0.5
    if ($script:Opt.Sim -eq 'firstrun') {
        Out-Line '   Tool in database   not installed yet' 'Yellow'
        Out-Line ''
        Out-Line ' The tool keeps its own tables in the database: a user EPFPG and a tablespace'
        Out-Line (' EPFPG_DATA of 128 MB (' + $script:Dir + $script:Opt.Tns + '/epfpg_data01.dbf). It touches nothing else.')
        if (-not (Read-YesNo 'Install it now (needs the SYS password)' $true $true)) {
            Out-Line ' Stopped: the tool is not installed. Nothing was changed.' 'Yellow'
            return $false
        }
        Read-Password 'SYS password' 'SYS_PASSWORD'
        Read-Password 'Password to give the EPFPG user' 'EPF_PASSWORD'
        Wait-Sim 1.5
        Out-Line ('   Tool in database   installed, version ' + $script:Version + ' (0:07)') 'Green'
    } else {
        Read-Password 'EPFPG password' 'EPF_PASSWORD'
        Out-Line ('   Tool in database   installed, version ' + $script:Version + ': up to date')
        if ($NeedSys) { Read-Password 'SYS password' 'SYS_PASSWORD' }
    }
    return $true
}

# The requirements as a table, then what to do about each one not met, then
# the question each calls for. Returns: GO, or STOP.
function Invoke-Checks {
    param([string]$Kind, [int]$N, [int]$Of, [bool]$DryRun)
    Invoke-Step $N $Of 'Checking the database (read-only)' 5
    $reqs = Get-Requirements $Kind
    Out-Line ''
    Out-Line ('   ' + 'Requirement'.PadRight(32) + 'Needed'.PadRight(10) + 'Now') 'White'
    foreach ($r in $reqs) {
        $state = 'ok'
        $color = ''
        if (-not $r.Met) {
            $state = 'NOT MET'
            $color = 'Yellow'
            if ($r.Need -eq 'required') { $color = 'Red' }
        }
        Out-Line ('   ' + $r.Name.PadRight(32) + $r.Need.PadRight(10) + $state.PadRight(9) + $r.Now) $color
    }
    $missing = @($reqs | Where-Object { -not $_.Met -and $_.Need -eq 'required' })
    $advice = @($reqs | Where-Object { -not $_.Met -and $_.Need -eq 'optional' })
    $what = 'purge'
    if ($Kind -eq 'RECLAIM') { $what = 'reclaim' }
    if ($missing.Count -eq 0 -and $advice.Count -eq 0) {
        Out-Line ''
        Out-Line ('   Every requirement is met: the ' + $what + ' can run as things are.') 'Green'
        return 'GO'
    }
    foreach ($r in ($missing + $advice)) {
        Out-Line ''
        $label = '   ' + $r.Name + ' (' + $r.Need + '): '
        $color = 'Yellow'
        if ($r.Need -eq 'required') { $color = 'Red' }
        Out-Wrapped $label ($r.Risk + '.') $color 5
        Out-Wrapped '     What to do: ' ($r.Do + '.')
    }
    Out-Line ''
    # The online redo logs: a question in a purge, said in a dry run. Without
    # questions: --redo-logs or REDO_LOGS=Y.
    $redo = @($advice | Where-Object { $_.ContainsKey('Redo') })
    if ($redo.Count -gt 0) {
        $auto = $script:Opt.Redo -or ($script:Conf.ContainsKey('REDO_LOGS') -and $script:Conf['REDO_LOGS'].ToUpper() -eq 'Y')
        if ($DryRun) {
            Out-Line '   A purge asks whether to enlarge the online redo logs for its time (--redo-logs says yes beforehand).'
        } else {
            $script:RedoApplied = Read-YesNo 'Enlarge the online redo logs for this purge' $true $auto
            if ($script:RedoApplied) { Out-Line '   The online redo logs will be 4 x 1 GB during the purge, then as they are now.' 'Green' }
            else { Out-Line '   The online redo logs stay as they are: the purge will be about a quarter slower.' }
        }
        Out-Line ''
    }
    if ($missing.Count -eq 0) {
        $left = @($advice | Where-Object { -not ($_.ContainsKey('Redo') -and $script:RedoApplied) })
        if ($left.Count -gt 0) {
            Out-Line ('   Only optional requirements are not met: the ' + $what + ' can run as things are.') 'Yellow'
        } else {
            Out-Line ('   Every requirement is settled: the ' + $what + ' can run.') 'Green'
        }
        if ($DryRun) {
            if (-not (Read-YesNo 'Go on with the simulation' $true $true)) { return 'STOP' }
        }
        return 'GO'
    }
    foreach ($r in $missing) {
        if ($DryRun) { continue }
        if ($r.Ask) {
            Out-Line ('   ' + $r.Name + ': answer yes only if a backup exists elsewhere (storage snapshot, export),') 'Red'
            Out-Line '   or if this database is a copy that can be lost.' 'Red'
            if (-not (Read-YesNo ('Purge without a backup known to RMAN') $false $false)) { return 'STOP' }
        } else {
            Out-Line ('   Not recommended: ' + $r.Name.ToLower() + ' is required and not met. ' + $r.Risk.Substring(0, 1).ToUpper() + $r.Risk.Substring(1) + '.') 'Red'
            if (-not (Read-YesNo 'Go on anyway' $false $false)) { return 'STOP' }
        }
    }
    if ($DryRun) {
        Out-Line ('   A required one is not met: a real ' + $what + ' would ask before starting, and is not recommended as things are.') 'Red'
        Out-Line '   The simulation itself changes nothing.'
        if (-not (Read-YesNo 'Go on with the simulation' $true $true)) { return 'STOP' }
    }
    return 'GO'
}

function Out-Stopped {
    param([string]$Why)
    Out-Line ''
    Out-Line (' Stopped: ' + $Why + ' Nothing was changed.') 'Yellow'
}

# ----------------------------------------------------------------------------
# The HTML report
# ----------------------------------------------------------------------------

function Get-RunFolder {
    param([string]$Label)
    $folder = Join-Path (Join-Path (Join-Path $script:RepoDir 'logs') 'sim') ((Get-Date -Format 'yyyy-MM-dd_HHmmss') + '_' + $Label)
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    return $folder
}

function Get-HtmlBar {
    param([string]$Label, [double]$Value, [double]$Max, [string]$Class, [string]$Text)
    $w = [string]::Format($script:Inv, '{0:0.0}', [Math]::Max(0.6, 100.0 * $Value / $Max))
    return '<div class="bar"><span class="bl">' + $Label + '</span><span class="track"><span class="fill ' + $Class + '" style="width:' + $w +
           '%"></span></span><span class="bv">' + $Text + '</span></div>'
}

# Writes report.html: $R has Title, Kind, Verdict (text), VerdictClass
# (ok|warn|bad), Lead, Tiles (label, value), Bars, Steps (label, seconds),
# Compare (title, list of status|label|detail), Notes, Next, Tables.
function Write-Report {
    param($R, [string]$Folder)
    $css = @'
:root{--bg:#f4f6f9;--card:#fff;--fg:#182131;--muted:#5a6577;--line:#d9dfe8;--accent:#2c5aa0;--ok:#1d7444;--oks:#e2f2e8;--warn:#8f5b00;--warns:#faefd9;--bad:#b42318;--bads:#fbe7e5;--idle:#8a94a6;--track:#e6eaf0}
@media (prefers-color-scheme:dark){:root{--bg:#0e131a;--card:#151c26;--fg:#e3e8ef;--muted:#98a3b5;--line:#273245;--accent:#8aaee8;--ok:#63cc90;--oks:#13301f;--warn:#e8b85e;--warns:#33270f;--bad:#f3897e;--bads:#3a1916;--idle:#7d8799;--track:#232c3b;color-scheme:dark}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:980px;margin:0 auto;padding:28px 20px 60px;display:grid;gap:18px}
.head{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;align-items:flex-end}
.kicker{font-size:.8rem;color:var(--muted);letter-spacing:.05em;text-transform:uppercase}h1{margin:0;font-size:1.7rem}
.when{color:var(--muted);text-align:right;font-size:.92rem}
.sim{background:var(--warns);color:var(--warn);border-radius:8px;padding:8px 14px;font-weight:600}
.verdict{display:flex;gap:14px;align-items:center;border-radius:12px;padding:16px 18px}
.verdict.ok{background:var(--oks)}.verdict.warn{background:var(--warns)}.verdict.bad{background:var(--bads)}
.badge{flex:none;color:var(--card);font-weight:800;border-radius:999px;padding:4px 16px}
.ok .badge{background:var(--ok)}.warn .badge{background:var(--warn)}.bad .badge{background:var(--bad)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.num{font-size:1.45rem;font-weight:800;font-variant-numeric:tabular-nums}.cap{color:var(--muted);font-size:.88rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;display:grid;gap:10px;min-width:0}
h2{margin:0;font-size:1.05rem}
.bar{display:grid;grid-template-columns:minmax(120px,18rem) 1fr 7rem;gap:10px;align-items:center;font-size:.93rem}
.track{background:var(--track);border-radius:4px;height:14px;overflow:hidden;display:block}.fill{display:block;height:100%;border-radius:4px;background:var(--accent)}
.fill.before{background:var(--idle)}.fill.after{background:var(--ok)}.bv{text-align:right;font-variant-numeric:tabular-nums}
ul.cmp{list-style:none;margin:0;padding:0;display:grid;gap:7px}.pill{display:inline-block;min-width:4.2em;text-align:center;border-radius:999px;padding:1px 10px;font-size:.8rem;font-weight:700}
.pill.ok{background:var(--oks);color:var(--ok)}.pill.warn{background:var(--warns);color:var(--warn)}.pill.bad{background:var(--bads);color:var(--bad)}
.muted{color:var(--muted)}table{border-collapse:collapse;width:100%;font-size:.93rem}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line)}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}.tw{overflow-x:auto}
code{font-family:Consolas,"Cascadia Mono",monospace;background:var(--track);border-radius:4px;padding:1px 6px;font-size:.9em}
.notes{margin:0;padding-left:1.2em;display:grid;gap:6px}.foot{color:var(--muted);font-size:.88rem}
@media (max-width:560px){.bar{grid-template-columns:1fr 5.5rem}.bl{grid-column:1/-1}}
@media print{body{background:#fff}.card,.tile{break-inside:avoid}}
'@
    $h = New-Object System.Text.StringBuilder
    $null = $h.Append('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    $null = $h.Append('<title>' + $R.Title + '</title><style>' + $css + '</style></head><body><div class="wrap">')
    $null = $h.Append('<div class="head"><div><div class="kicker">EPF Data Purge ' + $script:Version + ' &middot; ' + $R.Kind + '</div><h1>' + $R.Title + '</h1></div><div class="when">' + $R.When + '</div></div>')
    $null = $h.Append('<div class="sim">Simulation: this report was written by the simulator. No database was touched; every figure is scripted.</div>')
    $null = $h.Append('<div class="verdict ' + $R.VerdictClass + '"><span class="badge">' + $R.Verdict + '</span><div>' + $R.Lead + '</div></div>')
    $null = $h.Append('<div class="tiles">')
    foreach ($t in $R.Tiles) { $null = $h.Append('<div class="tile"><div class="num">' + $t[1] + '</div><div class="cap">' + $t[0] + '</div></div>') }
    $null = $h.Append('</div>')
    foreach ($table in $R.Tables) {
        $null = $h.Append('<div class="card"><h2>' + $table.Title + '</h2><div class="tw"><table><thead><tr>')
        $k = 0
        foreach ($c in $table.Head) { $cls = ''; if ($k -gt 0 -and $table.Numeric) { $cls = ' class="n"' }; $null = $h.Append('<th' + $cls + '>' + $c + '</th>'); $k++ }
        $null = $h.Append('</tr></thead><tbody>')
        foreach ($row in $table.Rows) {
            $null = $h.Append('<tr>')
            $k = 0
            foreach ($c in $row) { $cls = ''; if ($k -gt 0 -and $table.Numeric) { $cls = ' class="n"' }; $null = $h.Append('<td' + $cls + '>' + $c + '</td>'); $k++ }
            $null = $h.Append('</tr>')
        }
        $null = $h.Append('</tbody></table></div>')
        if ($table.Note -ne '') { $null = $h.Append('<div class="muted">' + $table.Note + '</div>') }
        $null = $h.Append('</div>')
    }
    if ($R.Bars.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>' + $R.BarsTitle + '</h2>')
        foreach ($b in $R.Bars) { $null = $h.Append((Get-HtmlBar $b[0] $b[1] $R.BarsMax $b[2] $b[3])) }
        $null = $h.Append('</div>')
    }
    if ($R.Steps.Count -gt 0) {
        $max = ($R.Steps | ForEach-Object { $_[1] } | Measure-Object -Maximum).Maximum
        $null = $h.Append('<div class="card"><h2>Duration by step</h2>')
        foreach ($s in $R.Steps) { $null = $h.Append((Get-HtmlBar $s[0] $s[1] $max '' (Format-Time $s[1]))) }
        $null = $h.Append('</div>')
    }
    if ($R.Compare.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>' + $R.CompareTitle + '</h2><ul class="cmp">')
        foreach ($c in $R.Compare) {
            $word = 'Pass'
            if ($c[0] -eq 'warn') { $word = 'Note' }
            if ($c[0] -eq 'bad') { $word = 'Fail' }
            $null = $h.Append('<li><span class="pill ' + $c[0] + '">' + $word + '</span> <strong>' + $c[1] + '</strong> <span class="muted">' + $c[2] + '</span></li>')
        }
        $null = $h.Append('</ul></div>')
    }
    if ($R.Notes.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>Good to know</h2><ul class="notes">')
        foreach ($n in $R.Notes) { $null = $h.Append('<li>' + $n + '</li>') }
        $null = $h.Append('</ul></div>')
    }
    if ($R.Next -ne '') { $null = $h.Append('<div class="card"><h2>Next</h2><div>' + $R.Next + '</div></div>') }
    $null = $h.Append('<div class="foot">In the real report, below: every table and index, the requirements with their figures, and the full text report. Files of the run: report.html, report.txt, console.log.</div>')
    $null = $h.Append('</div></body></html>')
    $path = Join-Path $Folder 'report.html'
    [System.IO.File]::WriteAllText($path, $h.ToString(), [System.Text.Encoding]::ASCII)
    return $path
}

function Out-Report {
    param([string]$Path)
    $opened = ''
    if ($script:Opt.Open -and $script:Opt.Interactive -and $script:Live) {
        try { Start-Process -FilePath $Path; $opened = '   (opened in your browser)' } catch { $opened = '' }
    }
    Out-Line ('  Report   ' + $Path + $opened)
}

# After every run: the tool's objects stay for the next one, or are removed.
function Invoke-UninstallQuestion {
    $auto = ($script:Conf.ContainsKey('UNINSTALL_AFTER') -and $script:Conf['UNINSTALL_AFTER'].ToUpper() -eq 'Y')
    if ($script:Opt.Interactive) {
        Out-Line ''
        Out-Line ' The tool''s own objects stay in the database for the next run: the user EPFPG and its'
        Out-Line ' tablespace EPFPG_DATA (128 MB), with the history of the runs and what they measured.'
        Out-Line ' Removing them frees that space; the next run installs them again, and forecasts start'
        Out-Line ' from statistics instead of measurements. The reports on this machine stay either way.'
    }
    if (Read-YesNo 'Remove the tool from the database now' $false $auto) {
        Read-Password 'SYS password' 'SYS_PASSWORD'
        Wait-Sim 1.0
        Out-Line ' Removed: the user EPFPG, the tablespace EPFPG_DATA and its datafile.' 'Green'
    } elseif ($script:Opt.Interactive) {
        Out-Line ' Kept.'
    }
}

# ----------------------------------------------------------------------------
# Purge
# ----------------------------------------------------------------------------

function Invoke-Purge {
    $dry = $script:Opt.DryRun
    $script:Run++
    $label = 'R-00000' + $script:Run
    $what = 'purge'
    if ($dry) { $what = 'purge, dry run' }
    Out-Head ('run ' + $label + ' . ' + $what)
    if (-not (Invoke-Ready (-not $dry))) { return 3 }
    $scope = Get-Scope
    Out-Line ''
    if ($dry) {
        Out-Line (' Simulating a purge of everything dated before ' + $scope.Text + '. Nothing is changed.') 'White'
    } else {
        Out-Line (' Purging everything dated before ' + $scope.Text + '.') 'White'
    }
    Out-Line ''
    $of = 2
    if (-not $dry) { $of = 5 }
    $decision = Invoke-Checks 'PURGE' 1 $of $dry
    if ($decision -eq 'STOP') { Out-Stopped 'you chose to stop at the requirements.'; return 3 }
    Out-Line ''
    Invoke-Step 2 $of 'Counting what the purge deletes' 77 2.0
    $freed = Format-Gb $scope.Gb
    $slow = ($script:Opt.Sim -ne 'ready' -and -not $script:RedoApplied)
    $notes = New-Object 'System.Collections.Generic.List[string]'
    if ($slow) {
        $notes.Add('The online redo logs are small (3 x 150 MB): the purge spends about a quarter of its time waiting for them. A purge asks whether to enlarge them for its time; they are put back afterwards.')
    }
    $tsLine = '   Tablespace affected    DATA, 41.7 GB: ' + $script:Dir + $script:Opt.Tns + '/data.dbf'
    $online = '   The application can stay in use during a purge: rows are deleted in small batches.'
    if ($dry) {
        Out-Line ''
        Out-Rule
        Out-Line ('  A purge would delete ' + (Format-Int $scope.Rows) + ' rows, about ' + $freed + ', dated before ' + $scope.Text + '.') 'White'
        $would = 'and would complete as things are.'
        if ($script:Opt.Sim -eq 'blocked' -or $script:Opt.Sim -eq 'nobackup') { $would = 'but a required condition is not met (above).' }
        Out-Line ('  It would take ' + (Format-About $scope.Seconds) + ', ' + $would) 'White'
        Out-Rule
        Out-Line ('   ' + 'What'.PadRight(20) + 'Rows to delete'.PadLeft(16) + 'Space freed (about)'.PadLeft(22)) 'White'
        foreach ($m in $scope.Modules) {
            Out-Line ('   ' + $m.Name.PadRight(20) + (Format-Int $m.Rows).PadLeft(16) + (Format-Gb ($scope.Gb * $m.Share)).PadLeft(22))
        }
        Out-Line ''
        Out-Line $tsLine
        Out-Line '   The space is freed inside the tables. The datafile keeps its size until a reclaim.'
        Out-Line ''
        Out-Line '   Disk used while the purge runs (given back at its end)' 'White'
        Out-Line ('     Undo               up to 4.0 GB   ' + $script:Dir + $script:Opt.Tns + '/undotbs01.dbf     extra disk needed: 3.4 GB')
        Out-Line ('     Temporary space    about 1.1 GB   ' + $script:Dir + $script:Opt.Tns + '/temp01.dbf        extra disk needed: none')
        Out-Line ('     Temporary indexes  about 1.4 GB   ' + $script:Dir + $script:Opt.Tns + '/epfpg_data01.dbf  extra disk needed: 1.3 GB')
        Out-Line '     Online redo logs   reused; nothing is kept (NOARCHIVELOG)'
        if ($script:Opt.Sim -ne 'ready') {
            Out-Line ('                        enlarged for the purge if you say so: 3.6 GB more in ' + $script:Dir + $script:Opt.Tns)
        }
        Out-Line ('     In all: about 4.7 GB free needed in ' + $script:Dir + $script:Opt.Tns + ' while it runs') 'White'
        if ($script:Opt.Sim -ne 'ready') { Out-Line '     (8.3 GB with the larger online redo logs).' 'White' }
        Out-Line ''
        Out-Line '   Other retentions, as examples of what else could be kept' 'White'
        Out-Line ('     ' + 'Days kept'.PadRight(22) + 'Rows deleted'.PadLeft(14) + 'Space freed (about)'.PadLeft(22)) 'DarkGray'
        $options = New-Object 'System.Collections.Generic.List[int]'
        foreach ($d in @(($scope.Kept + 200), $scope.Kept, ($scope.Kept - 200), ($scope.Kept - 335))) {
            if ($d -gt 0 -and -not $options.Contains([int]$d)) { $options.Add([int]$d) }
        }
        foreach ($d in $options) {
            $r = Get-RowsOlder $d
            $mark = ''
            if ($d -eq $scope.Kept) { $mark = '   (this dry run)' }
            Out-Line ('     ' + ((Format-Int $d) + ' days kept').PadRight(22) + (Format-Int $r).PadLeft(14) + (Format-Gb ($r * 390.0 / 1073741824)).PadLeft(22) + $mark)
        }
        Out-Line ''
        Out-Line $online
        if ($notes.Count -gt 0) {
            Out-Line ''
            Out-Line ('  Good to know (' + $notes.Count + ')') 'Yellow'
            foreach ($n in $notes) { Out-Wrapped '   - ' $n }
        }
        Out-Line ''
        Out-Line '  Nothing was changed.' 'Green'
        Out-Line ('  Next     epf_purge.bat purge ' + $scope.How + '          the purge itself')
        $folder = Get-RunFolder $label
        $rows = @()
        foreach ($m in $scope.Modules) { $rows += ,@($m.Name, (Format-Int $m.Rows), (Format-Gb ($scope.Gb * $m.Share))) }
        $report = @{ Title = $script:Opt.Tns + ' &middot; run ' + $label; Kind = 'purge, dry run'; When = 'simulated on ' + (Get-Date -Format 'd MMMM yyyy, HH:mm')
                     Verdict = 'Dry run'; VerdictClass = 'ok'
                     Lead = '<strong>A purge would delete ' + (Format-Int $scope.Rows) + ' rows, about ' + $freed + ', dated before ' + $scope.Text + '.</strong><br>It would take ' + (Format-About $scope.Seconds) + '. Nothing was changed.'
                     Tiles = @(@('rows a purge would delete', (Format-Int $scope.Rows)), @('freed inside the tables', $freed), @('expected duration', (Format-About $scope.Seconds)), @('free disk needed meanwhile', '4.7 GB'))
                     Tables = @(@{ Title = 'What a purge would delete'; Head = @('Module', 'Rows to delete', 'Space freed (about)'); Rows = $rows; Numeric = $true
                                   Note = 'Tablespace affected: DATA, 41.7 GB. The space is freed inside the tables; the datafile keeps its size until a reclaim.' },
                                @{ Title = 'Disk used while the purge runs'; Head = @('What', 'How much', 'Where', 'Compared with now'); Numeric = $false; Note = 'Given back at the end of the purge.'
                                   Rows = @(@('Undo', 'up to 4.0 GB', ($script:Dir + $script:Opt.Tns + '/undotbs01.dbf'), '3.4 GB more'),
                                            @('Temporary space', 'about 1.1 GB', ($script:Dir + $script:Opt.Tns + '/temp01.dbf'), 'fits in what is allocated'),
                                            @('Temporary indexes', 'about 1.4 GB', ($script:Dir + $script:Opt.Tns + '/epfpg_data01.dbf'), '1.3 GB more')) })
                     Bars = @(); BarsTitle = ''; BarsMax = 1; Steps = @(@('Checking the database', 5), @('Counting what the purge deletes', 77))
                     Compare = @(); CompareTitle = ''; Notes = $notes.ToArray()
                     Next = 'The purge itself: <code>epf_purge.bat purge ' + $scope.How + '</code>' }
        Out-Report (Write-Report $report $folder)
        Invoke-UninstallQuestion
        return 0
    }

    # The purge itself.
    Out-Line ''
    Out-Rule
    Out-Line ('  Ready. This deletes ' + (Format-Int $scope.Rows) + ' rows, about ' + $freed + ', dated before ' + $scope.Text + '.') 'White'
    Out-Line ('  ' + (Format-About $scope.Seconds).Substring(0, 1).ToUpper() + (Format-About $scope.Seconds).Substring(1) + '. It cannot be undone. The application can stay in use.') 'White'
    Out-Rule
    if ($script:Opt.Interactive) {
        $a = Read-Answer 'Type yes to start'
        if ($a -ne 'yes') { Out-Stopped 'you did not type yes.'; return 3 }
    }
    Out-Line ' Ctrl+C stops safely after the current batch.' 'DarkGray'
    Out-Line ''
    Invoke-Step 3 5 'Preparing the database for the purge (SYS)' 2
    Out-Line '         undo kept under 4.0 GB while rows are deleted; given back at the end'
    if ($script:RedoApplied) { Out-Line '         online redo logs 4 x 1 GB for the purge; the present ones put back at the end' }
    Out-Step 4 5 'Deleting' ''
    $done = 0.0
    $k = 0
    foreach ($m in $scope.Modules) {
        $k++
        $sec = $m.Rows * 0.0000255 + 8
        if ($script:Opt.Sim -eq 'fail' -and $k -eq 2) {
            Out-Line ('         ' + $m.Name.PadRight(16) + ' ' + (Get-Bar 40) + '  40%   the connection to the database was lost') 'Red'
            Out-Line ''
            Out-Rule
            Out-Line ('  STOPPED BY AN ERROR after ' + (Format-Int $done) + ' rows. What was deleted stays deleted; nothing is half done.') 'Red'
            Out-Rule
            Out-Line '  The connection to the database was lost (ORA-03113). Each batch is its own transaction:'
            Out-Line '  the batch that was running was rolled back by the database.'
            Out-Line '  The undo tablespace is put back by the next run, or now by:  epf_purge.bat status'
            Out-Line ('  To finish the purge, run the same command again:  epf_purge.bat purge ' + $scope.How)
            return 1
        }
        Show-Progress $m.Name $m.Rows 'rows' $sec 39000
        $done += $m.Rows
    }
    $back = 'Putting the undo tablespace back'
    if ($script:RedoApplied) { $back = 'Putting the undo tablespace and the online logs back' }
    Invoke-Step 5 5 $back 6
    $total = $scope.Seconds + 20
    Out-Line ''
    Out-Rule
    Out-Line ('  DONE   ' + (Format-Int $scope.Rows) + ' rows deleted in ' + (Format-Time $total) + '. Every check passed.') 'Green'
    Out-Rule
    Out-Line ('  ' + $freed + ' is now free inside the tables. The datafile keeps its size until a reclaim')
    Out-Line '  gives it back to the disk (the database must not be in use during a reclaim):'
    Out-Line '      epf_purge.bat reclaim --dry-run' 'Cyan'
    if ($notes.Count -gt 0) {
        Out-Line ''
        Out-Line ('  Good to know (' + $notes.Count + ')') 'Yellow'
        Out-Line ('   - The purge waited ' + (Format-Time ($scope.Seconds * 0.25)) + ' for the online redo logs, a quarter of the deleting time.')
        Out-Line '     --redo-logs removes that wait next time.'
    }
    Out-Line ''
    $folder = Get-RunFolder $label
    $rows = @()
    foreach ($m in $scope.Modules) { $rows += ,@($m.Name, (Format-Int $m.Rows), (Format-Time ($m.Rows * 0.0000255 + 8))) }
    $htmlNotes = @()
    if ($slow) { $htmlNotes = @('The purge waited ' + (Format-Time ($scope.Seconds * 0.25)) + ' for the online redo logs (3 x 150 MB), a quarter of the deleting time. <code>--redo-logs</code> removes that wait next time.') }
    $report = @{ Title = $script:Opt.Tns + ' &middot; run ' + $label; Kind = 'purge'; When = 'simulated on ' + (Get-Date -Format 'd MMMM yyyy, HH:mm') + '<br>' + (Format-Time $total)
                 Verdict = 'Done'; VerdictClass = 'ok'
                 Lead = '<strong>' + (Format-Int $scope.Rows) + ' rows deleted, dated before ' + $scope.Text + '.</strong><br>Every check passed. ' + $freed + ' is free inside the tables; a reclaim gives it back to the disk.'
                 Tiles = @(@('rows deleted', (Format-Int $scope.Rows)), @('freed inside the tables', $freed), @('duration', (Format-Time $total)), @('most undo held', '4.0 GB'))
                 Tables = @(@{ Title = 'What was deleted'; Head = @('Module', 'Rows deleted', 'Time'); Rows = $rows; Numeric = $true; Note = 'Tablespace affected: DATA.' })
                 Bars = @(); BarsTitle = ''; BarsMax = 1
                 Steps = @(@('Checking the database', 5), @('Counting what the purge deletes', 77), @('Preparing the database for the purge', 2), @('Deleting', ($scope.Seconds - 60)), @('Putting the undo tablespace and the logs back', 6))
                 CompareTitle = 'Verification'
                 Compare = @(@('ok', 'No row left before the cutoff', 'counted again after the purge'), @('ok', 'Rows deleted as counted', (Format-Int $scope.Rows) + ' deleted, ' + (Format-Int $scope.Rows) + ' counted'),
                             @('ok', 'No orphan row', '23 links between tables checked'), @('ok', 'Temporary indexes removed', '12 created, 12 dropped'), @('ok', 'Undo tablespace as before', '610 MB, the same names'))
                 Notes = $htmlNotes
                 Next = 'Give the space back to the disk, with the database not in use: <code>epf_purge.bat reclaim --dry-run</code>, then <code>epf_purge.bat reclaim</code>.' }
    Out-Report (Write-Report $report $folder)
    Invoke-UninstallQuestion
    return 0
}

# ----------------------------------------------------------------------------
# Reclaim
# ----------------------------------------------------------------------------

function Invoke-Reclaim {
    $dry = $script:Opt.DryRun
    $script:Run++
    $label = 'R-00000' + $script:Run
    $what = 'reclaim'
    if ($dry) { $what = 'reclaim, dry run' }
    Out-Head ('run ' + $label + ' . ' + $what)
    if (-not (Invoke-Ready $true)) { return 3 }
    Out-Line ''
    if ($dry) { Out-Line ' Looking at what a reclaim would give back. Nothing is changed.' 'White' }
    else { Out-Line ' Reclaim: compacting the datafiles to give disk space back.' 'White' }
    Out-Line ''
    $of = 2
    if (-not $dry) { $of = 7 }
    $decision = Invoke-Checks 'RECLAIM' 1 $of $dry
    if ($decision -eq 'STOP') { Out-Stopped 'you chose to stop at the requirements.'; return 3 }
    Out-Line ''
    Invoke-Step 2 $of 'Measuring what a reclaim gives back (the dry run)' 25 1.8
    $file = $script:Dir + $script:Opt.Tns + '/data.dbf'
    if ($script:Opt.Sim -eq 'compact') {
        Out-Line ''
        Out-Rule
        Out-Line '  Nothing to give back: DATA is 32.7 GB and holds 32.6 GB.' 'White'
        Out-Rule
        Out-Line '  A reclaim would rebuild 969 indexes for about 10 minutes and gain nothing.'
        Out-Line '  Nothing was changed.' 'Green'
        Invoke-UninstallQuestion
        return 0
    }
    $before = 41.7
    $after = 32.7
    $seconds = 3120
    Out-Line ''
    Out-Rule
    Out-Line ('  A reclaim takes DATA from ' + (Format-Gb $before) + ' to about ' + (Format-Gb $after) + ': ' + (Format-Gb ($before - $after)) + ' back to the disk.') 'White'
    Out-Line ('  It takes ' + (Format-About $seconds) + '.') 'White'
    Out-Rule
    Out-Line '  The database must not be in use meanwhile: the application accounts OP, OPPAYMENTS,' 'Yellow'
    Out-Line '  OPREPORTS, KDCM and SUPER are locked and their sessions disconnected until it ends.' 'Yellow'
    Out-Line ''
    Out-Line ('   DATA today      ' + (Get-Bar 100 40) + '  ' + (Format-Gb $before) + '   ' + $file)
    Out-Line ('   what it holds   ' + (Get-Bar (100 * 32.6 / $before) 40) + '  32.6 GB')
    Out-Line ('   after           ' + (Get-Bar (100 * $after / $before) 40) + '  ' + (Format-Gb $after))
    Out-Line ''
    Out-Line '   Disk used while the reclaim runs (removed at its end)' 'White'
    Out-Line ('     Scratch space      up to 8.5 GB   ' + $script:Dir + $script:Opt.Tns + '/epf_park_' + $script:Run + '.dbf   a file the tool creates and removes')
    Out-Line '     for the tables that cannot move within DATA: they wait there and come back.'
    Out-Line ('     The run takes only what it needs of it. Free now in ' + $script:Dir + $script:Opt.Tns + ': check with df -h.')
    Out-Line '     DATA itself never grows above its size at the start.'
    if ($dry) {
        Out-Line ''
        Out-Line '  Nothing was changed.' 'Green'
        Out-Line '  Next     epf_purge.bat reclaim                     the reclaim itself (it measures again, then asks)'
        $folder = Get-RunFolder $label
        $report = @{ Title = $script:Opt.Tns + ' &middot; run ' + $label; Kind = 'reclaim, dry run'; When = 'simulated on ' + (Get-Date -Format 'd MMMM yyyy, HH:mm')
                     Verdict = 'Dry run'; VerdictClass = 'ok'
                     Lead = '<strong>A reclaim would take DATA from ' + (Format-Gb $before) + ' to about ' + (Format-Gb $after) + ': ' + (Format-Gb ($before - $after)) + ' back to the disk.</strong><br>It would take ' + (Format-About $seconds) + '; the database must not be in use meanwhile. Nothing was changed.'
                     Tiles = @(@('back to the disk', (Format-Gb ($before - $after))), @('expected duration', (Format-About $seconds)), @('scratch space, at most', '8.5 GB'), @('accounts locked meanwhile', '5'))
                     Tables = @(); BarsTitle = 'The tablespace DATA'; BarsMax = $before
                     Bars = @(@('Today', $before, 'before', (Format-Gb $before)), @('What it holds', 32.6, '', '32.6 GB'), @('After a reclaim', $after, 'after', (Format-Gb $after)))
                     Steps = @(@('Checking the database', 5), @('Measuring what a reclaim gives back', 25)); Compare = @(); CompareTitle = ''; Notes = @()
                     Next = 'The reclaim itself, with the database not in use: <code>epf_purge.bat reclaim</code>' }
        Out-Report (Write-Report $report $folder)
        Invoke-UninstallQuestion
        return 0
    }
    Out-Line ''
    if ($script:Opt.Interactive) {
        Out-Line ('  The application will be unavailable for ' + (Format-About $seconds) + '.') 'Yellow'
        $a = Read-Answer 'Type yes to start the reclaim'
        if ($a -ne 'yes') { Out-Stopped 'you did not type yes.'; return 3 }
    } else {
        Out-Line '  No question (--non-interactive): the reclaim starts with up to 8.5 GB of scratch space.' 'DarkGray'
    }
    Out-Line ' Ctrl+C stops safely after the current table; everything is put back.' 'DarkGray'
    Out-Line ''
    Invoke-Step 3 7 'Locking the application accounts' 1 0.8
    Out-Line '         5 accounts locked; no session was connected'
    Invoke-Step 4 7 'Recording the state to compare afterwards' 21
    Out-Step 5 7 'Compacting the tables' ''
    Show-Progress 'DATA' 15 'tables' 1300 0 10
    Out-Line '         DATA 41.7 GB -> 22.2 GB . 14 tables moved, 1 set aside in scratch space (8.4 GB)'
    if ($script:Opt.Sim -eq 'fail') {
        Out-Line '         the connection to the database was lost' 'Red'
        Out-Line ''
        Out-Rule
        Out-Line '  STOPPED BY AN ERROR while compacting. No data is lost; the database is not yet as it was.' 'Red'
        Out-Rule
        Out-Line '  Still to put back: 1 table in scratch space, 969 indexes to rebuild, 5 accounts locked.'
        Out-Line '  The application stays unavailable until this command has run:' 'Yellow'
        Out-Line '      epf_purge.bat reclaim --restore' 'Cyan'
        return 1
    }
    Invoke-Step 6 7 'Bringing back the table set aside' 1118 1.6
    Out-Step 7 7 'Rebuilding the indexes, comparing, unlocking' ''
    Show-Progress 'indexes' 969 'indexes' 629 0 10
    Out-Line '         state compared with the one recorded; 5 accounts unlocked'
    $total = 3120
    Out-Line ''
    Out-Rule
    Out-Line ('  DONE   DATA went from ' + (Format-Gb $before) + ' to ' + (Format-Gb $after) + ': ' + (Format-Gb ($before - $after)) + ' given back to the disk.') 'Green'
    Out-Line ('         ' + (Format-Time $total) + '. The application accounts are unlocked.') 'Green'
    Out-Rule
    Out-Line '  State comparison: 969 indexes usable, 688 tables with the same row counts, no new'
    Out-Line '  invalid object, 5 accounts as they were.'
    Out-Line '  Most held on disk during the run: 41.7 GB, its size at the start.'
    Out-Line ''
    Out-Line '  Good to know (1)' 'Yellow'
    Out-Line '   - Within minutes Oracle adds about 5% of free space back to a datafile that can grow:'
    Out-Line '     expect DATA near 34.4 GB afterwards. Nothing to do.'
    Out-Line ''
    $folder = Get-RunFolder $label
    $report = @{ Title = $script:Opt.Tns + ' &middot; run ' + $label; Kind = 'reclaim'; When = 'simulated on ' + (Get-Date -Format 'd MMMM yyyy, HH:mm') + '<br>' + (Format-Time $total)
                 Verdict = 'Done'; VerdictClass = 'ok'
                 Lead = '<strong>DATA went from ' + (Format-Gb $before) + ' to ' + (Format-Gb $after) + ': ' + (Format-Gb ($before - $after)) + ' given back to the disk.</strong><br>Every check passed. The application accounts are unlocked.'
                 Tiles = @(@('given back to the disk', (Format-Gb ($before - $after))), @('database not in use', (Format-Time $total)), @('tables that had to move', '15 of 688'), @('most held on disk', '41.7 GB'))
                 Tables = @(); BarsTitle = 'The tablespace DATA'; BarsMax = $before
                 Bars = @(@('Before', $before, 'before', (Format-Gb $before)), @('After', $after, 'after', (Format-Gb $after)), @('What it holds', 32.6, '', '32.6 GB'))
                 Steps = @(@('Checking and measuring', 30), @('Locking the accounts, recording the state', 22), @('Compacting the tables', 1300), @('Bringing back the table set aside', 1118), @('Rebuilding 969 indexes', 629), @('Comparing, unlocking', 21))
                 CompareTitle = 'State comparison'
                 Compare = @(@('ok', 'Indexes', '969 of 969 usable and identical'), @('ok', 'Row counts', '688 of 688 tables identical'), @('ok', 'Constraints', '2,553 of 2,553 identical'),
                             @('ok', 'Invalid objects', 'none new'), @('ok', 'Accounts', '5 locked, 5 restored'), @('ok', 'Size against content', 'DATA 32.7 GB for 32.6 GB'))
                 Notes = @('Within minutes Oracle adds about 5% of free space back to a datafile that can grow: expect DATA near 34.4 GB afterwards. Nothing to do.')
                 Next = '' }
    Out-Report (Write-Report $report $folder)
    Invoke-UninstallQuestion
    return 0
}

# ----------------------------------------------------------------------------
# Help, menu, small actions
# ----------------------------------------------------------------------------

function Show-Help {
    $text = @'

 EPF Data Purge

 What it does
   PURGE     deletes old rows of the EPF application (payments, logs, bank
             statements) dated before a day you choose.
   RECLAIM   compacts the datafiles, so that the space the purge freed goes
             back to the disk.

 Two things to know
   - A purge alone does not free disk space. The rows are gone, but the
     datafiles keep their size until a reclaim.
   - A purge can run while the application is in use (online): it deletes in
     small batches. A reclaim cannot: the database must not be in use while
     it runs, and the tool locks the application accounts for that time.
   The two can be run or scheduled apart. The purge comes first.

 Every command checks first that it can run: sqlplus, the connection, the
 tool's own objects in the database (installed when they are missing) and
 the requirements. It tells you what is missing and what to do.

 Where to start
   1. See what a purge would delete, keeping the last 365 days. Nothing is
      changed:
        epf_purge.bat purge --dry-run --retention 365

   2. The whole job, in three commands:
        epf_purge.bat purge --dry-run --retention 365     what it would do
        epf_purge.bat purge --retention 365               delete the rows
        epf_purge.bat reclaim                             free the disk space
                                                          (database not in use)

   3. Be guided: the menu asks what you want and the questions that go with it:
        epf_purge.bat

 Options
   --dry-run            show what would happen; change nothing
   --retention DAYS     the days of data to keep: older rows are purged
                        (or --cutoff YYYY-MM-DD: rows dated before that day)
   --tns NAME           the database, as named in tnsnames.ora; asked for
                        when it is not given
   --redo-logs          larger online redo logs during the purge, without
                        being asked
   --non-interactive    ask nothing: the whole run in one command, which a
                        scheduler of yours can start. Passwords and choices
                        then come from --config FILE. The tool schedules
                        nothing itself.
   --config FILE        settings as KEY=VALUE: TNS, EPF_PASSWORD, SYS_PASSWORD,
                        RETENTION_DAYS or CUTOFF, REDO_LOGS, UNINSTALL_AFTER
   --help               this text

 Other actions:  report (of an earlier run)   status (is anything pending?)
                 uninstall (remove the tool's objects from the database)

'@
    Write-Host $text
    Out-Line ' SIMULATION options: --sim slow|ready|nobackup|blocked|firstrun|compact|fail, --fast, --no-open' 'Magenta'
    Out-Line ''
}

function Show-Menu {
    Out-Head 'menu'
    Out-Line ''
    Out-Line ' Last run: purge on 12 October 2026, 19,279,194 rows deleted. Nothing is pending.'
    Out-Line ''
    Out-Line ' What do you want to do?' 'White'
    Out-Line '   1  Dry run of a purge     shows what a purge would delete; changes nothing'
    Out-Line '   2  Purge                  deletes old rows. A reclaim is needed afterwards to free disk space'
    Out-Line '   3  Dry run of a reclaim   shows how much disk space a reclaim would give back; changes nothing'
    Out-Line '   4  Reclaim                compacts the datafiles to free disk space; the database must not be in use'
    Out-Line '   5  Report of an earlier run'
    Out-Line '   6  Status: is anything left pending?'
    Out-Line '   7  Uninstall: remove the tool''s objects from the database'
    Out-Line '   Q  Quit'
    $c = (Read-Answer 'Choice' '1').ToUpper()
    switch ($c) {
        '1' { $script:Opt.DryRun = $true; return (Invoke-Purge) }
        '2' { $script:Opt.DryRun = $false; return (Invoke-Purge) }
        '3' { $script:Opt.DryRun = $true; return (Invoke-Reclaim) }
        '4' { $script:Opt.DryRun = $false; return (Invoke-Reclaim) }
        '5' { return (Show-Report) }
        '6' { return (Show-Status) }
        '7' { return (Invoke-Uninstall) }
        default { Out-Line ' Nothing done.'; return 0 }
    }
}

function Show-Status {
    Out-Head 'status'
    Out-Line ''
    Out-Line ' Last run        R-000002, purge, 12 October 2026 09:49 to 09:59: done, 19,279,194 rows deleted'
    Out-Line ' Running now     nothing'
    Out-Line ' Left pending    nothing: no temporary index, no undo setting, no table set aside, no account locked' 'Green'
    return 0
}

function Show-Report {
    Out-Head 'report'
    Out-Line ''
    Out-Line ' Runs on this database'
    Out-Line '   R-000001   12 October 09:18   purge, dry run   19,279,194 rows would be deleted'
    Out-Line '   R-000002   12 October 09:49   purge            done: 19,279,194 rows deleted in 10:01'
    $r = Read-Answer 'Run to open' 'R-000002'
    Out-Line (' The report of ' + $r + ' would open in your browser (run a purge or a reclaim here to see one).')
    return 0
}

function Invoke-Uninstall {
    Out-Head 'uninstall'
    Out-Line ''
    Out-Line ' This removes the tool''s own objects from the database: the user EPFPG and its tablespace'
    Out-Line ' EPFPG_DATA (128 MB), with the history of the runs. The application''s data is not touched.'
    Out-Line ' The reports on this machine stay. Nothing is pending, so it is safe to remove.'
    if (-not (Read-YesNo 'Remove the tool from the database' $false $true)) { Out-Line ' Kept.'; return 0 }
    Read-Password 'SYS password' 'SYS_PASSWORD'
    Wait-Sim 1.0
    Out-Line ' Removed: the user EPFPG, the tablespace EPFPG_DATA and its datafile.' 'Green'
    return 0
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

$i = 0
while ($i -lt $script:CliArgs.Count) {
    $a = [string]$script:CliArgs[$i]
    $name = $a.ToLower()
    if ($name -eq '--dry-run') { $script:Opt.DryRun = $true }
    elseif ($name -eq '--non-interactive') { $script:Opt.Interactive = $false }
    elseif ($name -eq '--yes') { $script:Opt.Yes = $true }
    elseif ($name -eq '--redo-logs') { $script:Opt.Redo = $true }
    elseif ($name -eq '--fast') { $script:Opt.Fast = $true }
    elseif ($name -eq '--no-open') { $script:Opt.Open = $false }
    elseif ($name -eq '--no-color') { $script:Opt.Color = $false }
    elseif ($name -eq '--help') { $script:Opt.Action = 'help' }
    elseif (@('--cutoff', '--retention', '--tns', '--config', '--sim', '--scratch') -contains $name) {
        $i++
        if ($i -ge $script:CliArgs.Count) { Out-Line (' Option ' + $a + ' needs a value.') 'Red'; exit 4 }
        $v = [string]$script:CliArgs[$i]
        if ($name -eq '--cutoff') { $script:Opt.Cutoff = $v }
        elseif ($name -eq '--retention') { $script:Opt.Retention = $v }
        elseif ($name -eq '--tns') { $script:Opt.Tns = $v }
        elseif ($name -eq '--config') { $script:Opt.Config = $v }
        elseif ($name -eq '--sim') { $script:Opt.Sim = $v.ToLower() }
    }
    elseif ($name.StartsWith('--')) { Out-Line (' Unknown option ' + $a + '. See epf_sim.bat --help.') 'Red'; exit 4 }
    elseif ($script:Opt.Action -eq '') { $script:Opt.Action = $name }
    else { Out-Line (' Unexpected argument ' + $a + '. See epf_sim.bat --help.') 'Red'; exit 4 }
    $i++
}
if (@('slow', 'ready', 'nobackup', 'blocked', 'firstrun', 'compact', 'fail') -notcontains $script:Opt.Sim) {
    Out-Line (' --sim: slow, ready, nobackup, blocked, firstrun, compact or fail, got ' + $script:Opt.Sim + '.') 'Red'
    exit 4
}
if ($script:Opt.Config -ne '') {
    if (-not (Test-Path -LiteralPath $script:Opt.Config)) { Out-Line (' Configuration file not found: ' + $script:Opt.Config) 'Red'; exit 4 }
    foreach ($line in (Get-Content -LiteralPath $script:Opt.Config)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $eq = $t.IndexOf('=')
        if ($eq -gt 0) { $script:Conf[$t.Substring(0, $eq).Trim().ToUpper()] = $t.Substring($eq + 1).Trim() }
    }
    if ($script:Opt.Tns -eq '' -and $script:Conf.ContainsKey('TNS')) { $script:Opt.Tns = $script:Conf['TNS'] }
}
# The database: --tns, TNS of the configuration file, or asked for.
if ($script:Opt.Action -ne 'help' -and $script:Opt.Tns -eq '') {
    if (-not $script:Opt.Interactive) {
        Out-Line ' The database is required with --non-interactive: --tns NAME, or TNS in the configuration file.' 'Red'
        exit 4
    }
    Out-Line ''
    while ($script:Opt.Tns -eq '') {
        $script:Opt.Tns = (Read-Answer 'Database (its alias in tnsnames.ora, such as EPFPG782)').ToUpper()
    }
}
$code = 0
switch ($script:Opt.Action) {
    'help'      { Show-Help }
    ''          {
        if (-not $script:Opt.Interactive) { Out-Line ' An action is required with --non-interactive: purge or reclaim.' 'Red'; exit 4 }
        $code = Show-Menu
    }
    'purge'     { $code = Invoke-Purge }
    'reclaim'   { $code = Invoke-Reclaim }
    'status'    { $code = Show-Status }
    'report'    { $code = Show-Report }
    'uninstall' { $code = Invoke-Uninstall }
    default     { Out-Line (' Unknown action ' + $script:Opt.Action + '. See epf_sim.bat --help.') 'Red'; $code = 4 }
}
exit $code

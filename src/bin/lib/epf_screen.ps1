# ============================================================================
# EPF Data Purge - The screen of a run without --verbose
# ============================================================================
# Purpose : What a run shows by default: its steps by what they do, each with
#           its time; one line per module while rows are deleted (progress,
#           rows, speed, time left); the requirements as a table with what to
#           do about each one not met; and the end of the run in plain words
#           (what was done, what to know, what comes next). console.log and
#           --verbose keep every event and the whole report.
# Usage   : Loaded by epf.ps1 (dot-sourced); uses its output functions.
# Requires: Windows PowerShell 5.1.
# ============================================================================

# The steps of the action in progress (Start-Flow); $null: none.
$script:Flow = $null

# What the engine's steps do, for the line of the running step.
$script:StepWords = @{
    'REGISTRY' = 'checking the tables'; 'SUPPORTING_INDEXES' = 'checking the indexes';
    'ELIGIBLE_ROOTS' = 'counting what is old enough'; 'REDO_LOGS' = 'measuring the online redo logs';
    'UNDO' = 'measuring the undo tablespace'; 'REQUIREMENTS' = 'checking the requirements'; 'PLAN' = 'planning';
    'PREPARE' = 'preparing'; 'SPACE_BASELINE' = 'measuring the space used'; 'SNAPSHOT_KEYS' = 'listing the rows';
    'COUNT_BEFORE' = 'counting the rows'; 'TEMP_INDEXES' = 'creating temporary indexes'; 'PROCESS_BATCHES' = 'deleting';
    'COUNT_AFTER' = 'counting what is left'; 'SPACE_POST_PURGE' = 'measuring the space freed'; 'CLEANUP' = 'cleaning up';
    'ASSESS' = 'measuring the tablespaces'; 'LOCK_ACCOUNTS' = 'locking the accounts'; 'BASELINE' = 'recording the state';
    'RELEASE_INDEXES' = 'releasing the indexes'; 'FREEZE_FILES' = 'holding the datafiles'; 'COMPACT' = 'moving tables';
    'RETURN_PARKED' = 'bringing tables back'; 'REBUILD_INDEXES' = 'rebuilding indexes';
    'RESTORE_FILES' = 'restoring the datafile settings'; 'RESIZE' = 'giving space back'; 'RECOMPILE' = 'recompiling';
    'VERIFY' = 'comparing with the state recorded'; 'UNLOCK_ACCOUNTS' = 'unlocking the accounts'
}

# Steps of a reclaim whose result is said under the step of the screen.
$script:StepNotes = @('LOCK_ACCOUNTS', 'BASELINE', 'RELEASE_INDEXES', 'COMPACT', 'RETURN_PARKED', 'REBUILD_INDEXES',
                      'VERIFY', 'UNLOCK_ACCOUNTS')

# Warnings the requirements table already says in plain words.
$script:QuietWarnings = @('REDO_ESTIMATE', 'REDO_SUMMARY', 'UNDO_ESTIMATE', 'REQUIREMENTS', 'REDO_WAITS')

# Lines of a SYS step that puts things back (undo.sql RESTORE, redo_logs.sql
# RESTORE) which say that something was left as it was: shown on the screen.
$script:SysNotes = @('REDO_GROUP_KEPT', 'REDO_FILE_KEPT', 'UNDO_APPLIED', 'UNDO_FILE_GONE', 'UNDO_SWAP_KEPT', 'UNDO_SWITCH_FAILED',
                     'UNDO_SWITCH_PENDING', 'UNDO_SWITCH_SKIPPED', 'UNDO_SIZE_KEPT', 'TEMP_SIZE_KEPT')

# Events the steps prepared by SYS print themselves (undo.sql, redo_logs.sql).
$script:SysEvents = @('REDO_ENLARGED', 'REDO_UNCHANGED', 'REDO_RESTORED', 'UNDO_RETENTION_SET', 'UNDO_GROWTH_LIMITED',
                      'UNDO_RETENTION_RESTORED', 'UNDO_GROWTH_RESTORED', 'UNDO_CAP')

# The names of the requirements, and what to do about each one not met.
$script:ReqNames = @{
    'PURGE.ARCHIVE' = 'Room for the archived logs'; 'PURGE.UNDO' = 'Undo space'; 'PURGE.TEMP' = 'Temporary space';
    'PURGE.INDEX_SPACE' = 'Room for the temporary indexes'; 'PURGE.REDO_LOGS' = 'Online redo logs';
    'PURGE.BACKUP' = 'Backup';
    'RECLAIM.RECYCLEBIN' = 'Recycle bin empty'; 'RECLAIM.ARCHIVE' = 'Room for the archived logs';
    'RECLAIM.TEMP' = 'Temporary space'; 'RECLAIM.BACKUP' = 'Backup'; 'RECLAIM.QUOTA' = 'Space quotas of the owners';
    'RECLAIM.SCRATCH' = 'Scratch space'
}
$script:ReqActions = @{
    'PURGE.ARCHIVE' = 'free space in the archive destination (the DBA backs up and deletes archived logs), then run again; or purge in smaller runs, older data first (epf_purge.bat preflight --max-redo SIZE plans them)'
    'PURGE.UNDO' = 'a smaller batch (--batch-size; the tool takes one that fits when none is given), or room for the undo tablespace (the DBA)'
    'PURGE.TEMP' = 'let the temporary tablespace grow, or add a temporary file (the DBA), then run again'
    'PURGE.INDEX_SPACE' = 'nothing is required: a table without its temporary index is read once per batch, which is slower. Room in the tool''s tablespace removes that'
    'PURGE.REDO_LOGS' = 'the tool can enlarge them for the purge: 4 logs of 1 GB replace the present ones while it runs (up to 4 GB more disk in the directory of the online logs), and the present ones are put back under the same names at its end. Needs SYS. A purge asks; --redo-logs says yes beforehand'
    'PURGE.REDO_LOGS.PDB' = 'nothing is required: the purge waits for them at times. The online redo logs of a pluggable database belong to its container database, so this tool does not enlarge them here; the DBA of the container can'
    'PURGE.BACKUP' = 'take an RMAN backup, then run again. When a backup exists that RMAN does not know (storage snapshot, export), or this database is a copy that can be lost, a purge asks and goes on (--backup confirmed, --backup none)'
    'RECLAIM.RECYCLEBIN' = 'the DBA purges them (PURGE TABLESPACE name); or the reclaim purges them when you say so (--confirm RECYCLEBIN): FLASHBACK TABLE can then no longer restore them'
    'RECLAIM.ARCHIVE' = 'free space in the archive destination (the DBA backs up and deletes archived logs), then run again'
    'RECLAIM.TEMP' = 'let the temporary tablespace grow, or add a temporary file (the DBA), then run again'
    'RECLAIM.BACKUP' = 'take a backup first when the data matters: a reclaim changes no data, but it writes most of the tablespace again'
    'RECLAIM.QUOTA' = 'the DBA gives the owners listed a quota above what they use (ALTER USER owner QUOTA UNLIMITED ON tablespace), then run again'
    'RECLAIM.SCRATCH' = 'without scratch space a table that cannot move lower stops its datafile there. Leave --scratch none out and the reclaim takes the size it measures; --scratch SIZE sets another limit'
}

# ----------------------------------------------------------------------------
# Formats
# ----------------------------------------------------------------------------

# 0:05, 12:34, 1:02:03.
function Format-Clock {
    param([double]$Seconds)
    $s = [int][Math]::Max(0, [Math]::Round($Seconds))
    if ($s -ge 3600) { return ('{0}:{1:00}:{2:00}' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60), ($s % 60)) }
    return ('{0}:{1:00}' -f [Math]::Floor($s / 60), ($s % 60))
}

# "less than a minute", "about 8 minutes", "about 1 h 20 min".
function Format-About {
    param([double]$Seconds)
    if ($Seconds -lt 45) { return 'less than a minute' }
    $m = [int][Math]::Max(1, [Math]::Round($Seconds / 60))
    if ($m -ge 90) { return ('about ' + [Math]::Floor($m / 60) + ' h ' + ($m % 60) + ' min') }
    if ($m -eq 1) { return 'about 1 minute' }
    return ('about ' + $m + ' minutes')
}

# Seconds of a duration as HH:MM:SS; 0 when it is not one.
function ConvertTo-Seconds {
    param([string]$Text)
    if ($Text -match '^\s*(\d+):(\d\d):(\d\d)\s*$') { return ([int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]) }
    return 0
}

# 19,279,194 for a count.
function Format-Count {
    param([double]$Value)
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N0}', [Math]::Round($Value))
}

# A count written with thousands separators, as a number; 0 when it is not one.
function ConvertTo-Count {
    param([string]$Text)
    $value = [double]0
    if ([double]::TryParse(($Text -replace ',', '').Trim(), [Globalization.NumberStyles]::Float,
                           [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        return $value
    }
    return [double]0
}

# Bytes of a size as the report writes it (6.6 GB, 132.0 MB); 0 when it is
# not one.
function ConvertTo-SizeBytes {
    param([string]$Text)
    if ($Text -match '^\s*(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)\s*$') {
        $power = @{ 'B' = 0; 'KB' = 1; 'MB' = 2; 'GB' = 3; 'TB' = 4 }[$Matches[2]]
        return ([double]::Parse($Matches[1], [Globalization.CultureInfo]::InvariantCulture) * [Math]::Pow(1024, $power))
    }
    return [double]0
}

# 10 May 2016 for 2016-05-10.
function Format-Day {
    param([string]$Iso)
    $day = [datetime]::MinValue
    if ([datetime]::TryParseExact($Iso, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture,
                                  [Globalization.DateTimeStyles]::None, [ref]$day)) {
        return $day.ToString('d MMMM yyyy', [Globalization.CultureInfo]::InvariantCulture)
    }
    return $Iso
}

function Get-Bar {
    param([double]$Pct, [int]$Width = 20)
    $full = [int][Math]::Floor($Width * [Math]::Max(0, [Math]::Min(100, $Pct)) / 100)
    return '[' + ('#' * $full) + ('.' * ($Width - $full)) + ']'
}

# Columns a wrapped text may take: the console's, from 80 to 120.
function Get-WrapWidth {
    $width = 100
    try {
        if (-not [Console]::IsOutputRedirected) { $width = [Console]::WindowWidth - 1 }
    } catch {
        $width = 100
    }
    return [Math]::Max(80, [Math]::Min(120, $width))
}

# A text wrapped at the width of the screen: its first line after $First, the
# others under it, or indented by $Indent. On the console only; -Log: also in
# the log, in one line.
function Write-Wrapped {
    param([string]$First, [string]$Text, [string]$Color = '', [int]$Indent = -1, [switch]$Log)
    if ($Log) { Write-Log ($First + $Text) }
    $width = Get-WrapWidth
    $pad = ' ' * $First.Length
    if ($Indent -ge 0) { $pad = ' ' * $Indent }
    $line = $First
    foreach ($word in ($Text -split ' ')) {
        if ($word -eq '') { continue }
        if ($line.Length + $word.Length -gt $width -and $line.Trim() -ne '') {
            Write-Out $line.TrimEnd() $Color -NoLog
            $line = $pad
        }
        $line = $line + $word + ' '
    }
    if ($line.Trim() -ne '') { Write-Out $line.TrimEnd() $Color -NoLog }
}

function Write-Rule {
    param([string]$Color = 'White')
    Write-Out (' ' + ('=' * ($script:Width - 1))) $Color -NoLog
}

# The first letter of a sentence in capitals.
function Format-Sentence {
    param([string]$Text)
    if ($Text.Length -eq 0) { return $Text }
    return ($Text.Substring(0, 1).ToUpper() + $Text.Substring(1))
}

# ----------------------------------------------------------------------------
# Steps
# ----------------------------------------------------------------------------

# Starts the steps of an action. $Steps: Key, Text and Header ($true for a
# step that is a heading over the lines of what it does) of each, in order.
# $Map: the step of the screen an engine step belongs to (a reclaim).
function Start-Flow {
    param([object[]]$Steps, [hashtable]$Map = @{})
    $script:Flow = [pscustomobject]@{
        Steps = @($Steps); Map = $Map; N = 0; Started = (Get-Date); Open = $false;
        Module = ''; Phase = ''; Batch = $null; EngineStep = ''; EngineScope = '';
        Rebuilt = 0; Indexes = 0; Parked = 0; Returned = 0; Rows = [double]0; PurgeEnd = '';
        Pending = (New-Object 'System.Collections.Generic.List[object]');
        Missing = (New-Object 'System.Collections.Generic.List[string]');
        Notes = (New-Object 'System.Collections.Generic.List[string]');
        Errors = (New-Object 'System.Collections.Generic.List[string]')
    }
}

# The steps are shown: a flow is started and --verbose is not given.
function Test-Flow {
    return (-not $script:Verbose -and $null -ne $script:Flow)
}

function Get-FlowIndex {
    param([string]$Key)
    for ($i = 0; $i -lt $script:Flow.Steps.Count; $i++) {
        if ($script:Flow.Steps[$i].Key -eq $Key) { return ($i + 1) }
    }
    return 0
}

# " 2 of 4  Preparing the database for the purge (SYS)        done    0:02"
function Get-FlowLine {
    param([string]$State = '', [string]$Time = '', [int]$N = 0)
    $f = $script:Flow
    if ($N -eq 0) { $N = $f.N }
    $text = ' ' + $f.Steps[$N - 1].Text
    if ($f.Steps.Count -gt 1) { $text = ' ' + $N + ' of ' + $f.Steps.Count + '  ' + $f.Steps[$N - 1].Text }
    return ($text.PadRight(66) + ' ' + $State.PadRight(7) + $Time.PadLeft(5))
}

# Starts the step $Key (ending the one that runs); a step that is not of this
# flow, or that runs already, changes nothing. A step of a reclaim that its
# engine passed over is said not needed.
function Start-FlowStep {
    param([string]$Key)
    if (-not (Test-Flow)) { return }
    $n = Get-FlowIndex $Key
    $f = $script:Flow
    if ($n -eq 0 -or ($f.Open -and $f.N -eq $n)) { return }
    if ($f.Open) { Complete-FlowStep }
    if ($f.Map.Count -gt 0 -and $f.N -gt 0) {
        for ($k = $f.N + 1; $k -lt $n; $k++) {
            Write-Out (Get-FlowLine 'not needed' '' $k).TrimEnd() 'DarkGray' -NoLog
        }
    }
    $f.N = $n
    $f.Started = Get-Date
    $f.Open = $true
    $f.EngineStep = ''
    $f.EngineScope = ''
    if ($f.Steps[$n - 1].Header) {
        Write-Out (Get-FlowLine).TrimEnd() 'White' -NoLog
    } elseif ($script:StatusLine) {
        Show-Status (Get-FlowLine 'running' (Format-Clock 0))
    }
}

# Ends the running step with its time: done, FAILED or stopped. A heading
# gets a line only when it did not end well.
function Complete-FlowStep {
    param([string]$State = 'done')
    if (-not (Test-Flow)) { return }
    $f = $script:Flow
    if (-not $f.Open) { return }
    $f.Open = $false
    $time = Format-Clock ((Get-Date) - $f.Started).TotalSeconds
    $color = 'Green'
    if ($State -eq 'FAILED') { $color = 'Red' } elseif ($State -ne 'done') { $color = 'Yellow' }
    if ($f.Steps[$f.N - 1].Header) {
        Clear-Status
        if ($State -ne 'done') { Write-Out ('         ' + $State + ' after ' + $time) $color -NoLog }
        return
    }
    Write-Out (Get-FlowLine $State $time) $color -NoLog
    foreach ($note in $f.Pending) { Write-FlowLine $note }
    $f.Pending.Clear()
}

# One line under a step: as it is, or after its label and wrapped under its
# text.
function Write-FlowLine {
    param($Note)
    if ($Note.Label -ne '') {
        Write-Wrapped ('         ' + $Note.Label) $Note.Text $Note.Color
    } else {
        Write-Out ('         ' + $Note.Text) $Note.Color -NoLog
    }
}

# A line under the running step. The line of a step is written when it ends:
# what it says meanwhile waits for it; under a heading it is written at once.
# $Label: what goes before the text ("note   "); the text is then wrapped.
function Write-FlowNote {
    param([string]$Text, [string]$Color = '', [string]$Label = '')
    if (-not (Test-Flow)) { return }
    $f = $script:Flow
    $note = [pscustomobject]@{ Text = $Text; Color = $Color; Label = $Label }
    if ($f.Open -and -not $f.Steps[$f.N - 1].Header) {
        $f.Pending.Add($note)
        return
    }
    Write-FlowLine $note
}

# The line of the module whose rows are deleted now.
function Get-ModuleLine {
    param($Batch)
    $text = '         ' + ([string]$Batch.Module).PadRight(16) + ' ' + (Get-Bar $Batch.Pct) + ' ' +
            ('{0,3}%' -f [int][Math]::Floor($Batch.Pct))
    if ($Batch.Rows -ne '') { $text = $text + '   ' + $Batch.Rows + ' ' + $Batch.Unit }
    if ($Batch.Rate -ne '') { $text = $text + ' . ' + $Batch.Rate + ' ' + $Batch.Unit + ' a second' }
    if ($Batch.Left -gt 0) { $text = $text + ' . ' + (Format-Clock $Batch.Left) + ' left' }
    return $text
}

# What runs now, for the status line: the module whose rows are deleted, the
# indexes rebuilt so far, or the running step with what the engine does.
# ST|phase|step|scope|units_done|units_total|bytes_done
function Get-FlowStatus {
    param($Steps)
    $f = $script:Flow
    if ($null -eq $f -or -not $f.Open) { return '' }
    $engine = $null
    if ($Steps.Count -gt 0) { $engine = $Steps[$Steps.Count - 1] }
    if ($f.Phase -eq 'deleting' -and $null -ne $f.Batch) {
        $batch = $f.Batch
        # Between two progress events, the batches done say how far it is.
        $done = [double]0
        $total = [double]0
        if ($null -ne $engine -and $engine[2] -eq 'PROCESS_BATCHES' -and [double]::TryParse($engine[4], [ref]$done) -and
            [double]::TryParse($engine[5], [ref]$total) -and $total -gt 0) {
            $batch = [pscustomobject]@{ Module = $batch.Module; Pct = [Math]::Max($batch.Pct, 100.0 * $done / $total);
                                        Rows = $batch.Rows; Unit = $batch.Unit; Rate = $batch.Rate; Left = $batch.Left }
        }
        return (Get-ModuleLine $batch)
    }
    $elapsed = Format-Clock ((Get-Date) - $f.Started).TotalSeconds
    if ($f.Steps[$f.N - 1].Header) {
        # Under a heading the line says what the engine does now, or nothing.
        if ($null -eq $engine) { return '' }
        $text = '         '
        if ($f.Module -ne '') { $text = $text + $f.Module.PadRight(16) + ' ' }
    } else {
        $text = (Get-FlowLine 'running' $elapsed) + ' . '
    }
    if ($null -ne $engine) {
        $words = $engine[2].ToLower().Replace('_', ' ')
        if ($script:StepWords.ContainsKey($engine[2])) { $words = $script:StepWords[$engine[2]] }
        if ($engine[2] -eq 'REBUILD_INDEXES' -and $f.Indexes -gt 0) {
            $words = [string]$f.Rebuilt + ' of ' + $f.Indexes + ' indexes rebuilt'
        } elseif ($engine[2] -eq 'RETURN_PARKED' -and $f.Parked -gt 0) {
            $words = [string]$f.Returned + ' of ' + $f.Parked + ' tables back'
        } elseif ($engine[2] -eq 'COMPACT') {
            $words = $engine[3] + ': ' + $engine[4] + ' tables moved so far'
            if ($f.Parked -gt 0) { $words = $words + ', ' + $f.Parked + ' set aside' }
        } elseif ($engine[3] -ne '' -and $engine[3] -ne '-' -and $engine[3] -ne $f.Module) {
            $words = $words + ' (' + $engine[3] + ')'
        }
        $text = $text + $words
    }
    return $text.TrimEnd(' ', '.')
}

# An event on the screen of the steps: the progress of a module, the result
# of a step, a warning or an error. The other events are in console.log.
# EV|event_id|HH24:MI:SS|severity|phase|event_code|owner.object|message
function Show-FlowEvent {
    param([string[]]$Field)
    $f = $script:Flow
    $severity = $Field[3]
    $code = $Field[5]
    $message = $Field[7]
    if ($code -eq 'STEP_START') {
        $part = @($message.Split(' '))
        if ($part.Count -lt 2) { return }
        $step = $part[1]
        $scope = ''
        if ($part.Count -gt 2) { $scope = $part[2] }
        if ($f.Map.ContainsKey($step) -and (Get-FlowIndex $f.Map[$step]) -gt $f.N) { Start-FlowStep $f.Map[$step] }
        $f.EngineStep = $step
        $f.EngineScope = $scope
        if ($step -eq 'SNAPSHOT_KEYS') {
            $f.Module = $scope
            $f.Phase = 'counting'
            $f.Batch = $null
        } elseif ($step -eq 'PROCESS_BATCHES') {
            $f.Module = $scope
            $f.Phase = 'deleting'
            $f.Batch = [pscustomobject]@{ Module = $scope; Pct = [double]0; Rows = ''; Unit = 'rows'; Rate = ''; Left = 0 }
        } elseif ($step -eq 'REBUILD_INDEXES') {
            $f.Rebuilt = 0
        }
        return
    }
    if ($code -eq 'STEP_END') {
        if ($severity -eq 'ERROR') {
            Write-FlowNote $message 'Red'
            return
        }
        if ($message -match '^\S+ (\S+)(?: (\S+))? DONE in (\d\d:\d\d:\d\d)(?:: (.*))?$' -and $script:StepNotes -contains $Matches[1]) {
            $step = $Matches[1]
            $scope = [string]$Matches[2]
            $time = Format-Clock (ConvertTo-Seconds $Matches[3])
            $what = ([string]$Matches[4]) -replace '; log switch waits 00:00:00$', ''
            if ($what -eq '') { return }
            if ($step -eq 'COMPACT') {
                Write-FlowNote (($scope + ': ' + $what).PadRight(64) + $time.PadLeft(5)) 'Green'
            } else {
                Write-FlowNote $what
            }
        }
        return
    }
    if ($code -eq 'BATCH_PROGRESS') {
        # "PAYMENTS batch 1,200/2,400 50.0% rows 9,109,274 39,149/s ... ETA 00:03:50";
        # the unit is rows or LOB values, and the rate is empty at the start.
        if ($message -match '^(\S+) batch [\d,]+/[\d,]+ ([\d.]+)% (.+?) ([\d,]+) ([\d,]*)/s(?:.*? ETA (\d+:\d\d:\d\d))?') {
            $pct = [double]0
            $null = [double]::TryParse($Matches[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$pct)
            $f.Module = $Matches[1]
            $f.Phase = 'deleting'
            $f.Batch = [pscustomobject]@{ Module = $Matches[1]; Pct = $pct; Rows = $Matches[4]; Unit = $Matches[3]; Rate = [string]$Matches[5];
                                          Left = (ConvertTo-Seconds ([string]$Matches[6])) }
            # Without a console window the line of the module cannot be
            # rewritten in place: each progress is a line.
            if (-not $script:StatusLine -and $pct -lt 100) { Write-Out (Get-ModuleLine $f.Batch) -NoLog }
        }
        return
    }
    if ($code -eq 'MODULE_END') {
        # "PAYMENTS DONE: 18,218,547 rows deleted in 00:08:49; ..."; STOPPED
        # or FAILED in place of DONE; LOB values cleared in place of rows
        # deleted. A dry run has no count (its FORECAST event says it).
        if ($message -match '^(\S+) (DONE|STOPPED|FAILED): ([\d,]+) (.+?) in (\d+:\d\d:\d\d)') {
            $module = $Matches[1]
            $result = $Matches[2]
            $count = $Matches[3]
            $what = $Matches[4]
            $time = Format-Clock (ConvertTo-Seconds $Matches[5])
            if ($what.StartsWith('rows')) { $what = 'rows' } elseif ($what.StartsWith('LOB values')) { $what = 'LOB values' }
            $f.Rows = $f.Rows + (ConvertTo-Count $count)
            if ($result -eq 'DONE') {
                Write-Out ('         ' + $module.PadRight(16) + ' ' + (Get-Bar 100) + ' 100%   ' + ($count + ' ' + $what).PadRight(26) +
                           $time.PadLeft(7)) 'Green' -NoLog
            } else {
                $pct = [double]0
                if ($null -ne $f.Batch) { $pct = $f.Batch.Pct }
                $color = 'Yellow'
                if ($result -eq 'FAILED') { $color = 'Red' }
                Write-Out ('         ' + $module.PadRight(16) + ' ' + (Get-Bar $pct) + ' ' + ('{0,3}%' -f [int][Math]::Floor($pct)) + '   ' +
                           ($count + ' ' + $what).PadRight(26) + $time.PadLeft(7) + '  ' + $result.ToLower()) $color -NoLog
            }
        }
        $f.Phase = ''
        $f.Batch = $null
        return
    }
    if ($code -eq 'FORECAST') {
        # A dry run: what it counted for the module (rows, or LOB values).
        if ($message -match '^(\S+): ([\d,]+) (rows|LOB values)') {
            $text = '         ' + $Matches[1].PadRight(16) + ' ' + ($Matches[2] + ' ' + $Matches[3]).PadLeft(26)
            if ($message -match 'about ([\d.]+ \w+) freed') { $text = $text + ('about ' + $Matches[1]).PadLeft(18) }
            Write-Out $text -NoLog
        }
        return
    }
    if ($code -eq 'PURGE_END') {
        $f.PurgeEnd = $message
        return
    }
    # The end of the run is said by the screen's own last lines.
    if ($code -eq 'RUN_END' -or $code -eq 'RUN_START') { return }
    if ($code -eq 'INDEX_REBUILT') {
        $f.Rebuilt = $f.Rebuilt + 1
        return
    }
    if ($code -eq 'UNIT_PARKED') {
        $f.Parked = $f.Parked + 1
        return
    }
    if ($code -eq 'UNIT_RETURNED') {
        $f.Returned = $f.Returned + 1
        return
    }
    if ($code -eq 'INDEXES_RELEASED' -and $message -match '^(\d[\d,]*) indexes released') {
        $f.Indexes = [int](ConvertTo-Count $Matches[1])
        return
    }
    if ($code -eq 'SCRATCH_CREATED' -and $message -match '^\S+: (\S+), .*?up to ([\d.]+ \w+)') {
        Write-FlowNote ('scratch space: ' + $Matches[1] + ', up to ' + $Matches[2] + '; removed at the end')
        return
    }
    if ($code -eq 'FILE_DONE') {
        Write-Wrapped '         ' $message
        return
    }
    if ($code -eq 'PLAN_STEP' -or ($code -eq 'PLAN' -and $message -notmatch ': one run')) {
        Write-FlowNote $message
        return
    }
    if ($code -eq 'STOP_HONORED' -or $code -eq 'STOP_REQUESTED') {
        Write-FlowNote $message 'Yellow'
        return
    }
    # A purge refused for a requirement: the wrapper says it with the way out.
    if ($script:SysEvents -contains $code -or $code -eq 'REQUIREMENTS_NOT_MET') { return }
    if ($severity -eq 'ERROR') {
        $text = $message
        if ($Field[6] -ne '' -and $message.IndexOf($Field[6]) -lt 0) { $text = $text + '  [' + $Field[6] + ']' }
        $f.Errors.Add($text)
        Write-Wrapped '         ERROR  ' $text 'Red'
        return
    }
    if ($severity -eq 'WARN' -and $script:QuietWarnings -notcontains $code) {
        # The check of the tool's list of tables: the ones a database does not
        # have are named together, once, when the check ends.
        if ($code -eq 'REG_TABLE_MISSING') {
            if ($Field[6] -ne '' -and -not $f.Missing.Contains($Field[6])) { $f.Missing.Add($Field[6]) }
            return
        }
        $text = $message
        if ($code -eq 'REG_SUMMARY') {
            $others = 0
            if ($message -match '(\d+) warnings') { $others = [int]$Matches[1] - $f.Missing.Count }
            if ($f.Missing.Count -gt 0) {
                $text = [string]$f.Missing.Count + ' of the tables this tool can purge are not in this database and are skipped: ' + ($f.Missing.ToArray() -join ', ')
                if ($others -gt 0) { $text = $text + '. ' + $message }
            }
        } elseif ($Field[6] -ne '' -and $message.IndexOf($Field[6]) -lt 0) {
            $text = $text + '  [' + $Field[6] + ']'
        }
        # A purge checks twice (its check, then the run itself): said once.
        if ($f.Notes.Contains($text)) { return }
        $f.Notes.Add($text)
        Write-FlowNote $text 'Yellow' 'note   '
    }
}

# What a step run by SYS printed (undo.sql, redo_logs.sql), on the screen of
# the steps. Its lines are "  CODE  message", without a severity. A step that
# puts things back runs outside the run and logs no event: its lines that say
# something was left as it was ($script:SysNotes) are shown here; those of a
# step that prepares the purge come as events of the run. Then one line of
# what the step did.
function Show-SysResult {
    param([string]$Output, [string]$What)
    foreach ($line in ($Output -split "`r?`n")) {
        if ($line -match 'ORA-\d{5}|SP2-\d{4}') {
            Write-FlowNote $line.Trim() 'Red'
        } elseif ($What.EndsWith('_BACK') -and $line -match '^\s+([A-Z][A-Z_]+)\s+(\S.*)$' -and $script:SysNotes -contains $Matches[1]) {
            Write-FlowNote $Matches[2].Trim() 'Yellow'
        }
    }
    switch ($What) {
        'REDO' {
            if ($Output -match '(?m)^\s+REDO_ENLARGED\s') {
                Write-FlowNote 'online redo logs: 4 x 1 GB for the purge; the present ones are put back at its end'
            } elseif ($Output -match '(?m)^\s+REDO_UNCHANGED\s+(.+?)\s*$') {
                Write-FlowNote ('online redo logs left as they are: ' + $Matches[1])
            }
        }
        'UNDO' {
            $kept = '60 s'
            if ($Output -match '(?m)^\s+UNDO_RETENTION_SET\s.*-> (\d+ s)') { $kept = $Matches[1] }
            $cap = ''
            if ($Output -match '(?m)^\s+UNDO_CAP\s+\S+ limited to (\d+) MB') { $cap = ' and its tablespace under ' + (Format-Bytes ([double]$Matches[1] * 1048576)) }
            if ($Output -match '(?m)^\s+UNDO_ALREADY_APPLIED\s') {
                Write-FlowNote 'undo tuning was applied already: kept as it is; put back at the end'
            } elseif ($Output -match '(?m)^\s+(UNDO_RETENTION_SET|UNDO_CAP)\s') {
                Write-FlowNote ('undo kept ' + $kept + $cap + ' while rows are deleted; put back at the end')
            }
        }
        'REDO_BACK' {
            if ($Output -match '(?m)^\s+REDO_RESTORED\s') { Write-FlowNote 'online redo logs: as they were before the purge' }
        }
        'UNDO_BACK' {
            if ($Output -match '(?m)^\s+UNDO_SWITCHED\s+(.+?)\s*$') {
                Write-FlowNote ('undo tablespace created again to give its space back: ' + $Matches[1])
            } elseif ($Output -match '(?m)^\s+UNDO_RETENTION_RESTORED\s') {
                Write-FlowNote 'undo tablespace: settings as before'
            }
        }
    }
}

# ----------------------------------------------------------------------------
# Requirements
# ----------------------------------------------------------------------------

function Get-ReqName {
    param([string]$Kind, [string]$Code, $Item)
    $key = $Kind + '.' + $Code
    if ($script:ReqNames.ContainsKey($key)) { return $script:ReqNames[$key] }
    return $Item.Title
}

# The scratch space the assessment of a reclaim suggests, as 8448M; empty
# when it suggests none.
function Get-ScratchAdvice {
    param($Advice)
    if ($Advice.Details.ContainsKey('SCRATCH.SIZE') -and [string]$Advice.Details['SCRATCH.SIZE'] -match '--scratch (\d+)M') {
        return ($Matches[1] + 'M')
    }
    return ''
}

# The requirements as the checks found them: each one with whether it is
# required, its state and what was measured; then, for each one not met, what
# happens and what to do. $Kind: PURGE or RECLAIM. $Scratch: the scratch
# space a reclaim takes by itself (empty: none). Returns the codes not met,
# the required ones first.
function Show-Requirements {
    param($Advice, [string]$Kind, [string]$Scratch = '')
    $what = $Kind.ToLower()
    $required = @()
    $optional = @()
    if ($Advice.Req.Count -eq 0) { return ,@() }
    Write-Out '' -NoLog
    Write-Out ('   ' + 'Requirement'.PadRight(34) + 'Needed'.PadRight(11) + 'Now') 'White' -NoLog
    foreach ($code in $Advice.Req.Keys) {
        $item = $Advice.Req[$code]
        $need = 'required'
        if ($item.Blocking -ne 'Y') { $need = 'optional' }
        $state = 'ok'
        $color = ''
        $measured = $item.Measured
        if ($item.Status -eq 'NOT_APPLICABLE') {
            $state = 'not needed'
        } elseif ($item.Status -eq 'NOT_MET' -and $Kind -eq 'RECLAIM' -and $code -eq 'SCRATCH' -and $Scratch -ne '') {
            # The reclaim takes its scratch space by itself.
            $measured = 'the reclaim takes up to ' + $Scratch + ' by itself' + ($measured -replace '^none \([^)]*\)', '')
        } elseif ($item.Status -eq 'NOT_MET') {
            $state = 'NOT MET'
            if ($item.Blocking -eq 'Y') {
                $color = 'Red'
                $required += $code
            } else {
                $color = 'Yellow'
                $optional += $code
            }
        } elseif ($item.MetBy -eq 'CONFIRMED') {
            $state = 'ok (your choice)'
        }
        Write-Out ('   ' + (Get-ReqName $Kind $code $item).PadRight(34) + $need.PadRight(11) + $state) $color -NoLog
        if ($measured -ne '') { Write-Wrapped '       ' $measured 'DarkGray' }
        if ($state -eq 'NOT MET') {
            if ($item.Why -ne '') { Write-Wrapped '       What happens: ' $item.Why $color 7 }
            $key = $Kind + '.' + $code
            if ($key -eq 'PURGE.REDO_LOGS' -and $script:Database.Pdb) { $key = 'PURGE.REDO_LOGS.PDB' }
            if ($script:ReqActions.ContainsKey($key)) { Write-Wrapped '       What to do:   ' ($script:ReqActions[$key] + '.') '' 7 }
        }
    }
    Write-Out '' -NoLog
    if ($required.Count -gt 0) {
        $names = @($required | ForEach-Object { Get-ReqName $Kind $_ $Advice.Req[$_] })
        Write-Wrapped '   ' ('Required and not met: ' + ($names -join ', ') + '. A ' + $what + ' is not recommended as things are.') 'Red'
    } elseif ($optional.Count -gt 0) {
        Write-Out ('   Only optional requirements are not met: the ' + $what + ' can run as things are.') 'Yellow' -NoLog
    } else {
        Write-Out ('   Every requirement is met: the ' + $what + ' can run as things are.') 'Green' -NoLog
    }
    return ,@($required + $optional)
}

# ----------------------------------------------------------------------------
# What a purge covers: the questions on the mode and the depth
# ----------------------------------------------------------------------------

# The name of a table on the screen: without its owner when that is the owner
# of most tables.
function Get-ScopeName {
    param($Facts, $Table)
    if ($Table.Name.StartsWith($Facts.Owner + '.')) { return $Table.Name.Substring($Facts.Owner.Length + 1) }
    return $Table.Name
}

# The tables a mode works on in the modules $Modules, as Kind (DELETE: the
# rows are deleted; CLEAR: their large values are emptied) and Table. Mode
# LOGS is the module LOGS alone; CLOB_N_LOGS always takes it, to delete.
function Get-ScopeTables {
    param($Facts, [string]$Mode, [string[]]$Modules)
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($t in $Facts.Tables) {
        if ($t.Present -ne 'Y') { continue }
        $kind = ''
        if ($Mode -eq 'FULL' -and $Modules -contains $t.Module) { $kind = 'DELETE' }
        elseif ($Mode -eq 'LOGS' -and $t.Module -eq 'LOGS') { $kind = 'DELETE' }
        elseif ($Mode -eq 'CLOB_N_LOGS' -and $t.Module -eq 'LOGS') { $kind = 'DELETE' }
        elseif (($Mode -eq 'CLOB' -or $Mode -eq 'CLOB_N_LOGS') -and $Modules -contains $t.Module -and $t.Clear -eq 'Y' -and $t.Lob -gt 0) { $kind = 'CLEAR' }
        if ($kind -ne '') { $list.Add([pscustomobject]@{ Kind = $kind; Table = $t }) }
    }
    return ,$list.ToArray()
}

# The tables of a choice in figures: Count, Bytes (the tables with their
# indexes and large values, or the large values alone where they are
# emptied) and Frees: those bytes by the share of the rows of each table's
# root that are dated before the cutoff; -1 when a root could not be counted.
function Measure-Scope {
    param($Facts, [object[]]$Items)
    $bytes = [double]0
    $frees = [double]0
    $known = $true
    foreach ($item in $Items) {
        $size = $item.Table.Bytes
        if ($item.Kind -eq 'CLEAR') { $size = $item.Table.Lob }
        $bytes += $size
        if ($Facts.Roots.ContainsKey($item.Table.Root) -and $Facts.Roots[$item.Table.Root].All -gt 0) {
            $frees += $size * $Facts.Roots[$item.Table.Root].Old / $Facts.Roots[$item.Table.Root].All
        } elseif (-not $Facts.Roots.ContainsKey($item.Table.Root)) {
            $known = $false
        }
    }
    if (-not $known) { $frees = [double]-1 }
    return [pscustomobject]@{ Count = $Items.Count; Bytes = $bytes; Frees = $frees }
}

# What a choice frees, for a column headed "Frees (about)"; "?" when a root
# could not be counted.
function Format-Frees {
    param([double]$Bytes)
    if ($Bytes -lt 0) { return '?' }
    return (Format-Bytes $Bytes)
}

# The heading of the table of a question on the mode or the depth, and one
# of its rows: a choice, the tables it works on, their size today, what it
# frees, then what it is, wrapped under its column.
function Write-ScopeHeader {
    param([string]$Name, [string]$Text)
    Write-Out ('   ' + $Name.PadRight(17) + 'Tables'.PadLeft(6) + 'Size now'.PadLeft(11) + 'Frees (about)'.PadLeft(16) + '   ' + $Text) 'White' -NoLog
}

function Write-ScopeRow {
    param([string]$Name, $Measure, [string]$Text)
    Write-Wrapped ('   ' + $Name.PadRight(17) + $Measure.Count.ToString().PadLeft(6) + (Format-Bytes $Measure.Bytes).PadLeft(11) +
                   (Format-Frees $Measure.Frees).PadLeft(16) + '   ') $Text
}

# The tables of each module, largest first: the size of each today and, in
# brackets, that of its large values (what the mode CLOB empties). In a
# module of many tables the small ones share a line.
function Show-ScopeTables {
    param($Facts)
    Write-Out '' -NoLog
    Write-Wrapped '   ' 'The tables, largest first. In brackets: the large values of a table (LOB columns: documents, messages), the part that CLOB empties.' 'DarkGray'
    foreach ($module in @($Facts.Modules.Keys)) {
        $mine = @($Facts.Tables | Where-Object { $_.Module -eq $module -and $_.Present -eq 'Y' } | Sort-Object -Property Bytes -Descending)
        if ($mine.Count -eq 0) { continue }
        $total = [double]0
        foreach ($t in $mine) { $total += $t.Bytes }
        Write-Out ('   ' + $module.PadRight(17) + $mine.Count.ToString() + ' tables, ' + (Format-Bytes $total)) 'White' -NoLog
        $small = New-Object 'System.Collections.Generic.List[string]'
        $smallBytes = [double]0
        foreach ($t in $mine) {
            $name = Get-ScopeName $Facts $t
            $lob = ''
            if ($t.Clear -eq 'Y' -and $t.Lob -gt 0) { $lob = '[' + (Format-Bytes $t.Lob) + ']' }
            if ($mine.Count -gt 6 -and $t.Bytes -lt 0.03 * $total) {
                if ($lob -ne '') { $name = $name + ' ' + $lob }
                $small.Add($name)
                $smallBytes += $t.Bytes
                continue
            }
            Write-Out ('       ' + $name.PadRight(34) + (Format-Bytes $t.Bytes).PadLeft(10) + '   ' + $lob).TrimEnd() -NoLog
        }
        if ($small.Count -gt 0) {
            Write-Wrapped '       ' ($small.Count.ToString() + ' smaller, ' + (Format-Bytes $smallBytes) + ' in all: ' + ($small -join ', ')) 'DarkGray' 9
        }
    }
}

# What the figures of these questions are, and what they leave out.
function Show-ScopeNotes {
    param($Facts)
    Write-Out '' -NoLog
    $missing = @($Facts.Tables | Where-Object { $_.Present -ne 'Y' } | ForEach-Object { Get-ScopeName $Facts $_ })
    if ($missing.Count -gt 0) {
        Write-Wrapped '   ' ('Not in this database, and skipped: ' + ($missing -join ', ') + '.') 'DarkGray'
    }
    Write-Wrapped '   ' ('Size now: the tables today, with their indexes and large values (the large values alone where they are emptied). ' +
                         'Frees: that size by the share of top-level records dated before ' + (Format-Day $Facts.Day) +
                         '; a rough estimate, which a dry run replaces by a count.') 'DarkGray'
    $covered = [double]0
    foreach ($t in $Facts.Tables) { $covered += $t.Bytes }
    if ($Facts.Schemas -gt $covered) {
        Write-Wrapped '   ' ((Format-Bytes ($Facts.Schemas - $covered)) + ' of the application''s ' + (Format-Bytes $Facts.Schemas) +
                             ' is in tables this tool does not purge.') 'DarkGray'
    }
}

# The question on the mode: each mode with the tables it works on in this
# database, their size today and a rough estimate of what it frees with the
# cutoff $Facts.Day; then the tables themselves.
function Show-ModeChoices {
    param($Facts)
    $modules = @($Facts.Modules.Keys)
    Write-ScopeHeader 'Mode' 'What it does'
    Write-ScopeRow 'FULL' (Measure-Scope $Facts (Get-ScopeTables $Facts 'FULL' $modules)) `
                   'deletes the rows, in the modules chosen next'
    Write-ScopeRow 'CLOB' (Measure-Scope $Facts (Get-ScopeTables $Facts 'CLOB' $modules)) `
                   'keeps the rows, empties their large values'
    Write-ScopeRow 'LOGS' (Measure-Scope $Facts (Get-ScopeTables $Facts 'LOGS' $modules)) `
                   'same as FULL with the module LOGS alone'
    Write-ScopeRow 'CLOB_N_LOGS' (Measure-Scope $Facts (Get-ScopeTables $Facts 'CLOB_N_LOGS' $modules)) `
                   'CLOB, and deletes the rows of module LOGS'
    Show-ScopeTables $Facts
    Show-ScopeNotes $Facts
}

# The question on the depth: each module with what it holds and what the
# mode chosen works on and frees in it. -WithTables: the tables too (the
# question on the mode was not asked, so they were not listed).
function Show-DepthChoices {
    param($Facts, [string]$Mode, [switch]$WithTables)
    $modules = @($Facts.Modules.Keys)
    Write-ScopeHeader 'Module' 'What it holds'
    $all = Get-ScopeTables $Facts $Mode $modules
    Write-ScopeRow 'ALL' (Measure-Scope $Facts $all) 'every module'
    foreach ($module in $modules) {
        $what = [string]$Facts.Modules[$module]
        if ($Mode -eq 'CLOB_N_LOGS' -and $module -eq 'LOGS') { $what = 'always part of this mode: its rows are deleted' }
        Write-ScopeRow $module (Measure-Scope $Facts @($all | Where-Object { $_.Table.Module -eq $module })) $what
    }
    if ($WithTables) {
        Show-ScopeTables $Facts
        Show-ScopeNotes $Facts
    } else {
        Write-Out '' -NoLog
    }
    if ($Mode -ne 'FULL') {
        Write-Wrapped '   ' ('Mode ' + $Mode + ': the tables counted are those with large values, and the sizes are those values.') 'DarkGray'
    }
    Write-Wrapped '   ' 'Several modules: their names separated by commas, such as PAYMENTS,LOGS.' 'DarkGray'
}

# ----------------------------------------------------------------------------
# The end of a run
# ----------------------------------------------------------------------------

# The modules of a table of the report (ESTIMATE, SIMULATION): Module, Rows,
# Roots (top-level records), Seconds of deleting and Bytes freed of each; 0
# for what the table does not say (a preflight counts the roots only: its
# rows and space freed are "-").
function Read-ForecastTable {
    param([string]$Report, [string]$Title)
    $list = New-Object 'System.Collections.Generic.List[object]'
    $size = '(?:-|\d+(?:\.\d+)? [KMGT]?B)'
    foreach ($line in (Get-TableLines $Report $Title)) {
        if ($line -match ('^  (?!Total |Module )([A-Z][A-Z_]*)\s+([\d,]+|-)\s+([\d,]+|-)\s+(?:[\d,]+|-)\s+' + $size + '\s+' + $size +
                          '\s+(\d+:\d\d:\d\d|-)\s+(' + $size + ')\s*$')) {
            $list.Add([pscustomobject]@{ Module = $Matches[1]; Rows = (ConvertTo-Count $Matches[2]); Roots = (ConvertTo-Count $Matches[3]);
                                         Seconds = (ConvertTo-Seconds $Matches[4]); Bytes = (ConvertTo-SizeBytes $Matches[5]) })
        }
    }
    return ,$list.ToArray()
}

# The lines of a section of the report as the report prints them.
function Show-ReportLines {
    param([string]$Report, [string]$Title)
    $lines = Get-TableLines $Report $Title
    if ($lines.Count -eq 0) { return }
    Write-Out '' -NoLog
    $first = $true
    foreach ($line in $lines) {
        if ($first) { Write-Out $line 'White' -NoLog } else { Write-Out $line -NoLog }
        $first = $false
    }
}

# The checks of a report in short: Status, Id, Title and Value of each.
function Read-Checks {
    param([string]$Report)
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in ($Report -split "`r?`n")) {
        if ($line -match '^EPF_CHECK\|[^|]*\|([^|]*)\|([^|]*)\|([^|]*)\|(.*)$') {
            $list.Add([pscustomobject]@{ Id = $Matches[1]; Status = $Matches[2]; Value = $Matches[3].Trim(); Title = $Matches[4].Trim() })
        }
    }
    return ,$list.ToArray()
}

# "Every check passed.", or how many did not.
function Get-CheckSentence {
    param([object[]]$Checks)
    $failed = @($Checks | Where-Object { $_.Status -eq 'FAIL' })
    $warned = @($Checks | Where-Object { $_.Status -eq 'WARN' -and $_.Id -ne 'P5' })
    if ($failed.Count -gt 0) { return ($failed.Count.ToString() + ' of ' + $Checks.Count + ' checks FAILED.') }
    if ($Checks.Count -eq 0) { return '' }
    if ($warned.Count -eq 0) { return 'Every check passed.' }
    if ($warned.Count -eq 1) { return 'The checks passed, with 1 note.' }
    return ('The checks passed, with ' + $warned.Count + ' notes.')
}

# What to know after a run: the checks that failed or have a note, then the
# notes given.
function Show-GoodToKnow {
    param([object[]]$Checks, [string[]]$Notes = @())
    $failed = @($Checks | Where-Object { $_.Status -eq 'FAIL' })
    if ($failed.Count -gt 0) {
        Write-Out '' -NoLog
        Write-Out ('  Failed checks (' + $failed.Count + ')') 'Red' -NoLog
        foreach ($c in $failed) { Write-Wrapped '   - ' ($c.Title + ': ' + $c.Value) 'Red' }
    }
    $items = @($Checks | Where-Object { $_.Status -eq 'WARN' } | ForEach-Object { $_.Title + ': ' + $_.Value }) + @($Notes | Where-Object { $_ -ne '' })
    if ($items.Count -gt 0) {
        Write-Out '' -NoLog
        Write-Out ('  Good to know (' + $items.Count + ')') 'Yellow' -NoLog
        foreach ($item in $items) { Write-Wrapped '   - ' $item }
    }
}

# The lines of a section of the report that the screen shows as they are,
# under the heading $Heading.
function Show-ReportBlock {
    param([string]$Report, [string]$Title, [string]$Heading)
    $lines = Get-TableLines $Report $Title
    if ($lines.Count -lt 2) { return }
    Write-Out '' -NoLog
    Write-Out ('   ' + $Heading) 'White' -NoLog
    # A row wider than the screen goes on under its last column ("Where"),
    # or below the row when that column is one long word; a line that is not
    # a row of the table (what a column means) is a sentence, wrapped.
    $width = Get-WrapWidth
    $column = (' ' + $lines[1]).IndexOf('Where')
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $text = ' ' + $lines[$i]
        # Said by the lines that follow the block on the screen.
        if ($lines[$i].StartsWith('  The space is freed inside the tables')) { continue }
        $row = ($column -gt 2 -and $text.Length -gt $column -and $text.Substring($column - 2, 2) -eq '  ')
        if ($i -gt 1 -and -not $row) {
            Write-Wrapped '   ' $text.Trim() 'DarkGray'
        } elseif ($text.Length -le $width) {
            Write-Out $text -NoLog
        } else {
            $cut = $text.LastIndexOf(' ', $width - 1)
            if ($cut -gt $column) {
                Write-Out $text.Substring(0, $cut) -NoLog
                Write-Wrapped (' ' * $column) $text.Substring($cut + 1)
            } else {
                Write-Out $text.Substring(0, $column).TrimEnd() -NoLog
                Write-Wrapped '       ' $text.Substring($column)
            }
        }
    }
}

# The other retentions of a dry run or preflight: days kept, rows and space.
function Show-RetentionOptions {
    param([string]$Report)
    $rows = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in (Get-TableLines $Report 'RETENTION OPTIONS')) {
        if ($line -match '^  ([\d,]+)\s+(\d{4}-\d\d-\d\d)\s+([\d,]+)\s+([\d,]+|-)(.*)$') {
            $days = $Matches[1]
            $cutoff = $Matches[2]
            $count = $Matches[4]
            $rest = $Matches[5]
            $freed = ''
            # Redo, archive need and space freed follow the rows, each a size
            # or "-" (a preflight has no rows and no space freed).
            if ($rest -match '^\s+(?:-|[\d.]+ [KMGT]?B)\s+(?:-|[\d.]+ [KMGT]?B)\s+([\d.]+ [KMGT]?B)\s') { $freed = 'about ' + $Matches[1] }
            if ($count -eq '-') { continue }
            $mark = ''
            if ($rest.Contains('(requested)')) { $mark = '   (this dry run)' }
            $rows.Add('     ' + ($days + ' days kept').PadRight(20) + ('before ' + $cutoff).PadRight(20) + $count.PadLeft(14) +
                      $freed.PadLeft(20) + $mark)
        }
    }
    if ($rows.Count -lt 2) { return }
    Write-Out '' -NoLog
    Write-Out '   Other retentions, as examples of what else could be kept' 'White' -NoLog
    Write-Out ('     ' + 'Days kept'.PadRight(20) + 'Purges rows dated'.PadRight(20) + 'Rows deleted'.PadLeft(14) + 'Space freed'.PadLeft(20)) 'DarkGray' -NoLog
    foreach ($row in $rows) { Write-Out $row -NoLog }
    Write-Wrapped '   ' 'Any number of days can be tried the same way: epf_purge.bat purge --dry-run --retention DAYS.' 'DarkGray'
}

# The end of a dry run of a purge: what a purge would delete, how long, per
# module, the disk it uses meanwhile, the other retentions.
function Show-DryRunEnd {
    param($Ctx, [string]$Report, [string]$Status)
    $modules = Read-ForecastTable $Report 'SIMULATION'
    $rows = [double]0
    $bytes = [double]0
    $seconds = [double]0
    foreach ($m in $modules) { $rows += $m.Rows; $bytes += $m.Bytes; $seconds += $m.Seconds }
    $day = Format-Day (Get-CutoffDay $Ctx)
    $expected = ''
    if ($Report -match '(?m)^EPF_EXPECTED\|[^|]*\|([A-Z_]+)\|') { $expected = $Matches[1] }
    if ($Status -ne 'FAILED' -and $modules.Count -eq 0) {
        # Not the table this screen knows: the report's own lines.
        Show-ReportLines $Report 'SIMULATION'
        foreach ($line in (Get-ExpectedLines $Report)) { Write-Out $line -NoLog }
        Show-ReportBlock $Report 'DISK WHILE THE PURGE RUNS' 'Disk used while the purge runs (given back at its end)'
        Show-ReportLines $Report 'RETENTION OPTIONS'
        return
    }
    Write-Out '' -NoLog
    Write-Rule
    if ($Status -eq 'FAILED') {
        Write-Out '  The dry run did not finish: see the errors above. Nothing was changed.' 'Red' -NoLog
        Write-Rule
        return
    }
    Write-Wrapped '  ' ('A purge would delete ' + (Format-Count $rows) + ' rows, about ' + (Format-Bytes $bytes) + ', dated before ' + $day + '.') 'White'
    $outcome = 'and would complete as things are.'
    $color = 'White'
    if ($expected -eq 'FAIL') { $outcome = 'but it would FAIL as things are (below).'; $color = 'Red' }
    elseif ($expected -eq 'MAY_FAIL') { $outcome = 'but it may fail as things are (below).'; $color = 'Yellow' }
    Write-Wrapped '  ' ('It would take ' + (Format-About $seconds) + ' of deleting, ' + $outcome) $color
    Write-Rule
    if ($expected -ne 'COMPLETE' -and $expected -ne '') {
        foreach ($line in (Get-ExpectedLines $Report)) { Write-Wrapped '  ' $line.Trim() $color }
        Write-Out '' -NoLog
    }
    Write-Out ('   ' + 'What'.PadRight(20) + 'Rows to delete'.PadLeft(16) + 'Space freed (about)'.PadLeft(22) + 'Deleting'.PadLeft(12)) 'White' -NoLog
    foreach ($m in $modules) {
        Write-Out ('   ' + $m.Module.PadRight(20) + (Format-Count $m.Rows).PadLeft(16) + (Format-Bytes $m.Bytes).PadLeft(22) +
                   (Format-Clock $m.Seconds).PadLeft(12)) -NoLog
    }
    Write-Out '' -NoLog
    Write-Wrapped '   ' 'The space is freed inside the tables: the datafiles keep their size until a reclaim gives it back to the disk.'
    Show-ReportBlock $Report 'DISK WHILE THE PURGE RUNS' 'Disk used while the purge runs (given back at its end)'
    Show-RetentionOptions $Report
}

# The end of a purge: what was deleted and whether the checks passed.
function Show-PurgeEnd {
    param($Ctx, [string]$Report, [string]$Status, [string]$Total, [switch]$Refused)
    $checks = Read-Checks $Report
    $rows = [double]0
    if ($null -ne $script:Flow) { $rows = $script:Flow.Rows }
    $what = (Format-Count $rows) + ' rows deleted'
    if ($Ctx.Mode -eq 'CLOB') { $what = (Format-Count $rows) + ' LOB values cleared' }
    elseif ($Ctx.Mode -eq 'CLOB_N_LOGS') { $what = (Format-Count $rows) + ' rows deleted or LOB values cleared' }
    Write-Out '' -NoLog
    if ($Refused) {
        Write-Rule 'Red'
        Write-Wrapped '  NOT STARTED   ' 'A required condition is not met (above). Nothing was changed.' 'Red'
        Write-Rule 'Red'
        return
    }
    if ($Status -eq 'SUCCESS' -or $Status -eq 'WARNING') {
        $failed = @($checks | Where-Object { $_.Status -eq 'FAIL' })
        $color = 'Green'
        if ($failed.Count -gt 0) { $color = 'Red' }
        Write-Rule $color
        Write-Wrapped '  DONE   ' ((Format-Sentence $what) + ' in ' + $Total + '. ' + (Get-CheckSentence $checks)) $color
        Write-Rule $color
        $freed = ''
        foreach ($c in $checks) {
            if ($c.Id -eq 'P7' -and $c.Value -match '^(\d+(?:\.\d+)? [KMGT]?B) freed') { $freed = $Matches[1] }
        }
        if ($freed -ne '') {
            Write-Wrapped '  ' ($freed + ' is now free inside the tables. The datafiles keep their size until a reclaim gives it back to the disk (the database must not be in use during a reclaim):')
        } else {
            Write-Wrapped '  ' 'The space is free inside the tables. The datafiles keep their size until a reclaim gives it back to the disk (the database must not be in use during a reclaim):'
        }
        Write-Out '      epf_purge.bat reclaim --dry-run' 'Cyan' -NoLog
    } elseif ($Status -eq 'STOPPED') {
        Write-Rule 'Yellow'
        Write-Wrapped '  STOPPED   ' ('on request: ' + $what + ' so far, in ' + $Total + '. What was deleted stays deleted; nothing is half done.') 'Yellow'
        Write-Rule 'Yellow'
        Write-Wrapped '  ' 'The same command goes on from here.'
    } else {
        Write-Rule 'Red'
        Write-Wrapped '  FAILED   ' ($what + ' before it failed, in ' + $Total + '. What was deleted stays deleted; each batch is its own transaction, so nothing is half done.') 'Red'
        Write-Rule 'Red'
        if ($null -ne $script:Flow) {
            foreach ($e in $script:Flow.Errors) { Write-Wrapped '   - ' $e 'Red' }
        }
        Write-Wrapped '  ' 'epf_purge.bat status shows whether anything is left pending. Once the cause is removed, the same command goes on from here.'
    }
    # The warnings P5 counts are the notes of the run, shown as they came.
    $notes = @()
    if ($null -ne $script:Flow) { $notes += $script:Flow.Notes.ToArray() }
    foreach ($line in (Get-DiskLines $Report)) {
        if ($line -match '^ WAITS\s+(.+)$') { $notes += ('Time waiting for the online redo logs: ' + $Matches[1]) }
    }
    Show-GoodToKnow @($checks | Where-Object { $_.Id -ne 'P5' -or $_.Status -eq 'FAIL' }) $notes
}

# The accounts a reclaim locks, from the ACCOUNTS section of its report.
function Read-ReclaimAccounts {
    param([string]$Report)
    $names = @()
    foreach ($line in (Get-TableLines $Report 'ACCOUNTS')) {
        if ($line -match '^  (?!Account )([A-Z][A-Z0-9_$#]*)\s+\S') { $names += $Matches[1] }
    }
    return ,$names
}

# What a reclaim would give back, as its assessment found it. $Scratch: the
# scratch space the reclaim takes (bytes as text; empty: none).
function Show-ReclaimAssess {
    param([string]$Report, [object[]]$Spaces, [string]$Scratch = '', [string]$ScratchFile = '')
    Write-Out '' -NoLog
    Write-Rule
    if ($Spaces.Count -eq 0) {
        Write-Out '  Nothing to reclaim: no tablespace holds segments of the application.' 'White' -NoLog
        Write-Rule
        return
    }
    $start = [double]0
    $forecast = [double]0
    foreach ($t in $Spaces) { $start += $t.Start; $forecast += [Math]::Min($t.Forecast, $t.Start) }
    $back = [Math]::Max($start - $forecast, 0)
    $names = @($Spaces | ForEach-Object { $_.Name })
    if ($back -lt [Math]::Max(0.01 * $start, 67108864)) {
        Write-Wrapped '  ' ('Almost nothing to give back: ' + ($names -join ', ') + ' takes ' + (Format-Bytes $start) + ' and would take about ' + (Format-Bytes $forecast) + ' after a reclaim.') 'White'
    } else {
        Write-Wrapped '  ' ('A reclaim takes ' + ($names -join ', ') + ' from ' + (Format-Bytes $start) + ' to about ' + (Format-Bytes $forecast) + ': ' + (Format-Bytes $back) + ' back to the disk.') 'White'
    }
    Write-Rule
    $accounts = Read-ReclaimAccounts $Report
    if ($accounts.Count -gt 0) {
        Write-Wrapped '  ' ('The database must not be in use meanwhile: the application accounts ' + ($accounts -join ', ') + ' are locked and their sessions disconnected until it ends.') 'Yellow'
    } else {
        Write-Wrapped '  ' 'The database must not be in use meanwhile: the application accounts are locked and their sessions disconnected until it ends.' 'Yellow'
    }
    Write-Out '' -NoLog
    $max = [double]0
    foreach ($t in $Spaces) { $max = [Math]::Max($max, $t.Start) }
    foreach ($t in $Spaces) {
        $after = [Math]::Min($t.Forecast, $t.Start)
        Write-Out ('   ' + $t.Name.PadRight(18) + 'today  ' + (Get-Bar (100.0 * $t.Start / $max) 30) + '  ' + (Format-Bytes $t.Start)) -NoLog
        Write-Out ('   ' + ''.PadRight(18) + 'after  ' + (Get-Bar (100.0 * $after / $max) 30) + '  about ' + (Format-Bytes $after)) -NoLog
        Write-Out ('   ' + ''.PadRight(18) + $t.Tables + ' tables move, ' + $t.Indexes + ' indexes are rebuilt, ' + $t.Pins + ' segments stay where they are') 'DarkGray' -NoLog
    }
    Write-Out '' -NoLog
    Write-Out '   Disk used while the reclaim runs (removed at its end)' 'White' -NoLog
    if ($Scratch -ne '') {
        $where = ''
        if ($ScratchFile -ne '') { $where = ': ' + $ScratchFile }
        Write-Wrapped '     ' ('Scratch space, up to ' + (Format-Bytes ([double]$Scratch)) + $where + ' (a file the tool creates and removes), for the tables that cannot move lower: they wait there and come back. The run takes only what it needs of it.')
    } else {
        Write-Wrapped '     ' 'No scratch space: a table that cannot move lower stops its datafile there.'
    }
    Write-Wrapped '     ' 'No datafile grows above its size at the start.'
}

# The end of a reclaim: what went back to the disk and the state comparison.
function Show-ReclaimEnd {
    param([string]$Report, [string]$Status, [string]$Total, [string]$Mode, [switch]$Refused)
    $checks = Read-Checks $Report
    $spaces = Read-ReclaimTs $Report
    Write-Out '' -NoLog
    if ($Refused) {
        Write-Rule 'Red'
        Write-Wrapped '  NOT STARTED   ' 'A required condition is not met (above). Nothing was changed.' 'Red'
        Write-Rule 'Red'
        return
    }
    if ($Mode -eq 'RESTORE') {
        if ($Status -eq 'FAILED') {
            Write-Rule 'Red'
            Write-Wrapped '  FAILED   ' 'The restore did not finish: see the errors above. epf_purge.bat status shows what is still pending.' 'Red'
            Write-Rule 'Red'
        } else {
            Write-Rule 'Green'
            Write-Wrapped '  DONE   ' ('What reclaims left pending is restored, in ' + $Total + '. ' + (Get-CheckSentence $checks)) 'Green'
            Write-Rule 'Green'
        }
        Show-GoodToKnow $checks
        return
    }
    $parts = @()
    $back = [double]0
    foreach ($t in $spaces) {
        if ($t.End -gt 0) {
            $parts += ($t.Name + ' went from ' + (Format-Bytes $t.Start) + ' to ' + (Format-Bytes $t.End))
            $back += [Math]::Max($t.Start - $t.End, 0)
        }
    }
    if ($Status -eq 'SUCCESS' -or $Status -eq 'WARNING') {
        $failed = @($checks | Where-Object { $_.Status -eq 'FAIL' })
        $color = 'Green'
        if ($failed.Count -gt 0) { $color = 'Red' }
        Write-Rule $color
        if ($parts.Count -gt 0) {
            Write-Wrapped '  DONE   ' (($parts -join '; ') + ': ' + (Format-Bytes $back) + ' given back to the disk.') $color
        } else {
            Write-Wrapped '  DONE   ' 'Nothing had to move.' $color
        }
        Write-Wrapped '         ' ($Total + '. The application accounts are unlocked. ' + (Get-CheckSentence $checks)) $color
        Write-Rule $color
    } elseif ($Status -eq 'STOPPED') {
        Write-Rule 'Yellow'
        Write-Wrapped '  STOPPED   ' ('on request, in ' + $Total + '. The indexes, the datafile settings and the accounts are restored; a later reclaim goes on from here.') 'Yellow'
        Write-Rule 'Yellow'
        if ($parts.Count -gt 0) { Write-Wrapped '  ' (($parts -join '; ') + '.') }
    } else {
        Write-Rule 'Red'
        Write-Wrapped '  FAILED   ' ('in ' + $Total + '. No data is lost. Whether the database is as it was: epf_purge.bat status; epf_purge.bat reclaim --restore puts back what is pending.') 'Red'
        Write-Rule 'Red'
        if ($null -ne $script:Flow) {
            foreach ($e in $script:Flow.Errors) { Write-Wrapped '   - ' $e 'Red' }
        }
    }
    if ($Report -match '(?m)^\s+On disk: (.+?)\s*$') { Write-Wrapped '  ' ('Most held on disk: ' + $Matches[1] + '.') }
    $notes = @()
    if (($Status -eq 'SUCCESS' -or $Status -eq 'WARNING') -and $back -gt 0) {
        $notes += 'Within minutes Oracle adds about 5% of free space back to a datafile that can grow: expect it a little larger than above. Nothing to do.'
    }
    Show-GoodToKnow $checks $notes
}

# The end of a preflight: its estimate per module, the disk a purge takes and
# the other retentions.
function Show-PreflightEnd {
    param($Ctx, [string]$Report, [string]$Status)
    if ($Status -eq 'FAILED') {
        Write-Out '' -NoLog
        Write-Out '  The checks found errors: see above. Nothing was changed.' 'Red' -NoLog
        return
    }
    Show-ReportLines $Report 'ESTIMATE'
    Write-Wrapped '  ' 'Roots are the top-level records old enough to purge; a dry run counts the rows under them and the space they free: epf_purge.bat purge --dry-run.' 'DarkGray'
    Show-ReportBlock $Report 'DISK WHILE THE PURGE RUNS' 'Disk used while the purge runs (given back at its end)'
    Show-ReportLines $Report 'RETENTION OPTIONS'
    Write-Out '' -NoLog
    Write-Out '  Nothing was changed.' 'Green' -NoLog
}

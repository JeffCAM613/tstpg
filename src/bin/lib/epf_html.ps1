# ============================================================================
# EPF Data Purge - HTML report of a run
# ============================================================================
# Purpose : Writes report.html in a run folder from the files the wrapper
#           leaves there (manifest.txt, report.txt, console.log): the result
#           in one sentence, the main figures, the modules or the tablespaces,
#           the duration by step, the checks, the requirements, warnings and
#           errors, what to do next, and the full text report. One file with
#           its styles inside: it can be opened, printed and sent as it is.
# Usage   : dot-sourced by epf.ps1, with epf_screen.ps1 (Get-WaitSentence);
#           Write-HtmlReport <run folder> returns the path written, '' when
#           the folder has no manifest.
# Requires: Windows PowerShell 5.1.
# ============================================================================

function ConvertTo-HtmlText {
    param([string]$Text)
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Get-HtmlValue {
    param($Table, [string]$Key, [string]$Default = '')
    if ($Table.ContainsKey($Key)) { return [string]$Table[$Key] }
    return $Default
}

# Seconds as 0:07, 12:45 or 1:27:42.
function Format-HtmlTime {
    param([double]$Seconds)
    $s = [int][Math]::Round($Seconds)
    if ($s -ge 3600) { return ('{0}:{1:00}:{2:00}' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60), ($s % 60)) }
    return ('{0}:{1:00}' -f [Math]::Floor($s / 60), ($s % 60))
}

function Format-HtmlBytes {
    param([double]$Bytes)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1073741824) { return [string]::Format($inv, '{0:0.0} GB', $Bytes / 1073741824) }
    if ($Bytes -ge 1048576) { return [string]::Format($inv, '{0:0.0} MB', $Bytes / 1048576) }
    return [string]::Format($inv, '{0:0} KB', $Bytes / 1024)
}

# "PROCESS_BATCHES" as "Process batches".
function Format-HtmlStep {
    param([string]$Code, [string]$Scope)
    $text = $Code.Replace('_', ' ').ToLower()
    if ($text.Length -gt 0) { $text = $text.Substring(0, 1).ToUpper() + $text.Substring(1) }
    if ($Scope -ne '' -and $Scope -ne '-') { $text = $text + ', ' + $Scope }
    return $text
}

function Get-HtmlBar {
    param([string]$Label, [double]$Value, [double]$Max, [string]$Class, [string]$Text)
    $width = 0.6
    if ($Max -gt 0) { $width = [Math]::Max(0.6, [Math]::Min(100, 100.0 * $Value / $Max)) }
    $w = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', $width)
    return '<div class="bar"><span class="bl">' + (ConvertTo-HtmlText $Label) + '</span><span class="track"><span class="fill ' + $Class +
           '" style="width:' + $w + '%"></span></span><span class="bv">' + (ConvertTo-HtmlText $Text) + '</span></div>'
}

function Write-HtmlReport {
    param([string]$Folder)
    $manifestPath = Join-Path $Folder 'manifest.txt'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return '' }
    $m = @{}
    $steps = New-Object 'System.Collections.Generic.List[object]'
    $checkOrder = New-Object 'System.Collections.Generic.List[string]'
    $checks = @{}
    $reqs = New-Object 'System.Collections.Generic.List[object]'
    $spaces = New-Object 'System.Collections.Generic.List[object]'
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $key = $line.Substring(0, $eq)
        $value = $line.Substring($eq + 1)
        $m[$key] = $value
        if ($line -match '^step\.[^.]+\.([^.=]+)\.([^=]*)=([^|]*)\|(\d*)$') {
            $sec = 0
            if ($Matches[4] -ne '') { $sec = [int]$Matches[4] }
            $steps.Add(@{ Code = $Matches[1]; Scope = $Matches[2]; Status = $Matches[3]; Seconds = $sec })
        } elseif ($line -match '^check\.(\w+)=([^|]*)\|?(.*)$') {
            $checkOrder.Add($Matches[1])
            $checks[$Matches[1]] = @{ Status = $Matches[2]; Value = $Matches[3]; Title = $Matches[1] }
        } elseif ($line -match '^req\.(\w+)=([^|]*)\|([^|]*)\|(.*)$') {
            $reqs.Add(@{ Code = $Matches[1]; Status = $Matches[2]; Blocking = $Matches[3]; By = $Matches[4] })
        } elseif ($line -match '^tablespace\.([^=]+)=([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|') {
            $nums = @(0, 0, 0, 0)
            for ($k = 0; $k -lt 4; $k++) { $d = 0.0; if ([double]::TryParse($Matches[$k + 3], [ref]$d)) { $nums[$k] = $d } }
            $spaces.Add(@{ Name = $Matches[1]; Status = $Matches[2]; Start = $nums[0]; End = $nums[1]; Peak = $nums[2]; Forecast = $nums[3]
                           Tables = $Matches[7]; Indexes = $Matches[8]; Moved = $Matches[9] })
        }
    }
    $reportLines = @()
    $reportPath = Join-Path $Folder 'report.txt'
    if (Test-Path -LiteralPath $reportPath) { $reportLines = @(Get-Content -LiteralPath $reportPath) }
    $when = ''
    # What a purge takes on disk while it runs (EPF_DISK lines) and the other
    # retentions of a dry run or preflight (the rows of RETENTION OPTIONS).
    $disk = New-Object 'System.Collections.Generic.List[object]'
    $options = New-Object 'System.Collections.Generic.List[object]'
    $diskNames = @{ 'UNDO' = 'Undo'; 'TEMP' = 'Temporary space'; 'INDEXES' = 'Temporary indexes'; 'REDO' = 'Online redo logs';
                    'ARCHIVE' = 'Archived logs' }
    $inOptions = $false
    foreach ($line in $reportLines) {
        if ($line -match '^ RETENTION OPTIONS') {
            $inOptions = $true
        } elseif ($line -match '^ [A-Z]') {
            $inOptions = $false
        }
        if ($line -match '^EPF_DISK\|[^|]*\|([A-Z_]+)\|(\d*)\|(\d*)\|(.*)$') {
            $name = $Matches[1]
            if ($diskNames.ContainsKey($name)) { $name = $diskNames[$name] }
            $most = 0.0
            $more = 0.0
            $null = [double]::TryParse($Matches[2], [ref]$most)
            $null = [double]::TryParse($Matches[3], [ref]$more)
            $disk.Add(@{ Name = $name; Most = $most; More = $more; Where = $Matches[4].Trim() })
        } elseif ($inOptions -and $line -match '^  ([\d,]+)\s+(\d{4}-\d\d-\d\d)\s+[\d,]+\s+([\d,]+|-)(.*)$') {
            $days = $Matches[1]
            $cutoff = $Matches[2]
            $count = $Matches[3]
            $rest = $Matches[4]
            # Redo, archive need and space freed follow the rows, each a size
            # or "-" (a preflight has no rows and no space freed).
            $freed = '-'
            if ($rest -match '^\s+(?:-|[\d.]+ [KMGT]?B)\s+(?:-|[\d.]+ [KMGT]?B)\s+([\d.]+ [KMGT]?B)\s') { $freed = $Matches[1] }
            $options.Add(@{ Days = $days; Cutoff = $cutoff; Rows = $count; Freed = $freed; Yours = $rest.Contains('(requested)') })
        }
    }
    foreach ($line in $reportLines) {
        if ($line -match '^EPF_CHECK\|[^|]*\|([^|]*)\|[^|]*\|[^|]*\|(.*)$' -and $checks.ContainsKey($Matches[1])) {
            $checks[$Matches[1]].Title = $Matches[2].Trim()
        } elseif ($when -eq '' -and $line -match 'started (\S+ \S+), ended (\S+ \S+), duration (\d+:\d\d:\d\d)') {
            $when = $Matches[1] + ' to ' + $Matches[2] + '<br>' + $Matches[3]
        }
    }
    # The modules of a purge (rows and time), what a dry run forecasts, and
    # the lines that say what went wrong or what comes next: from console.log.
    $modules = New-Object 'System.Collections.Generic.List[object]'
    $forecasts = New-Object 'System.Collections.Generic.List[object]'
    $troubles = New-Object 'System.Collections.Generic.List[string]'
    $next = New-Object 'System.Collections.Generic.List[string]'
    $peak = ''
    $reclaimText = ''
    $dbFiles = ''
    $waits = ''
    $consolePath = Join-Path $Folder 'console.log'
    if (Test-Path -LiteralPath $consolePath) {
        foreach ($line in (Get-Content -LiteralPath $consolePath)) {
            if ($line -match '^\s\d\d:\d\d:\d\d \[(.{4})\] (\S+)\s+(.*)$') {
                $tag = $Matches[1]
                $code = $Matches[2]
                $text = $Matches[3]
                if ($code -eq 'MODULE_END' -and $text -match '^(\S+) \w+: ([\d,]+) (rows deleted|LOB values cleared) in (\d+:\d\d:\d\d)') {
                    $modules.Add(@{ Name = $Matches[1]; Rows = $Matches[2]; What = $Matches[3]; Time = $Matches[4] })
                } elseif ($code -eq 'FORECAST' -and $text -match '^(\S+): ([\d,]+) rows, [\d,]+ batches, about (.+?) redo, (.+?) undo, (\d+:\d\d:\d\d) deleting, about (.+?) freed') {
                    $forecasts.Add(@{ Name = $Matches[1]; Rows = $Matches[2]; Redo = $Matches[3]; Undo = $Matches[4]; Time = $Matches[5]; Freed = $Matches[6] })
                } elseif ($code -eq 'DISK_PEAK') {
                    $peak = $text
                } elseif ($code -eq 'RECLAIMABLE') {
                    $reclaimText = $text
                } elseif ($code -eq 'DB_FILES') {
                    $dbFiles = $text
                } elseif ($code -eq 'REDO_WAITS') {
                    $waits = $text
                }
                if (($tag -eq 'WARN' -or $tag -eq 'FAIL') -and $code -ne 'RUN_END') {
                    $entry = $tag + '|' + $code + '|' + $text
                    if (-not $troubles.Contains($entry) -and $troubles.Count -lt 40) { $troubles.Add($entry) }
                }
            } elseif ($line -match '^ (Next|Plan)    (.*)$') {
                $next.Add($Matches[2].Trim())
            }
        }
    }

    $action = Get-HtmlValue $m 'action'
    $dry = ((Get-HtmlValue $m 'dry_run') -eq 'Y')
    $mode = Get-HtmlValue $m 'reclaim_mode'
    $status = Get-HtmlValue $m 'status'
    $verdict = Get-HtmlValue $m 'verdict'
    $kind = $action.ToLower()
    if ($action -eq 'RECLAIM' -and $mode -eq 'RESTORE') { $kind = 'reclaim, restore' }
    elseif ($dry) { $kind = $kind + ', dry run' }
    $scope = ''
    if ((Get-HtmlValue $m 'cutoff') -ne '') { $scope = 'rows dated before ' + (Get-HtmlValue $m 'cutoff') }
    elseif ((Get-HtmlValue $m 'retention_days') -ne '') { $scope = 'the last ' + (Get-HtmlValue $m 'retention_days') + ' days kept' }

    # The verdict in a word and the result in a sentence.
    $class = 'ok'
    $badge = 'Done'
    if ($verdict -eq 'FAIL' -or $status -eq 'FAILED') { $class = 'bad'; $badge = 'Failed' }
    elseif ($status -eq 'STOPPED') { $class = 'warn'; $badge = 'Stopped' }
    elseif ($verdict -eq 'PASS WITH WARNINGS') { $class = 'warn'; $badge = 'Done, with notes' }
    if ($dry -and $class -ne 'bad') { $badge = 'Dry run' }
    if ($action -eq 'PREFLIGHT' -and $class -ne 'bad') { $badge = 'Checked' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $sumRows = 0.0
    $source = $modules
    if ($dry) { $source = $forecasts }
    foreach ($x in $source) { $sumRows += [double]($x.Rows.Replace(',', '')) }
    $rowsText = [string]::Format($inv, '{0:N0}', $sumRows)
    $start = 0.0
    $end = 0.0
    $forecast = 0.0
    $moved = 0
    foreach ($t in $spaces) {
        $start += $t.Start
        $end += $t.End
        $forecast += $t.Forecast
        $n = 0
        if ([int]::TryParse($t.Moved, [ref]$n)) { $moved += $n }
    }
    $lead = ''
    $tiles = New-Object 'System.Collections.Generic.List[object]'
    if ($action -eq 'PURGE' -and $dry) {
        $lead = '<strong>A purge would delete ' + $rowsText + ' rows</strong>'
        if ($scope -ne '') { $lead = $lead + ' (' + $scope + ')' }
        $lead = $lead + '. Nothing was changed.'
        $tiles.Add(@('rows a purge would delete', $rowsText))
        $expected = (Get-HtmlValue $m 'expected').Split('|')
        if ($expected.Count -ge 3) {
            $sec = 0.0
            $bytes = 0.0
            if ([double]::TryParse($expected[1], [ref]$sec)) { $tiles.Add(@('expected deleting time', (Format-HtmlTime $sec))) }
            if ([double]::TryParse($expected[2], [ref]$bytes)) { $tiles.Add(@('would be freed inside the tables', (Format-HtmlBytes $bytes))) }
            $word = @{ 'COMPLETE' = 'It would complete as things are.'; 'FAIL' = 'It would not complete as things are.'; 'MAY_FAIL' = 'It may not complete as things are.' }
            if ($word.ContainsKey($expected[0])) { $lead = $lead + ' ' + $word[$expected[0]] }
        }
    } elseif ($action -eq 'PURGE') {
        # Rows deleted, LOB values cleared (mode CLOB), or both, as the
        # modules say it (MODULE_END).
        $unit = 'rows deleted'
        $units = @($modules | ForEach-Object { $_.What } | Select-Object -Unique)
        if ($units.Count -eq 1 -and $units[0] -eq 'LOB values cleared') { $unit = 'LOB values cleared' }
        elseif ($units.Count -gt 1) { $unit = 'rows deleted or LOB values cleared' }
        $lead = '<strong>' + $rowsText + ' ' + $unit + '</strong>'
        if ($scope -ne '') { $lead = $lead + ' (' + $scope + ')' }
        # Tables compacted (P8: "9 tables compacted, 0 skipped, ..."): none
        # when the purge only empties large values, or when no table has
        # enough free space inside.
        if ($checks.ContainsKey('P8') -and $checks['P8'].Value -match '^[1-9]\d* tables compacted') {
            $lead = $lead + '. The purged tables were compacted; the datafiles keep their size until a reclaim.'
        } else {
            $lead = $lead + '. The space is free inside the tables; the datafiles keep their size until a reclaim.'
        }
        # What a reclaim could give back to the disk now (RECLAIMABLE, an
        # upper bound); the recommendation to run it is under Next.
        $reclaim = Get-ReclaimEstimate (' RECLAIM   ' + $reclaimText)
        if ($null -ne $reclaim) { $lead = $lead + ' A reclaim could give back up to about ' + $reclaim.Size + ' to the disk.' }
        $tiles.Add(@($unit, $rowsText))
        if ($checks.ContainsKey('P7') -and $checks['P7'].Value -match 'freed (\d+(?:\.\d+)? [KMGT]?B)') { $tiles.Add(@('space freed', $Matches[1])) }
        # What the database's files took on disk: the most during the purge,
        # and at its end (DISK_PEAK).
        if ($peak -match '^at most (\S+ \S+) ') { $tiles.Add(@('most on disk during the purge', $Matches[1])) }
        if ($peak -match '(\S+ \S+) at the end') { $tiles.Add(@('on disk after the purge', $Matches[1])) }
        if ($null -ne $reclaim) { $tiles.Add(@('a reclaim could give back, up to', $reclaim.Size)) }
        # The time waited for the online redo logs, as advice for the next
        # purge when it is worth acting on (Get-WaitSentence).
        $wait = Get-WaitSentence (' WAITS     ' + $waits)
        if ($wait -ne '') { $next.Add($wait) }
    } elseif ($action -eq 'PREFLIGHT') {
        $lead = '<strong>The database was checked and the purge estimated.</strong> Nothing was changed.'
    } elseif ($mode -eq 'ASSESS') {
        $lead = '<strong>A reclaim would take the datafiles from ' + (Format-HtmlBytes $start) + ' to about ' + (Format-HtmlBytes $forecast) + '</strong>: ' +
                (Format-HtmlBytes ([Math]::Max($start - $forecast, 0))) + ' back to the disk. The database must not be in use while a reclaim runs. Nothing was changed.'
        $tiles.Add(@('would go back to the disk', (Format-HtmlBytes ([Math]::Max($start - $forecast, 0)))))
        $tiles.Add(@('size now', (Format-HtmlBytes $start)))
        $tiles.Add(@('size after, about', (Format-HtmlBytes $forecast)))
    } elseif ($mode -eq 'RESTORE') {
        $lead = '<strong>What an earlier reclaim left pending was put back.</strong>'
    } elseif ($action -eq 'RECLAIM') {
        $lead = '<strong>The datafiles went from ' + (Format-HtmlBytes $start) + ' to ' + (Format-HtmlBytes $end) + '</strong>: ' +
                (Format-HtmlBytes ([Math]::Max($start - $end, 0))) + ' given back to the disk.'
        $tiles.Add(@('given back to the disk', (Format-HtmlBytes ([Math]::Max($start - $end, 0)))))
        $tiles.Add(@('tables that had to move', [string]$moved))
        # The database's files, as a purge's report has them (DB_FILES); a
        # run without them has the reclaim's own figure (DISK_PEAK).
        if ($dbFiles -match '^at most (\S+ \S+) ') {
            $tiles.Add(@('most on disk during the reclaim', $Matches[1]))
            if ($dbFiles -match '(\S+ \S+) at the end') {
                $tiles.Add(@('on disk after the reclaim', $Matches[1]))
                $lead = $lead + ' The database''s files take ' + $Matches[1] + ' on disk now.'
            }
        } elseif ($peak -match '^at most (\S+ \S+) ') {
            $tiles.Add(@('most held on disk during the run', $Matches[1]))
        }
    }
    if ($class -eq 'bad') { $lead = '<strong>The run did not complete.</strong> The errors are listed below. ' + $lead }
    elseif ($status -eq 'STOPPED') { $lead = '<strong>The run was stopped.</strong> ' + $lead }
    $total = 0
    foreach ($s in $steps) { $total += $s.Seconds }
    if ($total -gt 0) { $tiles.Add(@('duration of the steps', (Format-HtmlTime $total))) }

    $css = @'
:root{--bg:#f4f6f9;--card:#fff;--fg:#182131;--muted:#5a6577;--line:#d9dfe8;--accent:#2c5aa0;--ok:#1d7444;--oks:#e2f2e8;--warn:#8f5b00;--warns:#faefd9;--bad:#b42318;--bads:#fbe7e5;--idle:#8a94a6;--track:#e6eaf0}
@media (prefers-color-scheme:dark){:root{--bg:#0e131a;--card:#151c26;--fg:#e3e8ef;--muted:#98a3b5;--line:#273245;--accent:#8aaee8;--ok:#63cc90;--oks:#13301f;--warn:#e8b85e;--warns:#33270f;--bad:#f3897e;--bads:#3a1916;--idle:#7d8799;--track:#232c3b;color-scheme:dark}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 "Segoe UI",system-ui,sans-serif}
.wrap{max-width:1000px;margin:0 auto;padding:28px 20px 60px;display:grid;gap:18px}
.head{display:flex;justify-content:space-between;gap:16px;flex-wrap:wrap;align-items:flex-end}
.kicker{font-size:.8rem;color:var(--muted);letter-spacing:.05em;text-transform:uppercase}h1{margin:0;font-size:1.7rem}
.when{color:var(--muted);text-align:right;font-size:.92rem}
.verdict{display:flex;gap:14px;align-items:center;border-radius:12px;padding:16px 18px}
.verdict.ok{background:var(--oks)}.verdict.warn{background:var(--warns)}.verdict.bad{background:var(--bads)}
.badge{flex:none;color:var(--card);font-weight:800;border-radius:999px;padding:4px 16px}
.ok .badge{background:var(--ok)}.warn .badge{background:var(--warn)}.bad .badge{background:var(--bad)}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px}
.tile{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.num{font-size:1.45rem;font-weight:800;font-variant-numeric:tabular-nums}.cap{color:var(--muted);font-size:.88rem}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;display:grid;gap:10px;min-width:0}
h2{margin:0;font-size:1.05rem}
.bar{display:grid;grid-template-columns:minmax(120px,18rem) 1fr 7rem;gap:10px;align-items:center;font-size:.93rem}
.track{background:var(--track);border-radius:4px;height:14px;overflow:hidden;display:block}.fill{display:block;height:100%;border-radius:4px;background:var(--accent)}
.fill.before{background:var(--idle)}.fill.after{background:var(--ok)}.bv{text-align:right;font-variant-numeric:tabular-nums}
ul.cmp{list-style:none;margin:0;padding:0;display:grid;gap:7px}.pill{display:inline-block;min-width:4.6em;text-align:center;border-radius:999px;padding:1px 10px;font-size:.8rem;font-weight:700}
.pill.ok{background:var(--oks);color:var(--ok)}.pill.warn{background:var(--warns);color:var(--warn)}.pill.bad{background:var(--bads);color:var(--bad)}.pill.skip{background:var(--track);color:var(--muted)}
.muted{color:var(--muted)}table{border-collapse:collapse;width:100%;font-size:.93rem}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--line)}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums}.tw{overflow-x:auto}
code{font-family:Consolas,"Cascadia Mono",monospace;font-size:.9em}
ul.plain{margin:0;padding-left:1.2em;display:grid;gap:6px}
pre{margin:0;overflow-x:auto;font:12.5px/1.4 Consolas,"Cascadia Mono",monospace;background:var(--track);border-radius:8px;padding:12px}
summary{cursor:pointer;font-weight:600}.foot{color:var(--muted);font-size:.88rem}
@media (max-width:560px){.bar{grid-template-columns:1fr 5.5rem}.bl{grid-column:1/-1}}
@media print{body{background:#fff}.card,.tile{break-inside:avoid}details{display:none}}
'@
    $h = New-Object System.Text.StringBuilder
    $title = (Get-HtmlValue $m 'database') + ' &middot; run ' + (Get-HtmlValue $m 'run')
    $null = $h.Append('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
    $null = $h.Append('<title>EPF Data Purge ' + (ConvertTo-HtmlText (Get-HtmlValue $m 'run')) + '</title><style>' + $css + '</style></head><body><div class="wrap">')
    $null = $h.Append('<div class="head"><div><div class="kicker">EPF Data Purge ' + (ConvertTo-HtmlText (Get-HtmlValue $m 'tool_version')) + ' &middot; ' + (ConvertTo-HtmlText $kind) +
                      '</div><h1>' + $title + '</h1></div><div class="when">' + $when + '</div></div>')
    $null = $h.Append('<div class="verdict ' + $class + '"><span class="badge">' + $badge + '</span><div>' + $lead + '</div></div>')
    if ($tiles.Count -gt 0) {
        $null = $h.Append('<div class="tiles">')
        foreach ($t in $tiles) { $null = $h.Append('<div class="tile"><div class="num">' + (ConvertTo-HtmlText ([string]$t[1])) + '</div><div class="cap">' + (ConvertTo-HtmlText ([string]$t[0])) + '</div></div>') }
        $null = $h.Append('</div>')
    }
    if ($modules.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>What was done</h2><div class="tw"><table><thead><tr><th>Module</th><th class="n">Rows</th><th>What</th><th class="n">Time</th></tr></thead><tbody>')
        foreach ($x in $modules) { $null = $h.Append('<tr><td>' + $x.Name + '</td><td class="n">' + $x.Rows + '</td><td>' + $x.What + '</td><td class="n">' + $x.Time + '</td></tr>') }
        $null = $h.Append('</tbody></table></div></div>')
    }
    if ($forecasts.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>What a purge would delete</h2><div class="tw"><table><thead><tr><th>Module</th><th class="n">Rows</th><th class="n">Space freed (about)</th><th class="n">Deleting time</th><th class="n">Redo written</th><th class="n">Undo</th></tr></thead><tbody>')
        foreach ($x in $forecasts) {
            $null = $h.Append('<tr><td>' + $x.Name + '</td><td class="n">' + $x.Rows + '</td><td class="n">' + (ConvertTo-HtmlText $x.Freed) + '</td><td class="n">' + $x.Time +
                              '</td><td class="n">' + (ConvertTo-HtmlText $x.Redo) + '</td><td class="n">' + (ConvertTo-HtmlText $x.Undo) + '</td></tr>')
        }
        $null = $h.Append('</tbody></table></div></div>')
    }
    if ($disk.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>Disk used while the purge runs</h2><div class="tw"><table><thead><tr><th>What</th><th class="n">Uses at most</th><th class="n">Extra disk needed</th><th>Where</th></tr></thead><tbody>')
        $sum = 0.0
        foreach ($x in $disk) {
            $sum += $x.More
            $null = $h.Append('<tr><td>' + $x.Name + '</td><td class="n">' + (Format-HtmlBytes $x.Most) + '</td><td class="n">' + (Format-HtmlBytes $x.More) +
                              '</td><td>' + (ConvertTo-HtmlText $x.Where) + '</td></tr>')
        }
        $null = $h.Append('</tbody></table></div><div class="muted">Extra disk needed: what the file has to grow by, beyond its size today (0 when it has the room already). ' +
                          'In all ' + (Format-HtmlBytes $sum) + ' of free disk space needed where these files are; given back at the end of the purge. ' +
                          'The datafiles of the tables purged keep their size until a reclaim.</div></div>')
    }
    if ($options.Count -gt 1) {
        $null = $h.Append('<div class="card"><h2>Other retentions, as examples</h2><div class="tw"><table><thead><tr><th>Days of data kept</th><th>Purges rows dated before</th><th class="n">Rows deleted</th><th class="n">Space freed (about)</th></tr></thead><tbody>')
        foreach ($x in $options) {
            $mark = ''
            if ($x.Yours) { $mark = ' (this run)' }
            $null = $h.Append('<tr><td>' + $x.Days + $mark + '</td><td>' + $x.Cutoff + '</td><td class="n">' + $x.Rows + '</td><td class="n">' + $x.Freed + '</td></tr>')
        }
        $null = $h.Append('</tbody></table></div><div class="muted">Examples of what else could be kept. Any number of days can be tried the same way: ' +
                          '<code>epf_purge.bat purge --dry-run --retention DAYS</code>.</div></div>')
    }
    if ($spaces.Count -gt 0) {
        $max = 0.0
        foreach ($t in $spaces) { $max = [Math]::Max($max, $t.Start) }
        $null = $h.Append('<div class="card"><h2>Tablespaces</h2>')
        foreach ($t in $spaces) {
            $null = $h.Append((Get-HtmlBar ($t.Name + ', before') $t.Start $max 'before' (Format-HtmlBytes $t.Start)))
            if ($t.End -gt 0) { $null = $h.Append((Get-HtmlBar ($t.Name + ', after') $t.End $max 'after' (Format-HtmlBytes $t.End))) }
            elseif ($t.Forecast -gt 0) { $null = $h.Append((Get-HtmlBar ($t.Name + ', after a reclaim (about)') $t.Forecast $max 'after' (Format-HtmlBytes $t.Forecast))) }
        }
        if ($peak -ne '') { $null = $h.Append('<div class="muted">On disk: ' + (ConvertTo-HtmlText $peak) + '</div>') }
        $null = $h.Append('</div>')
    }
    $long = @($steps | Where-Object { $_.Seconds -ge 1 })
    if ($long.Count -gt 0) {
        $max = ($long | ForEach-Object { $_.Seconds } | Measure-Object -Maximum).Maximum
        $null = $h.Append('<div class="card"><h2>Duration by step</h2>')
        foreach ($s in $long) {
            $label = Format-HtmlStep $s.Code $s.Scope
            if ($s.Status -ne 'DONE') { $label = $label + ' (' + $s.Status.ToLower() + ')' }
            $null = $h.Append((Get-HtmlBar $label $s.Seconds $max '' (Format-HtmlTime $s.Seconds)))
        }
        $short = $steps.Count - $long.Count
        if ($short -gt 0) { $null = $h.Append('<div class="muted">' + $short + ' more steps took less than a second.</div>') }
        $null = $h.Append('</div>')
    }
    if ($checkOrder.Count -gt 0) {
        $heading = 'Verification'
        if ($action -eq 'RECLAIM') { $heading = 'State comparison' }
        $null = $h.Append('<div class="card"><h2>' + $heading + '</h2><ul class="cmp">')
        foreach ($id in $checkOrder) {
            $c = $checks[$id]
            $pill = 'ok'
            $word = 'Pass'
            if ($c.Status -eq 'WARN') { $pill = 'warn'; $word = 'Note' }
            elseif ($c.Status -eq 'FAIL') { $pill = 'bad'; $word = 'Fail' }
            elseif ($c.Status -eq 'SKIP') { $pill = 'skip'; $word = 'Skipped' }
            $null = $h.Append('<li><span class="pill ' + $pill + '">' + $word + '</span> <strong>' + (ConvertTo-HtmlText $c.Title) + '</strong> <span class="muted">' + (ConvertTo-HtmlText $c.Value) + '</span></li>')
        }
        $null = $h.Append('</ul></div>')
    }
    if ($reqs.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>Requirements</h2><ul class="cmp">')
        foreach ($r in $reqs) {
            $need = 'optional'
            if ($r.Blocking -eq 'Y') { $need = 'required' }
            $pill = 'ok'
            $word = 'Met'
            if ($r.Status -eq 'NOT_MET') { $word = 'Not met'; $pill = 'warn'; if ($r.Blocking -eq 'Y') { $pill = 'bad' } }
            elseif ($r.Status -eq 'NOT_APPLICABLE') { $pill = 'skip'; $word = 'n/a' }
            $by = ''
            if ($r.By.Trim() -ne '') { $by = ' &middot; ' + (ConvertTo-HtmlText $r.By.Trim().Replace('_', ' ').ToLower()) }
            $null = $h.Append('<li><span class="pill ' + $pill + '">' + $word + '</span> <strong>' + (ConvertTo-HtmlText $r.Code.Replace('_', ' ')) + '</strong> <span class="muted">' + $need + $by + '</span></li>')
        }
        $null = $h.Append('</ul><div class="muted">What each one asks and how to meet it is in the text report below (REQUIREMENTS).</div></div>')
    }
    if ($troubles.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>Warnings and errors</h2><ul class="cmp">')
        foreach ($entry in $troubles) {
            $p = $entry.Split([char[]]@('|'), 3)
            $pill = 'warn'
            $word = 'Warning'
            if ($p[0] -eq 'FAIL') { $pill = 'bad'; $word = 'Error' }
            $null = $h.Append('<li><span class="pill ' + $pill + '">' + $word + '</span> <code>' + (ConvertTo-HtmlText $p[1]) + '</code> ' + (ConvertTo-HtmlText $p[2]) + '</li>')
        }
        $null = $h.Append('</ul></div>')
    }
    if ($next.Count -gt 0) {
        $null = $h.Append('<div class="card"><h2>Next</h2><ul class="plain">')
        foreach ($n in $next) { $null = $h.Append('<li>' + (ConvertTo-HtmlText $n) + '</li>') }
        $null = $h.Append('</ul></div>')
    }
    if ($reportLines.Count -gt 0) {
        $null = $h.Append('<div class="card"><details><summary>Full text report</summary><pre>')
        foreach ($line in $reportLines) {
            if ($line -match '^EPF_[A-Z_]+\|') { continue }
            $null = $h.Append((ConvertTo-HtmlText $line) + "`n")
        }
        $null = $h.Append('</pre></details></div>')
    }
    $null = $h.Append('<div class="foot">Files of this run, in the same folder: report.html, report.txt (the full report), console.log (every line of the run), manifest.txt.</div>')
    $null = $h.Append('</div></body></html>')
    $path = Join-Path $Folder 'report.html'
    [System.IO.File]::WriteAllText($path, $h.ToString(), (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

# ============================================================================
# EPF Data Purge - Parity check (comparison of the snapshots)
# ============================================================================
# Purpose : Compares the four snapshots written by parity.sql: the copy
#           purged by the previous tool (legacy/) before and after its purge,
#           and the copy purged by this tool before and after. Checks that
#           both copies started identical, that each tool changed exactly the
#           rows its rules select, and explains every difference between the
#           two results:
#             D8   this tool also purges bank statement files that have no
#                  directory rows; the previous tool keeps them
#             D16  this tool keeps rows still referenced by rows that are kept
#                  (held back), where the previous tool deletes them, also
#                  through ON DELETE CASCADE
#             PAYMENT_AUDIT (LOB clearing) this tool also clears rows reached
#                  through the payment only; the previous tool clears
#                  PAYMENT_AUDIT by bulk payment only
#           Any other difference fails the check.
#           With -Before, only the two snapshots taken before the purges are
#           read: checks that both copies start identical and shows what each
#           tool will change, so the purges are started only on usable copies.
# Usage   : powershell -NoProfile -ExecutionPolicy Bypass -File src\tests\parity\compare.ps1
#               -Mode FULL|CLOB_ONLY|CLOB_N_LOGS [-Depth ALL|<modules>] [-Before] [-Dir logs\parity]
#           Mode and depth are the ones both purges run with (CLOB is the
#           name of CLOB_ONLY in this tool).
# Output  : The report, on the console and in <Dir>\parity_report.txt
#           (parity_before_report.txt with -Before).
#           Exit code 0 identical results (-Before: copies ready), 2
#           differences that are all explained, 1 unexplained differences,
#           rule differences found before the purges, or unusable snapshots.
# ============================================================================
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('FULL', 'CLOB_ONLY', 'CLOB', 'CLOB_N_LOGS')]
    [string]$Mode,
    [string]$Depth = 'ALL',
    [switch]$Before,
    [string]$Dir = 'logs\parity'
)

$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$ReportName = 'parity_report.txt'
if ($Before) { $ReportName = 'parity_before_report.txt' }
if ($Mode -eq 'CLOB') { $Mode = 'CLOB_ONLY' }
$DepthList = @($Depth.ToUpper().Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

# The 27 tables of the previous tool, in its delete order, with their module.
$Tables = @(
    @('OPPAYMENTS.BULK_PAYMENT_ADDITIONAL_INFO', 'PAYMENTS'),
    @('OPPAYMENTS.BULK_SIGNATURE', 'PAYMENTS'),
    @('OPPAYMENTS.MANDATORY_SIGNERS', 'PAYMENTS'),
    @('OPPAYMENTS.OIDC_REQUEST_TOKEN', 'PAYMENTS'),
    @('OPPAYMENTS.PAYMENT_AUDIT', 'PAYMENTS'),
    @('OPPAYMENTS.TRANSMISSION_EXECUTION_AUDIT', 'PAYMENTS'),
    @('OPPAYMENTS.IMPORT_AUDIT_MESSAGES', 'PAYMENTS'),
    @('OPPAYMENTS.NOTIFICATION_EXECUTION', 'PAYMENTS'),
    @('OPPAYMENTS.IMPORT_AUDIT', 'PAYMENTS'),
    @('OPPAYMENTS.TRANSMISSION_EXECUTION', 'PAYMENTS'),
    @('OPPAYMENTS.TRANSMISSION_EXCEPTION', 'PAYMENTS'),
    @('OPPAYMENTS.APPROBATION_EXECUTION_OPT', 'PAYMENTS'),
    @('OPPAYMENTS.WORKFLOW_EXECUTION_OPT', 'PAYMENTS'),
    @('OPPAYMENTS.APPROBATION_EXECUTION', 'PAYMENTS'),
    @('OPPAYMENTS.WORKFLOW_EXECUTION', 'PAYMENTS'),
    @('OPPAYMENTS.BULKPAYMENT_EXCEPTION', 'PAYMENTS'),
    @('OPPAYMENTS.INVOICE_ADDITIONAL_INFO', 'PAYMENTS'),
    @('OPPAYMENTS.INVOICE', 'PAYMENTS'),
    @('OPPAYMENTS.PAYMENT_ADDITIONAL_INFO', 'PAYMENTS'),
    @('OPPAYMENTS.PAYMENT', 'PAYMENTS'),
    @('OPPAYMENTS.BULK_PAYMENT', 'PAYMENTS'),
    @('OPPAYMENTS.FILE_INTEGRATION', 'PAYMENTS'),
    @('OPPAYMENTS.AUDIT_ARCHIVE', 'LOGS'),
    @('OPPAYMENTS.AUDIT_TRAIL', 'LOGS'),
    @('OP.SPEC_TRT_LOG', 'LOGS'),
    @('OPPAYMENTS.DIRECTORY_DISPATCHING', 'BANK_STATEMENTS'),
    @('OPPAYMENTS.FILE_DISPATCHING', 'BANK_STATEMENTS')
)
# Tables whose rows this tool counts as held back (roots and the table
# reached by a reverse link): rows it selects and keeps.
$HeldTables = @('OPPAYMENTS.BULK_PAYMENT', 'OPPAYMENTS.FILE_INTEGRATION', 'OPPAYMENTS.AUDIT_TRAIL',
                'OP.SPEC_TRT_LOG', 'OPPAYMENTS.FILE_DISPATCHING', 'OPPAYMENTS.AUDIT_ARCHIVE')

# Row class filters (flags D, X, N, C; see parity_step.sql).
$F_All      = { param($c) $true }
$F_Leg      = { param($c) ($c[0] -eq 'D') -or ($c[1] -eq 'X') }
$F_LegKeep  = { param($c) ($c[0] -ne 'D') -and ($c[1] -ne 'X') }
$F_New      = { param($c) $c[2] -eq 'N' }
$F_NotNew   = { param($c) $c[2] -ne 'N' }
$F_BothKeep = { param($c) ($c[0] -ne 'D') -and ($c[1] -ne 'X') -and ($c[2] -ne 'N') }
$F_NewOnly  = { param($c) ($c[0] -ne 'D') -and ($c[1] -ne 'X') -and ($c[2] -eq 'N') }
$F_Both     = { param($c) (($c[0] -eq 'D') -or ($c[1] -eq 'X')) -and ($c[2] -eq 'N') }
$F_XOnly    = { param($c) ($c[0] -ne 'D') -and ($c[1] -eq 'X') -and ($c[2] -ne 'N') }
$F_DNotNew  = { param($c) ($c[0] -eq 'D') -and ($c[2] -ne 'N') }
$F_Clr      = { param($c) $c[3] -eq 'C' }
$F_NotClr   = { param($c) $c[3] -ne 'C' }
$F_NewNoClr = { param($c) ($c[2] -eq 'N') -and ($c[3] -ne 'C') }
$F_ClrNoNew = { param($c) ($c[3] -eq 'C') -and ($c[2] -ne 'N') }

function Num([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return [decimal]0 }
    return [decimal]::Parse($Text, $Inv)
}

function Fmt([decimal]$Value) {
    return $Value.ToString('#,0', $Inv)
}

function Read-Snapshot([string]$Label) {
    $path = Join-Path $Dir ($Label + '.txt')
    $s = @{ Label = $Label; Path = $path; Found = $false; Head = $null; Ended = $false
            Rows = @{}; Lobs = @{}; KeyDesc = @{}; Missing = @(); Errors = @(); Fks = @()
            LegacyRuns = @(); LegacyEnds = @(); LegacyErrors = @(); NewRuns = @(); NewHeld = @() }
    if (-not (Test-Path -LiteralPath $path)) { return $s }
    $s.Found = $true
    foreach ($line in [IO.File]::ReadAllLines((Resolve-Path -LiteralPath $path).Path)) {
        if (-not $line.StartsWith('PARITY|')) { continue }
        $f = $line.Split('|')
        $kind = $f[1]
        if ($kind -eq 'HEAD') {
            $s.Head = @{ Label = $f[2]; Db = $f[3]; Cutoff = $f[4]; Scope = $f[5]; Taken = $f[6] }
        } elseif ($kind -eq 'KEY') {
            $s.KeyDesc[$f[2]] = $f[3]
        } elseif ($kind -eq 'ROWS') {
            if (-not $s.Rows.ContainsKey($f[2])) { $s.Rows[$f[2]] = @{} }
            $s.Rows[$f[2]][$f[3]] = @{ N = (Num $f[4]); H = (Num $f[5]) }
        } elseif ($kind -eq 'LOB') {
            if (-not $s.Lobs.ContainsKey($f[2])) { $s.Lobs[$f[2]] = @{} }
            if (-not $s.Lobs[$f[2]].ContainsKey($f[3])) { $s.Lobs[$f[2]][$f[3]] = @{} }
            $s.Lobs[$f[2]][$f[3]][$f[4]] = @{ N = (Num $f[5]); H = (Num $f[6]) }
        } elseif ($kind -eq 'MISSING') {
            $s.Missing += $f[2]
        } elseif ($kind -eq 'ERROR') {
            $text = ''
            if ($f.Count -gt 3) { $text = ($f[3..($f.Count - 1)] -join '|') }
            $s.Errors += ($f[2] + ': ' + $text)
        } elseif ($kind -eq 'FK') {
            $s.Fks += , @{ Child = $f[2]; Name = $f[3]; Rule = $f[4]; Parent = $f[5]; Rows = (Num $f[6]); Covered = ($f[7] -eq 'COVERED') }
        } elseif ($kind -eq 'LEGACYRUN') {
            $s.LegacyRuns += , @{ Run = $f[2]; Started = $f[3]; Message = $f[4] }
        } elseif ($kind -eq 'LEGACYEND') {
            $s.LegacyEnds += , @{ Run = $f[2]; Status = $f[3]; At = $f[4]; Text = $f[5] }
        } elseif ($kind -eq 'LEGACYERR') {
            $s.LegacyErrors += , @{ Run = $f[2]; Module = $f[3]; Table = $f[4]; Code = $f[5]; Text = $f[6] }
        } elseif ($kind -eq 'NEWRUN') {
            $s.NewRuns += , @{ Run = $f[2]; Status = $f[3]; Verdict = $f[4]; Cutoff = $f[5]; Depth = $f[6]
                               PurgeMode = $f[7]; DryRun = $f[8]; Created = $f[9] }
        } elseif ($kind -eq 'NEWHELD') {
            $s.NewHeld += , @{ Run = $f[2]; Table = $f[3]; Held = (Num $f[4]) }
        } elseif ($kind -eq 'END') {
            $s.Ended = $true
        }
    }
    return $s
}

function Sum-Classes($Map, [scriptblock]$Filter) {
    $r = @{ N = [decimal]0; H = [decimal]0 }
    if ($null -ne $Map) {
        foreach ($cls in $Map.Keys) {
            if (& $Filter $cls) {
                $r.N += $Map[$cls].N
                $r.H += $Map[$cls].H
            }
        }
    }
    return $r
}

function Get-Rows($Snap, [string]$Table, [scriptblock]$Filter) {
    return Sum-Classes $Snap.Rows[$Table] $Filter
}

function Get-Lobs($Snap, [string]$Table, [string]$Column, [scriptblock]$Filter) {
    $map = $null
    if ($Snap.Lobs.ContainsKey($Table)) { $map = $Snap.Lobs[$Table][$Column] }
    return Sum-Classes $map $Filter
}

function Get-LobColumns($Snaps, [string]$Table) {
    $cols = @{}
    foreach ($s in $Snaps) {
        if ($s.Lobs.ContainsKey($Table)) {
            foreach ($c in $s.Lobs[$Table].Keys) { $cols[$c] = $true }
        }
    }
    return @($cols.Keys | Sort-Object)
}

function Test-Same($A, $B) {
    return ($A.N -eq $B.N) -and ($A.H -eq $B.H)
}

# Action of a module for one tool: delete, clear or none. In CLOB_N_LOGS the
# previous tool adds LOGS to the depth.
function Get-Action([string]$Module, [bool]$Legacy) {
    $inDepth = ($DepthList -contains 'ALL') -or ($DepthList -contains $Module)
    if ($Legacy -and $Mode -eq 'CLOB_N_LOGS' -and $Module -eq 'LOGS') { $inDepth = $true }
    if (-not $inDepth) { return 'none' }
    if ($Mode -eq 'FULL') { return 'delete' }
    if ($Mode -eq 'CLOB_N_LOGS' -and $Module -eq 'LOGS') { return 'delete' }
    return 'clear'
}

$Report    = New-Object System.Collections.Generic.List[string]
$Fails     = New-Object System.Collections.Generic.List[string]
$Explained = New-Object System.Collections.Generic.List[string]
$Notes     = New-Object System.Collections.Generic.List[string]
function Say([string]$Text) { $Report.Add($Text) }
function Add-Fail([string]$Table, [string]$Text) { $Fails.Add($Table + ': ' + $Text); $script:TableFail = $true }
function Add-Explained([string]$Table, [string]$Code, [string]$Text) { $Explained.Add($Table + '  [' + $Code + '] ' + $Text); $script:TableExplained = $true }
function Add-Note([string]$Text) { $Notes.Add($Text) }

# ---------------------------------------------------------------------------
# Snapshots
# ---------------------------------------------------------------------------
$LB = Read-Snapshot 'LEGACY_BEFORE'
$LA = Read-Snapshot 'LEGACY_AFTER'
$NB = Read-Snapshot 'NEW_BEFORE'
$NA = Read-Snapshot 'NEW_AFTER'
$Snaps = @($LB, $LA, $NB, $NA)
if ($Before) { $Snaps = @($LB, $NB) }
$Invalid = New-Object System.Collections.Generic.List[string]

foreach ($s in $Snaps) {
    if (-not $s.Found) { $Invalid.Add($s.Path + ' not found'); continue }
    if ($null -eq $s.Head) { $Invalid.Add($s.Path + ': no header line (snapshot did not start)'); continue }
    if (-not $s.Ended) { $Invalid.Add($s.Path + ': incomplete (no end line)') }
    if ($s.Head.Label -ne $s.Label) { $Invalid.Add($s.Path + ': written as ' + $s.Head.Label) }
    foreach ($e in $s.Errors) { $Invalid.Add($s.Label + ': ' + $e) }
    foreach ($m in $s.Missing) { $Invalid.Add($s.Label + ': table ' + $m + ' not found') }
}
$cutoff = $null
$scope = $null
if ($Invalid.Count -eq 0) {
    $cutoff = $LB.Head.Cutoff
    $scope = $LB.Head.Scope
    foreach ($s in $Snaps) {
        if ($s.Head.Cutoff -ne $cutoff) { $Invalid.Add($s.Label + ': cutoff ' + $s.Head.Cutoff + ', LEGACY_BEFORE has ' + $cutoff) }
        if ($s.Head.Scope -ne $scope) { $Invalid.Add($s.Label + ': scope ' + $s.Head.Scope + ', LEGACY_BEFORE has ' + $scope) }
    }
    if ($Mode -ne 'FULL' -and $scope -ne 'CLOB') {
        $Invalid.Add('Mode ' + $Mode + ' clears LOB values: take the snapshots with scope CLOB')
    }
    if ($LB.Head.Db -eq $NB.Head.Db) { $Invalid.Add('LEGACY_BEFORE and NEW_BEFORE both come from ' + $LB.Head.Db + ': each tool needs its own copy') }
    if (-not $Before) {
        if ($LB.Head.Db -ne $LA.Head.Db) { $Invalid.Add('LEGACY_BEFORE and LEGACY_AFTER come from ' + $LB.Head.Db + ' and ' + $LA.Head.Db) }
        if ($NB.Head.Db -ne $NA.Head.Db) { $Invalid.Add('NEW_BEFORE and NEW_AFTER come from ' + $NB.Head.Db + ' and ' + $NA.Head.Db) }
    }
}

Say '=============================================================================='
Say ' EPF parity check: previous tool (legacy/) and this tool'
Say '=============================================================================='
Say (' Mode ' + $Mode + ', depth ' + ($DepthList -join ',') + ', cutoff ' + $cutoff + ' (rows dated before it are purged)')
if ($Invalid.Count -gt 0) {
    Say ''
    Say ' The snapshots cannot be compared:'
    foreach ($i in $Invalid) { Say ('   ' + $i) }
    Say ''
    Say ' RESULT  INVALID'
    $Report | ForEach-Object { Write-Host $_ }
    if (Test-Path -LiteralPath $Dir) { [IO.File]::WriteAllLines((Join-Path (Resolve-Path -LiteralPath $Dir).Path $ReportName), $Report) }
    exit 1
}
if ($Before) {
    Say (' Previous tool  ' + $LB.Head.Db + '  before ' + $LB.Head.Taken)
    Say (' This tool      ' + $NB.Head.Db + '  before ' + $NB.Head.Taken)
} else {
    Say (' Previous tool  ' + $LB.Head.Db + '  before ' + $LB.Head.Taken + '  after ' + $LA.Head.Taken)
    Say (' This tool      ' + $NB.Head.Db + '  before ' + $NB.Head.Taken + '  after ' + $NA.Head.Taken)
}

# Foreign keys that make the previous tool fail or delete outside its tables.
function Add-FkNotes {
    foreach ($fk in $LB.Fks) {
        if ($fk.Covered -or $fk.Rows -eq 0) { continue }
        if ($fk.Rule -eq 'CASCADE') {
            Add-Note ($fk.Child + ' (' + $fk.Name + ', ON DELETE CASCADE): ' + (Fmt $fk.Rows) + ' rows are deleted with the ' + $fk.Parent + ' rows the previous tool deletes')
        } elseif ($fk.Rule -eq 'SET NULL') {
            Add-Note ($fk.Child + ' (' + $fk.Name + ', ON DELETE SET NULL): ' + (Fmt $fk.Rows) + ' rows lose their reference when the previous tool deletes ' + $fk.Parent + ' rows')
        } else {
            Add-Note ($fk.Child + ' (' + $fk.Name + '): ' + (Fmt $fk.Rows) + ' kept rows reference ' + $fk.Parent + ' rows the previous tool deletes: its delete fails with ORA-02292 and that module stops')
        }
    }
}

# ---------------------------------------------------------------------------
# Purge runs recorded by the tools: same cutoff as the snapshots
# ---------------------------------------------------------------------------
if ($Before) {
    # no purge yet
} elseif ($LA.LegacyRuns.Count -gt 0) {
    $run = $LA.LegacyRuns[0]
    $end = @($LA.LegacyEnds | Where-Object { $_.Run -eq $run.Run } | Select-Object -Last 1)
    $endText = 'no RUN_END'
    if ($end.Count -gt 0) { $endText = 'ended ' + $end[0].Status + ' ' + $end[0].At }
    $errors = @($LA.LegacyErrors | Where-Object { $_.Run -eq $run.Run })
    Say (' Previous run   started ' + $run.Started + ', ' + $endText + ', ' + $errors.Count + ' errors: ' + $run.Message)
    if ($run.Message -notmatch ('cutoff=' + [regex]::Escape($cutoff))) {
        Add-Note ('The last run of the previous tool did not use cutoff ' + $cutoff + ': ' + $run.Message)
    }
    foreach ($e in $errors) {
        Add-Note ('Previous tool error in ' + $e.Module + ' ' + $e.Table + ' (' + $e.Code + '): ' + $e.Text)
    }
} else {
    Add-Note 'No run of the previous tool found in OPPAYMENTS.EPF_PURGE_LOG on the copy it purged.'
}
$newRuns = @($NA.NewRuns | Where-Object { $_.Cutoff -eq $cutoff -and $_.DryRun -eq 'N' })
if ($Before) {
    # no purge yet
} elseif ($newRuns.Count -gt 0) {
    foreach ($r in $newRuns) {
        Say (' This tool run  R-' + $r.Run.PadLeft(6, '0') + ' ' + $r.Created + ' depth ' + $r.Depth + ', mode ' + $r.PurgeMode +
             ', ' + $r.Status + ', verdict ' + $r.Verdict)
    }
} else {
    Add-Note ('No purge of this tool with cutoff ' + $cutoff + ' found in EPFPG.EPF_RUN on the copy it purged.')
}

# ---------------------------------------------------------------------------
# Same starting data on both copies
# ---------------------------------------------------------------------------
$startDiffs = New-Object System.Collections.Generic.List[string]
foreach ($t in $Tables) {
    $name = $t[0]
    $classes = @{}
    foreach ($s in @($LB, $NB)) {
        if ($s.Rows.ContainsKey($name)) { foreach ($c in $s.Rows[$name].Keys) { $classes[$c] = $true } }
    }
    foreach ($c in $classes.Keys) {
        $one = { param($x) $x -eq $c }.GetNewClosure()
        $a = Get-Rows $LB $name $one
        $b = Get-Rows $NB $name $one
        if (-not (Test-Same $a $b)) {
            $startDiffs.Add($name + ' class ' + $c + ': ' + (Fmt $a.N) + ' rows on ' + $LB.Head.Db + ', ' + (Fmt $b.N) + ' on ' + $NB.Head.Db)
        }
    }
    foreach ($col in (Get-LobColumns @($LB, $NB) $name)) {
        $a = Get-Lobs $LB $name $col $F_All
        $b = Get-Lobs $NB $name $col $F_All
        if (-not (Test-Same $a $b)) {
            $startDiffs.Add($name + '.' + $col + ': ' + (Fmt $a.N) + ' non-empty values on ' + $LB.Head.Db + ', ' + (Fmt $b.N) + ' on ' + $NB.Head.Db)
        }
    }
}
if ($startDiffs.Count -gt 0) {
    Say ''
    Say (' The two copies did not start with the same data (' + $startDiffs.Count + ' differences):')
    $startDiffs | Select-Object -First 20 | ForEach-Object { Say ('   ' + $_) }
    Say ''
    Say ' RESULT  INVALID (refresh both copies from the same source and take the snapshots again)'
    $Report | ForEach-Object { Write-Host $_ }
    [IO.File]::WriteAllLines((Join-Path (Resolve-Path -LiteralPath $Dir).Path $ReportName), $Report)
    exit 1
}
Say (' Starting data  identical on both copies (27 tables, rows and checksums per class)')

# ---------------------------------------------------------------------------
# Before the purges: what each tool will change
# ---------------------------------------------------------------------------
if ($Before) {
    $ruleDiffs = 0
    $planned = New-Object System.Collections.Generic.List[string]
    foreach ($t in $Tables) {
        $name = $t[0]
        $short = $name.Substring($name.IndexOf('.') + 1)
        $actPrev = Get-Action $t[1] $true
        $actThis = Get-Action $t[1] $false
        $what = @()
        if ($actPrev -ne $actThis) {
            $what += ('the tools differ here: previous tool ' + $actPrev + ', this tool ' + $actThis)
            $ruleDiffs++
        }
        if ($actPrev -eq 'clear' -or $actThis -eq 'clear') {
            $total = [decimal]0; $prevCount = [decimal]0; $thisCount = [decimal]0
            foreach ($col in (Get-LobColumns @($LB) $name)) {
                $total += (Get-Lobs $LB $name $col $F_All).N
                if ($actPrev -eq 'clear') { $prevCount += (Get-Lobs $LB $name $col $F_Clr).N }
                if ($actThis -eq 'clear') { $thisCount += (Get-Lobs $LB $name $col $F_New).N }
                if ($actPrev -eq 'clear' -and $actThis -eq 'clear') {
                    $nnc = (Get-Lobs $LB $name $col $F_NewNoClr).N
                    $cnn = (Get-Lobs $LB $name $col $F_ClrNoNew).N
                    if ($nnc -gt 0) {
                        if ($name -eq 'OPPAYMENTS.PAYMENT_AUDIT') {
                            $what += ('PAYMENT_AUDIT: ' + $col + ' ' + (Fmt $nnc) + ' values reached through the payment only, cleared by this tool only')
                        } elseif ($name -eq 'OPPAYMENTS.FILE_DISPATCHING') {
                            $what += ('D8: ' + $col + ' ' + (Fmt $nnc) + ' values of files without directory rows, cleared by this tool only')
                        } else {
                            $what += ('RULES DIFFER: ' + $col + ' ' + (Fmt $nnc) + ' values only this tool selects')
                            $ruleDiffs++
                        }
                    }
                    if ($cnn -gt 0) {
                        $what += ('RULES DIFFER: ' + $col + ' ' + (Fmt $cnn) + ' values only the previous tool clears')
                        $ruleDiffs++
                    }
                }
            }
            $unit = 'LOB values'
        } else {
            $total = (Get-Rows $LB $name $F_All).N
            $prevCount = [decimal]0; $thisCount = [decimal]0
            if ($actPrev -eq 'delete') { $prevCount = (Get-Rows $LB $name $F_Leg).N }
            if ($actThis -eq 'delete') { $thisCount = (Get-Rows $LB $name $F_New).N }
            if ($actPrev -eq 'delete' -and $actThis -eq 'delete') {
                $only = (Get-Rows $LB $name $F_NewOnly).N
                $xOnly = (Get-Rows $LB $name $F_XOnly).N
                $dOnly = (Get-Rows $LB $name $F_DNotNew).N
                if ($only -gt 0) {
                    if ($name -eq 'OPPAYMENTS.FILE_DISPATCHING') {
                        $what += ('D8: ' + (Fmt $only) + ' files without directory rows, deleted by this tool only')
                    } else {
                        $what += ('RULES DIFFER: ' + (Fmt $only) + ' rows only this tool selects')
                        $ruleDiffs++
                    }
                }
                if ($xOnly -gt 0) {
                    $what += ('D16: ' + (Fmt $xOnly) + ' rows of kept roots the previous tool deletes through ON DELETE CASCADE; this tool keeps them')
                }
                if ($dOnly -gt 0) {
                    $what += ('RULES DIFFER: ' + (Fmt $dOnly) + ' rows only the previous tool deletes')
                    $ruleDiffs++
                }
            }
            $unit = 'rows'
        }
        $planned.Add(('  {0,-32} {1,14} {2,14} {3,14}  {4}' -f $short, (Fmt $total), (Fmt $prevCount), (Fmt $thisCount), $unit))
        foreach ($w in $what) { Add-Note ($name + ': ' + $w) }
    }
    Add-FkNotes
    Say ''
    Say ' What each tool will change (this tool can still hold back rows that kept rows reference: D16)'
    Say ('  {0,-32} {1,14} {2,14} {3,14}' -f 'TABLE', 'BEFORE', 'PREVIOUS', 'THIS TOOL')
    $planned | ForEach-Object { Say $_ }
    if ($Notes.Count -gt 0) {
        Say ''
        Say ' Notes'
        $Notes | ForEach-Object { Say ('  ' + $_) }
    }
    Say ''
    if ($ruleDiffs -gt 0) {
        $code = 1
        Say (' RESULT  CHECK: the rules of the two tools differ in ' + $ruleDiffs + ' places; send this report before purging')
    } else {
        $code = 0
        Say ' RESULT  READY: both copies start identical; run the two purges, then the AFTER snapshots'
    }
    $Report | ForEach-Object { Write-Host $_ }
    [IO.File]::WriteAllLines((Join-Path (Resolve-Path -LiteralPath $Dir).Path $ReportName), $Report)
    exit $code
}

# ---------------------------------------------------------------------------
# Per table
# ---------------------------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$identicalAll = $true
foreach ($t in $Tables) {
    $name = $t[0]
    $module = $t[1]
    $actPrev = Get-Action $module $true
    $actThis = Get-Action $module $false
    $script:TableFail = $false
    $script:TableExplained = $false
    $legacyIncomplete = $false
    $short = $name.Substring($name.IndexOf('.') + 1)

    # Previous tool: changed exactly what its rules select.
    if ($actPrev -eq 'delete') {
        $keepB = Get-Rows $LB $name $F_LegKeep
        $keepA = Get-Rows $LA $name $F_LegKeep
        if (-not (Test-Same $keepB $keepA)) {
            Add-Fail $name ('the previous tool removed or changed ' + (Fmt ($keepB.N - $keepA.N)) + ' rows its rules keep (the snapshot does not model it)')
        }
        $leftA = Get-Rows $LA $name $F_Leg
        if ($leftA.N -gt 0) {
            $legacyIncomplete = $true
            Add-Note ($name + ': the previous tool left ' + (Fmt $leftA.N) + ' rows its rules delete (see its errors)')
        }
    } else {
        if (-not (Test-Same (Get-Rows $LB $name $F_All) (Get-Rows $LA $name $F_All))) {
            Add-Fail $name ('the previous tool deleted or changed rows in a ' + $actPrev + ' run')
        }
    }
    if ($actPrev -eq 'clear') {
        foreach ($col in (Get-LobColumns @($LB, $LA) $name)) {
            if (-not (Test-Same (Get-Lobs $LB $name $col $F_NotClr) (Get-Lobs $LA $name $col $F_NotClr))) {
                Add-Fail $name ($col + ': the previous tool cleared values its rules keep (the snapshot does not model it)')
            }
            $leftA = Get-Lobs $LA $name $col $F_Clr
            if ($leftA.N -gt 0) {
                $legacyIncomplete = $true
                Add-Note ($name + '.' + $col + ': the previous tool left ' + (Fmt $leftA.N) + ' values its rules clear (see its errors)')
            }
        }
    } elseif ($actPrev -eq 'none') {
        foreach ($col in (Get-LobColumns @($LB, $LA) $name)) {
            if (-not (Test-Same (Get-Lobs $LB $name $col $F_All) (Get-Lobs $LA $name $col $F_All))) {
                Add-Fail $name ($col + ': the previous tool cleared values outside its depth')
            }
        }
    }

    # This tool: kept everything it does not select; differences classified.
    if ($actThis -eq 'delete') {
        if (-not (Test-Same (Get-Rows $NB $name $F_BothKeep) (Get-Rows $NA $name $F_BothKeep))) {
            $n = (Get-Rows $NB $name $F_BothKeep).N - (Get-Rows $NA $name $F_BothKeep).N
            Add-Fail $name ('this tool removed or changed ' + (Fmt $n) + ' rows that both tools keep')
        }
        $onlyB = Get-Rows $NB $name $F_NewOnly
        $onlyA = Get-Rows $NA $name $F_NewOnly
        if ($onlyB.N -gt 0) {
            if ($name -eq 'OPPAYMENTS.FILE_DISPATCHING') {
                Add-Explained $name 'D8' ('this tool deletes ' + (Fmt ($onlyB.N - $onlyA.N)) + ' files without directory rows; the previous tool keeps all ' + (Fmt $onlyB.N))
            } else {
                Add-Fail $name ('this tool selects ' + (Fmt $onlyB.N) + ' rows the rules of the previous tool keep')
            }
        }
        $dnB = Get-Rows $NB $name $F_DNotNew
        if ($dnB.N -gt 0) {
            Add-Fail $name ('the previous tool deletes ' + (Fmt $dnB.N) + ' rows this tool does not select')
        }
        $xB = Get-Rows $NB $name $F_XOnly
        $xA = Get-Rows $NA $name $F_XOnly
        if ($xB.N -gt 0) {
            if (Test-Same $xB $xA) {
                Add-Explained $name 'D16' ('this tool keeps ' + (Fmt $xB.N) + ' rows of kept roots that the previous tool deletes through ON DELETE CASCADE')
            } else {
                Add-Fail $name ('this tool lost ' + (Fmt ($xB.N - $xA.N)) + ' rows of kept roots through ON DELETE CASCADE')
            }
        }
        $heldA = Get-Rows $NA $name $F_Both
        if ($heldA.N -gt 0) {
            Add-Explained $name 'D16' ('this tool keeps ' + (Fmt $heldA.N) + ' rows the previous tool deletes (held back: still referenced by rows that are kept)')
        }
    } else {
        if (-not (Test-Same (Get-Rows $NB $name $F_All) (Get-Rows $NA $name $F_All))) {
            Add-Fail $name ('this tool deleted or changed rows in a ' + $actThis + ' run')
        }
    }
    if ($actThis -eq 'clear') {
        foreach ($col in (Get-LobColumns @($NB, $NA) $name)) {
            if (-not (Test-Same (Get-Lobs $NB $name $col $F_NotNew) (Get-Lobs $NA $name $col $F_NotNew))) {
                Add-Fail $name ($col + ': this tool cleared values of rows it does not select')
            }
            $leftA = Get-Lobs $NA $name $col $F_New
            if ($leftA.N -gt 0) {
                if ($name -eq 'OPPAYMENTS.AUDIT_ARCHIVE') {
                    Add-Explained $name 'D16' ($col + ': this tool keeps ' + (Fmt $leftA.N) + ' values of archives still referenced by kept audit rows')
                } else {
                    Add-Fail $name ($col + ': this tool left ' + (Fmt $leftA.N) + ' values of rows it selects')
                }
            }
            $nncB = Get-Lobs $NB $name $col $F_NewNoClr
            if ($nncB.N -gt 0) {
                if ($name -eq 'OPPAYMENTS.PAYMENT_AUDIT') {
                    Add-Explained $name 'PAYMENT_AUDIT' ($col + ': this tool also clears ' + (Fmt $nncB.N) + ' values of rows reached through the payment only')
                } elseif ($name -eq 'OPPAYMENTS.FILE_DISPATCHING') {
                    Add-Explained $name 'D8' ($col + ': this tool also clears ' + (Fmt $nncB.N) + ' values of files without directory rows')
                } else {
                    Add-Fail $name ($col + ': this tool selects ' + (Fmt $nncB.N) + ' values the previous tool keeps')
                }
            }
            $cnnB = Get-Lobs $NB $name $col $F_ClrNoNew
            if ($cnnB.N -gt 0) {
                Add-Fail $name ($col + ': the previous tool clears ' + (Fmt $cnnB.N) + ' values this tool does not select')
            }
        }
    } elseif ($actThis -eq 'none') {
        foreach ($col in (Get-LobColumns @($NB, $NA) $name)) {
            if (-not (Test-Same (Get-Lobs $NB $name $col $F_All) (Get-Lobs $NA $name $col $F_All))) {
                Add-Fail $name ($col + ': this tool cleared values outside its depth')
            }
        }
    }

    # Held rows reported by this tool for the run(s) with this cutoff.
    if ($actThis -eq 'delete' -and $HeldTables -contains $name -and $newRuns.Count -gt 0) {
        $runIds = @($newRuns | ForEach-Object { $_.Run })
        $reported = [decimal]0
        foreach ($h in $NA.NewHeld) { if ($runIds -contains $h.Run -and $h.Table -eq $name) { $reported += $h.Held } }
        $kept = (Get-Rows $NA $name $F_New).N
        if ($reported -ne $kept) {
            Add-Note ($name + ': this tool reported ' + (Fmt $reported) + ' rows held back, the snapshot finds ' + (Fmt $kept) + ' selected rows still present')
        }
    }

    # Result of the table: remaining rows (and LOB values) the same on both copies?
    $same = Test-Same (Get-Rows $LA $name $F_All) (Get-Rows $NA $name $F_All)
    foreach ($col in (Get-LobColumns @($LA, $NA) $name)) {
        if (-not (Test-Same (Get-Lobs $LA $name $col $F_All) (Get-Lobs $NA $name $col $F_All))) { $same = $false }
    }
    if ($script:TableFail) {
        $status = 'FAIL'
    } elseif ($same) {
        $status = 'SAME'
    } elseif ($legacyIncomplete) {
        $status = 'PARTIAL'
    } elseif ($script:TableExplained) {
        $status = 'EXPLAINED'
    } else {
        $status = 'FAIL'
        Add-Fail $name 'the remaining rows differ without a known reason'
    }
    if (-not $same) { $identicalAll = $false }

    $rowsBefore = (Get-Rows $NB $name $F_All).N
    if ($actPrev -eq 'clear' -or $actThis -eq 'clear') {
        $vb = [decimal]0; $vla = [decimal]0; $vnb = [decimal]0; $vna = [decimal]0
        foreach ($col in (Get-LobColumns $Snaps $name)) {
            $vb  += (Get-Lobs $LB $name $col $F_All).N
            $vla += (Get-Lobs $LA $name $col $F_All).N
            $vnb += (Get-Lobs $NB $name $col $F_All).N
            $vna += (Get-Lobs $NA $name $col $F_All).N
        }
        $lines.Add(('  {0,-32} {1,14} {2,14} {3,14}  {4}' -f $short, (Fmt $vnb), (Fmt ($vb - $vla)), (Fmt ($vnb - $vna)), ($status + ' (LOB values)')))
    } else {
        $prevCount = (Get-Rows $LB $name $F_All).N - (Get-Rows $LA $name $F_All).N
        $thisCount = $rowsBefore - (Get-Rows $NA $name $F_All).N
        $lines.Add(('  {0,-32} {1,14} {2,14} {3,14}  {4}' -f $short, (Fmt $rowsBefore), (Fmt $prevCount), (Fmt $thisCount), $status))
    }
}

Add-FkNotes

Say ''
if ($Mode -eq 'FULL') {
    Say ('  {0,-32} {1,14} {2,14} {3,14}  {4}' -f 'TABLE', 'ROWS BEFORE', 'PREVIOUS DEL', 'THIS TOOL DEL', 'RESULT')
} else {
    Say ('  {0,-32} {1,14} {2,14} {3,14}  {4}' -f 'TABLE', 'BEFORE', 'PREVIOUS', 'THIS TOOL', 'RESULT (rows deleted, or LOB values cleared)')
}
$lines | ForEach-Object { Say $_ }
if ($Explained.Count -gt 0) {
    Say ''
    Say ' Explained differences'
    $Explained | ForEach-Object { Say ('  ' + $_) }
}
if ($Notes.Count -gt 0) {
    Say ''
    Say ' Notes'
    $Notes | ForEach-Object { Say ('  ' + $_) }
}
if ($Fails.Count -gt 0) {
    Say ''
    Say ' Unexplained differences'
    $Fails | ForEach-Object { Say ('  ' + $_) }
}
Say ''
if ($Fails.Count -gt 0) {
    $code = 1
    Say ' RESULT  FAIL: differences without a known reason'
} elseif ($identicalAll) {
    $code = 0
    Say ' RESULT  IDENTICAL: both tools left exactly the same rows'
} else {
    $code = 2
    Say ' RESULT  EXPLAINED: every difference has a known reason'
}

$Report | ForEach-Object { Write-Host $_ }
[IO.File]::WriteAllLines((Join-Path (Resolve-Path -LiteralPath $Dir).Path $ReportName), $Report)
exit $code

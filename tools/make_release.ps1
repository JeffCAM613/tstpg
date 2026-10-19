# ============================================================================
# EPF Data Purge - Release builder
# ============================================================================
# Purpose : Builds the copy of the tool a client receives, then zips it. The
#           copy holds what a client uses, in the layout of the repository:
#           the tool (src\bin, src\sql\install, src\sql\run), the
#           configuration example (src\config), the user guide (README.md)
#           and the documents of docs\, as committed, with RELEASE.txt (the
#           version, the commit, each file with its SHA-256). It leaves out
#           the tests, the previous tool (legacy\), the notes of the
#           development (.local\), this folder, and every file git does not
#           track: a real configuration file, with its passwords, among them.
# Usage   : make_release.bat [--force]
#             --force     builds again a version whose zip exists, and
#                         replaces that zip
#             --version   prints the version (the tool's) and nothing else
#             --help      this text
# Version : the tool's: tool_version in src\sql\install\registry_data.sql,
#           which the wrapper and the database objects carry too.
# Checks  : the release is refused, and nothing is zipped, when
#           - a file of the release is changed and not committed, or new and
#             not added to git;
#           - a file holds a character that is not ASCII;
#           - a file names a test database, another client's data, a test
#             server's path or account, the development repository, or a path
#             of the machine that builds it;
#           - a link of a document finds no file in the release;
#           - the release's own launcher does not answer --help.
#           A document that shows another version than the tool's gets a
#           note: its sample may need the new one.
# Requires: Windows PowerShell 5.1; git on the PATH (a release holds the files
#           the repository tracks).
# Output  : release\epf_purge_<version>\      the copy, built again each time
#                                             (git-ignored)
#           release\epf_purge_<version>.zip  the copy zipped, with its folder
#                                             (not ignored: commit it)
# Exit    : 0 built, 1 refused or failed, 4 usage error.
# ============================================================================

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:CliArgs = @($args)
$script:RepoDir = Split-Path -Parent $PSScriptRoot
$script:ReleaseRoot = Join-Path $script:RepoDir 'release'
$script:Git = ''

# What a client receives: these paths of the repository, with the files git
# tracks in them.
$script:Paths = @('README.md', 'docs', 'src/bin', 'src/config', 'src/sql/install', 'src/sql/run')

# What a release must not name: a pattern (case ignored) and what it is.
$script:Forbidden = @(
    @('EPFPG78\d|TANM78\d\d|RFS6528', 'a test database'),
    @('SONEPAR|CLUBMED', 'the data of another client'),
    @('/files2/|u735031|FR1SLV', 'a path or an account of a test server'),
    @('JeffCAM613|tstpg', 'the development repository'),
    @('[A-Za-z]:\\Users\\|AppData|scratchpad|claude', 'a path of the machine that builds it')
)

function Write-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    Write-Host $Text -ForegroundColor $Color
}

# A refusal: what is wrong, with the items it concerns (20 at most), then
# exit 1.
function Stop-Release {
    param([string]$Text, [string[]]$Items = @())
    Write-Line ''
    Write-Line (' ' + $Text) 'Red'
    $shown = 0
    foreach ($item in $Items) {
        if ($shown -eq 20) {
            Write-Line ('   ... and ' + ($Items.Count - 20) + ' more') 'Red'
            break
        }
        Write-Line ('   ' + $item) 'Red'
        $shown++
    }
    Write-Line ''
    exit 1
}

function Show-Usage {
    Write-Line 'Builds the release of EPF Data Purge for a client, from what is committed,'
    Write-Line 'and zips it: release\epf_purge_<version>\ and release\epf_purge_<version>.zip.'
    Write-Line 'The version is the tool''s (tool_version in src\sql\install\registry_data.sql).'
    Write-Line ''
    Write-Line 'Usage: tools\make_release.bat [--force]'
    Write-Line '  --force     builds again a version whose zip exists, and replaces that zip'
    Write-Line '  --version   prints the version and nothing else'
    Write-Line '  --help      this text'
}

# The tool's version, as the wrapper reads it (Get-ScriptVersion in epf.ps1).
function Get-ToolVersion {
    $path = Join-Path $script:RepoDir 'src\sql\install\registry_data.sql'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    foreach ($line in (Get-Content -LiteralPath $path)) {
        if ($line -match "'tool_version'\s*,\s*'([^']+)'") { return $Matches[1] }
    }
    return ''
}

# git in the repository: the lines it prints; an error when it fails.
function Invoke-Git {
    param([string[]]$Arguments)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:Git
    $info.Arguments = '-C "' + $script:RepoDir + '" ' + ($Arguments -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        throw ('git ' + ($Arguments -join ' ') + ' failed: ' + $err.Result.Trim())
    }
    return @($out.Result -split "`r?`n" | Where-Object { $_ -ne '' })
}

# The line of a position in a text: 1 for the first.
function Get-LineNumber {
    param([string]$Text, [int]$Index)
    $line = 1
    $at = $Text.IndexOf("`n")
    while ($at -ge 0 -and $at -lt $Index) {
        $line++
        $at = $Text.IndexOf("`n", $at + 1)
    }
    return $line
}

# The checks of the copy: the problems that refuse it, and the notes.
function Test-Release {
    param([string]$Folder, [string]$Version, $Problems, $Notes)
    # Bytes as characters one to one (ISO-8859-1): a byte above 127 stays one.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    foreach ($file in @(Get-ChildItem -LiteralPath $Folder -Recurse -File | Sort-Object FullName)) {
        $relative = $file.FullName.Substring($Folder.Length + 1)
        $text = $latin1.GetString([System.IO.File]::ReadAllBytes($file.FullName))
        $match = [regex]::Match($text, '[^\x00-\x7F]')
        if ($match.Success) {
            $Problems.Add($relative + ', line ' + (Get-LineNumber $text $match.Index) + ': a character that is not ASCII')
        }
        foreach ($rule in $script:Forbidden) {
            $match = [regex]::Match($text, $rule[0], [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) {
                $Problems.Add($relative + ', line ' + (Get-LineNumber $text $match.Index) + ': ' + $rule[1] + ' ("' + $match.Value + '")')
            }
        }
        # The links of the documents: each file they point to is in the release.
        $pattern = ''
        if ($file.Extension -eq '.md') { $pattern = '\]\(([^)\s]+)\)' }
        elseif ($file.Extension -eq '.html') { $pattern = '(?:href|src)="([^"]+)"' }
        if ($pattern -ne '') {
            foreach ($link in [regex]::Matches($text, $pattern)) {
                $href = $link.Groups[1].Value
                if ($href.StartsWith('#') -or $href -match '^[A-Za-z][A-Za-z0-9+.-]*:') { continue }
                $target = $href.Split('#')[0]
                if ($target -eq '') { continue }
                $path = [System.IO.Path]::GetFullPath((Join-Path $file.DirectoryName ([Uri]::UnescapeDataString($target).Replace('/', '\'))))
                if (-not $path.StartsWith($Folder + '\', [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $path)) {
                    $Problems.Add($relative + ', line ' + (Get-LineNumber $text $link.Index) + ': a link to ' + $href + ', which is not in the release')
                }
            }
            # A sample that shows another version than this one, alone on its
            # line ("version 0.9.2; these scripts are version 0.9.8" is right).
            $lines = $text -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                $found = @([regex]::Matches($lines[$i], '(?i)\bversion (\d+\.\d+\.\d+)\b') | ForEach-Object { $_.Groups[1].Value })
                if ($found.Count -gt 0 -and $found -notcontains $Version) {
                    $Notes.Add($relative + ', line ' + ($i + 1) + ': shows version ' + ($found -join ', '))
                }
            }
        }
    }
    # The release's own launcher, run from elsewhere: it answers --help and
    # writes nothing into the release.
    $before = @(Get-ChildItem -LiteralPath $Folder -Recurse).Count
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /c ""' + (Join-Path $Folder 'src\bin\epf_purge.bat') + '" --help"'
    $info.WorkingDirectory = [System.IO.Path]::GetTempPath()
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
        $process.Kill()
        $Problems.Add('src\bin\epf_purge.bat --help did not answer within 2 minutes')
    } elseif ($process.ExitCode -ne 0 -or $out.Result -notmatch 'Usage: ') {
        $first = @(($out.Result + $err.Result) -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -Last 3) -join ' / '
        $Problems.Add('src\bin\epf_purge.bat --help: exit ' + $process.ExitCode + ', ' + $first)
    }
    if (@(Get-ChildItem -LiteralPath $Folder -Recurse).Count -ne $before) {
        $Problems.Add('src\bin\epf_purge.bat --help wrote into the release')
    }
}

# The copy zipped with its folder, entries named with forward slashes as the
# zip format has them.
function New-ReleaseZip {
    param([string]$Folder, [string]$Zip, [string]$Name)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File | Sort-Object FullName)
    $stream = [System.IO.File]::Open($Zip, [System.IO.FileMode]::CreateNew)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in $files) {
                $inside = $Name + '/' + $file.FullName.Substring($Folder.Length + 1).Replace('\', '/')
                $null = [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $inside,
                                                                                    [System.IO.Compression.CompressionLevel]::Optimal)
            }
        } finally {
            $archive.Dispose()
        }
    } catch {
        $stream.Dispose()
        if (Test-Path -LiteralPath $Zip) { Remove-Item -LiteralPath $Zip -Force }
        throw
    }
    $stream.Dispose()
    # Read back: every file, under the folder, nothing else.
    $read = [System.IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        $names = @($read.Entries | ForEach-Object { $_.FullName })
    } finally {
        $read.Dispose()
    }
    $wrong = @($names | Where-Object { -not $_.StartsWith($Name + '/') -or $_.Contains('\') })
    if ($names.Count -ne $files.Count -or $wrong.Count -gt 0) {
        throw ('the zip does not hold the release as built: ' + $names.Count + ' entries for ' + $files.Count + ' files')
    }
    return $files.Count
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

$version = Get-ToolVersion
if ($version -notmatch '^\d+(\.\d+){1,3}$') {
    Write-Line (' The tool''s version was not found in src\sql\install\registry_data.sql (tool_version): "' + $version + '".') 'Red'
    exit 1
}
$force = $false
foreach ($arg in $script:CliArgs) {
    switch -Regex ($arg) {
        '^--force$' { $force = $true }
        '^--version$' { Write-Output $version; exit 0 }
        '^(--help|-h|/\?)$' { Show-Usage; exit 0 }
        default {
            Write-Line (' Unknown option: ' + $arg) 'Red'
            Write-Line ''
            Show-Usage
            exit 4
        }
    }
}

try {
    $name = 'epf_purge_' + $version
    $folder = Join-Path $script:ReleaseRoot $name
    $zip = $folder + '.zip'
    Write-Line ''
    Write-Line (' EPF Data Purge - release ' + $version) 'White'

    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) { Stop-Release 'git is not on the PATH: a release holds the files the repository tracks.' }
    $script:Git = $command.Path
    # @() keeps one line a line: alone, it would come back as a string.
    $commit = @(Invoke-Git @('rev-parse', 'HEAD'))[0]
    $short = @(Invoke-Git @('rev-parse', '--short', 'HEAD'))[0]
    $branch = @(Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD'))[0]
    Write-Line ('   From         commit ' + $short + ' (' + $branch + ') of ' + $script:RepoDir)

    # A release is a commit: nothing of it changed or left out of git.
    $changed = @(Invoke-Git (@('status', '--porcelain', '--untracked-files=all', '--') + $script:Paths))
    if ($changed.Count -gt 0) {
        Stop-Release ('Not committed: a release is built from the commit, and these files of it differ (commit them, or add the new ones):') $changed
    }
    if ((Test-Path -LiteralPath $zip) -and -not $force) {
        Stop-Release ('release\' + $name + '.zip exists: a version is released once. Raise tool_version for a new release, or add --force to build this one again.')
    }
    # The files git tracks in the paths of a release; a configuration file
    # other than the example never, even if one were tracked.
    $files = @(Invoke-Git (@('ls-files', '--') + $script:Paths) | Where-Object { $_ -notmatch '\.conf$' })
    if ($files.Count -eq 0) { Stop-Release 'Git tracks no file in the paths of a release.' }

    # The copy, built again each time.
    if (Test-Path -LiteralPath $folder) { Remove-Item -LiteralPath $folder -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $folder -Force
    foreach ($file in $files) {
        $relative = $file.Replace('/', '\')
        $target = Join-Path $folder $relative
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
        [System.IO.File]::Copy((Join-Path $script:RepoDir $relative), $target, $true)
    }
    $manifest = New-Object 'System.Collections.Generic.List[string]'
    $manifest.Add('EPF Data Purge ' + $version)
    $manifest.Add('')
    $manifest.Add('Built on ' + (Get-Date -Format 'yyyy-MM-dd HH:mm') + ' from commit ' + $commit + '.')
    $manifest.Add('Start with README.md, or docs\README.html in a browser.')
    $manifest.Add('')
    $manifest.Add('The files of the release, each with its SHA-256:')
    foreach ($file in $files) {
        $relative = $file.Replace('/', '\')
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $folder $relative)).Hash.ToLower()
        $manifest.Add($hash + '  ' + $relative)
    }
    [System.IO.File]::WriteAllLines((Join-Path $folder 'RELEASE.txt'), $manifest.ToArray(), [System.Text.Encoding]::ASCII)
    Write-Line ('   Files        ' + $files.Count + ' and RELEASE.txt: the tool, its configuration example, the user guide, docs\')

    $problems = New-Object 'System.Collections.Generic.List[string]'
    $notes = New-Object 'System.Collections.Generic.List[string]'
    Test-Release $folder $version $problems $notes
    if ($problems.Count -gt 0) {
        Stop-Release ('The release is refused (' + $problems.Count + ' problems); nothing was zipped. The copy stays in release\' + $name + '\ for a look:') $problems.ToArray()
    }
    Write-Line '   Checks       committed, ASCII, no name of a test or of this machine, every link, the launcher answers --help'
    foreach ($note in $notes) { Write-Line ('   Note         ' + $note) 'Yellow' }

    $replaced = ''
    if (Test-Path -LiteralPath $zip) {
        Remove-Item -LiteralPath $zip -Force
        $replaced = ', replaced with --force'
    }
    $count = New-ReleaseZip $folder $zip $name
    $size = (Get-Item -LiteralPath $zip).Length
    Write-Line ('   Copy         release\' + $name + '\  (git-ignored)')
    Write-Line ('   Zip          release\' + $name + '.zip  (' + [Math]::Ceiling($size / 1024) + ' KB, ' + $count + ' files' + $replaced + ')') 'Green'
    Write-Line ''
    Write-Line (' Next: git add release\' + $name + '.zip, then commit it.')
    Write-Line ''
    exit 0
} catch {
    Write-Line ''
    Write-Line (' The release failed: ' + $_.Exception.Message) 'Red'
    Write-Line ''
    exit 1
}

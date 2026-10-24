# EPF Data Purge

EPF Data Purge removes old data from the EPF application's database and gives the disk space it frees back to the disk. It checks the database before it changes anything, can show what it would do before it does it, and ends every run with a report.

This guide is also available as a web page: [docs/README.html](docs/README.html).

## Contents

- [What it does](#what-it-does)
- [Before you start](#before-you-start)
- [Getting started](#getting-started)
- [Advanced usage](#advanced-usage)
- [Parameters](#parameters)
- [If something goes wrong](#if-something-goes-wrong)
- [More detail](#more-detail)

## What it does

The tool does two jobs. Each has a dry run, which shows the result and changes nothing.

| | Purge | Reclaim |
|---|---|---|
| **What it does** | Deletes the old rows of the application: everything older than the days of data you keep. It then compacts the tables it purged | Compacts the datafiles, so that the space the purge freed goes back to the disk |
| **Its dry run** | Counts what would be deleted, the space it frees and the time it takes | Measures how much disk space would come back |
| **The application meanwhile** | Its accounts are not locked. Run the purge in a quiet period | Not available: its accounts are locked until the reclaim ends |
| **Can it be undone** | No. Have a backup first | Nothing to undo: it changes no row of the application |
| **Passwords** | EPFPG (the tool's own account) and SYS | SYS |

Two things to know:

- **A purge alone does not free disk space.** The rows are gone, but the datafiles keep their size until a reclaim.
- **The purge comes first, the reclaim after.** They can be run on different days: the purge in a quiet period, the reclaim when the application can be stopped. When it can be stopped for both, they run in one go (see [The purge and the reclaim in one go](#the-purge-and-the-reclaim-in-one-go)).

The data a purge works on is in three groups, called modules:

| Module | What it holds |
|---|---|
| PAYMENTS | Bulk payments with all their dependent records, and file integrations |
| LOGS | The functional audit trail and the technical logs |
| BANK_STATEMENTS | Bank statement dispatching |

You say how many days of data to keep. With 365, everything dated more than 365 days ago is purged. A record that newer data still refers to stays, and goes with a later purge.

By default a purge deletes the old rows of all three modules. It can also be limited to some modules, or keep the rows and only empty their large values (documents, messages): see [Choose what is purged](#choose-what-is-purged).

## Before you start

You need:

- A Windows machine with Windows PowerShell 5.1 and an Oracle client (`sqlplus.exe` in the PATH or in `%ORACLE_HOME%\bin`), best on the database's own network rather than through a VPN.
- The database: its alias in tnsnames.ora, or `host:port/service`.
- The SYS password. It is asked for the first time on a database, for every purge that deletes, and for every reclaim.
- A backup taken shortly before a purge. The tool looks for an RMAN backup of the last 24 hours, and asks when it finds none.
- For a reclaim: a time when nobody uses the application.

The database is Oracle 12.2 or later (the tool was built and tested on 19c), single instance. A purge that deletes does not yet run in a pluggable database of a container database, nor on RAC.

Nothing has to be installed by hand: the first run on a database does it (see [The first time on a database](#the-first-time-on-a-database)).

Open a Command Prompt or a PowerShell window in the tool's folder. Every command of this guide is typed there.

## Getting started

### The menu

The simplest way in is the command alone:

```bat
src\bin\epf_purge.bat
```

It asks what you want to do, then the questions that go with your choice:

```text
 What do you want to do?
   1  Dry run of a purge     shows what a purge would delete; changes nothing
   2  Purge                  deletes old rows; a reclaim is needed afterwards to
                             free disk space
   3  Dry run of a reclaim   shows how much disk space a reclaim would give back;
                             changes nothing
   4  Reclaim                compacts the datafiles to free disk space; the
                             database must not be in use meanwhile
   5  Purge, then reclaim    both in one go: one yes, then the purge and the
                             reclaim; the database must not be in use during
                             the reclaim
   6  Report of an earlier run
   7  Status: is anything left pending?
   8  Uninstall: remove the tool's objects from the database
   Q  Quit
 > Choice [1]:
```

Every question stands under a line with its name and waits at a prompt marked `>`. The value in brackets is the default: press Enter to take it.

Start with choice 1: it changes nothing. The steps below are the first four choices as commands; choice 5 runs steps 2 and 3 in one go (see [The purge and the reclaim in one go](#the-purge-and-the-reclaim-in-one-go)):

| Step | Command | What it does |
|---|---|---|
| 1 | `src\bin\epf_purge.bat purge --dry-run --retention 365` | Shows what a purge would delete, keeping the last 365 days. Changes nothing |
| 2 | `src\bin\epf_purge.bat purge --retention 365` | Deletes those rows, then compacts the tables it purged |
| 3 | `src\bin\epf_purge.bat reclaim --dry-run` | Shows how much disk space would come back. Changes nothing |
| 3 | `src\bin\epf_purge.bat reclaim` | Gives that space back to the disk. The application is not available meanwhile |

### The first time on a database

Every run gets ready by itself: it finds sqlplus, reaches the database and looks for the tool's own objects there. The first time they are missing. The run says so and asks whether to install them: an account EPFPG and a tablespace EPFPG_DATA, beside the application's data, with the history of the runs and what they measured. Installing them changes nothing else.

At the question for the EPFPG password, press Enter alone. The run then asks for the SYS password, and for the password to give the new EPFPG account:

```text
 -- The tool's own account (EPFPG) ---------------------------------------------
 > EPFPG password (Enter alone if the tool was never installed on this database):

 -- SYS password ---------------------------------------------------------------
 > SYS password:
   Database           EPFDB: connected as SYS (EPFDB)
   Tool in database   not installed yet

 -- Install the tool -----------------------------------------------------------
   The tool keeps its own objects in the database: an account EPFPG and a tablespace EPFPG_DATA,
   with the history of its runs and what they measured. Installing them changes nothing else.
 > Install them now (Y/N) [Y]:

 -- Password of the new account ------------------------------------------------
 > Password to give the EPFPG account:
 > Password to give the EPFPG account (again):
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.9 (installed now, 0:02)
```

The run then goes on with what it was asked. Keep the EPFPG password: the next runs ask for it. After an update of the tool's files, a run asks the same way whether to upgrade the objects in the database; the history of the runs is kept.

### Step 1: see what a purge would delete

```bat
src\bin\epf_purge.bat purge --dry-run --retention 365
```

The dry run asks for the database and the EPFPG password, then what the purge should do. Each choice is shown with the tables it works on in your database, their size today and a rough estimate of what it frees. Press Enter twice to take everything old in every module:

```text
 -- Mode: what is done to the rows dated before 13 October 2025 ----------------
   Mode             Tables   Size now   Frees (about)   What it does
   FULL                 25    22.0 GB          6.9 GB   deletes the rows, in the modules chosen next
   CLOB                  6    13.8 GB          1.6 GB   keeps the rows, empties their large values
   LOGS                  3     1.2 GB         24.6 MB   same as FULL with the module LOGS alone
   CLOB_N_LOGS           8    14.6 GB          1.6 GB   CLOB, and deletes the rows of module LOGS
   ...
 > Mode (FULL, CLOB, LOGS, CLOB_N_LOGS) [FULL]:

 -- Depth: in which modules (mode FULL) ----------------------------------------
   Module           Tables   Size now   Frees (about)   What it holds
   ALL                  25    22.0 GB          6.9 GB   every module
   PAYMENTS             20     8.9 GB          6.5 GB   Bulk payments with all dependent records,
                                                        and file integrations
   LOGS                  3     1.2 GB         24.6 MB   Functional audit trail and technical logs
   BANK_STATEMENTS       2    11.9 GB        389.9 MB   Bank statement dispatching
 > Depth (ALL, or modules such as PAYMENTS,LOGS,BANK_STATEMENTS) [ALL]:
```

It then checks the database, counts the rows, and says what a purge would do:

```text
 ===============================================================================
  A purge would delete 19,279,194 rows, about 7.0 GB, dated before 13 October 2025.
  It would take about 8 minutes of deleting, and would complete as things are.
 ===============================================================================
   What                  Rows to delete   Space freed (about)    Deleting
   PAYMENTS                  18,218,547                6.6 GB        7:40
   LOGS                         125,517               21.0 MB        0:04
   BANK_STATEMENTS              935,130              380.0 MB        0:33
```

Below that it shows:

- the disk a purge uses while it runs, file by file, with the extra disk each needs (given back at the end of the purge);
- the same figures for other numbers of days, as examples, so that the days to keep can be chosen by the space they free;
- the command that runs the purge itself, and where the report is.

Nothing was changed. Try other numbers of days the same way.

### Step 2: purge

```bat
src\bin\epf_purge.bat purge --retention 365
```

The purge asks the same questions, plus whether it is a dry run (no). Then:

1. **It checks the database** and shows its requirements as a table: each one is required or optional, with its state now, and for each one not met what happens and what to do.
2. **It asks what the requirements call for.** For example whether to enlarge the online redo logs for the time of the purge when they are small (the default is yes; they are put back at the end), or whether a backup exists when it found none.
3. **It shows what it is about to delete and waits** for you to type `yes`. Nothing is deleted before that.
4. **It deletes**, in small batches, and shows one line per module with the progress, the speed and the time left.
5. **It compacts the tables it purged**, so that the database can use the space of the deleted rows again. This is part of every purge: there is nothing to ask for.
6. **It puts the database back as it was** (what it changed for the purge: the undo settings, the online redo logs) and ends with the result.

```text
   Requirement                       Needed     Now
   Undo space                        required   ok
   Temporary space                   required   ok
   Online redo logs                  optional   NOT MET
       What happens: Small online logs fill every few seconds and the purge waits on each switch.
       Slower, not a failure.
       What to do:   the tool can enlarge them for the purge ...
   Backup                            required   ok

 ===============================================================================
  Ready. This deletes everything dated before 13 October 2025: 197,409 top-level records, with the
  rows under them (a dry run counts those).
  About 8 minutes of deleting, then the purged tables are compacted. It cannot be undone.
 ===============================================================================
 > Type yes to start the purge: yes

 2 of 5  Preparing the database for the purge (SYS)                done    0:11
 3 of 5  Deleting
         PAYMENTS         [##########..........]  50%   9,109,274 rows . 39,149 rows a second . 3:50 left
 ...
 4 of 5  Compacting the purged tables                              done    2:41
         9 tables compacted, 0 skipped
 5 of 5  Putting the database back as it was (SYS)                 done    0:04

 ===============================================================================
  DONE   19,279,194 rows deleted in 12:42. The checks passed, with 1 note.
 ===============================================================================
  7.0 GB was freed, and the purged tables were compacted: the database can use that space again. The
  disk does not have it back yet: the datafiles keep their size until a reclaim. A reclaim could
  give back up to about 35.4 GB, the space free in DATA: 35.4 of 50.1 GB (71%). Recommended next, at
  a time the database can be out of use (a reclaim locks the application's accounts while it runs):
  see what it gives back, then run it:
      src\bin\epf_purge.bat reclaim --dry-run
      src\bin\epf_purge.bat reclaim
  On disk: at most 65.7 GB during the purge (4.2 GB more than at its start); 61.5 GB at the start,
  61.6 GB at the end (datafiles, temporary files and online redo logs).
```

The end says how much a reclaim could give back to the disk at most: the space free now in the tablespaces the purge worked in. From 1 GB on it recommends one, with its two commands: the dry run measures what it gives back, then the reclaim gives it back while the database is out of use. Below 1 GB it says the gain is small.

The "On disk" line is what the database's files took on disk: the most while the purge ran, and what they take after it, once the database is put back. When the purge waited a tenth of its deleting time or more for small online redo logs, a note says how long, and that enlarging them for the time of the next purge saves most of that wait.

A required condition that is not met is a strong warning. Going on is your choice, and the default answer is no.

When nothing is old enough (an earlier purge took it), the purge says so before the typed `yes` and at its end, in place of a count of zero.

Every command the tool shows can be typed as it is: it begins with the path of the tool from where you are.

The reclaim is a command of its own: `src\bin\epf_purge.bat reclaim`, as in step 3. As in the previous tool, `--reclaim` with the days to keep runs it after the purge in the same command (see [The purge and the reclaim in one go](#the-purge-and-the-reclaim-in-one-go)). Alone (`purge --reclaim`, with `--dry-run` for its dry run) it runs the reclaim, and says which command that is.

### Step 3: give the space back to the disk

```bat
src\bin\epf_purge.bat reclaim --dry-run
src\bin\epf_purge.bat reclaim
```

The dry run measures and changes nothing. It says what the reclaim gives back, which accounts it locks, and the disk it uses meanwhile:

```text
 ===============================================================================
  A reclaim takes DATA from 50.1 GB to about 16.3 GB: 33.8 GB back to the disk.
 ===============================================================================
  The database must not be in use meanwhile: the application accounts KDCM, OP, OPPAYMENTS,
  OPREPORTS, SUPER are locked and their sessions disconnected until it ends.

   DATA              today  [##############################]  50.1 GB
                     after  [#########.....................]  about 16.3 GB
                     738 tables move, 1000 indexes are rebuilt, 2 segments stay where they are
```

The reclaim itself measures again, shows the same, and waits for you to type `yes`. It then locks the application's accounts, compacts the tables, rebuilds the indexes, compares everything with what it recorded at the start, and unlocks the accounts:

```text
 ===============================================================================
  DONE   DATA went from 50.1 GB to 15.5 GB: 34.6 GB given back to the disk.
         11:55. The application accounts are unlocked. The checks passed, with 1 note.
 ===============================================================================
  On disk: at most 62.3 GB during the reclaim (0.7 GB more than at its start); 61.6 GB at the start,
  27.0 GB at the end (datafiles, temporary files and online redo logs).
  Its tablespaces: at most 50.1 GB during the run (its size at the start); 50.1 GB at the start,
  15.5 GB at the end.
```

"On disk" is the database's files as a whole, as at the end of a purge, so the two can be compared: what they take after the reclaim is what the disk holds now.

A reclaim takes time with the amount of data it has to move, from minutes to more than an hour. It changes no row of the application: the row counts and the objects are compared before and after.

### The purge and the reclaim in one go

When the application can be stopped for the whole time, the purge and the reclaim run in one command: choice 5 of the menu, or

```bat
src\bin\epf_purge.bat purge --retention 365 --reclaim
```

The purge asks its questions as in step 2. One typed `yes` then covers both: the sentence before it says that a reclaim follows, and that the application is not available until it ends. Once the purge has run to its end, the reclaim measures, shows what it gives back, and starts without a second `yes` (a requirement of the reclaim that is not met is still asked about, as in step 3):

```text
 ===============================================================================
  Ready. This deletes everything dated before 13 October 2025: 197,409 top-level records, with the
  rows under them (a dry run counts those).
  About 8 minutes of deleting, then the purged tables are compacted. It cannot be undone.
  Then a reclaim gives the space back to the disk: the application is not available until it ends
  (its accounts are locked).
 ===============================================================================
 > Type yes to start the purge, then the reclaim: yes
 ...
 ===============================================================================
 Then the reclaim: compacting the datafiles to give the space back to the disk.
 ...
  The reclaim starts: the yes typed before the purge covers it.
```

- A purge that fails, is stopped or does not start is not followed by a reclaim.
- The purge, the reclaim's measurement and the reclaim are runs of their own, each with its folder and its report (with questions, the purge's checks are one more, before the purge).
- The exit code is the worse of the two: a failure first, then a stop, then warnings.
- With `--dry-run` it is the dry run of the purge alone: what the reclaim gives back depends on what the purge frees. `src\bin\epf_purge.bat reclaim --dry-run` measures the database as it is now.
- With `--non-interactive` nothing is asked, the typed `yes` included: the command a scheduler can start in a maintenance window.

### After a run

- **The report** opens in the browser at the end of every run: the result in one sentence, the main figures, the time of each step, the checks. `src\bin\epf_purge.bat report` shows the latest one again.
- **The run folder** `logs\<date>_<time>_<database>_R-000123`, such as `logs\2026-10-24_192320_EPFDB_R-000123`, keeps it, with the text report and every line of the run (report.html, report.txt, console.log). The database is the one the run worked on, as its report names it.
- **The tool's objects**: a purge or a reclaim that ended well asks whether to remove them from the database. The default is to keep them: the next run is then ready at once.

### Stop a run

Press Ctrl+C in the window of the run, or, from another window:

```bat
src\bin\epf_purge.bat stop
```

A purge stops after its current batch: what was deleted stays deleted, nothing is half done, and the same command goes on from there. A reclaim stops after its current table and puts everything back: indexes, datafile settings, accounts.

## Advanced usage

### Choose what is purged

**How far back.** `--retention DAYS` keeps that many days, counted from today. `--cutoff YYYY-MM-DD` gives the day itself instead: rows dated before it are purged.

**What is done to the old rows**, with `--mode`:

| Mode | What it does |
|---|---|
| FULL | Deletes the old rows, in the modules chosen with `--depth`. The default |
| CLOB | Keeps the rows and empties their large values (LOB columns: documents, messages) |
| LOGS | Deletes the old rows of the module LOGS only. The same as FULL with `--depth LOGS` |
| CLOB_N_LOGS | Both: empties the large values of the other modules, and deletes the old rows of the module LOGS |

**In which modules**, with `--depth`: `ALL` (the default), or names separated by commas, such as `PAYMENTS,LOGS`.

The mode says what is done, the depth says where. LOGS is the name of a module, and also of the mode that is a shorthand for that module alone.

```bat
src\bin\epf_purge.bat purge --dry-run --retention 730 --depth PAYMENTS,BANK_STATEMENTS
src\bin\epf_purge.bat purge --dry-run --cutoff 2024-01-01 --mode CLOB
src\bin\epf_purge.bat purge --retention 90 --mode LOGS
```

Every purge that deletes ends by compacting the tables it purged (those with at least 20 % of free space inside them): the space of the deleted rows goes back to their tablespace, where the database can use it again. That is not disk space yet: the datafiles keep their size until the reclaim. A purge that only empties large values (mode CLOB) has no table to compact.

### Run without questions

With `--non-interactive` nothing is asked: every answer comes from the options, the environment or the configuration file, and the purge or the reclaim starts without confirmation. This is the command a scheduler of yours can start. The tool schedules nothing itself.

```bat
src\bin\epf_purge.bat purge --non-interactive --tns EPFDB --retention 365 --redo-logs
src\bin\epf_purge.bat reclaim --non-interactive --tns EPFDB
```

- A purge without questions deletes only what it is told to: the days to keep must be given (`--retention`, `--cutoff`, or the configuration file).
- With `--reclaim` the reclaim follows the purge in the same command, once the purge has run to its end (see [The purge and the reclaim in one go](#the-purge-and-the-reclaim-in-one-go)).
- The first run on a database installs the tool's objects without asking, and a run after an update upgrades them.
- When a required condition is not met, the run does not start: it changes nothing, names the condition, and gives the option that goes past it (see [When a requirement is not met](#when-a-requirement-is-not-met)).
- The exit code says how it ended (see [Exit codes](#exit-codes)).

### Passwords

The tool never puts a password on a command line or in a file it writes. Without questions it reads them from:

| Password | Environment variable | Key of the configuration file |
|---|---|---|
| EPFPG, the tool's own account | EPF_PASSWORD | EPF_PASSWORD |
| SYS | EPF_SYS_PASSWORD | SYS_PASSWORD |

In a PowerShell window, this line asks for both without showing them and keeps them for that window only:

```powershell
$env:EPF_PASSWORD = [Net.NetworkCredential]::new('', (Read-Host 'EPFPG password' -AsSecureString)).Password; $env:EPF_SYS_PASSWORD = [Net.NetworkCredential]::new('', (Read-Host 'SYS password' -AsSecureString)).Password
```

A configuration file that holds passwords is as sensitive as they are: keep it where only the account that runs the tool can read it.

### A configuration file

Copy `src\config\epf_purge.conf.example` to `src\config\epf_purge.conf`, or give another file with `--config FILE`. It holds one `KEY=VALUE` per line, and the example describes every key:

```text
TNS=EPFDB
RETENTION_DAYS=365
MODE=FULL
DEPTH=ALL
REDO_LOGS=Y
OPEN_REPORT=N
```

- An option on the command line wins over the file.
- With questions, a value of the file is the default answer of its question (the database, the days to keep), or the answer itself for a yes or no.
- Without questions, it is the answer.

A whole purge as one command, such as a nightly job:

```bat
src\bin\epf_purge.bat purge --non-interactive --config D:\epf\nightly.conf
```

### When a requirement is not met

Every purge checks six requirements before it starts, and a reclaim checks its own. With questions the run asks. Without questions these options answer beforehand:

| Requirement not met | What it means | Option that answers |
|---|---|---|
| Online redo logs (optional) | They are small: the purge works, but waits for them at times | `--redo-logs` enlarges them for the purge and puts them back at the end |
| Backup | No RMAN backup of the last 24 hours was found | `--backup confirmed` when a backup was made another way; `--backup none` to purge without one |
| Room for the archived logs, undo space, temporary space | The purge may run out of room | `--confirm ARCHIVE`, `--confirm UNDO`, `--confirm TEMP` go on anyway. Not recommended: make room instead |
| Recycle bin (reclaim) | Dropped objects lie in the tablespaces to compact | `--confirm RECYCLEBIN` lets the reclaim purge them first: they can then no longer be restored |

The table of the requirements, on the screen and in the report, says for each one what was measured and what to do. The [reference](docs/REFERENCE.md#the-requirements-and-their-questions) has every requirement in detail.

### A large purge in several runs

When one purge would write more redo than the archive destination can take (a database in ARCHIVELOG mode), or more than you allow with `--max-redo`, the tool plans it in several runs, older data first:

```bat
src\bin\epf_purge.bat preflight --retention 365 --max-redo 20G
src\bin\epf_purge.bat plan
src\bin\epf_purge.bat purge
```

`preflight` runs the checks of a purge alone and makes the plan, `plan` shows its steps, and each `purge` without other options carries out the next step. Back up and delete the archived logs between runs. More in the [reference](docs/REFERENCE.md#large-purges-a-plan-of-smaller-runs).

### More control over a reclaim

| Option | What it does |
|---|---|
| `--tablespaces DATA,INDX` | Compacts these tablespaces only. By default: every tablespace that holds the application's data |
| `--scratch 3G` | Sets the most scratch space the reclaim may take. `--scratch none` runs without |
| `--confirm RECYCLEBIN` | Purges the dropped objects of those tablespaces first, without asking |
| `--restore` | Puts back what a reclaim that did not finish left pending, and unlocks the accounts |

Scratch space: a table that cannot move lower in its datafile waits in a scratch tablespace, which the reclaim creates next to that datafile and removes at the end. The dry run says how much it takes and where, so that the disk can be checked first. Apart from it, no datafile grows above its size at the start.

### Earlier runs and the state of the database

```bat
src\bin\epf_purge.bat report
src\bin\epf_purge.bat report --run 123
src\bin\epf_purge.bat status
```

`report` shows the report of the latest run, or of the run given. `status` shows the run in progress, or the latest one, and anything a run left pending.

On the screen, `--verbose` shows every event and the whole report instead of the short view. `--no-open` writes report.html without opening it, and `--log-dir DIR` puts the run folders elsewhere.

### Remove the tool from the database

```bat
src\bin\epf_purge.bat uninstall
```

This removes the account EPFPG and its tablespace EPFPG_DATA, with the history of the runs. The application's data is not touched, and the reports on the machine stay. The next purge or reclaim installs the objects again.

## Parameters

Usage: `src\bin\epf_purge.bat [action] [options]`. `src\bin\epf_purge.bat --help` prints all of it.

### Actions

| Action | What it does |
|---|---|
| (none) | The menu |
| `purge` | Deletes the rows older than the days of data to keep: checks, questions, purge, report. With `--dry-run` it counts what it would delete and changes nothing |
| `reclaim` | Gives the space a purge freed back to the disk (SYS; the application's accounts are locked meanwhile). It measures first and asks. With `--dry-run` it measures only; with `--restore` it puts back what a reclaim that did not finish left pending |
| `report` | Shows the report of a run: the latest, or `--run ID` |
| `status` | Shows the run in progress or the latest one, and anything left pending |
| `stop` | Asks the run in progress to stop cleanly |
| `preflight` | The checks and estimates of a purge alone, and its plan. Changes no data |
| `plan` | Shows the open plan of a purge in several runs; `--close` closes it |
| `install` | Installs or upgrades the tool's objects in the database (SYS). A purge or a reclaim does it when needed |
| `uninstall` | Removes the tool's objects from the database (SYS) |

### Options of every action

| Option | Configuration key | What it does |
|---|---|---|
| `--tns NAME` | TNS | The database: its alias in tnsnames.ora, or `host:port/service`. Asked for when not given |
| `--config FILE` | | The configuration file. By default `src\config\epf_purge.conf` |
| `--non-interactive` | | Ask nothing. A purge or a reclaim starts without confirmation |
| `--yes` | | Skip the typed `yes` of a run with questions. Required with `--non-interactive` for `uninstall` and `plan --close` |
| `--verbose` | VERBOSE | Show every event and the whole report on the screen |
| `--no-color` | NO_COLOR | Plain output, without colours |
| `--no-open` | OPEN_REPORT=N | Write report.html without opening it in the browser |
| `--log-dir DIR` | LOG_DIR | Where the run folders go. By default `logs` in the tool's folder |
| `--help` | | Explain purge and reclaim, then list every action and option |

### Options of a purge

They also apply to `preflight`. "Asked" means: a run with questions asks when the option is not given, and Enter takes the value shown.

| Option | Configuration key | What it does |
|---|---|---|
| `--dry-run` | DRY_RUN | Show what would happen and change nothing. Asked (no) |
| `--retention DAYS` | RETENTION_DAYS | The days of data to keep: older rows are purged. Asked; required without questions |
| `--cutoff YYYY-MM-DD` | CUTOFF | Instead of the retention: purge the rows dated before this day |
| `--mode MODE` | MODE | FULL, CLOB, LOGS or CLOB_N_LOGS (see [Choose what is purged](#choose-what-is-purged)). Asked (FULL) |
| `--depth LIST` | DEPTH | ALL, or modules separated by commas: PAYMENTS, LOGS, BANK_STATEMENTS. Not used with the mode LOGS. Asked (ALL) |
| `--compact` | COMPACT | Accepted and ignored: every purge that deletes compacts the tables it purged afterwards |
| `--batch-size N` | BATCH_SIZE | Top-level rows per transaction, 100 to 100000. By default what the checks recommend; never asked |
| `--redo-logs` | REDO_LOGS | Larger online redo logs for the time of the purge (4 x 1 GB) when one batch does not fit in them; the original ones are put back at the end. Asked (yes); without questions, only with this option. Not in a pluggable database |
| `--backup CHOICE` | BACKUP | When no recent RMAN backup is found: `confirmed` (a backup was made another way) or `none` (purge without a backup). Asked |
| `--confirm LIST` | CONFIRM | Go on although these requirements are not met: ARCHIVE, UNDO, TEMP, separated by commas. Asked (no) |
| `--max-redo SIZE` | MAX_REDO | The most redo one run may write, such as `500M` or `20G`: the purge is planned in several runs |
| `--new` | | Start over: close the open plan and follow the options given |
| `--reclaim` | | With the days to keep (or another option of a purge): the purge, then the reclaim, in one command. The reclaim starts once the purge has run to its end, without a second `yes`; the options of a reclaim apply to it. With `--dry-run`: the dry run of the purge alone. With `purge` and no option of a purge: the reclaim, as the action `reclaim` runs it (`--dry-run`: its dry run) |
| `--undo-tuning` | UNDO_TUNING | Accepted and ignored: every purge keeps undo in check for its time (see [undo tuning](docs/REFERENCE.md#undo-tuning-every-purge)) |

### Options of a reclaim

| Option | Configuration key | What it does |
|---|---|---|
| `--dry-run` | | Measure what a reclaim gives back and change nothing |
| `--tablespaces LIST` | RECLAIM_TABLESPACES | The tablespaces to compact, separated by commas. By default every tablespace that holds the application's data |
| `--scratch SIZE` | RECLAIM_SCRATCH | The most scratch space, such as `3G`; `none` for no scratch space. By default the size the dry run measures |
| `--confirm LIST` | RECLAIM_CONFIRM | Go on although these requirements are not met: ARCHIVE, TEMP, RECYCLEBIN |
| `--restore` | | Put back what a reclaim that did not finish left pending: the tables set aside, the indexes, the datafile settings, the locked accounts |

### Options of report, stop and plan

| Option | What it does |
|---|---|
| `--run ID` | The run, as `124` or `R-000124`. For `report`: by default the latest. For `stop`: by default the run in progress |
| `--close` | With `plan`: close the open plan |

### Keys of the configuration file only

| Key | What it does |
|---|---|
| EPF_PASSWORD, SYS_PASSWORD | The passwords, for runs without questions (see [Passwords](#passwords)) |
| UNINSTALL_AFTER | Y: after a purge or a reclaim that ended well, remove the tool's objects from the database. With questions, the run asks |
| CONNECT_TIMEOUT_S | Seconds a connection may take, 10 to 3600 (120 by default). It is tried 3 times |
| RECONNECT_S | Seconds a run keeps trying while the network or the database does not answer, 60 to 86400 (600 by default) |

### Exit codes

| Exit code | Meaning |
|---|---|
| 0 | Done, every check passed |
| 1 | Failed, or not started because a required condition is not met |
| 2 | Done, with warnings |
| 3 | Stopped, or you answered no |
| 4 | A mistake in the command or the configuration. Nothing was changed |

A purge followed by a reclaim in one command (`--reclaim`) ends with the worse code of the two runs: 1, then 3, then 2.

## If something goes wrong

| What you see | What to do |
|---|---|
| `sqlplus.exe was not found` | Install an Oracle client, or add its `bin` folder to the PATH (or set ORACLE_HOME) |
| The connection as EPFPG is refused | Either the password is wrong, or the tool was never installed on this database: press Enter alone at the EPFPG password and the run installs it (SYS) |
| "The purge does not start: a required condition is not met" | Nothing was changed. The screen names the condition and the way past it (see [When a requirement is not met](#when-a-requirement-is-not-met)) |
| A purge was interrupted: the window was closed, the connection dropped | Run the same command again: it goes on from where it stopped. What was deleted stays deleted |
| A reclaim was interrupted, or the application's accounts are still locked | `src\bin\epf_purge.bat reclaim --restore` puts everything back and unlocks the accounts |
| You are not sure whether something is left pending | `src\bin\epf_purge.bat status` says so. The [reference](docs/REFERENCE.md#status-and-recovery) lists what clears each thing |
| The datafiles are as large as before the purge | That is expected: the space is free for the database to use again, not yet given back to the disk. Run the reclaim |
| A datafile is a little larger again some minutes after a reclaim | Oracle adds about 5% of free space back to a datafile that can grow. Nothing to do |
| During a purge, a long query of another session fails with ORA-01555 | The purge keeps undo for 60 seconds only while it runs. Purge in a quiet period |

When you ask for help, send the run folder: `console.log` has every line of the run and `report.txt` the whole report.

## More detail

The [reference](docs/REFERENCE.md) has what lies behind this guide:

- [How a purge chooses its rows](docs/REFERENCE.md#what-it-does): the root tables and their date columns.
- [The requirements and their questions](docs/REFERENCE.md#the-requirements-and-their-questions), and [undo tuning](docs/REFERENCE.md#undo-tuning-every-purge): what every purge changes for its time and puts back.
- [How a reclaim works](docs/REFERENCE.md#reclaim-disk-space), with its scratch space.
- [Runs, reports and logs](docs/REFERENCE.md#runs-reports-and-logs): the files of a run folder.
- [Status and recovery](docs/REFERENCE.md#status-and-recovery): what can be left pending and what clears it.
- [Settings](docs/REFERENCE.md#settings) kept in the database, and the [SQL*Plus scripts](docs/REFERENCE.md#sqlplus-scripts).

[Scenarios](docs/SCENARIOS.md) walks through the tool screen by screen, without a database: what is typed and what the tool answers, in the everyday cases and when something is not as it should be.

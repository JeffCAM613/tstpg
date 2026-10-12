# EPF Data Purge

EPF Data Purge removes old data from the EPF application's schemas (OP, OPPAYMENTS and OPREPORTS), and can give the disk space it frees back to the disk. It checks the database before it changes anything, can simulate a purge first, splits a large purge into smaller runs, and records every run with a report and a verdict.

This guide is also available as a web page: [docs/README.html](docs/README.html).

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Install](#install)
- [Configure](#configure)
- [Run it](#run-it)
- [Purge](#purge)
- [Large purges: a plan of smaller runs](#large-purges-a-plan-of-smaller-runs)
- [Reclaim disk space](#reclaim-disk-space)
- [Stop a run](#stop-a-run)
- [Runs, reports and logs](#runs-reports-and-logs)
- [Status and recovery](#status-and-recovery)
- [Settings](#settings)
- [SQL*Plus scripts](#sqlplus-scripts)
- [Command reference](#command-reference)
- [Repository layout](#repository-layout)
- [Testing](#testing)

## What it does

The data is grouped in three modules. Each module has root tables with a date column. A root row is eligible when its date is before the cutoff, and its whole tree of dependent rows goes with it.

| Module | What it holds | Root tables (date column) |
|---|---|---|
| PAYMENTS | Bulk payments with all their dependent records, and file integrations | OPPAYMENTS.BULK_PAYMENT (VALUE_DATE), OPPAYMENTS.FILE_INTEGRATION (INTEGRATION_DATE) |
| LOGS | Functional audit trail and technical logs | OPPAYMENTS.AUDIT_TRAIL (AUDIT_TIMESTAMP), OP.SPEC_TRT_LOG (DTLOG) |
| BANK_STATEMENTS | Bank statement dispatching | OPPAYMENTS.FILE_DISPATCHING (DATE_RECEPTION) |

The cutoff is today minus the days of data to keep (`--retention DAYS`; a purge asks for them when they are not given), or a date given with `--cutoff YYYY-MM-DD`. A root that a kept row still references is left, with its tree, for a later run.

The mode decides what happens to the eligible rows:

| Mode | Effect |
|---|---|
| FULL | Deletes the eligible rows of the modules chosen with `--depth` (ALL by default). |
| CLOB | Keeps the rows and empties their large text and binary values (LOB columns). |
| LOGS | Deletes the eligible rows of the LOGS module only. |
| CLOB_N_LOGS | Deletes the eligible rows of the LOGS module, and empties the LOB values of the other modules. |

A purge works in batches: each batch is one transaction, committed before the next one starts. It does not lock the application's accounts.

The space a purge frees stays inside the tables: the datafiles keep their size. The [reclaim](#reclaim-disk-space) gives that space back to the disk.

## Requirements

- A Windows machine with Windows PowerShell 5.1 and an Oracle client: `sqlplus.exe` in the PATH or in `%ORACLE_HOME%\bin`, and a TNS alias or an EZConnect string for the database.
- Oracle Database 12.2 or later (developed on 19c). In a multitenant database, connect to the PDB service.
- The SYS password (AS SYSDBA) to install, upgrade and uninstall the tool's objects, to reclaim, and for every purge that deletes (its [undo tuning](#undo-tuning-every-purge), and the larger online redo logs). A dry run of a purge needs only the tool's own account, EPFPG, which the install creates.
- For a reclaim: a single-instance database (not RAC).
- Best run from a machine on the database's own network rather than through a VPN. Every step opens a sqlplus session, and a long reclaim depends on its connection until the end: a dropped connection ends the run, which then restores what it changed. Short drops are retried for 10 minutes (`RECONNECT_S`).

## Install

There is nothing to install by hand. Every purge and every reclaim gets ready by itself and says so:

```text
 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFPDB: connected (EPFPDB)
   Tool in database   version 0.9.4
```

- **The first time on a database** the tool's own objects are missing. The run says so, explains what they are (an account EPFPG and a tablespace EPFPG_DATA next to the application's data, with the tool's tables and packages), and asks whether to install them. It then asks for the SYS password and for the password to give the EPFPG account (twice), and goes on with what it was asked. At the question for the EPFPG password, press Enter alone when the tool was never installed there.
- **After an update of these scripts** the objects in the database are of an older version: the run asks whether to upgrade them (SYS). The run history and the settings you changed are kept.
- Without prompts (`--non-interactive`), both are done without asking, with the passwords of the environment or the configuration file (see [Passwords](#passwords)).

`src\bin\epf_purge.bat install --tns EPFPDB` does the same by hand, and ends with `EPFPG objects valid, tool version <version>`.

To remove the tool: `src\bin\epf_purge.bat uninstall` drops the EPFPG account and the EPFPG_DATA tablespace, with the history of the runs. A purge or a reclaim that ended well also asks whether to remove them (the default is to keep them); `UNINSTALL_AFTER=Y` in the configuration file answers yes for runs without prompts. The reports on the machine stay either way, and the next run installs the objects again.

## Configure

Copy `src\config\epf_purge.conf.example` to `src\config\epf_purge.conf` and set at least `TNS`. The example file describes every key. Another file can be given with `--config FILE`.

Command-line options override the file. With prompts, a value in the file is the default answer of its question (the database, the days to keep) or the answer itself (a yes or no such as `REDO_LOGS`); with `--non-interactive`, it is the answer.

| Key | Option | Meaning |
|---|---|---|
| TNS | `--tns` | The database: its alias in tnsnames.ora, or host:port/service. Asked for when not given |
| RETENTION_DAYS | `--retention` | Days of data to keep: older rows are purged. Asked for when not given; required for a purge without prompts |
| CUTOFF | `--cutoff` | Instead of the retention: purge rows dated before this day |
| MODE | `--mode` | FULL (the default), CLOB, LOGS or CLOB_N_LOGS |
| DEPTH | `--depth` | ALL (the default), or modules separated by commas |
| BATCH_SIZE | `--batch-size` | Root rows per transaction, 100 to 100000. By default, with prompts: what the checks recommend |
| DRY_RUN | `--dry-run` | Y: show what would happen, change nothing |
| COMPACT | `--compact` | Y: shrink the purged tables afterwards |
| REDO_LOGS | `--redo-logs` | Y: larger online redo logs (4 x 1 GB) for the purge when one batch does not fit, without being asked; the original groups are put back at the end (SYS) |
| UNDO_TUNING | `--undo-tuning` | Accepted and ignored: every purge runs with [undo tuning](#undo-tuning-every-purge) |
| BACKUP | `--backup` | Without a recent RMAN backup, without being asked: CONFIRMED (a backup was made another way) or NONE |
| CONFIRM | `--confirm` | Requirements to go on without although they are not met, without being asked: ARCHIVE, UNDO, TEMP |
| MAX_REDO | `--max-redo` | The most redo one run may write, such as 20G: the purge is split into runs |
| RECLAIM_TABLESPACES | `--tablespaces` | Reclaim: the tablespaces to compact |
| RECLAIM_CONFIRM | `--confirm` | Reclaim: ARCHIVE, TEMP, RECYCLEBIN |
| RECLAIM_SCRATCH | `--scratch` | Reclaim: the most scratch space for the tables that cannot move lower, such as 3G. By default the size the reclaim measures; NONE: no scratch space |
| UNINSTALL_AFTER | | Y: after a purge or a reclaim that ended well, the tool's objects are removed from the database. With prompts, the run asks |
| LOG_DIR | `--log-dir` | Where the run folders go (`logs` by default) |
| VERBOSE | `--verbose` | Y: every event and the whole report on the console |
| NO_COLOR | `--no-color` | Y: plain output |
| OPEN_REPORT | `--no-open` | N: report.html is written and not opened in the browser |

### Passwords

The tool never places a password on a command line or in a file it writes. It reads the passwords from the environment variables EPF_PASSWORD (EPFPG) and EPF_SYS_PASSWORD (SYS), or from EPF_PASSWORD and SYS_PASSWORD in the configuration file, or asks for them without showing them. A configuration file that holds them is as sensitive as the passwords: keep it where only the account that runs the tool can read it.

With `--non-interactive` the tool cannot ask. Set both variables first, once per PowerShell window. This line asks for both passwords without showing them; the command history keeps only the line:

```powershell
$env:EPF_PASSWORD = [Net.NetworkCredential]::new('', (Read-Host 'EPFPG password' -AsSecureString)).Password; $env:EPF_SYS_PASSWORD = [Net.NetworkCredential]::new('', (Read-Host 'SYS password' -AsSecureString)).Password
```

When you are done (closing the window does the same):

```powershell
Remove-Item Env:EPF_PASSWORD, Env:EPF_SYS_PASSWORD
```

## Run it

There are two things to do, and each can be a dry run:

| | Dry run (changes nothing) | For real |
|---|---|---|
| **Purge**: delete the old rows | `epf_purge.bat purge --dry-run --retention 365` | `epf_purge.bat purge --retention 365` |
| **Reclaim**: give the freed space back to the disk | `epf_purge.bat reclaim --dry-run` | `epf_purge.bat reclaim` |

A purge alone frees no disk space: the rows are gone, and the datafiles keep their size until a reclaim. A purge deletes in small batches and does not lock the application's accounts (run it in a quiet period); a reclaim needs the database not in use, and locks those accounts while it runs. The purge comes first.

- **The menu.** `src\bin\epf_purge.bat` without an action asks what you want: a dry run of a purge, a purge, a dry run of a reclaim, a reclaim, the report of an earlier run, the status, or the removal of the tool.
- **Commands.** `src\bin\epf_purge.bat <action> [options]`. `src\bin\epf_purge.bat --help` explains purge and reclaim, then lists every action and option.
- **One command without prompts.** With `--non-interactive` nothing is asked: the database, the passwords and the days to keep come from the options, the environment or `--config FILE`, and the purge or the reclaim starts without confirmation. This is the command a scheduler of yours can start; the tool schedules nothing itself. For example `epf_purge.bat purge --non-interactive --config D:\epf\nightly.conf`.

Every run asks only what it cannot find: the database when `--tns` and the configuration file do not give it, the passwords, the days of data to keep.

The screen shows the steps of the run by what they do, each with its time. While rows are deleted there is one line per module, with its progress, the rows, the speed and the time left:

```text
 1 of 4  Checking the database (read-only)                         done    0:05
 2 of 4  Preparing the database for the purge (SYS)                done    0:02
         undo kept 60 s and its tablespace under 4.0 GB while rows are deleted; put back at the end
 3 of 4  Deleting
         PAYMENTS         [##########..........]  50%   9,109,274 rows . 39,149 rows a second . 3:50 left
```

Warnings and errors are shown as they come. At the end the run says in plain words what was done, what to know and what comes next, and opens its report in the browser (see [Runs, reports and logs](#runs-reports-and-logs)). `--verbose` shows every event and the whole text report instead; console.log in the run folder has every line either way. Ctrl+C asks for a graceful stop (see [Stop a run](#stop-a-run)).

## Purge

### 1. Dry run

```bat
src\bin\epf_purge.bat purge --dry-run --retention 365
```

A dry run checks the database, counts exactly what a purge would delete, and changes nothing. It shows:

- the requirements as a table (below);
- the rows to delete and the space freed, per module, and how long the deleting would take;
- the disk a purge takes while it runs and where: the undo tablespace up to its limit, the temporary space, the temporary indexes and the online redo logs, each with its file and how much more than now, then the tablespaces whose tables are purged;
- the same figures for other retentions, so that the days to keep can be chosen by the space they free;
- whether the purge would complete as things are, and the command that runs it.

### 2. Purge

```bat
src\bin\epf_purge.bat purge --retention 365
```

The purge checks the database, shows the requirements and asks the questions they call for, shows what it is about to delete and asks you to type `yes`. It then deletes in batches and ends with its checks and its report. Without prompts, every answer comes from the options or the configuration file and nothing is confirmed:

```bat
src\bin\epf_purge.bat purge --non-interactive --retention 365 --redo-logs
```

A purge without prompts deletes only what it is told to: the days to keep must be given (`--retention`, `--cutoff`, or the configuration file).

### The requirements and their questions

Every purge, and every dry run, checks six requirements and shows them as a table: whether each is required or optional, its state now with what was measured, and for each one not met what happens and what to do.

| Requirement | Needed | What it checks | With prompts | Without prompts |
|---|---|---|---|---|
| Room for the archived logs (ARCHIVE) | required | In ARCHIVELOG mode, the archive destination has room for the purge's redo, plus 20 % | Go on anyway? (not recommended) | `--confirm ARCHIVE`, or a [plan of smaller runs](#large-purges-a-plan-of-smaller-runs) |
| Undo space (UNDO) | required | The undo tablespace holds four batches within the limit [undo tuning](#undo-tuning-every-purge) sets | A batch size that fits is taken; otherwise: go on anyway? | `--batch-size`, or `--confirm UNDO` |
| Temporary space (TEMP) | required | The temporary tablespace holds the purge's work keys | Go on anyway? (not recommended) | `--confirm TEMP` |
| Backup (BACKUP) | required | An RMAN database backup newer than 24 hours | Is there a backup RMAN does not know? If not: purge without a backup? | `--backup confirmed` or `--backup none` |
| Room for the temporary indexes (INDEX_SPACE) | optional | EPFPG_DATA holds the temporary indexes the purge creates | Nothing is asked: the purge is only slower | |
| Online redo logs (REDO_LOGS) | optional | One batch fits in an online redo log (otherwise the purge waits for them at times) | Enlarge them for this purge? (4 x 1 GB, put back at its end) | `--redo-logs` |

A required one that is not met is a strong warning, and going on is your choice: the default answer is no. Without prompts nothing is gone past unless its option says so: the purge does not start, says which requirement stops it and the option that goes past it, and changes nothing. A dry run asks nothing about them; when something is not met it says so and asks whether to go on.

More options for the purge:

- `--compact` shrinks the purged tables afterwards (tables with at least 20 % free inside them).
- `--redo-logs` gives the purge online redo logs of 4 x 1 GB when one batch does not fit in the smallest log, and puts the original groups back at the end: the same group numbers, file names and sizes (Oracle-managed and ASM files get new names in the same place). Logs that already hold a batch are left as they are (SYS).
- `--mode` and `--depth` limit the purge to some modules, or to emptying LOB values (see [What it does](#what-it-does)).

The end of a purge says how long the batches waited for log switches, for example `log switches 00:02:13 of 00:28:53 in batches (8%), online logs 3 x 200.0 MB`. A full online log is reused only once Oracle has written its changes to the datafiles (a checkpoint), and archived it in ARCHIVELOG mode; small logs make the purge wait for that. That figure is what larger logs could save.

### The checks alone (preflight)

```bat
src\bin\epf_purge.bat preflight --retention 365
```

The preflight is the first step of every purge, run alone: it validates the tool's table registry against the database, counts the eligible rows, estimates the redo, undo and time of the purge, checks the requirements with their questions, and plans the purge. It changes nothing. The answers are saved with the plan, and the purges of the plan follow them.

### Undo tuning (every purge)

Every purge runs with undo tuning, and needs the SYS password for it. Why:

- Every row a purge deletes writes undo, about half as much as its redo: 31.7 GB for 89 M rows on one test copy.
- Oracle keeps committed undo for undo_retention (900 s by default), and with autoextensible undo datafiles for as long as the longest call runs. A purge is one long call, so the undo tablespace grows by tens of GB (27.6 GB in one purge without tuning).
- A datafile does not shrink by itself: Oracle keeps the size an undo, temporary or data file grew to. Undo retention only says how long old undo is kept inside the undo tablespace.

For the purge, undo tuning sets undo_retention to 60 s (in memory only) and caps the undo tablespace at the largest of its size, 4 GB (setting undo_cap_mb) and 4 batches of undo. Each batch commits, so the purge reuses its own undo instead of growing the tablespace. It does not slow the purge.

At the end it restores undo_retention and the cap, and gives back what the undo datafiles and the temporary tablespaces grew: the temporary tablespaces at once, the undo datafiles as far as Oracle has released their extents. Oracle keeps undo extents for hours (18 hours after the purges, one test database could only go from 5.4 to 4.6 GB), so when the undo datafiles are still more than 1 GB (setting undo_switch_min_mb) above their size before, the undo tablespace is switched:

1. A small undo tablespace, EPF_UNDO_SWAP (256 MB, next to the undo datafile), becomes the instance's undo tablespace.
2. Once none of the original's undo segments is in use, the original is dropped with its datafiles and created again: the same tablespace name, the same file names, each file at its size before and with its growth settings. On Oracle-managed files and ASM, Oracle names the files.
3. It becomes the undo tablespace again, and EPF_UNDO_SWAP is dropped with its file.

Nothing is renamed, run after run. The switch takes a few seconds; the original is created small and then resized, so the moment without it is well under a second. It is not done with a standby database. On an instance started from a pfile that names undo_tablespace it is skipped, since a crash in that moment would need the pfile edited before the next startup; the setting undo_switch_pfile (Y) accepts that. An spfile follows each step, and a pfile that does not name undo_tablespace takes whichever undo tablespace exists. It waits up to 5 minutes (setting undo_switch_wait_s) for the transactions of other sessions to end; otherwise it is skipped and says why. Each step is recorded first: a switch that stops part way is carried on by `src/sql/run/undo.sql SWITCH`, the next restore or the next purge, and `status` shows it. `undo.sql SWITCH <size_mb>` switches by hand, such as on a database a tool grew before.

While it is applied, a long query of another session can fail with ORA-01555 (snapshot too old): run purges in a quiet window. An undo tablespace with RETENTION GUARANTEE has to be set to NOGUARANTEE by the DBA first.

## Large purges: a plan of smaller runs

When the archive destination (ARCHIVELOG mode) cannot take the whole purge's redo at once, or when `--max-redo SIZE` limits it, the preflight plans several runs, older data first.

```bat
src\bin\epf_purge.bat preflight --retention 365 --max-redo 20G
src\bin\epf_purge.bat plan
src\bin\epf_purge.bat purge
```

- `purge`, without scope options, carries out the next step of the open plan; `purge --dry-run` rehearses it.
- `preflight` checks the plan again; a purge with prompts does so itself when the last check is older than 8 hours or found requirements not met.
- Without prompts, `purge` continues an open plan only with `--yes` or with the days to keep given (options or configuration file).
- In ARCHIVELOG mode, back up and delete the archived logs between runs.
- While a plan is in progress, a purge with other options is refused; `--new` starts over (the steps already done stay done). `plan --close` closes the plan.

## Reclaim disk space

A purge frees space inside the tables, but the datafiles keep their size. The reclaim compacts the application's tablespaces in place and shrinks their datafiles:

1. It locks the application's accounts and disconnects their sessions. **The application is unavailable until the end of the run.**
2. It records the row counts and a fingerprint of the objects, releases the indexes of the tables that will move (they are rebuilt at the end), and stops the datafiles from growing.
3. Repeatedly, the table holding the highest block of a datafile moves into free space lower down, and the datafile is cut down to its new end.
4. It rebuilds the indexes, restores the datafiles' growth settings, resizes each datafile to its highest block plus 64 MB of free space, recompiles what became invalid, counts the rows again and unlocks the accounts.

The reclaim changes no row of the application, and no datafile grows above its size at the start (two rare exceptions are reported as warnings).

A datafile that can grow by itself does not stay at exactly the size of its tables and indexes: within minutes of the run Oracle extends such a file ahead of need, until about 5% of it is free. The run therefore passes its efficiency check (R7) when a tablespace ends within 5% of its segments (256 MB for a small one), and warns above that, naming what held the space.

```bat
src\bin\epf_purge.bat reclaim --dry-run
src\bin\epf_purge.bat reclaim
```

Every reclaim measures first, in a read-only run (its dry run): what it gives back to the disk, tablespace by tablespace, the accounts it locks, the requirements, and the scratch space it takes with the file it creates for it. `--dry-run` ends there. With prompts, the reclaim then asks about each required one that is not met, and asks you to type `yes` before anything moves. Without prompts (`reclaim --non-interactive`) it goes straight on, and does not start while a required one is not met.

Options:

- `--tablespaces DATA,INDX` limits the reclaim to those tablespaces. By default it takes every tablespace holding segments of the application's schemas.
- `--confirm RECYCLEBIN` lets it purge the recycle bin of those tablespaces first, without being asked; without it, recycle-bin objects stop a reclaim without prompts before any change. `--confirm ARCHIVE` and `--confirm TEMP` work as for a purge.
- `--scratch SIZE`, such as `--scratch 3G`, sets the limit of the scratch tablespace; by default it is the size the reclaim measures, and `--scratch none` runs without scratch space. Oracle chooses where the copy of a moved table goes, and may put it back at the top of the file; a table may also not fit lower down. With scratch space, such a table waits in a scratch tablespace (created next to its tablespace's datafile) while the rest is compacted, then comes back into the space left free, and the scratch tablespace is dropped. Without it, the datafile stops shrinking at that table. Parking ends once it would not make the tablespace smaller: the parked tables take the free space when they come back, so with less free space than is parked, emptying more of the top would only write tables twice (FILE_DONE says so); the tables with free space inside them that fit below still move first. The tables come back last parked first and the scratch datafile is resized down after each, so the scratch datafile shrinks while the tablespace grows again. The result says the most the run held on disk, scratch space included (`On disk`, event DISK_PEAK), and the steps that write say how long they waited for log switches. The dry run shows where the scratch datafile would go and suggests a size: the largest table that moves and half of all that moves, plus a tenth. The scratch datafile grows only as far as the tables parked need, up to that size. A table that does not fit in what is left is reported with the size that would have taken it; once the scratch space is full, no more table is parked in that run (SCRATCH_FULL, with the size that would have taken the next one), and the tables that cannot move lower stay where they are.

The measurement checks these requirements, shown as a table like those of a purge: the recycle bin, the room for the archived logs, the temporary space and the space quotas of the owners are required (the quotas cannot be gone past: the owners need a space quota where their tables are written again); a backup is optional, and the scratch space is taken by the reclaim itself.

Some segments cannot move: partitioned tables, queue tables, tables with a LONG column, and a few other kinds. They stay where they are, the assessment lists them, and a datafile cannot shrink below the highest of them.

If a reclaim is interrupted, what it changed is undone: at once after Ctrl+C or `stop`; in the same run when its session is lost; otherwise by `src\bin\epf_purge.bat reclaim --restore`. `status` shows anything left pending.

## Stop a run

Press Ctrl+C in the window that shows the run, or, from another window:

```bat
src\bin\epf_purge.bat stop
```

A purge stops after its current batch, a reclaim after its current table. The run then ends with its report, with status STOPPED and exit code 3. Run the purge again to continue: the rows already deleted stay deleted.

## Runs, reports and logs

Every action that works on the database creates a run, such as R-000123, recorded in the EPFPG tables, and a folder `logs\<date>_<time>_R-000123`:

| File | Content |
|---|---|
| console.log | Every line of the run as `--verbose` shows it: every event and the whole report |
| report.txt | The run's report: parameters, steps, results, checks and verdict |
| manifest.txt | A key=value summary: status, verdict, exit code, checks |
| requirements.txt, plan.txt | The requirements and the plan, when the run has them |
| summary.txt | The report in short: the estimate or the simulation, the disk a purge takes while it runs, the requirements, the tablespaces, the checks that did not pass and the verdict; for a reclaim, also its datafiles at the start and at the end |
| report.html | The run in a browser: the result in one sentence, the main figures, the modules or tablespaces, for a dry run the disk a purge takes while it runs and the other retentions, the duration by step, the checks, the requirements, warnings and errors, what to do next, and the full text report. One file with its styles inside. It opens at the end of the run when somebody is at the console |
| sqlplus_*.log | The output of the SQL*Plus sessions |

Each run ends with its checks and a verdict: PASS, PASS WITH WARNINGS or FAIL. To show a report again:

```bat
src\bin\epf_purge.bat report
src\bin\epf_purge.bat report --run 123
```

The first shows the latest run. Runs older than 180 days (setting history_retention_days) are removed from the database when a new run starts; the run folders stay until you delete them.

| Exit code | Meaning |
|---|---|
| 0 | PASS |
| 1 | FAIL |
| 2 | PASS WITH WARNINGS |
| 3 | Aborted or stopped |
| 4 | Usage or configuration error (nothing was changed) |

## Status and recovery

```bat
src\bin\epf_purge.bat status
```

The status shows the active run, or the latest one, with its steps and last events, and anything left pending:

| Left pending | Cleared by |
|---|---|
| Temporary indexes of an interrupted purge | The next purge drops them. |
| Undo tuning still active | The purge restores it at its end; otherwise `src/sql/run/undo.sql RESTORE` as SYS (see [SQL*Plus scripts](#sqlplus-scripts)). |
| An undo switch not finished (another session's transaction still held the original) | `src/sql/run/undo.sql SWITCH` as SYS carries it on; the next purge does too. |
| Online redo logs replaced for a purge | The purge puts the original groups back at its end; otherwise `src/sql/run/redo_logs.sql RESTORE` as SYS. |
| Undo or temporary space a purge or reclaim made Oracle add (information) | Given back as far as Oracle allows at the end of the run, undo by a switch when more than 1 GB stays; the rest by `src/sql/run/undo.sql RESTORE`, or all of the undo at once by `undo.sql SWITCH`, as SYS. |
| Reclaim changes: datafile growth stopped, indexes still unusable, accounts still locked, tables still parked, a scratch tablespace | `src\bin\epf_purge.bat reclaim --restore`; a new reclaim restores them too. |

## Settings

The tunables are rows of the table EPFPG.EPF_SETTING. An upgrade keeps the values you changed. The ones most often changed:

| Setting | Default | Meaning |
|---|---|---|
| app_schemas | OP,OPPAYMENTS,OPREPORTS | The application's schemas; the tablespaces they use are reclaim candidates |
| retention_days_default | 30 | Retention in days when none is given |
| batch_size_default | 1000 | Root rows per batch when none is given |
| history_retention_days | 180 | Runs older than this are removed when a new run starts |
| backup_max_age_h | 24 | An RMAN backup newer than this meets BACKUP |
| archive_margin_pct | 20 | Margin added to the redo estimate for ARCHIVE |
| undo_cap_mb | 4096 | Undo growth limit with undo tuning |
| undo_switch_min_mb | 1024 | After a purge, the undo tablespace is switched when its datafiles are still this much above their size before |
| compact_min_free_pct | 20 | `--compact` shrinks the tables with at least this share free |
| reclaim_margin_mb | 64 | Free space a reclaim leaves at the end of each datafile |
| reclaim_growth_mb | 0 | How far a reclaim may grow a datafile above its size at the start |
| disconnect_timeout_s | 300 | Seconds a reclaim waits for sessions to end before it disconnects them at once |

To change one, connected as EPFPG:

```sql
UPDATE epfpg.epf_setting SET value = '365' WHERE name = 'retention_days_default';
COMMIT;
```

## SQL*Plus scripts

The tool runs the scripts of `src\sql\run`. Some of them can be run directly in SQL*Plus, from the tool's folder:

| Script | Connect as | Purpose |
|---|---|---|
| `report.sql <run_id or LATEST>` | EPFPG | The report of a run |
| `status.sql` | EPFPG | The status, as `epf_purge.bat status` |
| `stop.sql <run_id or ACTIVE>` | EPFPG | A graceful stop |
| `preflight.sql NEW` | EPFPG | A standalone preflight with the default parameters |
| `undo.sql APPLY, RESTORE or STATUS` | SYS AS SYSDBA | Undo tuning by hand (APPLY before `purge.sql`, which does not start without it); RESTORE also gives back what undo and temp grew |
| `undo.sql SWITCH [<size_mb>]` | SYS AS SYSDBA | Creates the undo tablespace again under the same names: each datafile at its size before the purge, or at `size_mb`. Also carries on a switch that stopped part way |
| `redo_logs.sql RESTORE` | SYS AS SYSDBA | Puts back the online redo log groups replaced for a purge |
| `redo_logs.sql SET <size_mb> <groups>` | SYS AS SYSDBA | Sets the online redo logs to that many groups of that size and keeps them so, such as `SET 200 3` for the size they had before another tool enlarged them. New groups take the lowest free numbers (group 1 is redo01.log); the others are dropped once Oracle no longer needs them, with their files |

For example (SQL*Plus asks for the password):

```bat
sqlplus -L -S "epfpg@EPFPDB" @src/sql/run/report.sql LATEST
sqlplus -L "sys@EPFPDB AS SYSDBA" @src/sql/run/undo.sql RESTORE
```

## Command reference

`src\bin\epf_purge.bat --help` prints the complete reference.

| Action | What it does |
|---|---|
| (none) | The menu |
| `purge` | Checks, questions, purge and report; `--dry-run` counts what it would delete and changes nothing |
| `reclaim` | Gives the freed space back to the disk, after measuring; `--dry-run` measures only, `--restore` restores what a reclaim left pending |
| `report` | The report of a run: `--run ID`, the latest by default |
| `status` | The state of the active or latest run, and anything left pending |
| `stop` | A graceful stop of the active run |
| `uninstall` | Removes the tool's objects from the database (SYS) |
| `install` | Installs or upgrades them (SYS); a purge or a reclaim does it when needed |
| `preflight` | The checks and estimates of a purge alone, and its plan |
| `plan` | The open plan with its steps; `--close` closes it |

General options: `--config FILE`, `--tns NAME`, `--non-interactive` (ask nothing; a purge or a reclaim starts without confirmation), `--yes` (skip the typed confirmation of a run with prompts; required with `--non-interactive` for `uninstall` and `plan --close`), `--no-open`, `--log-dir DIR`, `--verbose`, `--no-color`, `--help`.

## Repository layout

```text
src\bin\epf_purge.bat    the tool (its code is in src\bin\lib: epf.ps1, the screen in
                         epf_screen.ps1, the HTML report in epf_html.ps1)
src\config\              the configuration example
src\sql\install\         installer, tables and packages of the EPFPG schema
src\sql\run\             the SQL*Plus scripts the tool runs
src\tests\               end-to-end tests, test labs and the parity check
docs\README.html         this guide as a web page
legacy\                  the previous tool, kept for reference
logs\                    run folders (not part of the repository)
```

## Testing

The end-to-end test suite runs every feature against a test database, and changes it: it purges every module, clears LOB values, compacts tables, enlarges the online redo logs during the purges (put back after each) and changes undo_retention during them. Its reclaim tests work on tablespaces they create and remove. Run it only on a copy that can be discarded.

1. Copy `src\tests\e2e\test.conf.example` to `src\tests\e2e\test.conf`, and set TNS, EXPECTED_DB and DESTRUCTIVE_OK=YES.
2. Run `src\tests\e2e\run_tests.bat` for the whole suite (about 3 hours), or a part of it, such as `src\tests\e2e\run_tests.bat --only T18A,T18B`.
3. `src\tests\e2e\run_tests.bat --digest` writes a short summary of the last test session and of the runs after it to `logs\digest.txt` and copies it to the clipboard: each run with its checks, every step with its duration, key events (a large move with the time it took), restore lines and summary, and the time of the runs in all. With the SYS password at hand (EPF_SYS_PASSWORD, or SYS_PASSWORD in test.conf) it adds the database as it is now: how the instance started, the tool installed and whether its objects are valid, the online logs, and every datafile and temporary file with its size, the free space inside it and the step it grows by.
4. `src\tests\e2e\run_tests.bat --sys redo_logs.sql SET 200 3` runs a SYS script of `src\sql\run` (`redo_logs.sql`, `undo.sql`) on the test database of test.conf with the arguments that follow, as typed in SQL*Plus, after checking the database name. Its output is shown and kept in `logs\sys\`, and the digest lists what the script did. Test steps use it in place of SQL*Plus by hand, so that the digest carries them too.
5. `src\tests\sim\epf_sim.bat` plays the screens and questions of a purge and a reclaim with scripted figures, as they were designed before the tool followed them: it connects to nothing and needs no database. `epf_sim.bat --help` lists what it takes; `--sim` chooses the state the database is found in (a requirement not met, the tool not installed, a run that fails). It writes a sample `report.html` under `logs\sim\`.

# EPF Data Purge: reference

What lies behind the [user guide](../README.md): how a purge chooses its rows, the requirements it checks, undo tuning, a purge planned in several runs, how a reclaim works, the files of a run, what can be left pending and what clears it, the settings and the SQL*Plus scripts. Start with the user guide; come here for the detail.

This reference is also available as a web page: [REFERENCE.html](REFERENCE.html).

## Contents

- [What it does](#what-it-does)
- [Requirements](#requirements)
- [Purge](#purge)
- [Large purges: a plan of smaller runs](#large-purges-a-plan-of-smaller-runs)
- [Reclaim disk space](#reclaim-disk-space)
- [Runs, reports and logs](#runs-reports-and-logs)
- [Status and recovery](#status-and-recovery)
- [Settings](#settings)
- [SQL*Plus scripts](#sqlplus-scripts)
- [Files of the tool](#files-of-the-tool)

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
| LOGS | Deletes the eligible rows of the LOGS module only: the same as FULL with `--depth LOGS`. The depth is not asked for then. |
| CLOB_N_LOGS | Deletes the eligible rows of the LOGS module, and empties the LOB values of the other modules. |

The mode says what is done to the rows; the depth says in which modules (PAYMENTS, LOGS, BANK_STATEMENTS, or ALL). LOGS is the name of a module, and also of the mode that is a shorthand for that module alone.

A purge works in batches: each batch is one transaction, committed before the next one starts. It does not lock the application's accounts.

Every purge that deletes ends by compacting the tables it purged, so the space of the deleted rows goes back to their tablespace, where the database can use it again. The datafiles keep their size: the [reclaim](#reclaim-disk-space) gives that space back to the disk.

## Requirements

- A Windows machine with Windows PowerShell 5.1 and an Oracle client: `sqlplus.exe` in the PATH or in `%ORACLE_HOME%\bin`, and a TNS alias or an EZConnect string for the database.
- Oracle Database 12.2 or later (developed on 19c), single instance. A purge that deletes does not run in a multitenant database yet (a pluggable database of a container database), nor on RAC: its undo tuning needs the instance to itself and refuses both.
- The SYS password (AS SYSDBA) to install, upgrade and uninstall the tool's objects, to reclaim, and for every purge that deletes (its [undo tuning](#undo-tuning-every-purge), and the larger online redo logs). A dry run of a purge needs only the tool's own account, EPFPG, which the install creates.
- For a reclaim: a single-instance database (not RAC).
- Best run from a machine on the database's own network rather than through a VPN. Every step opens a sqlplus session, and a long reclaim depends on its connection until the end: a dropped connection ends the run, which then restores what it changed. Short drops are retried for 10 minutes (`RECONNECT_S`).

## Purge

The steps of a purge are in the [user guide](../README.md#getting-started). This part is what lies behind them.

### The requirements and their questions

Every purge, and every dry run, checks six requirements and shows them as a table: whether each is required or optional, its state now with what was measured, and for each one not met what happens and what to do.

| Requirement | Needed | What it checks | With prompts | Without prompts |
|---|---|---|---|---|
| Room for the archived logs (ARCHIVE) | required | In ARCHIVELOG mode, the archive destination has room for the purge's redo, plus 20 % | Go on anyway? (not recommended) | `--confirm ARCHIVE`, or a [plan of smaller runs](#large-purges-a-plan-of-smaller-runs) |
| Undo space (UNDO) | required | The undo tablespace holds four batches within the limit [undo tuning](#undo-tuning-every-purge) sets | A batch size that fits is taken; otherwise: go on anyway? | `--batch-size`, or `--confirm UNDO` |
| Temporary space (TEMP) | required | The temporary tablespace holds the purge's work keys | Go on anyway? (not recommended) | `--confirm TEMP` |
| Backup (BACKUP) | required | An RMAN database backup newer than 24 hours | Is there a backup RMAN does not know? If not: purge without a backup? | `--backup confirmed` or `--backup none` |
| Room for the temporary indexes (INDEX_SPACE) | optional | EPFPG_DATA holds the temporary indexes the purge creates | Nothing is asked: the purge is only slower | |
| Online redo logs (REDO_LOGS) | optional | One batch fits in an online redo log (otherwise the purge waits for them at times) | Enlarge them for this purge? (4 x 1 GB, put back at its end). Not asked in a pluggable database | `--redo-logs` (not used in a pluggable database) |

In a pluggable database the online redo logs belong to the container database: the tool neither asks about them nor enlarges them there, and says so.

A required one that is not met is a strong warning, and going on is your choice: the default answer is no. Without prompts nothing is gone past unless its option says so: the purge does not start, says which requirement stops it and the option that goes past it, and changes nothing. A dry run asks nothing about them; when something is not met it says so and asks whether to go on.

More options for the purge:

- The compaction is part of every purge that deletes, after its last module: the tables it purged that have at least 20 % of free space inside them (setting compact_min_free_pct) are shrunk, largest free space first. Row movement is enabled for the time of the shrink and put back; the table is shrunk online, then its indexes and LOB segments where Oracle allows it. A table Oracle cannot shrink (index-organized, compressed, with a LONG column or a function-based index) is skipped, and the report says why. A dry run does not compact, nor does a purge that was stopped (the run that carries on does). `--compact` is accepted and changes nothing.
- `--redo-logs` gives the purge online redo logs of 4 x 1 GB when one batch does not fit in the smallest log, and puts the original groups back at the end: the same group numbers, file names and sizes (Oracle-managed and ASM files get new names in the same place). Logs that already hold a batch are left as they are (SYS).
- `--mode` and `--depth` limit the purge to some modules, or to emptying LOB values (see [What it does](#what-it-does)).

The report of a purge says how long its batches waited for log switches (WAITS), for example `log switches 00:02:13 of 00:28:53 in batches (8%), online logs 3 x 200.0 MB`. A full online log is reused only once Oracle has written its changes to the datafiles (a checkpoint), and archived it in ARCHIVELOG mode; small logs make the purge wait for that. That figure is what larger logs could save. When it is a tenth of the deleting time or more and the logs are smaller than 1 GB, the end of the purge and report.html say so in a sentence, with what saves it next time: the purge's question on the online logs, or `--redo-logs`; in a pluggable database, the DBA of the container database. A dry run says the same in advance when one batch writes more redo than an online log holds.

The report of a purge also says what the database's files took on disk (ON DISK): their size at the start, the most while the purge ran and their size at its end, once the database is put back, for example `at most 26.1 GB during the purge (4.2 GB more than at its start); 21.9 GB at the start, 22.0 GB at the end`. The files counted are the datafiles, the temporary files and the members of the online redo log groups; archived logs are not. The most is the largest size measured while the purge ran (the monitor measures it every few seconds). The end of the purge shows that line, and report.html the most and the size after.

### The checks alone (preflight)

```bat
src\bin\epf_purge.bat preflight --retention 365
```

The preflight is the first step of every purge, run alone: it validates the tool's table registry against the database, counts the top-level records old enough to purge (the roots; a dry run counts the rows under them), estimates the redo, undo and time of the purge, checks the requirements with their questions, and plans the purge. It changes nothing. The answers are saved with the plan, and the purges of the plan follow them.

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

A purge frees space inside the tablespaces, but the datafiles keep their size. The reclaim compacts the application's tablespaces in place and shrinks their datafiles:

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

## Runs, reports and logs

Every action that works on the database creates a run, such as R-000123, recorded in the EPFPG tables, and a folder `logs\<date>_<time>_R-000123`:

| File | Content |
|---|---|
| console.log | Every line of the run as `--verbose` shows it: every event and the whole report |
| report.txt | The run's report: parameters, steps, results, checks and verdict |
| manifest.txt | A key=value summary: status, verdict, exit code, checks |
| requirements.txt, plan.txt | The requirements and the plan, when the run has them |
| summary.txt | The report in short: the estimate or the simulation, the disk a purge takes while it runs, the requirements, the tablespaces, the checks that did not pass and the verdict; for a reclaim, also its datafiles at the start and at the end |
| report.html | The run in a browser: the result in one sentence, the main figures (for a purge also the most its database's files took on disk and their size after it), the modules or tablespaces, for a dry run the disk a purge takes while it runs and the other retentions, the duration by step, the checks, the requirements, warnings and errors, what to do next, and the full text report. One file with its styles inside. It opens at the end of the run when somebody is at the console |
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
| compact_min_free_pct | 20 | The compaction at the end of a purge shrinks the tables with at least this share free |
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
| `scope.sql <YYYY-MM-DD>` | EPFPG | What a purge covers with that cutoff, as `EPF_SCOPE` lines: the tables of each module with their sizes, and the rows of each root with those dated before the cutoff. Read-only; the questions on the mode and the depth show it |
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

## Files of the tool

```text
README.md                the user guide
RELEASE.txt              in a release: its version, and each of its files with its SHA-256
src\bin\epf_purge.bat    the tool (its code is in src\bin\lib: epf.ps1, the screen in
                         epf_screen.ps1, the HTML report in epf_html.ps1)
src\config\              the configuration example
src\sql\install\         installer, tables and packages of the EPFPG schema
src\sql\run\             the SQL*Plus scripts the tool runs
docs\                    this reference (REFERENCE.md), the scenarios (SCENARIOS.md), and
                         the user guide, the reference and the scenarios as web pages
logs\                    run folders, made by the first run
```

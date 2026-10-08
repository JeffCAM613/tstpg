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

The cutoff is today minus the retention (`--retention DAYS`, 30 by default), or a date given with `--cutoff YYYY-MM-DD`. A root that a kept row still references is left, with its tree, for a later run.

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
- The SYS password (AS SYSDBA) to install, upgrade and uninstall, to reclaim, and for `--redo-logs` and `--undo-tuning`. Everything else uses the tool's own account, EPFPG, which the install creates.
- For a reclaim: a single-instance database (not RAC).

## Install

From the tool's folder:

```bat
src\bin\epf_purge.bat install --tns EPFPDB
```

It asks for the SYS password, and for the EPFPG password to set (twice), unless EPF_SYS_PASSWORD and EPF_PASSWORD are set (see [Passwords](#passwords)). It creates the EPFPG user and its tablespace EPFPG_DATA (next to the application's data), then the tool's tables and packages, and ends with:

```text
  EPFPG objects valid, tool version <version>
```

Running the install again upgrades the tool in place: the run history and the settings you changed are kept.

To remove the tool: `src\bin\epf_purge.bat uninstall` drops the EPFPG user and the EPFPG_DATA tablespace.

## Configure

Copy `src\config\epf_purge.conf.example` to `src\config\epf_purge.conf` and set at least `TNS`. The example file describes every key. Another file can be given with `--config FILE`.

Command-line options override the file. In the wizard, a value in the file is the default answer of its question; with `--non-interactive`, it is the answer.

| Key | Option | Meaning |
|---|---|---|
| TNS | `--tns` | TNS alias or EZConnect string |
| RETENTION_DAYS | `--retention` | Days of data to keep (30 by default) |
| CUTOFF | `--cutoff` | Instead of the retention: purge rows dated before this day |
| MODE | `--mode` | FULL, CLOB, LOGS or CLOB_N_LOGS |
| DEPTH | `--depth` | ALL, or modules separated by commas |
| BATCH_SIZE | `--batch-size` | Root rows per transaction, 100 to 100000 |
| DRY_RUN | `--dry-run` | Y: simulate only |
| COMPACT | `--compact` | Y: shrink the purged tables afterwards |
| REDO_LOGS | `--redo-logs` | Y: enlarge the online redo logs to 4 x 1 GB first (permanent; SYS) |
| UNDO_TUNING | `--undo-tuning` | Y: lower undo_retention and limit the undo growth for the purge, restored at the end (SYS) |
| BACKUP | `--backup` | Without a recent RMAN backup: CONFIRMED (a backup was made another way) or NONE |
| CONFIRM | `--confirm` | Requirements the DBA confirms are handled: ARCHIVE, UNDO, TEMP |
| MAX_REDO | `--max-redo` | The most redo one run may write, such as 20G: the purge is split into runs |
| RECLAIM_TABLESPACES | `--tablespaces` | Reclaim: the tablespaces to compact |
| RECLAIM_CONFIRM | `--confirm` | Reclaim: ARCHIVE, TEMP, RECYCLEBIN |
| RECLAIM_SCRATCH | `--scratch` | Reclaim: scratch space for the tables that cannot move lower, such as 3G |
| LOG_DIR | `--log-dir` | Where the run folders go (`logs` by default) |
| VERBOSE | `--verbose` | Y: every event and the whole report on the console |
| NO_COLOR | `--no-color` | Y: plain output |

### Passwords

The tool never places a password on a command line or in a file it writes. It reads the passwords from the environment variables EPF_PASSWORD (EPFPG) and EPF_SYS_PASSWORD (SYS), or asks for them without showing them. The configuration file may hold them too, which is discouraged: the file is then as sensitive as the passwords.

With `--non-interactive` the tool cannot ask. Set both variables first, once per PowerShell window. This line asks for both passwords without showing them; the command history keeps only the line:

```powershell
$env:EPF_PASSWORD = [Net.NetworkCredential]::new('', (Read-Host 'EPFPG password' -AsSecureString)).Password; $env:EPF_SYS_PASSWORD = [Net.NetworkCredential]::new('', (Read-Host 'SYS password' -AsSecureString)).Password
```

When you are done (closing the window does the same):

```powershell
Remove-Item Env:EPF_PASSWORD, Env:EPF_SYS_PASSWORD
```

## Run it

There are two ways to use the tool.

- **The wizard.** `src\bin\epf_purge.bat` without an action opens a menu: purge, preflight only, reclaim disk space, report of a run, status, install or upgrade, uninstall. While a plan is open, it shows the plan and offers to continue it, check it again, rehearse its next step or start over. It asks every question before the first change.
- **Commands.** `src\bin\epf_purge.bat <action> [options]`, for example from a scheduled task with `--non-interactive`. `src\bin\epf_purge.bat --help` lists every action and option.

While a run is shown, the console shows the end of each step, the progress, warnings, errors and milestones such as the rows deleted per module or the size of each tablespace after a reclaim. A status line at the bottom shows what runs now. At the end comes a summary of the report: the estimate or the simulation, the requirements, the tablespaces, the checks that did not pass and the verdict. `--verbose` shows every event and the whole report instead. Either way, console.log in the run folder has every line (see [Runs, reports and logs](#runs-reports-and-logs)). Ctrl+C asks for a graceful stop (see [Stop a run](#stop-a-run)).

## Purge

### 1. Preflight (read-only)

```bat
src\bin\epf_purge.bat preflight --retention 365
```

The preflight validates the tool's table registry against the database, counts the eligible rows, estimates the redo, undo and time of the purge, checks six requirements, and plans the purge. It changes nothing.

Without `--non-interactive` it asks, for each requirement not met, how to meet it, then the batch size, and checks again. The answers are saved with the plan, and the purges of the plan follow them.

| Requirement | Blocking | What it checks | How to meet it |
|---|---|---|---|
| ARCHIVE | yes | In ARCHIVELOG mode, the archive destination has room for the purge's redo, plus 20 % | Free archive space; a [plan of smaller runs](#large-purges-a-plan-of-smaller-runs); or `--confirm ARCHIVE` when the database cannot measure the destination |
| UNDO | yes | The undo tablespace holds four batches and the undo kept for undo_retention | `--undo-tuning`, a smaller batch size, or `--confirm UNDO` |
| TEMP | yes | The temporary tablespace holds the purge's work keys | Room in TEMP, or `--confirm TEMP` |
| BACKUP | yes | An RMAN database backup newer than 24 hours | A backup; or `--backup confirmed` (made another way) or `--backup none` |
| INDEX_SPACE | no | EPFPG_DATA holds the temporary indexes the purge creates | Room in EPFPG_DATA |
| REDO_LOGS | no | One batch fits in an online redo log (otherwise the purge is only slower) | `--redo-logs`, or a smaller batch size |

A purge does not start while a blocking requirement is not met.

### 2. Dry run

```bat
src\bin\epf_purge.bat purge --dry-run
```

A dry run simulates the purge: the exact counts, the forecast and the expected outcome. It deletes nothing. While a plan is open, it rehearses the plan's next step.

### 3. Purge

```bat
src\bin\epf_purge.bat purge
```

With prompts, the purge runs a preflight first, asks how to meet any requirement not met, shows what it will do and asks you to confirm. It then deletes in batches and ends with its report. While a plan is open, `purge` without `--retention`, `--cutoff`, `--mode` or `--depth` carries out the plan's next step with its choices.

Unattended, every answer comes from the options or the configuration file, and `--yes` replaces the confirmation:

```bat
src\bin\epf_purge.bat purge --non-interactive --yes --retention 365 --mode FULL --backup confirmed
```

More options for the purge:

- `--compact` shrinks the purged tables afterwards (tables with at least 20 % free inside them).
- `--undo-tuning` lowers undo_retention and limits the growth of the undo tablespace (4 GB by default) for the purge, then restores both (SYS).
- `--redo-logs` enlarges the online redo logs to 4 x 1 GB first. This change is permanent (SYS).

With a preflight or a dry run, `--undo-tuning` and `--redo-logs` are checked as planned; nothing is changed.

## Large purges: a plan of smaller runs

When the archive destination (ARCHIVELOG mode) cannot take the whole purge's redo at once, or when `--max-redo SIZE` limits it, the preflight plans several runs, older data first.

```bat
src\bin\epf_purge.bat preflight --retention 365 --max-redo 20G
src\bin\epf_purge.bat plan
src\bin\epf_purge.bat purge
```

- `purge`, without scope options, carries out the next step of the open plan; `purge --dry-run` rehearses it.
- `preflight` checks the plan again; the wizard does so itself when the last check is older than 8 hours or found requirements not met.
- In ARCHIVELOG mode, back up and delete the archived logs between runs.
- While a plan is in progress, a purge with other options is refused; `--new` starts over (the steps already done stay done). `plan --close` closes the plan.

## Reclaim disk space

A purge frees space inside the tables, but the datafiles keep their size. The reclaim compacts the application's tablespaces in place and shrinks their datafiles:

1. It locks the application's accounts and disconnects their sessions. **The application is unavailable until the end of the run.**
2. It records the row counts and a fingerprint of the objects, releases the indexes of the tables that will move (they are rebuilt at the end), and stops the datafiles from growing.
3. Repeatedly, the table holding the highest block of a datafile moves into free space lower down, and the datafile is cut down to its new end.
4. It rebuilds the indexes, restores the datafiles' growth settings, resizes each datafile to its highest block plus 64 MB of free space, recompiles what became invalid, counts the rows again and unlocks the accounts.

The reclaim changes no row of the application, and no datafile grows above its size at the start (two rare exceptions are reported as warnings).

Assess first, then compact:

```bat
src\bin\epf_purge.bat reclaim --dry-run
src\bin\epf_purge.bat reclaim
```

The dry run is read-only. It lists the tablespaces, what moves and what stays, the forecast, the accounts that will be locked, and the requirements. With prompts, the reclaim shows the same assessment and asks before anything moves. Unattended: `reclaim --non-interactive --yes`.

Options:

- `--tablespaces DATA,INDX` limits the reclaim to those tablespaces. By default it takes every tablespace holding segments of the application's schemas.
- `--confirm RECYCLEBIN` lets it purge the recycle bin of those tablespaces first; without it, recycle-bin objects stop the reclaim before any change. `--confirm ARCHIVE` and `--confirm TEMP` work as for a purge.
- `--scratch SIZE`, such as `--scratch 3G`, allows a scratch tablespace. Oracle chooses where the copy of a moved table goes, and may put it back at the top of the file; a table may also not fit lower down. With scratch space, such a table waits in a scratch tablespace (created next to its tablespace's datafile) while the rest is compacted, then comes back into the space left free, and the scratch tablespace is dropped. Without it, the datafile stops shrinking at that table. The dry run shows where the scratch datafile would go and suggests a size.

The assessment checks these requirements: RECYCLEBIN, ARCHIVE, TEMP and QUOTA block the reclaim when not met (QUOTA cannot be confirmed: the owners need a space quota where their tables are written again); BACKUP and SCRATCH are advice.

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
| `undo.sql APPLY, RESTORE or STATUS` | SYS AS SYSDBA | Undo tuning by hand |

For example (SQL*Plus asks for the password):

```bat
sqlplus -L -S "epfpg@EPFPDB" @src/sql/run/report.sql LATEST
sqlplus -L "sys@EPFPDB AS SYSDBA" @src/sql/run/undo.sql RESTORE
```

## Command reference

`src\bin\epf_purge.bat --help` prints the complete reference.

| Action | What it does |
|---|---|
| (none) | The wizard |
| `preflight` | Read-only checks, estimates and the plan of the purge |
| `purge` | Preflight, purge and report; `--dry-run` simulates |
| `plan` | The open plan with its steps; `--close` closes it |
| `report` | The report of a run: `--run ID`, the latest by default |
| `status` | The state of the active or latest run, and anything left pending |
| `stop` | A graceful stop of the active run |
| `reclaim` | Gives the freed space back to the disk; `--dry-run` assesses, `--restore` restores what a reclaim left pending |
| `install` | Installs or upgrades the database objects (SYS) |
| `uninstall` | Removes them (SYS) |

General options: `--config FILE`, `--tns NAME`, `--yes` (required with `--non-interactive` for a purge that deletes, a reclaim and an uninstall), `--non-interactive`, `--log-dir DIR`, `--verbose`, `--no-color`, `--help`.

## Repository layout

```text
src\bin\epf_purge.bat    the tool (its code is in src\bin\lib\epf.ps1)
src\config\              the configuration example
src\sql\install\         installer, tables and packages of the EPFPG schema
src\sql\run\             the SQL*Plus scripts the tool runs
src\tests\               end-to-end tests, test labs and the parity check
docs\README.html         this guide as a web page
legacy\                  the previous tool, kept for reference
logs\                    run folders (not part of the repository)
```

## Testing

The end-to-end test suite runs every feature against a test database, and changes it: it purges every module, clears LOB values, compacts tables, enlarges the online redo logs to 4 x 1 GB (permanent) and changes undo_retention during the purges. Its reclaim tests work on tablespaces they create and remove. Run it only on a copy that can be discarded.

1. Copy `src\tests\e2e\test.conf.example` to `src\tests\e2e\test.conf`, and set TNS, EXPECTED_DB and DESTRUCTIVE_OK=YES.
2. Run `src\tests\e2e\run_tests.bat` for the whole suite (about 3 hours), or a part of it, such as `src\tests\e2e\run_tests.bat --only T18A,T18B`.
3. `src\tests\e2e\run_tests.bat --digest` writes a short summary of the last test session to `logs\digest.txt` and copies it to the clipboard.

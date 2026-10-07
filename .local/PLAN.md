# EPF Data Purge - Rebuild Plan

| | |
|---|---|
| Status | Decisions D1-D18 applied; D19-D20 round 1 built and tested (0.5.0: requirements, gate, simulation, forecast against result; end-to-end 21/21 on EPFPG781), choices asked by the preflight and followed by the purge (0.5.1, set C passed), dry-run accuracy measured (set B: rows exact, space +2 to +7%, redo and undo +12 to +69% on a first purge); per-row forecast and LOB space fix (0.5.2, set E passed: second purge redo and undo within +-12%); first-purge estimate calibrated, deleting time per row, batches limited by rows, emptied blocks counted as free (0.5.3, set G passed: first purge within +-25%, second within +-11%, space within +-6%); lighter measuring and no redo log warning when the logs are to be enlarged (0.5.4, set F passed after a test fix: a few measured batches forecast the whole purge within 4%); round 2 built (0.6.0: plan of smaller runs, plan lifecycle, menu; set H to run); reclaim built (0.7.0: compaction in place, D3 revised, checks R1-R9, lab tests; set R to run); phases 1-6 delivered (5 and 6 to verify on the database); parity with the previous tool met for FULL on 2026-10-02 (only difference D8). Change history: `.local/changes.md`. |
| Scope | Full rebuild of `bin/`, `sql/`, `config/`. Docs are out of scope for now (written after the tool is proven). The Linux `.sh` wrapper is regenerated in the final phase. |
| Baseline | Repository state at commit `3f532e7` (21 files, 10,353 lines). |
| Target DB | Assumed Oracle 19c Enterprise Edition (minimum 12.2). Edition-specific features (parallel DDL) are detected at runtime and disabled on SE2. |

Reading guide: sections 1-2 explain *why*, sections 3-11 are the *design*, 12-14 are *how we get there*, 15 lists the decisions I need from you.

---

## Table of contents

1. Goals and success criteria
2. Current-state assessment (findings)
3. Target architecture
4. Repository layout and SQL organization rules
5. Database objects (data model)
6. Purge engine design
7. Space reclaim engine design (deep dive)
8. Live logging and console output
9. Integrity and results report
10. CLI, configuration and interaction flow
11. Code, comment and formatting standards
12. Testing and validation strategy
13. Implementation phases
14. What is removed, and where everything goes
15. Design decisions (need your answers)
16. Risks and mitigations

---

## 1. Goals and success criteria

Every goal has a check the tool itself performs, so "did the run happen 100% as intended" is answered by the tool, not by reading logs.

| # | Goal | Measured by (automatic) |
|---|------|-------------------------|
| G1 | Purge is complete | Residual eligible rows = 0 for every in-scope table (FULL mode); residual non-empty LOBs = 0 (CLOB modes). |
| G2 | Purge is exact | Rows deleted per table = rows eligible at start (key snapshot). No row newer than the cutoff is deleted (retention-safety check). |
| G3 | No referential damage | Orphan count = 0 on every registry relationship that is not protected by an enabled, validated FK. |
| G4 | Reclaim never makes things worse | Per datafile: never above its size at the start plus `reclaim_growth_mb` (default 0) during the run, and at most its start size at the end (7.6). Checked by R6. |
| G5 | Reclaim reaches the achievable minimum | Per tablespace: final size <= segment bytes + `reclaim_margin_mb` per datafile + max(1 %, 256 MB), unless a segment that cannot move holds the top: it is named with its position and reason (R7). |
| G6 | Zero schema drift | After reclaim: same indexes (VALID/USABLE, same degree/logging), same constraints (status/validated), no new invalid objects, row counts unchanged, tablespace name unchanged, accounts back to their original status. The only permitted change is each LONG column you approved for conversion, reported individually. |
| G7 | Always recoverable | Any interruption (error, stop, kill, instance restart) leaves a state that the wrapper restores at once, or that the next `reclaim` (or `reclaim --restore`) restores before anything else. No separate recovery scripts. |
| G8 | Always visible | Live events within ~2 s; a heartbeat line at least every 15 s while a single statement runs (progress %, wait event, blocking session). |
| G9 | Machine-checkable output | Each run folder contains a human log, a report, and stable `EPF_CHECK|...` lines plus a `manifest.txt` that can be pasted back for review. |
| G10 | One place per fact | Table list, module membership and relationships exist once (registry). Numbers in reports come from structured columns, never parsed from message text. |

---

## 2. Current-state assessment (findings)

IDs are referenced from the design sections ("fixes R-01").

### 2.1 Purge correctness and integrity

| ID | Finding | Where |
|----|---------|-------|
| F-01 | Driving cursors are fetched across commits while `08_undo_tune.sql` lowers `undo_retention` to 60 s: classic ORA-01555 (snapshot too old) setup on long purges. The module then aborts and the run continues. | `03_epf_purge_pkg_body.sql` cursor at 1327 / commit 1706 (payments), 879 / 941 (audit), 1060 / 1131 (bank) |
| F-02 | Module failures are swallowed: each module logs ERROR in its own handler and returns; `run_purge` still writes `RUN_END` = SUCCESS. A partially failed purge reports success. | body `run_purge` end |
| F-03 | "Rows deleted" totals are double counted: per-batch rows and the per-table/module total are both logged as `DELETE`/`SUCCESS` with `rows_affected`, and both summaries sum them. | body 577 + 591, 702 + 716; payments batch rows + per-table totals; bat final summary |
| F-04 | CLOB modes: every PAYMENTS clear count accumulates into `l_tot_tx_aud`, then is reported as "transmission_execution_audit: N CLOBs cleared". | body 1591-1698 |
| F-05 | Bank statements: the driving query INNER JOINs `directory_dispatching`, so `file_dispatching` rows without children are never purged (see D8). The batch log row records only the last statement's count. | body 1060, 1125 |
| F-06 | Dry run counts only `bulk_payment` and `payment`; the other 20 PAYMENTS tables are "and dependents". | body dry-run branch of `purge_bulk_payments` |
| F-07 | `undo_retention` is "restored" to a hard-coded 900 s, not the original value; the UNDO autoextend cap (8G) is never restored. | bat 798; `utility/08_undo_tune.sql` |
| F-08 | The in-scope table list and module mapping are duplicated in 8+ places (package `get_purged_tables` (unused), `capture_space_snapshot`, `print_space_comparison`, `12_capture_module_sizes`, utilities 07/10/11/16, bat prompts with hard-coded "27 / 22 / 3 / 2 tables", `06b` index list). Utility 07 already drifted (lists tables not in scope, misses in-scope ones). | multiple |
| F-09 | Run identity is guessed ("latest RUN_END", "latest RUN_START") in the reclaim, shrink, monitor and summaries. Purge and reclaim can end up with different run_ids; the final summary regex-parses numbers back out of message text. | 05 ~545, 05a, monitor, bat `write_final_summary` |

### 2.2 Space reclaim (root causes of "stuck", "not fully rearranged", "HWM increased")

| ID | Finding | Effect | Where |
|----|---------|--------|-------|
| R-01 | HWM is computed tablespace-wide as `MAX(block_id + blocks)` but `block_id` is per datafile; drain/refill resizes only the first datafile (`ROWNUM = 1`). | Wrong targets and incomplete shrink on multi-file tablespaces. | 05: 181, 507 |
| R-02 | Only `segment_type = 'TABLE'` (and their LOBs) are moved. Partitioned tables, LOB partitions, IOTs and LONG tables stay put, and nothing reports them up front. | Anchors stay high: "doesn't rearrange fully". | 05: 141 |
| R-03 | `build_move_sql` sends every LOB column to the move target; on refill all LOBs land in the data tablespace even if they originally lived elsewhere. | Layout drift, unexpected growth of the data TS. | 05: 369 |
| R-04 | All PK/UK/FK constraints and indexes are dropped and recreated from captured DDL. DDL backup inserts swallow errors (drops proceed without a backup); the guard only catches "0 objects" so a partial earlier failure passes and the missing objects vanish from later backups; FKs owned by *other* schemas that reference OPPAYMENTS/OP are dropped too. | Integrity window, and a real risk of permanently lost constraints. | 05: 746, 836, 875 |
| R-05 | Indexes are recreated with `PARALLEL 4` + `FORCE PARALLEL DDL`. Each PX server allocates its own extents, leaving trimmed extents and holes. | Final HWM above used space. | 05: 72, 1420-1480 |
| R-06 | `AUTOEXTEND ON NEXT 1G MAXSIZE UNLIMITED` is forced on the data file and never restored. | Operator's size cap silently removed. | 05: 1028, 1207 |
| R-07 | `get_hwm_gb` (full `dba_extents` aggregation) runs several times per progress line inside the drain/refill loops. On large dictionaries each call can take minutes. | Looks "stuck". | 05: 1075-1329 |
| R-08 | No handling of concurrent activity: no check for connected application sessions, no `ddl_lock_timeout`, no visibility of blocking sessions. Library-cache waits can hang indefinitely. | "Stuck", no explanation. | 05 (absent) |
| R-09 | Two full data moves + index builds, all LOGGING. In ARCHIVELOG mode this can fill the recovery area and freeze the whole instance (`log file switch (archiving needed)`). No estimate is made. | Instance-wide hang. | 05 (absent) |
| R-10 | `EPF_SCRATCH` is created next to the data file with unlimited autoextend and no peak-disk forecast. Disk-full stops drain/refill half way. | Partial, inconsistent results. | 05: ~1000, 1100, 1290 |
| R-11 | `RECLAIM_END` is logged before step 14 (UNDO/TEMP), so the monitor exits while work continues. Step 14 may create a new UNDO tablespace, change `undo_tablespace` with `SCOPE=BOTH` and drop the old one. | Invisible tail; instance-level change outside the tool's purpose. | 05: 1610 vs 1641, 1706 |
| R-12 | Recycle-bin segments are not detected: they count as free in `dba_free_space` but block `RESIZE` (ORA-03297). | Resize fails "for no reason". | 05 (absent) |
| R-13 | Post-purge `SHRINK SPACE CASCADE` runs on *every* table in the tablespace after every live purge; BASICFILE LOB shrink can run for hours; errors are silently counted. | "Stuck" after purge. | 05a: 53-77 |
| R-14 | Resize fallback walks +1 GB up to 10 times, then gives up. | Space left unreclaimed when an anchor sits > 10 GB above target. | 05: ~300, ~425 |
| R-15 | Recovery lives in two separate scripts (14: 298 lines, 17: 811 lines) that re-implement reclaim logic and depend on the DDL backup being intact. | Divergent logic, fragile recovery. | utility/14, 17 |

### 2.3 Live logging and output

| ID | Finding | Where |
|----|---------|-------|
| L-01 | Separate monitor window polls every 10 s, spawning a new `sqlplus` per poll; run_id discovered by timestamp heuristics; the wrapper sleeps 15 s at several points so the monitor can catch up; final events can still be missed. | `epf_monitor.ps1`; bat 264, 872, 891 |
| L-02 | `DBMS_OUTPUT` is buffered until each PL/SQL call ends, so sqlplus output arrives in one flood at the end of an hour-long block. | all SQL |
| L-03 | Two processes append to one log file (FileShare workarounds); every `:log` call spawns `powershell.exe` (30+ per run). | bat `:log` |
| L-04 | Nothing is shown while a single long statement runs: no wait event, no blocker, no `v$session_longops` progress. | monitor |
| L-05 | Inconsistent formats: `[INFO]`, `** PURGE STARTED **`, `=== Phase 4c ===`, `>>> PHASE:`, `RECLAIM ...` | all |

### 2.4 Architecture and maintainability

| ID | Finding | Where |
|----|---------|-------|
| A-01 | 1,668-line batch file generating SQL through `echo` escaping, ~15 temp files in `%TEMP%`. The committed file also contains a spliced block (around lines 268-273): the reclaim-only branch ends mid-block and runs into the prompt section; `INTERACTIVE` is read (592) but never set; the prompt-section header and connection/retention prompts are missing. The committed file does not run as intended. | bat |
| A-02 | Numbered SQL files accumulate per feature (05, 05a, 06, 06b, 06c, 12, utility 07-17) with overlapping responsibilities (3 space reports, 2 recovery scripts, sizing logic in 3 places) and dead code (commented-out `reclaim_space`, accepted-but-ignored flags). | sql/ |
| A-03 | `ensure_log_table` duplicates install DDL inside the package; schema migrations are inline. | body 380-470 |
| A-04 | `wmic` (deprecated, removed from current Windows builds) generates the timestamp. | bat 28 |
| A-05 | Mixed encodings: README is UTF-16LE/CRLF; several SQL/PS1 files contain non-ASCII characters (em dashes) that render incorrectly in `cmd` / PowerShell 5.1. | README, 03, 05, 06, 06b, monitor |

### 2.5 Security

| ID | Finding | Where |
|----|---------|-------|
| S-01 | Schema and SYS passwords are passed as `sqlplus` command-line arguments (visible in process listings) and the monitor launcher writes the schema password in plain text to `%TEMP%\epf_monitor_launcher.bat`. | bat 1528 and every sqlplus call |
| S-02 | `SYS AS SYSDBA` is used for all DBA work at runtime, and SYS executes code owned by the application schema (`capture_space_snapshot`). | bat, 05 |

### 2.6 Performance

| ID | Finding | Where |
|----|---------|-------|
| P-01 | Deletes use `IN (SELECT COLUMN_VALUE FROM TABLE(:1))`; the optimizer assumes a default collection cardinality (8,168 rows) and can pick full scans / hash joins on large child tables. | body, all modules |
| P-02 | Single-table date purges repeat `DELETE ... WHERE date < :c AND ROWNUM <= :n`. Without an index on the date column every batch rescans from the start of the segment: quadratic on big log tables. `op.spec_trt_log.dtlog` is not in the temporary index list. | body 560, 685; 06b |
| P-03 | Supporting indexes for child deletes exist only when `--optimize-db` is chosen; otherwise child deletes full-scan once per batch. | bat, 06b |
| P-04 | One autonomous insert + commit per batch per module, plus per-table total rows. | body |

---

## 3. Target architecture

### 3.1 Principles

1. **The database is the engine, the shell is a thin client.** All purge, reclaim and report logic lives in PL/SQL packages. The wrapper collects input, starts steps, streams events and writes files. This keeps the later `.sh` port small and identical in behavior.
2. **One run, one run_id.** The wrapper creates the run first (`epf_control.start_run`) and passes the id explicitly to every step and to the monitor. Nothing is discovered by timestamp.
3. **The data dictionary is the source of truth for reclaim state.** The journal records intent; every step recomputes remaining work from the dictionary, so every step is idempotent and resumable.
4. **Integrity is never weakened.** Constraints are never dropped (D2).
5. **Structured facts.** Every number displayed or checked comes from a typed column (`rows_affected`, `bytes`, `pct`), never from message text.
6. **One place per fact.** Tables, modules, relationships, tunables live in registry/settings tables seeded by one install file.
7. **Tool objects never live in a tablespace being reclaimed** (removes the "relocate log tables" step and its anchor problems).
8. **Fail loud.** Any ERROR event makes the run FAILED (or WARNING for tolerated conditions) and produces a non-zero exit code.
9. **No silent instance changes.** Anything the tool changes outside the application schemas (file autoextend, parallel degree, logging) is recorded first and restored to the recorded value. The only permanent instance change is the opt-in redo log sizing (D17), which is asked for explicitly and reported. The opt-in undo tuning (D18) is recorded in `EPF_INSTANCE_CHANGE` and restored.

### 3.2 Components

```
 operator
    |
 bin/epf_purge.bat  -->  bin/lib/epf.ps1   (CLI, wizard, config, credentials, runner, live view, run folder)
                              |
            sqlplus sessions fed through stdin (no passwords in argv or files)
          +-------------------+----------------------+
          | worker            | monitor (every 2 s)  | report
          v                   v                      v
 +--------------------------- EPFPG schema (D1) ------------------------------+
 | packages : epf_util  epf_log  epf_control  epf_registry  epf_space                 |
 |            epf_purge  epf_reclaim  epf_report                                  |
 | tables   : EPF_SETTING EPF_MODULE EPF_TABLE EPF_LINK                           |
 |            EPF_RUN EPF_STEP EPF_EVENT EPF_WORK_KEY EPF_TABLE_STAT              |
 |            EPF_SEGMENT_SNAP EPF_FILE_SNAP EPF_OBJECT_BASELINE                  |
 |            EPF_RECLAIM_OBJECT EPF_TEMP_INDEX                                   |
 +--------------------------------------------------------------------------------+
          | DELETE / UPDATE (object grants)       | MOVE / REBUILD / RESIZE (SYS, invoker rights)
          v                                       v
   OPPAYMENTS, OP tables                 target tablespaces (in place), run as SYS
```

### 3.3 Run lifecycle

```
START (epf_control.start_run -> run_id)
  INPUT             every question, confirmation and password up front (10.3)
  PREFLIGHT         read-only checks, inventories, forecasts, blockers  (always)
  PURGE             SNAPSHOT_KEYS -> PROCESS_BATCHES -> TABLE_STATS -> SPACE_USAGE [-> COMPACT]
  RECLAIM           PREPARE -> ASSESS -> LOCK_ACCOUNTS -> BASELINE -> RELEASE_INDEXES -> FREEZE_FILES
                    -> COMPACT (per tablespace) -> REBUILD_INDEXES -> RESTORE_FILES -> RESIZE
                    -> RECOMPILE -> VERIFY -> UNLOCK_ACCOUNTS                 (7.5)
  REPORT            integrity + results + verdict                         (always)
END (status, verdict, exit code)
```

Each named step is a row in `EPF_STEP` (status PENDING/RUNNING/DONE/FAILED/SKIPPED) and emits `STEP_START` / `STEP_END` events. The console shows the step list as a checklist. No step ever asks for input.

### 3.4 Privileges and credentials

| Account | Used for | Rights |
|---------|----------|--------|
| `EPFPG` (tool schema, created by `install.sql` as SYS) | purge, report, preflight, event logging | `CREATE SESSION/TABLE/PROCEDURE`, quota on its own tablespace `EPFPG_DATA` (created by the installer, never a reclaim target); `SELECT, DELETE, INDEX` on every registry table and `UPDATE` on tables with `lob_clear = Y` (generated from the registry; `INDEX` lets EPFPG create the temporary purge indexes in its own schema, so no `CREATE/DROP ANY INDEX`); `SELECT` on tables outside the registry that have an FK into it (hold-back check, D16); `EXECUTE` on `DBMS_SPACE`; direct `SELECT` on the dictionary views the preflight and report read (`DBA_SEGMENTS`, `DBA_DATA_FILES`, `DBA_FREE_SPACE`, `DBA_TABLES`, `DBA_INDEXES`, `DBA_CONSTRAINTS`, `DBA_LOBS`, `DBA_TAB_COLUMNS`, `DBA_DEPENDENCIES`, `DBA_USERS`, `V_$SESSION`, `V_$SESSION_LONGOPS`, `V_$TRANSACTION`, `V_$DATABASE`, ...); `ANALYZE ANY` (for `DBMS_SPACE.SPACE_USAGE`); `ALTER ANY TABLE` only if compaction (6.7) is used |
| `SYS` (asked at startup only when reclaim is selected) | reclaim | runs `EPFPG.epf_reclaim`, an invoker-rights package, so all DDL executes with SYS rights; the installer grants `INHERIT PRIVILEGES ON USER SYS TO EPFPG` for this. Logging still goes through `EPFPG.epf_log` (definer rights). |

Purge never needs SYS. Passwords are handled as in 10.2. In a multitenant database both accounts connect to the **PDB service**; a connection to `CDB$ROOT` is refused with a message.

---

## 4. Repository layout and SQL organization rules

### 4.1 Layout

The new implementation lives in `src/`; the previous implementation is kept unchanged in `legacy/` for comparison and is not used by the new tool.

```
src/bin/
  epf_purge.bat              launcher only (~20 lines): finds PowerShell, forwards arguments, returns exit code
  epf_purge.sh               final phase: bash equivalent of launcher + wrapper
  lib/
    epf.ps1                  wrapper implementation (CLI, config, wizard, credentials, runner, live view, files)
src/config/
  epf_purge.conf.example     all keys documented; real epf_purge.conf is git-ignored
src/sql/
  install/
    install.sql              master installer (SYS): tool schema, grants, then every file below in order
    uninstall.sql            removes the tool schema (refuses if a reclaim is incomplete)
    tables.sql               every EPF_* table; idempotent create + column-level upgrades
    registry_data.sql        MERGE of modules, tables, links, settings - the only place table lists exist
    grants.sql               object grants generated from the registry
    epf_util.pks / .pkb      formatting, elapsed time, dictionary helpers
    epf_log.pks / .pkb       events, steps, heartbeat (module/action/client_info)
    epf_control.pks / .pkb   run lifecycle, run lock, stop requests
    epf_registry.pks / .pkb  registry access and validation against the FK graph
    epf_space.pks / .pkb     segment/file snapshots, per-file HWM, resize helper
    epf_purge.pks / .pkb     purge engine
    epf_tuning.pks / .pkb    opt-in instance tuning for purges: redo log sizing, undo (invoker rights, run as SYS)
    epf_reclaim.pks / .pkb   reclaim engine
    epf_report.pks / .pkb    integrity and results report
  run/                       one entry script per action; the wrapper calls only these
    start_run.sql  preflight.sql  purge.sql  reclaim.sql  report.sql  status.sql  stop.sql  advice.sql
    begin_run.sql  attach.sql  poll.sql  finish.sql
                             monitor-session scripts (no EXIT; the wrapper's persistent session, 8.1)
    redo_logs.sql            opt-in redo log sizing (SYS)
    undo.sql                 opt-in undo tuning for a purge: APPLY / RESTORE / STATUS (SYS)
  tools/                     read-only diagnostics (no DML, no DDL)
    segment_map.sql          physical layout / HWM anchors per datafile
    fk_coverage.sql          FK graph vs registry (coverage gaps)
    run_history.sql          last N runs with status and verdict
src/tests/
  e2e/                       end-to-end test suite (run_tests.bat / run_tests.ps1, test.conf.example; 12.5)
  verify/                    read-only verification queries for the target database
  fixtures/                  synthetic scope schema + data generator for a test database
  scenarios/                 reclaim layouts and fault-injection scripts (section 12)
logs/                        git-ignored; one folder per run
legacy/                      previous implementation (bin/, sql/, config/), unchanged
.local/
  PLAN.md                    this plan
  changes.md                 change history of the plan and of each phase
.gitattributes               CRLF for .bat/.ps1, LF for .sh/.sql/.md
.gitignore                   logs/, src/config/epf_purge.conf
```

### 4.2 Rules that keep SQL organized permanently

1. **New behavior goes into an existing package**, exposed through an option of an existing `run/` script. A new SQL file is justified only by a new package (new responsibility) or a new read-only diagnostic in `tools/`.
2. **In-scope tables and relationships are data**, edited in `registry_data.sql` only. Adding a table never requires code changes.
3. **No numeric file prefixes.** Install order is defined in exactly one place: `install.sql`.
4. **`run/` scripts contain no logic**: sqlplus settings, argument binding, one package call, exit status.
5. **`tools/` scripts are read-only.**
6. **Every install file is idempotent**: re-running `install.sql` upgrades in place.
7. **No SQL is generated by the wrapper** (the only inline statement is the connection test).
8. **Naming**: packages `epf_<area>`, tables `EPF_<NOUN>`, event/step codes `UPPER_SNAKE`, files `lower_snake`.

---

## 5. Database objects (data model)

All tables live in the tool schema, in tablespace `EPFPG_DATA`, which is never reclaimed. `install.sql` creates it when missing, with one datafile (128 MB, autoextend 128 MB, maxsize unlimited) in the directory of the first datafile of the tablespace holding most of the OPPAYMENTS segments, whatever that tablespace is named (fallbacks: OP, OPREPORTS, their default tablespaces, the database default tablespace, SYSTEM). On ASM the file goes to the same disk group. An existing file is never reused: a name already on disk is skipped (`epfpg_data01.dbf`, `02`, ...). `uninstall.sql` drops the tablespace and its datafiles once nothing else references it.

| Table | Purpose | Key columns |
|-------|---------|-------------|
| `EPF_SETTING` | Tunables with defaults (batch size, progress interval, LOB throttle, ddl_lock_timeout, resize margin, parallel threshold, history retention days, scope schemas) | `name`, `value`, `description` |
| `EPF_MODULE` | PAYMENTS, LOGS, BANK_STATEMENTS | `module_code`, `display_order`, `description` |
| `EPF_TABLE` | Every in-scope table | `table_id`, `module_code`, `owner`, `table_name`, `role` (ROOT/DEPENDENT), `key_column`, `date_column` (roots), `delete_order`, `lob_clear` Y/N, `active` Y/N |
| `EPF_LINK` | How a dependent table's keys derive from another table's keys | `link_id`, `table_id`, `match_column`, `source_table_id`, `source_column` |
| `EPF_RUN` | One row per run | `run_id`, `action`, `status`, `verdict`, `retention_days`, `cutoff_date`, `depth`, `mode`, `batch_size`, `dry_run`, `with_reclaim`, `started_at`, `ended_at`, `stop_requested`, `db_name`, `host`, `os_user`, `exit_code` |
| `EPF_STEP` | Step checklist / state | `run_id`, `step_seq`, `phase`, `step_code`, `status`, `started_at`, `ended_at`, `units_done`, `units_total`, `bytes_done`, `bytes_total` |
| `EPF_EVENT` | Event stream (replaces `epf_purge_log`) | `event_id` (identity), `run_id`, `ts`, `phase`, `step_code`, `severity` (INFO/OK/WARN/ERROR/PROGRESS), `event_code`, `object_owner`, `object_name`, `rows_affected`, `bytes`, `pct`, `elapsed_s`, `ora_code`, `message` |
| `EPF_WORK_KEY` | Key snapshot of the running purge: global temporary table (ON COMMIT PRESERVE ROWS) private to the purging session; no redo, its undo in the temporary tablespace (`temp_undo_enabled`); truncated at purge start and end. Needs temporary tablespace for the keys (about 1 GB for 5.5 M keys with their indexes) | `run_id`, `table_id`, `batch_no`, `key_num`, `key_rowid`, `root_key`, `group_key`; indexes (`run_id`, `table_id`, `batch_no`), (`run_id`, `table_id`, `root_key`), (`run_id`, `table_id`, `key_num`) |
| `EPF_HELD_ROOT` | Roots held back (D16) with the first reference found | `run_id`, `table_id`, `root_key`, `child_owner`, `child_table`, `constraint_name`, `parent_owner`, `parent_table`, `iteration` |
| `EPF_TABLE_STAT` | Per-table counts per phase | `run_id`, `table_id`, `phase`, `total_rows`, `eligible_rows`, `retained_rows`, `nonempty_lob_rows`, `processed_rows`, `orphan_rows`, `held_rows` |
| `EPF_SEGMENT_SNAP` | Segment sizes per phase (BASELINE, POST_PURGE, POST_RECLAIM) | `run_id`, `phase`, `owner`, `segment_name`, `partition_name`, `segment_type`, `parent_owner`, `parent_table`, `tablespace_name`, `bytes`, `module_code` |
| `EPF_FILE_SNAP` | Datafile geometry per phase | `run_id`, `phase`, `tablespace_name`, `file_id`, `file_name`, `bytes`, `hwm_bytes`, `free_bytes`, `autoextensible`, `increment_by`, `maxbytes` |
| `EPF_OBJECT_BASELINE` | Reclaim fingerprint once the accounts are locked, and again before they are unlocked (indexes, constraints, tables, LOB columns, invalid objects, row counts) | `run_id`, `object_type`, `owner`, `name`, `table_owner`, `table_name`, `tablespace_name`, `status`, `validated`, `degree`, `logging`, `row_count`, `row_count_after`, `detail`, `detail_after` |
| `EPF_RECLAIM_OBJECT` | Reclaim journal per item: tables that move (TABLE, IOT), indexes released and rebuilt (INDEX), segments that stay (PIN) | `run_id`, `item_id`, `owner`, `object_name`, `sub_name`, `unit_type`, `source_ts`, `table_owner`, `table_name`, `bytes`, `est_bytes`, `after_bytes`, `move_status`, `attempts`, `last_ora`, `orig_status`, `detail`, timestamps |
| `EPF_RECLAIM_TS` | Per reclaim run and tablespace: assessment, forecast and result | `run_id`, `tablespace_name`, `status`, `start_bytes`, `segment_bytes`, unit, index and pin counts and bytes, `est_final_bytes`, `growth_bytes`, `peak_bytes`, `end_bytes`, `moved_count`, `detail` |
| `EPF_TEMP_INDEX` | Temporary supporting indexes created by a run | `run_id`, `owner` (EPFPG), `index_name`, `table_owner`, `table_name`, `column_name`, `created_at`, `dropped_at` |
| `EPF_SPACE_USAGE` | Space used inside segments (from `DBMS_SPACE`) per phase | `run_id`, `phase`, `owner`, `segment_name`, `partition_name`, `segment_type`, `allocated_bytes`, `used_bytes`, `free_bytes`, `method` |
| `EPF_TS_INVENTORY` | The segments of the target tablespaces, per segment and datafile | `run_id`, `tablespace_name`, `kind` (SEGMENT, RECYCLEBIN), `owner`, `object_name`, `sub_name`, `segment_type`, `bytes`, `file_id`, `top_block`, `handler` (MOVE, RELEASE, PIN), `item_id`, `est_bytes`, `blocker_reason` |
| `EPF_LONG_CONVERSION` | LONG / LONG RAW columns found, the decision taken, and the result | `run_id`, `owner`, `table_name`, `column_name`, `original_type`, `new_type`, `decision` (CONVERT/SKIP), `row_count`, `bytes`, `dependents`, `status`, `converted_at`, `ora_code` |
| `EPF_ACCOUNT_ACTION` | Accounts locked and sessions disconnected for the reclaim window | `run_id`, `username`, `original_status`, `locked_at`, `unlocked_at`, `sessions_disconnected`, `detail` |

History older than `history_retention_days` (default 180) is pruned at run start.

Registry content (seeded by `registry_data.sql`) reproduces today's scope exactly: 27 tables, 3 modules, and these links (dependent.column <- source.column):

| Module | Root (date) | Dependents |
|--------|-------------|------------|
| PAYMENTS | `bulk_payment.value_date` | `bulk_payment_additional_info`, `bulk_signature`, `mandatory_signers`, `oidc_request_token`, `payment_audit`, `transmission_execution_audit`, `notification_execution`, `import_audit`, `transmission_execution`, `transmission_exception`, `workflow_execution_opt`, `payment` <- `bulk_payment.bulk_payment_id`; `import_audit_messages.import_audit_id` <- `import_audit`; `approbation_execution_opt.execution_id` <- `workflow_execution_opt`; `workflow_execution`, `payment_audit`, `bulkpayment_exception`, `invoice`, `payment_additional_info` <- `payment.payment_id`; `approbation_execution.execution_id` <- `workflow_execution`; `invoice_additional_info.invoice_id` <- `invoice` |
| PAYMENTS | `file_integration.integration_date` | none |
| LOGS | `audit_trail.audit_timestamp` | `audit_archive.audit_archive_id` <- `audit_trail.audit_archive_id` |
| LOGS | `op.spec_trt_log.dtlog` | none |
| BANK_STATEMENTS | `file_dispatching.date_reception` | `directory_dispatching.file_dispatching_id` <- `file_dispatching` (every eligible `file_dispatching` row is purged, with or without children - D8) |

`delete_order` reproduces today's order (leaves first, roots last). At preflight `epf_registry.validate` checks it against the live FK graph of **all schemas**: an FK that the order would violate is a FAIL; an FK from an unregistered table (including client-added schemas) into a registered one is a FAIL if it is `ON DELETE CASCADE` or `SET NULL` (the purge would silently change client data) and a WARN otherwise (the purge would fail on it). This replaces utility 16.

---

## 6. Purge engine design

Fixes F-01..F-06, F-08, P-01..P-04.

### 6.1 Flow per module

1. **Key snapshot.** Root keys older than the cutoff are inserted once into `EPF_WORK_KEY`; the keys of every link source below the root (payment, import_audit, workflow executions, invoice) are derived once, each tagged with the root it belongs to (`root_key`). For deleting modules, roots are then held back (D16, 6.1.1) and roots whose trees reference each other share a group. Roots are numbered into batches in key order: at most `batch_size` roots and about `batch_rows_max` rows per batch. A root's rows are estimated from its derived keys and the rows per key from statistics. The roots of a group share a batch. A derived key belongs to the batch of its root. Roots without key column (no dependents: `file_integration`, `spec_trt_log`) snapshot `ROWID`s in physical order instead, and each delete re-checks the cutoff. Consequences:
   - no cursor is held across commits: ORA-01555 cannot happen (F-01);
   - the total number of batches is known: progress % and ETA;
   - deletes join a real, indexed table with correct statistics instead of a collection (P-01);
   - ROWID-ordered deletes on single tables touch each block once, independent of date indexes (P-02).
2. **Eligible counts.** From the key snapshot, the engine counts eligible rows for every dependent table (following `EPF_LINK`) plus rows retained (newer than cutoff / linked to retained roots) and stores them in `EPF_TABLE_STAT` (phase BEFORE). A dry run stops here and reports exact per-table counts for all 27 tables (F-06).
3. **Batch processing.** For each batch, in one transaction:
   - intermediate key sets needed by deeper links (payment ids, import_audit ids, workflow execution ids, invoice ids, audit_archive ids) are materialized into `EPF_WORK_KEY` for that batch;
   - tables are processed in `delete_order` (leaves first, root last);
   - per-table counters are accumulated in memory; commit; `EPF_STEP` progress updated.
4. **Totals.** Per-table processed counts are written once to `EPF_TABLE_STAT` (no double counting, F-03); per-module completion event.
5. **After-counts.** Residual eligible rows, retained rows and orphans are recounted (phase AFTER) for the report.

#### 6.1.1 Held back (D16)

A row that is kept must never lose a row it references, and nothing newer than the cutoff is deleted by a cascade.

- **FK references.** For every enabled FK into a registry table of a deleting tree (from any schema), rows that are kept (not eligible, or in a table outside the registry) referencing an eligible row cause the root(s) of that row to be held back with their whole tree (`EPF_HELD_ROOT`, WARN `ROOTS_HELD`). Repeated until no reference remains (a held root makes more rows "kept"). FKs whose child is derived from the parent through the same column (the normal tree FKs) cannot conflict and are skipped. On this database the checked FKs are `NOTIFICATION_EXECUTION -> IMPORT_AUDIT` (ON DELETE CASCADE), `NOTIFICATION_EXECUTION -> TRANSMISSION_EXECUTION`, `TRANSMISSION_EXECUTION -> TRANSMISSION_EXCEPTION`, `TRANSMISSION_EXECUTION_AUDIT -> TRANSMISSION_EXECUTION`.
- **Reverse links** (the source row points at the dependent: `audit_trail.audit_archive_id -> audit_archive`). A dependent row still pointed at by a kept source row is kept (held row, `held_rows`, WARN `ROWS_HELD`); the old source row is still deleted. Applies to CLOB modes as well.
- **Eligible rows referencing across roots** (both eligible, different roots): their roots share a batch, so the child is always deleted before or with its parent.
- Held roots are purged by a later run once the rows that reference them are eligible too.

### 6.2 Modes

| Mode | PAYMENTS / BANK_STATEMENTS | LOGS module |
|------|----------------------------|-------------|
| FULL | delete | delete |
| CLOB | set LOB columns to `EMPTY_CLOB()` / `EMPTY_BLOB()` where length > 0 (tables with `lob_clear = Y`, LOB columns discovered from the dictionary) | same as left |
| LOGS | not touched | delete |
| CLOB_N_LOGS | as CLOB | delete |

`--depth` selects modules; the mode says what happens to each selected module. LOGS mode processes only the LOGS module whatever the depth (the wizard does not ask for depth in LOGS mode). Counters are per table and per action, so reporting is exact (F-04). The LOB throttle (`lob_throttle_ms`, default 500) between LOB batches is kept as a setting (workaround for the dw00 space-management crash on unpatched 19c).

### 6.3 Errors, stop and re-run

- A failing batch is rolled back, an ERROR event records the ORA code and the batch number, and that module stops (order within a module matters). Independent modules continue. The run ends FAILED (F-02).
- `epf_purge.bat stop` sets `stop_requested`; the engine stops after the current batch; run status STOPPED; the report shows the expected residuals.
- Re-running a purge is idempotent (a new key snapshot of what is still eligible).

### 6.4 Supporting indexes (D5)

- Preflight lists missing indexes on every link `match_column` (and on the source column of a reverse link) (P-03). For each module, the purge creates the missing ones on tables of at least `temp_index_min_mb` (default 64 MB) as `EPF_TMP_<run>_<n>`, **owned by EPFPG in `EPFPG_DATA`** (never in a reclaim target), `ONLINE` on EE, tracked in `EPF_TEMP_INDEX`, and drops them when the module ends; any left over from an interrupted run are dropped at the next purge start. A failed creation is a WARN; the purge continues without the index.
- **FK child columns** of every enabled FK into a table the module deletes from are indexed whatever the table size: for each deleted parent row Oracle looks up child rows, and without an index on the FK columns it scans the whole child table once per parent row (1,000 scans of a 46 MB table per batch for `bulk_payment_additional_info` on EPFPG781). A child table outside the registry cannot be indexed by the tool: preflight and purge report it (WARN).
- Root date columns are not indexed: the snapshot reads them once, so building an index would cost more than it saves.
- No other database-level change is made: no statistics gathering, no redo log changes, no `undo_retention` change, no UNDO/TEMP resizing. Everything kept works inside a PDB.

### 6.5 Session instrumentation

Every worker session sets `DBMS_APPLICATION_INFO` (module `EPF`, action = current step, client_info `run=<id>`) and `DBMS_SESSION.SET_IDENTIFIER('EPF:<id>')`. The monitor uses this to find the worker in `V$SESSION` (section 8.3).

Progress events are time-throttled: first batch, last batch, and at most one per `progress_interval_s` (default 5 s) per module (P-04).

### 6.6 Measuring the effect of a purge (D7)

A DELETE frees space inside blocks; segment and tablespace sizes do not change, which is why a purge-only report used to show nothing. Before and after the purge the engine records, for every registry table and its indexes and LOB segments, the space actually used inside the segment with `DBMS_SPACE.SPACE_USAGE` (reads only the space-management bitmaps, not the data) into `EPF_SPACE_USAGE`. Where a segment type is not supported by `SPACE_USAGE` (e.g. manual segment space management), the report falls back to `rows x avg_row_len` and labels the figure as estimated. BASICFILE LOB segments keep the chunks of deleted or cleared values as used blocks for `SPACE_USAGE` (they are reused by new values of the same column after the LOB retention; on EPFPG782 the 12 GB of LOB segments of the emptied bank statement tables still read as used): after a purge their use is the BASELINE measurement times the share of the LOB data the purge left (deleting: rows not deleted; clearing: 1 - values cleared / non-empty values of the eligible rows x eligible rows / rows) (method `BASICFILE_EST`; the measured value when lower, e.g. after a shrink), named in P7 and noted under the space section. The report then shows, per table and module: allocated (unchanged), used before -> after, and "freed inside segments, reusable now".

### 6.7 Optional compaction (D7, opt-in)

Step `COMPACT` of a purge run with `with_compact = Y`; `start_run` accepts it only for a PURGE that is not a dry run and does not reclaim (`purge.sql` 7th argument, `--compact`, wizard question default No). It returns the freed space to the tablespace (tablespace usage drops, datafile size does not):

- only registry tables of the run's deleting modules whose free space inside the segment at `POST_PURGE` is at least `compact_min_free_pct` (default 20 %) of the segment, in ASSM tablespaces, are processed, largest benefit first;
- pre-checks skip a table with the reason (`COMPACT_SKIPPED`): index-organized, clustered, compressed, function-based, domain or join indexes, LONG columns;
- per table: record `row_movement`, `ENABLE ROW MOVEMENT`, `SHRINK SPACE COMPACT` (online), `SHRINK SPACE CASCADE` (short lock, bounded by `ddl_lock_timeout`; dependent indexes and LOB segments too), falling back to the table alone when CASCADE is refused, then restore the recorded `row_movement` value (`ROW_MOVEMENT_KEPT` when it cannot be restored). `COMPACTED` records the bytes returned; a failure is `COMPACT_FAILED` (WARN) and the next table follows;
- honors stop requests between tables; space usage is measured again afterwards (`SPACE_POST_COMPACT`, phase `POST_COMPACT`); check P8 reports the result.

### 6.8 Redo (D17)

A DELETE writes about twice the row length plus overhead for the row and for every index entry (about 1 KB per row on EPFPG781, close to 1 GB per batch of 1,000 bulk payments). Redo cannot be switched off for DML; what matters is that the online redo logs can absorb it.

- **Measured:** each root tree records the redo it wrote (`TREE_REDO`: roots processed, bytes); progress events show redo per batch, `MODULE_END` the module total.
- **Preflight (`REDO_LOGS`):** online log groups and sizes, log mode, switches in the last 24 hours; per deleting tree the redo per root (latest measurement on this database by a purge that did the same, deleting or clearing, otherwise estimated from optimizer statistics: rows per root x (2 x avg_row_len + 300 + per index 2 x key length + 270)), the redo of one batch at the run's batch size (fewer roots when fewer are eligible), and a recommended batch size that keeps one batch within half of the smallest online log. A batch larger than a whole log is a WARN: the session will wait on `log file switch (checkpoint incomplete)`; larger logs remove the waits, a smaller batch only spreads them. Trees without eligible roots are not estimated.
- **Opt-in sizing:** `epf_tuning.enlarge_redo(size_mb, groups)` as SYS (`run/redo_logs.sql`, default 4 x 1024 MB): adds the new groups (same directories and multiplexing, or Oracle-managed), switches and checkpoints until the smaller groups are inactive (archived in ARCHIVELOG mode), drops them and deletes their files. Non-CDB single instance only; in a CDB the logs belong to CDB$ROOT and the DBA sizes them.
- **Wizard (phase 4):** shows the `REDO_LOGS` findings, offers the recommended batch size as the default, and offers the redo log sizing (SYS password required) when a batch exceeds a whole log.

### 6.9 Undo (D18)

A DELETE writes undo (about half of its redo, 400-450 MB per batch of 1,000 bulk payments on EPFPG781). One batch fits easily; the problem is retention: after each commit Oracle keeps the undo for `undo_retention` (900 s by default) and, with an autoextensible undo datafile, grows the file to do so rather than reuse it (about rate x retention, 12-14 GB at the target pace). The file does not shrink afterwards.

- **Measured:** each root tree records its undo and elapsed time (`TREE_UNDO`); progress events show undo per batch, `MODULE_END` the module total.
- **Preflight (`UNDO`):** undo tablespace size and growth limit, `undo_retention` and the tuned retention of the last 24 hours, retention guarantee, active undo tuning; per deleting tree the undo per root (measured, otherwise 45% of the redo estimate), the undo of a batch and of all eligible roots, and the undo kept by retention: at the measured rate, at most the undo of all eligible roots; without a measured rate (first purge of the tree on the database) up to the undo of all eligible roots, reported as "may grow". Trees without eligible roots are not estimated. WARN when a batch needs more than half of what the undo tablespace can hold, or when the kept undo exceeds its current size and undo tuning is not applied.
- **Opt-in tuning (`run/undo.sql APPLY [run_id [preflight_run_id]]|RESTORE|STATUS`, SYS):** APPLY records, then sets `undo_retention` to `undo_retention_s` (60, SCOPE=MEMORY, so a restart also restores it) and limits the growth (MAXSIZE) of the autoextensible undo datafiles to `epf_tuning.undo_cap`: the largest of the undo tablespace's current size, `undo_cap_mb` (4096) and 4 x the undo of one batch (batch size of the run x the largest undo per root of its preflight). The room under the cap is shared between the files; no file is resized or limited below its current size. Why both: with autoextensible undo datafiles Oracle keeps undo for the longest running statement, and a purge is one long call, so a lower `undo_retention` alone did not stop the growth (EPFPG783, 0.4.2: UNDOTBS1 450 MB -> 27.6 GB during a PAYMENTS purge); with a growth limit Oracle reuses committed undo instead (EPFPG782, 0.2.2 with an 8 GB limit: the file stayed at 8 GB). Only the running batch needs undo that cannot be reused (120-250 MB per batch at the recommended batch sizes), so the limit holds on larger databases too; a batch that still hits it fails with ORA-30036, rolls back alone, and the run ends FAILED with nothing half-deleted. The run records the plan (`EPF_RUN.with_undo_tuning`, `begin_run.sql` 9th argument), so its preflight reports the limit (`UNDO_CAP`) instead of a growth warning. Refused with RETENTION GUARANTEE. RESTORE puts back every recorded original value. `EPF_INSTANCE_CHANGE` keeps the records outside history pruning; uninstall refuses while a change is active. A purge reports at start and end whether undo tuning is active.
- **Wizard (phase 4):** offered when the preflight expects the undo tablespace to grow (SYS password; `--undo-tuning` or `UNDO_TUNING=Y` without the wizard); applied after the preflight, just before the purge worker starts, and restored in a `finally` block on every exit path of the wrapper. When tuning from an earlier run is still active, the wizard offers to keep it for this purge and restore it at the end; `status` lists active tuning.

### 6.10 Requirements, purge plan and simulation (D19, D20)

The preflight decides whether a purge can run to the end on this database and prepares how it runs; the purge follows what the preflight prepared. The user runs the preflight again after every action until it reports READY.

- **Requirements.** Each is shown with a one-line reason, its measured status and the ways to meet it.

  | Requirement | Why | Met by |
  |---|---|---|
  | ARCHIVE (ARCHIVELOG only) | Every deleted row is written to redo. Archived logs stay until backed up, and a full archive destination stops the database (ORA-00257). | NOARCHIVELOG (detected; the tool never changes the log mode); room in the archive destination of at least the redo estimate + 20% (recovery area: limit - used + reclaimable; ASM: disk group free; a directory: not measurable, the DBA frees space and confirms); smaller runs (the plan) |
  | UNDO | A batch's undo must fit until its commit; without undo tuning the undo tablespace grows. | Undo tuning (D18); the undo tablespace holds 4 batches and the undo kept for undo_retention without growing; smaller batch; the DBA accepts the growth (`--confirm UNDO`) |
  | TEMP | The work keys (temporary table) need room in TEMP. | Room in TEMP; the DBA confirms (`--confirm TEMP`) |
  | INDEX_SPACE | Temporary indexes on unindexed link columns need room in the table's tablespace. | Room (free + autoextend); indexes already present |
  | REDO_LOGS | Small online logs slow the purge (not a failure). | Logs of at least 1 GB; redo log sizing at purge start (D17); smaller batch |
  | BACKUP | A purge cannot be undone. | RMAN full backup newer than 24 h (`v$rman_backup_job_details`); backup made another way (confirmed); purge without a backup (confirmed) |

- **Choices.** For a requirement that is not met, the wizard offers the options the tool can apply and records the choice:
  - smaller runs: the plan below;
  - smaller batch: the batch size the purge then uses;
  - redo log sizing and undo tuning: applied by the purge;
  - the backup choice.

  Options outside the tool (free space, take a backup) are listed with what to do, and the preflight is run again after them.
- **Plan (smaller runs).** The preflight estimates the redo for any cutoff from the root dates (redo per root x roots before the date, per module). It proposes the fewest runs that each fit the archive room: older data first (a higher retention purges less), and modules that fit together share a run. The last run uses the requested retention. Each step shows rows, redo, archive space needed and space freed; the user accepts the plan or sets the steps. Between steps the DBA backs up and deletes the archived logs.
- **Stored in the database.** Requirements, choices and plan belong to the preflight run, with who confirmed what. The run folder gets `requirements.txt` and `plan.txt`. Each preflight shows what changed since the previous one for the same scope.
- **Purge.** `purge` without scope options takes the latest preflight for this database not older than `preflight_valid_h` (8). It runs the next step of the plan with its choices: depth, retention, batch size, redo log sizing and undo tuning.
  - At start it measures ARCHIVE, UNDO, TEMP and INDEX_SPACE again. If one is not met it refuses (non-interactive) or asks to type yes (wizard).
  - Options that differ from the plan: the wizard asks to continue the plan, start over with those options, or cancel. Non-interactive runs stop with exit 4 ("a plan is in progress; add --new to start over").
  - A plan older than `preflight_valid_h` is not refused: the purge re-checks the requirements with the saved choices, shows the result and asks to continue.
  - The report ends with the next step and what to do before it.
- **Plan lifecycle.** One plan per database at a time; the latest preflight decides.
  - States: READY (no step run), IN PROGRESS (step n of m done; a stopped or failed step is offered again and continues with what is left), DONE, CLOSED (started over or closed).
  - Starting over closes the plan. Completed steps stay done (purged rows cannot come back), and the new preflight measures what is left; choices and confirmations are asked again.
  - Checking again (`preflight` while a plan is open) offers the saved choices as one question: use them? [Y/n].
  - The wizard's main menu shows the plan (who, when, steps done, next step) and offers: continue the plan, check again, rehearse (dry run), start over. Without a plan it offers the preflight first.
  - Commands: `purge` (continue), `preflight` (check again, or start a plan), `preflight --new` (start over), `plan` (show), `plan --close`.
- **Dry run = simulation (D20).** The full rehearsal of the plan without changing anything:
  - exact rows per table and module (key snapshot), rows held back, references that would block, enabled triggers on the tables, current sessions of the application;
  - batches, redo, undo, time (measured rates, otherwise estimated), space freed, and the requirements;
  - a predicted outcome: WOULD COMPLETE (time, space) or WOULD FAIL (where and why, for example the batch at which the archive space runs out);
  - a retention table: rows, redo, archive space needed and space freed for the requested retention and longer ones, and the smallest retention that fits the archive room now.

  A dry run counts as a preflight for the purge.

- **Built in round 1 (0.5.0).**
  - The requirements, with the confirmations `--backup` and `--confirm`.
  - The gate: a purge that deletes refuses to start while a blocking requirement of its own preflight is not met.
  - The wizard's questions.
  - Root counts reused from the wizard's preflight.
  - The simulation, with the retention table and the expected outcome.
  - FORECAST AND RESULT in every purge report.
  - `--cutoff`.
- **Built in 0.5.1.**
  - The preflight asks for the choices, saves them with its run and checks again.
  - A purge or dry run of the same scope follows the latest READY preflight for `preflight_valid_h`; the wizard asks once.
- **Built in 0.5.2.**
  - The dry run forecasts redo and undo per row.
  - BASICFILE LOB space carried over between purges.
- **Built in 0.5.3.**
  - The statistics estimate is calibrated on measured purges.
  - Deleting time is forecast from rows per second.
  - Batches are limited by rows as well as by roots (`batch_rows_max`).
  - Redo and undo are measured per table.
  - Blocks at least 75% free count as empty in the space figures.
- **Built in 0.5.4.**
  - The batches read redo and undo once per statement.
  - The redo log check uses the 1 GB logs planned with `--redo-logs`.
- **Built in 0.6.0 (round 2).**
  - Every preflight records the plan of its scope (EPF_PLAN, EPF_PLAN_STEP): one run, or several when the archive room (ARCHIVELOG, ARCHIVE not confirmed) or `--max-redo` cannot take its redo at once.
    - Steps follow the months of the root dates, older data first. A month alone above the limit is a step of its own (`fits N`). The last step ends at the requested cutoff.
    - ARCHIVE is met by SMALLER_RUNS when the plan has several runs that each fit.
  - `purge` without scope options carries out the next step with the plan's choices, and `--dry-run` rehearses it. A step is DONE when its purge ends without residual rows (P1 PASS); a stopped or failed step is offered again.
  - Lifecycle: READY, IN_PROGRESS, DONE, CLOSED, with at most one open plan.
    - A run with other options replaces a READY plan.
    - While a plan is in progress, a purge with other options is refused (exit 4; the wizard asks), and `--new` starts over.
    - `plan` shows the open plan (or the latest), `plan --close` closes it; done steps stay done.
  - A preflight of the same scope checks the plan again: done steps stay, the rest is planned anew, and CHANGES SINCE lists what moved since the previous check. A preflight that does not end leaves no plan to follow.
  - The wizard's menu shows the open plan and offers continue, check again, rehearse and start over. Before a step it checks the plan again when the last check is not ready, older than `preflight_valid_h`, or `--max-redo` changes.
  - The run folder gets `plan.txt` and `requirements.txt`.
  - Differences from the design above:
    - runs are split by months of the root dates; modules share every run;
    - the operator sets the limit (`--max-redo`) instead of editing steps;
    - a preflight of another scope while a plan is in progress plans nothing (PLAN_KEPT) instead of being refused;
    - the choices no longer expire after `preflight_valid_h`: the plan keeps them, and only the reuse of root counts expires.

---

## 7. Space reclaim engine design (deep dive)

A purge frees space inside segments, not on disk: a datafile can only be resized down to its highest allocated block. The reclaim gives the freed space back to the disk by **compacting each target tablespace in place** (D3, revised 2026-10-06): the table holding the highest block of a datafile moves within its own tablespace into the free space below, the file is resized down to its new highest block, and so on down. The tablespace is never assumed to be named DATA: targets are detected from where the segments of the application schemas actually live (7.4). Built in 0.7.0 (`epf_reclaim`, `run/reclaim.sql`).

### 7.1 Why in place, not a swap

The first design moved every segment into a new tablespace, dropped the old one and renamed the new one (with the old file shrinking as the new one grew). Assessed again before building it:

- **Disk peak.** The old file can only shrink below the highest extent still in it. After years of growth most segments have an extent near the top of the file, so the old file barely shrinks until the last units leave. The two files together approach the old size plus all the live data. In place, a datafile never grows above its size at the start (7.6).
- **Moving parts.** The swap needs a clone tablespace with every attribute, repointing of segmentless objects, defaults, user defaults and quotas, a reference check, the drop, the rename, deleting the old files through a directory object, moving the new files back to the original paths (EE only), and a revert path if the drop is refused. Each is a failure mode with the data split across two tablespaces. In place needs none of them: the tablespace, its files, names, defaults and quotas never change.
- **Cost.** The swap moves everything once. In place moves only what lies above the final size, plus the tables used to make room (7.5). A table below the final highest block never moves.
- **Limit.** In place cannot go below a segment that cannot move (a pin). The swap could not either: a tablespace with a blocker was not swapped at all. In place still compacts everything above the highest pin, and the report names it.

The previous tool's in-place approach got stuck and grew the HWM because it moved without a free-space model, re-placed segments above anchors and let the files autoextend (7.2). The new engine freezes the files, always moves the unit at the top, checks it fits before moving, and makes room first when it does not.

### 7.2 Symptom -> cause -> fix

| Symptom | Root cause(s) | Fix in the new engine |
|---------|---------------|-----------------------|
| Gets stuck | R-07 slow dictionary queries in loops; R-08 lock/library-cache waits; R-09 archiver stuck; R-13 LOB shrink; L-02/L-04 no visibility | Inventory read once, refreshed per unit only; accounts locked and sessions disconnected before any DDL (7.7); `ddl_lock_timeout` + bounded retries; archive requirement in ARCHIVELOG (7.9); no shrink; heartbeat with wait event, blocker and longops % |
| Doesn't rearrange fully | R-01 first file only; R-02 partitions/IOTs/LOB partitions not moved; R-10 disk full; R-12 recycle bin; R-14 resize gives up | Every datafile of every target; every segment classified (move, release, pin) with its reason; room making for a table that does not fit (7.5); recycle bin as a requirement; resize after every move |
| HWM increases | R-03 LOBs relocated to the wrong tablespace; R-05 parallel index builds; R-06 autoextend forced; segments re-placed above anchors | Each LOB stated with its own tablespace and type in the MOVE; serial rebuilds; datafiles frozen (AUTOEXTEND OFF, recorded and restored); the moved copy can only land in free space below the top |
| Inconsistent results between runs | R-04 drop/recreate from DDL; R-15 separate recovery scripts; run_id heuristics | Constraints never dropped (7.3); one engine with a built-in restore path, run on every exit and by `reclaim --restore` (7.8); explicit run_id |

### 7.3 Index and constraint strategy (D2)

1. `ALTER INDEX ... UNUSABLE` for every index of a table that moves and every index stored in a target tablespace (all owners). Since 11.2 this drops the segment while the index and its constraint stay defined; the space becomes free space below the top.
2. Move the tables.
3. `ALTER INDEX ... REBUILD TABLESPACE <its tablespace>`, largest first, serial, LOGGING (D9). Degree, logging, compression and visibility are kept by the rebuild and compared by R1.

The primary key index of an index-organized table holds its rows: it moves with `ALTER TABLE ... MOVE` and is never released. Secondary IOT indexes follow steps 1-3. An index unusable before the reclaim is left as found (KEPT); a table with a disabled function-based index is not moved.

PK/UK/FK constraints are never dropped. While a unique index is unusable, DML on that table fails with ORA-01502: writes fail loudly instead of bypassing uniqueness. Recovery from any failure is "rebuild whatever the reclaim released", which is recorded (EPF_RECLAIM_OBJECT) and idempotent.

### 7.4 Scope and inventory

- **Targets**: `--tablespaces`, or every online permanent tablespace holding segments of the application schemas (setting `app_schemas`), except SYSTEM, SYSAUX, UNDO, TEMP and the tool's tablespace.
- **Everything in a target is inventoried, whatever the owner**, from `DBA_EXTENTS`: one row per segment and datafile with its highest block (EPF_TS_INVENTORY). Each segment gets a handler:

| Segment | Handler |
|---------|---------|
| Table, IOT (index segment and overflow), their LOB segments and LOB indexes | MOVE, as one unit per table: `ALTER TABLE ... MOVE TABLESPACE <own> [OVERFLOW TABLESPACE ...] LOB (c) STORE AS SECUREFILE (TABLESPACE <own>)` (or BASICFILE, as the LOB is) for each LOB in a target |
| Index (normal, bitmap, function-based, reverse) | RELEASE (7.3) |
| Partitioned table, index or LOB; cluster; nested table; queue table and the tables Oracle keeps for it (`AQ$_<queue table>_*`); table of an Oracle Text index (`DR$`, `DR#`) or a spatial index (`MDRT_...$`, `MDXT_...$`); MV container; MV log with rowids; flashback archive table; table with a LONG or object-type column, a domain or partitioned index, or a disabled function-based index; segment of an Oracle-maintained owner; recycle-bin object; temporary segment; index left as found (unusable before, or on a queue, Oracle Text or spatial table) | PIN, with the reason |

- A pin is not a blocker: the datafile cannot shrink below it, everything above it is still compacted. The report lists the highest pins per tablespace with position and reason.
- Recycle-bin objects: `DBA_EXTENTS` does not list their segments and `DBA_FREE_SPACE` counts them as free (seen on 19c in H5: the lab's dropped table was missing from the inventory). The requirement RECYCLEBIN counts them from `DBA_RECYCLEBIN` (7.9); confirmed, FREEZE_FILES purges them before the files stop growing.
- A table stored outside the targets whose LOB segments are inside moves too (the MOVE rebuilds the table in its own tablespace, which may grow): warned (TABLE_OUTSIDE_SCOPE).
- Segmentless objects, partition default attributes and user defaults need no handling: nothing is repointed. Space quotas do: a move or a rebuild writes the segment in its owner's quota, also when SYS runs it (requirement QUOTA, 7.9).

### 7.5 Algorithm

| Step | What happens |
|------|--------------|
| PREPARE | Restores what earlier reclaims left: locked accounts, datafile growth settings; indexes rebuilt outside the tool are marked. Indexes still released are adopted by the assessment and rebuilt by this run. |
| ASSESS | Inventory, units, pins, indexes; forecast per tablespace (7.6); the segments that move or are rebuilt with an INITIAL larger than they need (INITIAL_OVERSIZED: count, total, the five largest); accounts in scope (7.7); requirements (7.9). An assessment run (`--dry-run`) stops here. |
| (gate) | A blocking requirement not met and not confirmed ends the run: nothing is changed. |
| LOCK_ACCOUNTS | 7.7. |
| BASELINE | Once the accounts are locked, so no write changes the counts afterwards. Fingerprint (EPF_OBJECT_BASELINE): every index of the run, the constraints of the tables in scope and the foreign keys to them, the tables that move with their attributes and row counts, their LOB columns, the invalid objects; the datafiles (EPF_FILE_SNAP). |
| RELEASE_INDEXES | 7.3 step 1. |
| FREEZE_FILES | The recycle-bin objects of the targets are purged when the DBA confirmed it (`--confirm RECYCLEBIN`; PURGE TABLESPACE, RECYCLEBIN_PURGED). AUTOEXTEND OFF on every datafile of every target (recorded first in EPF_INSTANCE_CHANGE, RECLAIM_DATAFILE), then each file resized to the end of its highest extent (no free space left at the top, where Oracle would place the first extents of the next copy). Frozen together, because a table that moves writes its LOB segments into another target. |
| COMPACT (per tablespace, the largest first) | Loop: pick the unit holding the highest block of a datafile not done; if its need (estimate plus one extent per segment) exceeds the free space, **make room**: move the table that frees the most (purged tables: at least 1 MB and 10 % free inside) and fits, repeatedly; if still short, grow that file within its room; move the unit; resize the files down to the end of their highest extent. A unit that moved already and holds the top again (its copy filled partly used stretches near the top: Oracle fills those first with 64 KB, 1 MB and 8 MB extents) moves again with extents of 64 MB (STORAGE INITIAL its size rounded up to 64 MB), which take only wholly free stretches, the lowest first: the tables with free space inside them move first until such stretches cover it, otherwise the file is done there; a unit of 640 MB or more moves that way from its first move. Only segments large enough for them do (system-allocated extents; the INITIAL at most a quarter above the size, so from about 51 MB; a LOB segment likewise): a smaller unit that came back, or one with uniform extents, has room made for it once more and moves lower only when it fits in the free space as it is (no growth: that room lies above it); otherwise, or when that move fails, it keeps its move (MOVED) and the file is done. A file is done when its highest block is a pin, an index left as found, or a unit that did not fit, failed, cannot move lower after its move, whose copy held the top again after `reclaim_unit_moves` of its moves (default 3; a move that left another table at the top does not count), or that moved 10 times. Where each file stopped and why is kept with its tablespace (stop_detail: TABLESPACES "stopped:" and R7). A segment created again by a move or a rebuild gets its INITIAL storage at once: an INITIAL larger than the segment needs (above its estimate and 1 MB; for an index, the smaller of its estimate and its leaf blocks by its statistics; an export typically leaves the size of the segment then) is set to 64 KB in the same statement (INITIAL_RESET; the table's Detail in TABLES). A unit with segments in other targets (a LOB or an IOT overflow stored apart) writes them again there too: each other target that is short grows within its room first (also for a unit that moved already: a LOB tablespace compacted after the tablespace of its tables, which that compaction left full), and is resized down after the move. A copy that holds the top of another datafile of the tablespace counts as a return too. A move refused by the owner's quota (ORA-01536, ORA-01950) keeps the table where it is (NO_ROOM, MOVE_NO_QUOTA). Stop requests are honored before every move, also right after the moves that made room. |
| REBUILD_INDEXES | While the files are still frozen: each index's tablespace first grows within its room when short. An index that does not fit is rebuilt after its growth settings are restored, with resumable space allocation (a warning: the file may end above its start size; an unusable index would stop the application). |
| RESTORE_FILES | Growth settings back as recorded. |
| RESIZE | Each datafile to its highest block plus `reclaim_margin_mb` when that is smaller. A tablespace none of whose datafiles grows by itself gets `reclaim_margin_mb` of free space back (its datafiles grow, never above their start size), since the compaction left no free space above the highest extents; when it still has less, a warning (FILE_NO_GROWTH, one per tablespace). |
| RECOMPILE | Objects invalid now that were valid at the baseline, per owner. |
| VERIFY | The fingerprint and row counts again, before the accounts are unlocked (compared by R1-R5). |
| UNLOCK_ACCOUNTS | 7.7. |

Units not reached are STAYED (below a pin: moving them gains nothing) or SKIPPED (stop, error, interruption). Every step of the restore path runs even when an earlier one fails.

### 7.6 Disk usage and forecast

- **Limit**: a datafile never grows above its size at the start of the run plus `reclaim_growth_mb` (default 0), nor above its original growth limit. Growth within that limit is used only for a unit or an index that does not fit after room making. One exception, reported: an index that does not fit is rebuilt after the growth settings are restored.
- **Peak** (EPF_RECLAIM_TS.peak_bytes) is tracked after every growth and rebuild; R6 checks it against the limit and the end size against the start.
- **Forecast**: the assessment replays the loop on the inventory: top-down, each unit's need against the free space below the current top, room makers by gain, the room left by trims; the released indexes are rebuilt into the space left below. Positions take the datafiles of a tablespace end to end (exact for one file). The forecast names the unit that may not fit, and how many tables move first to make room.
- **Estimates**: a segment's latest measurement by a purge (EPF_SPACE_USAGE) plus a margin; otherwise for a table its optimizer statistics; otherwise its size. Never more than its size.

### 7.7 Accounts and sessions (D10, D15)

- **Accounts in scope**: owners of the tables that move and of the tables whose indexes are released; accounts with INSERT, UPDATE or DELETE on those tables, directly or through roles (nested); owners of tables with a foreign key to them (checking the key reads the parent's index); accounts with a session holding a lock on them. Never SYS, SYSTEM, EPFPG, the current account or an Oracle-maintained account. PUBLIC DML grants are warned. System privileges do not bring an account into scope.
- The assessment lists each account with the reasons and each of its sessions (SID, OS user, machine, program, logon time, open transaction).
- **At LOCK_ACCOUNTS**: the status is read again and the lock recorded (locked_at) before `ALTER USER ... ACCOUNT LOCK`; an account locked already stays as it is. Sessions are disconnected POST_TRANSACTION, then IMMEDIATE after `disconnect_timeout_s` (default 300), each logged.
- **UNLOCK_ACCOUNTS always runs** and unlocks only what the reclaim locked; a restore unlocks what any reclaim left locked. Recorded in EPF_ACCOUNT_ACTION.

### 7.8 Lock, wait, space; interruption and restore

- `ddl_lock_timeout` (default 30 s) on every DDL; ORA-00054 retried `ddl_retries` times (default 3, after 30/60/120 s); a table still busy stays where it is (MOVE_BUSY).
- A MOVE is atomic: a failed or interrupted move leaves the table where it was.
- **Recorded before changed**: datafile growth (EPF_INSTANCE_CHANGE), account locks (EPF_ACCOUNT_ACTION), released indexes (EPF_RECLAIM_OBJECT RELEASED). A crash between the record and the change is harmless: the restore checks the live state.
- **Stop request**: honored before every move; the restore path runs; the run ends STOPPED with the units not reached SKIPPED.
- **Test pause** (tests only): setting `reclaim_test_pause_s` makes the next compaction pause after each table that moves (TEST_PAUSE), up to that many seconds or until a stop is requested; the compaction sets it back to 0 when it reads it, and every install resets it. T18C and T18D use it, because a stop request or a kill takes a connection of its own (about 15 s on the test network) while the lab's compaction takes seconds.
- **Worker session lost** (killed, connection lost): `reclaim.sql` prints `EPF_RECLAIM_STATUS=` only when the run ended in the session. Without it the wrapper runs mode RESTORE in the same run, in a new SYS session (rebuilds, growth settings, resize, verify, accounts).
- **Worker whose client is gone**: the compaction and its restore path are one database call, which goes on until it ends when the connection of its client is lost. So a restore, and a new compaction, first wait while another reclaim session is still active (SYS, module EPF, a run's client identifier, ACTIVE; WORKER_RUNNING when found and every 10 minutes; a stop request ends the wait with ORA-20162, nothing changed). When the worker's database session has ended but its sqlplus still waits (a connection dropped without notice), the wrapper ends that sqlplus after about 10 minutes of polls without the worker (300 polls), then restores in the same run. A long call across a firewall is the likely case: the DBA can keep such connections alive with `SQLNET.EXPIRE_TIME` in the server's sqlnet.ora.
- **Wrapper lost too**: the next `reclaim` restores what is pending first (PREPARE, adoption of released indexes); `reclaim --restore` does it on its own; `status` lists every pending item with that command; uninstall refuses while anything is pending; history pruning keeps the records of such runs.
- A later reclaim continues from the current layout: there is no resume step, the assessment sees what is left.

### 7.9 Requirements

| Requirement | Blocking | Met when |
|-------------|----------|----------|
| RECYCLEBIN | yes | no recycle-bin object in the targets, counted from `DBA_RECYCLEBIN` (while the files cannot grow, Oracle purges them to make room), or `--confirm RECYCLEBIN`: FREEZE_FILES then purges them first |
| ARCHIVE | yes (ARCHIVELOG only) | the archive destination has room for the redo of the moves and rebuilds plus `archive_margin_pct`, or `--confirm ARCHIVE` |
| TEMP | yes | the temporary tablespace of SYS holds 1.5 x the largest rebuild (free plus growth), or `--confirm TEMP` |
| BACKUP | no (advice) | an RMAN database backup within `backup_max_age_h` |
| QUOTA | yes, not confirmable | every owner of a table that moves or of an index that is rebuilt may use space where those segments are: `UNLIMITED TABLESPACE`, an unlimited quota, or a quota it is not above. An owner without a quota there or above it would be refused the space, and a released index that cannot be rebuilt stays unusable: only the DBA meets it (`ALTER USER ... QUOTA`). With a limited quota and room, a table needing more than the room stays where it is (MOVE_NO_QUOTA). |

### 7.10 Not part of this version

LONG / LONG RAW conversion (D14) and partitioned objects: such tables are pins, named in the report. Redo log, undo and instance parameter changes are never made by the reclaim (R-11, D5).

---

## 8. Live logging and console output

Fixes L-01..L-05. Recommended upgrade: one console, event stream + heartbeat, one run folder.

### 8.1 Mechanism

1. The wrapper starts the worker `sqlplus` in the background (credentials through stdin) and captures its raw output to the run folder.
2. A **persistent monitor session** (one `sqlplus` kept open, queries sent through stdin, end-of-result marker) polls every 2 s:
   - new `EPF_EVENT` rows for the run (`event_id > last_seen`),
   - `EPF_STEP` state (checklist),
   - heartbeat: the worker's `V$SESSION` row (current step, SQL, wait event, seconds waiting, blocking session with user/machine/program) and `V$SESSION_LONGOPS` (% done, time remaining), plus `DBA_RESUMABLE` (suspended statements).
   A watchdog restarts the monitor session if a poll does not answer within 60 s.
   The monitor connects as EPFPG, so it keeps working while the application accounts are locked.
3. When the worker exits, one final poll drains the remaining events. No sleeps, no timestamp guessing.
4. The worker's exit code (`WHENEVER SQLERROR EXIT FAILURE`) and `EPF_RUN.status` decide what happens next.

Implementation (phase 4):

- The monitor session runs `run/begin_run.sql` (creates the run and attaches it, so it holds the run lock for the whole run and prints `EPF_RUN_ID=<n>`), then `run/poll.sql <run> <last_event_id>` every 2 s, and finally `run/finish.sql <run> <status>` (`epf_report.close_run`: checks, verdict, `RUN_END`, lock released; prints `EPF_EXIT=<n>`). Each command is followed by `PROMPT <marker>`; the wrapper reads lines until the marker. These scripts do not exit and continue on SQL errors.
- `epf_log.poll` prints `EV|...` (new events), `ST|...` (running steps), `HB|...` (worker session: action, wait event, blocker, SQL_ID, longops, resumable suspension) and `RUN|status|stop_requested`. The worker is found by `CLIENT_IDENTIFIER = 'EPF:<run>'` excluding the monitor's own SID.
- Workers are one-shot sessions: `preflight.sql <run>`, `purge.sql <run> - - - - - -`, then `report.sql <run>` after the run is ended; SYS steps (`redo_logs.sql`, `undo.sql APPLY|RESTORE`) run in their own sessions. `SP2-0640`, `SP2-0310` and logon errors in a worker's output count as a failure even when sqlplus exits 0.
- A poll that fails or does not answer within 60 s kills the monitor session, opens a new one and re-attaches the run (`run/attach.sql`, up to 5 attempts); when that fails too, the live view stops, the worker is still waited for, and the run is attached again to be ended.
- Once the worker has been seen in the heartbeat, 300 polls in a row (about 10 minutes) that answer without it, while its sqlplus still waits, mean that its connection was lost without notice: its database call has ended, so the wrapper ends that sqlplus and the run goes on as for a worker that ended early (a reclaim restores in the same run, a purge ends FAILED with undo tuning restored).
- Section headers show the database clock, the clock of the event times; when it differs from the machine running the wrapper, the run header says by how much.
- Ctrl+C while a run is shown requests a graceful stop (`run/stop.sql` in its own session) instead of ending the wrapper (also with `--non-interactive`, whenever the console input is a keyboard); the purge stops after its current batch and the run ends STOPPED with its report (exit 3).

Only one process writes the console log file (no file-sharing workarounds, no per-line PowerShell launches).

### 8.2 Console layout (mockup)

```
 EPF Data Purge                                                     run R-000124
 --------------------------------------------------------------------------------
 Database  EPFPROD 19.21 EE on dbsrv01        tool schema EPFPG
 Run folder logs\2026-09-28_104200_R-000124\

 PREFLIGHT                                                               00:00:41
 [ OK ] Connection, privileges, registry (27 tables, 22 links)
 [ OK ] Supporting indexes: 22/24 present, 2 temporary indexes will be created
 [ OK ] Eligible before 2026-08-29: PAYMENTS 1,204,331 roots / LOGS 18,442,090 / BANK 22,019
 [WARN] 3 sessions connected as OPPAYMENTS from appsrv01 (purge is online-safe)

 PURGE  depth=ALL  mode=FULL  batch=1000
 10:42:07  PAYMENTS   key snapshot  1,204,331 bulk_payment in 1,205 batches
 10:44:12  PAYMENTS   batch    120/1,205   10.0%   rows    781,220   6,250 rows/s   ETA 00:18:40
 10:47:33  PAYMENTS   batch    360/1,205   29.9%   rows  2,340,118   6,310 rows/s   ETA 00:13:21
 ..        PAYMENTS   batch 402 . DELETE OPPAYMENTS.PAYMENT_AUDIT . db file sequential read 0.2s
 10:58:40  PAYMENTS   done     7,811,402 rows in 21 tables                              16m33s
 [ OK ] PAYMENTS  residual 0 . orphans 0 . retention-safe

 RECLAIM  COMPACTION IN PLACE, tablespaces DATA                              10:58:41
 10:58:52 [INFO] TS_ASSESSED          DATA: 118.0 GB in 1 datafile(s), segments 41.2 GB; 612 tables move, 214 indexes released and rebuilt, 2 segments stay; forecast 43.2 GB
 10:59:02 [ OK ] ACCOUNT_LOCKED       OPPAYMENTS locked (was OPEN)
 11:02:10 [ OK ] INDEXES_RELEASED     214 indexes released: 8.1 GB of index segments become free space
 11:03:55 [ OK ] UNIT_MOVED           OPPAYMENTS.AUDIT_TRAIL: 3.2 GB -> 1.1 GB; DATA 88.4 GB -> 85.2 GB (4m12s)
 ..       COMPACT DATA . direct path write 3s . OP.SPEC_TRT_LOG 62% (4m12s left)
 11:48:12 [ OK ] COMPACT_DONE         DATA: 412 of 612 tables moved; datafiles 118.0 GB -> 36.9 GB before the indexes are rebuilt
 ...
 12:31:40 [ OK ] RECLAIM_RESULT       DATA COMPACTED: datafiles 118.0 GB -> 43.0 GB (75.0 GB given back), segments 41.2 GB

 RESULT  PASS                                               total 01:48:12 . exit 0
 Report  logs\2026-09-28_104200_R-000124\report.txt
```

Rules:

- Fixed columns: time, phase, subject, metrics; widths stable so logs diff cleanly.
- Status tags: `[ OK ]`, `[INFO]`, `[WARN]`, `[FAIL]`; heartbeat lines start with `..` and are shown on the console at most every 15 s while no event arrives (not written to the log unless they carry a WARN).
- Colors via `Write-Host -ForegroundColor` (no ANSI dependency); `--no-color` for plain output. ASCII only.
- Section headers per phase with elapsed time.

### 8.3 Run folder (one per run)

```
logs/2026-09-28_104200_R-000124/
  console.log        everything shown on screen (without colors)
  report.txt         integrity and results report (section 9)
  manifest.txt       key=value summary: run_id, parameters, step statuses, check results, exit code
  sqlplus_*.log      raw worker/report session output (evidence)
```

`manifest.txt` and the `EPF_CHECK|...` lines at the end of `report.txt` are the machine-readable part: pasting the folder (or just those two) is enough for a full review of whether the run went exactly as intended.

---

## 9. Integrity and results report

`epf_report.print(run_id)` (entry: `sql/run/report.sql <run_id|LATEST>`), printed at the end of every run and on demand via `epf_purge.bat report [--run R-000124]`.

### 9.1 Sections

1. **Run header**: run_id, action, parameters, cutoff date, database, operator, host, start/end, duration per step, final status.
2. **Purge results per module and table**: eligible at start, processed, residual after, total before/after, retained before/after, orphans, status.
3. **Space**: per module and table, segment MB at BASELINE / POST_PURGE / POST_RECLAIM; per tablespace used/free; per datafile size and HWM before/after; bytes returned to disk.
4. **Reclaim** (reclaim runs): tablespaces (start, segments, forecast, end, peak, given back, status), tables, indexes, segments that stay (the highest first, with reasons), accounts, datafiles, requirements.
5. **Checks and verdict**.

### 9.2 Checks

| ID | Check | PASS | WARN | FAIL |
|----|-------|------|------|------|
| P1 | Residual eligible rows (deleting modules) / residual non-empty LOBs (clearing modules) | 0 | > 0 when the run was stopped or failed | > 0 |
| P2 | Accounting: processed = eligible at start, per table | equal | more processed (rows became eligible during the run), or fewer when stopped or failed | fewer |
| P3 | Retention safety: retained rows (newer than cutoff, or linked to retained roots) not reduced | not reduced | - | reduced |
| P4 | Orphans on every registry link (links protected by an enabled validated FK pass by constraint) | 0 | orphans that existed before the purge | new orphans |
| P5 | Errors during the run (RUN_END excluded) | none | WARN events | any ERROR event, or the run ended FAILED (a step outside the database failed, or the worker session ended) |
| P6 | Temporary supporting indexes dropped | all dropped | - | leftovers |
| R1 | Indexes the reclaim released: usable again, every attribute identical (status, tablespace, degree, logging, type, uniqueness, visibility, compression, pct_free); an index unusable before stays as found | identical | an index dropped meanwhile | unusable or different |
| R2 | Constraints of the tables in scope and foreign keys to the tables that move: status, validated, deferral | identical | - | any difference |
| R3 | Objects invalid after the recompilation that were valid before | none | - | any |
| R4 | Row counts of the tables that move (`reclaim_row_counts`), taken after the accounts are locked and before they are unlocked | identical | not counted after | differs |
| R5 | Table attributes (tablespace, logging, degree, pct_free, ini_trans, compression) and LOB attributes | identical | a LOB stored as SECUREFILE (db_securefile), a new LOB retention or segment name | any other difference |
| R6 | Datafiles: growth settings restored as at the start; each tablespace at most its start size at the end, at most its start size plus `reclaim_growth_mb` per datafile at its peak | yes | above the start size at the end, or at the peak for an index that did not fit | a setting not restored, any other excess |
| R7 | Efficiency: each tablespace within max(1 %, 256 MB) of its segments plus the margin | yes | above it, the segment that stays at the top named | - |
| R8 | Tables: every table above the highest segment that stays moved | yes | tables that did not fit, were busy or were not reached (stop) | a move failed |
| R9 | Accounts the reclaim locked unlocked again (a restore: any reclaim) | yes | - | an account still locked |
| P7 | Space measured inside segments before/after purge (6.6) | measured | estimated or unsupported segments, or a phase missing | - |
| P8 | Compaction (6.7), when requested | every candidate compacted | tables skipped or failed | - |

Checks that do not apply are `SKIP`: P1-P4, P6 and P8 for dry runs and runs without a purge; P7 for runs that are not purges. A reclaim run has P5 and R1-R9; its assessment skips R1-R9; a restore run checks R1, R6 and R9; without a baseline (nothing to move, or the run ended before the compaction) R2-R5 and R8 are skipped. LONG conversions (D14) will add their own check.

Orphan counts are also events (`LINK_ORPHANS`): INFO before the purge and for orphans that were already there, WARN only for orphans the purge added, so orphans in the application data do not turn P5 into a warning.

Verdict: `PASS`, `PASS WITH WARNINGS`, `FAIL`. Exit code follows the verdict (0, 2, 1); 3 when the run was stopped.

### 9.3 Output format (mockup, end of report.txt)

```
 CHECKS                                                              run R-000124
 ------------------------------------------------------------------------------------
 P1  Residual eligible rows ................................ PASS   0 in 27 tables
 P2  Processed = eligible at start ......................... PASS   27/27 tables
 P3  Retention safety ...................................... PASS   retained rows unchanged
 P4  Orphans ............................................... PASS   22 links (9 by FK, 13 scanned)
 R1  Indexes usable and identical ........................... PASS   214/214 usable and identical
 R6  Datafiles within their start size ...................... PASS   DATA 118.0 GB -> 43.0 GB
 R7  Efficiency ............................................ PASS   DATA 43.0 GB vs 41.2 GB of segments
 R8  Tables moved .......................................... PASS   412 of 612 moved, 200 below where the datafile stopped
 R9  Accounts restored ..................................... PASS   4 locked, 4 restored
 ------------------------------------------------------------------------------------
 VERDICT  PASS

EPF_CHECK|R-000124|P1|PASS|0|residual eligible rows
EPF_CHECK|R-000124|P2|PASS|27/27|processed equals eligible
...
EPF_STEP|R-000124|PURGE|PROCESS_BATCHES|PAYMENTS|DONE|993
...EPF_VERDICT|R-000124|PASS|exit=0
```

---

## 10. CLI, configuration and interaction flow

### 10.1 Command line

```
epf_purge.bat [action] [options]

Actions
  (none)       interactive wizard
  purge        purge (--reclaim to reclaim afterwards: later)
  reclaim      compaction in place (SYS); --dry-run assesses, --restore restores what a
               reclaim left pending (7)
  preflight    read-only checks, inventories and forecasts; changes nothing
  report       report for a run (default: latest)          --run R-000124
  status       state of the latest/current run, degraded objects, locked accounts
  stop         request a graceful stop of the running run
  install      install or upgrade database objects (SYS)
  uninstall    remove database objects (refuses while a reclaim is incomplete)

Options
  --config FILE           configuration file (CLI overrides file values)
  --tns NAME              TNS alias or EZConnect string (PDB service in multitenant)
  --retention DAYS        default 30
  --depth LIST            ALL | PAYMENTS | LOGS | BANK_STATEMENTS (comma-separated)
  --mode MODE             FULL | CLOB | LOGS | CLOB_N_LOGS
  --batch-size N          100-100000; wizard default: the preflight's recommendation (6.8); otherwise
                          the batch_size_default setting (1000)
  --dry-run               snapshot and count only
  --compact               shrink worthwhile purged tables after a purge-only run (6.7)
  --redo-logs             enlarge the online redo logs before the purge (D17; SYS)
  --undo-tuning           lower undo_retention for the purge, restored at the end (D18; SYS)
  --run ID                run for report (default LATEST) and stop (default: active run); 124 or R-000124
  --tablespaces LIST      reclaim: target tablespaces (default: all candidates, 7.4)
  --restore               reclaim: restore what a reclaim left pending (7.8)
  --confirm LIST          purge: ARCHIVE, UNDO, TEMP; reclaim: ARCHIVE, TEMP, RECYCLEBIN (7.9)
  --yes                   skip the final confirmation; required with --non-interactive for a purge that
                          deletes, a reclaim and uninstall
  --non-interactive       never prompt; missing input is an error (exit 4)
  --log-dir DIR           default logs\ in the tool folder
  --no-color
  --help

Environment
  EPF_PASSWORD            EPFPG password
  EPF_SYS_PASSWORD        SYS password (reclaim, install, uninstall, --redo-logs, --undo-tuning)
```

Exit codes: `0` PASS, `1` FAIL (including a preflight that finds errors: nothing is changed), `2` PASS WITH WARNINGS, `3` aborted or stopped (user answer, Ctrl+C / stop request), `4` usage/configuration error (also: connection failed, run could not be created). `--reclaim` (purge then reclaim), `--long-conversion` (D14) and `--resume` (not needed: a new reclaim continues from the current layout) are refused with exit 4; `--dry-run`, `--compact`, `--redo-logs` and `--undo-tuning` are refused where they do not apply (preflight; compaction and instance tuning with a dry run).

The configuration file (`src/config/epf_purge.conf`, or `--config`; documented in `epf_purge.conf.example`) uses KEY=VALUE lines: `TNS`, `CONNECT_TIMEOUT_S`, `RETENTION_DAYS`, `MODE`, `DEPTH`, `BATCH_SIZE`, `DRY_RUN`, `COMPACT`, `REDO_LOGS`, `UNDO_TUNING`, `LOG_DIR`, `NO_COLOR`, `RECLAIM_TABLESPACES`, `RECLAIM_CONFIRM` (later `LONG_CONVERSION`, ...). A command line value skips its question; a file value is the question's default in the wizard and the answer with `--non-interactive`. Passwords in the file (`EPF_PASSWORD`, `SYS_PASSWORD`) are allowed but discouraged; the file is git-ignored.

### 10.2 Credentials

- Read with a masked prompt or from the environment; never placed in a command line, temp file or child environment (S-01).
- Every `sqlplus` starts as `sqlplus -S -L /nolog`; the wrapper writes `CONNECT user/"password"@tns` to its stdin with echo off.
- A session is sent the CONNECT line and a marker (`PROMPT`) only; sqlplus prints the marker once the CONNECT has finished, successful or not, and only then does the script, query or monitor command follow. A marker that does not come within `CONNECT_TIMEOUT_S` (default 120 s) means the connection hangs: nothing has been sent yet, so the session is ended and started again, 3 attempts in all, then the step fails with "the database did not answer the connection". Seen on the test network (H5, H8): a session whose connection never completed and had no database session, while the next connection took the usual 15 s. The test suite connects the same way (Invoke-Sql), and its connection limit is `CONNECT_TIMEOUT_S` in test.conf.
- Passwords are kept as `SecureString` and decoded only to write the CONNECT line (and, for install, the EPFPG password argument written to the same stdin).

### 10.3 Interactive flow ("all input at the beginning")

Every question, confirmation and password is collected before the first change. After the final confirmation the run proceeds to the end without any further input - the operator can leave and come back to a finished run.

1. **Connect**: TNS, EPFPG password; connection test; container check (refuses `CDB$ROOT`); version and install check (offers `install` if objects are missing or outdated).
2. **Choose action**: Purge / Preflight only / Reclaim / Report / Status (Purge + reclaim later). What an interrupted reclaim left is restored by the next reclaim before anything else, or by `reclaim --restore`.
3. **SYS password** - asked here, only if the action includes reclaim.
4. **Purge parameters**, each with its default and a live preview:
   - retention -> cutoff date and eligible roots per module,
   - mode (FULL / CLOB / LOGS / CLOB_N_LOGS), depth (not asked in LOGS mode) with per-module size and estimate,
   - batch size (default: the preflight's recommended batch size, 6.8), dry run,
   - redo log sizing, offered when a batch exceeds a whole online log (D17, SYS password required),
   - undo tuning for the purge, offered when preflight expects the undo tablespace to grow (D18, SYS password required; restored at the end),
   - compaction (only when reclaim is not selected; default No).
5. **Reclaim preparation** (if chosen), all read-only, built in 0.7.0:
   - tablespaces to reclaim (Enter: every candidate);
   - an assessment run (its own run folder and report): per tablespace the start size, segments, tables that move, indexes, segments that stay with their reasons, the forecast; the accounts and sessions that will be locked and disconnected (7.7); the requirements (7.9);
   - one question per blocking requirement not met: the DBA confirms it, or stop;
   - LONG conversions, one item at a time (later, D14).
6. **Review screen**: every parameter, forecasts, warnings, what will change. One confirmation (`Proceed? [y/N]`; destructive actions require typing `yes` unless `--yes`).
7. **Run**: live view (8.2) through to the verdict.

Implementation of the purge flow (phase 4): after retention, mode, depth, dry run and compaction, the wizard runs a read-only PREFLIGHT run with these parameters (its own run and run folder, shown live with its report). `run/advice.sql` then returns its findings as `EPF_ADVICE|...` lines: recommended batch size, redo warning, undo warning, undo tuning still active, error count. Errors end the wizard (exit 1, nothing changed). Otherwise the redo sizing and undo tuning questions are asked when the findings call for them (not for a dry run), the batch size is asked with the recommendation as default (clamped to 100-100000), the SYS password is asked only when a SYS step was chosen, then the review. The PURGE run refers to that preflight run (`preflight_run` in the manifest) instead of repeating it. Without the wizard (`--non-interactive`), the PURGE run runs the preflight itself as its first step.

Every prompt validates immediately and re-asks on invalid input, shows `[default]`, and accepts Enter. Supplying an option on the command line skips its prompt.

---

## 11. Code, comment and formatting standards

"Official-only script comments and descriptions" is applied as follows:

1. **Header block** in every file: name, purpose, usage/parameters, privileges required, side effects. Written as reference documentation.
2. **Comments describe what the code does and why, in present tense.** No history, no narration of earlier versions or attempts, no "previously", "old", "legacy", "new", "v2", "fix for", "rework", no author notes or TODOs in delivered code.
3. **No dead code**: no commented-out blocks, no accepted-but-ignored parameters.
4. Every package procedure has a spec comment: purpose, parameters, exceptions raised, events emitted.
5. Error handling: never `WHEN OTHERS THEN NULL`; every handler logs an ERROR/WARN event with ORA code and re-raises or returns a status the caller checks.
6. SQL*Plus entry scripts start with a fixed settings block (`SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF SERVEROUTPUT ON SIZE UNLIMITED`, `WHENEVER SQLERROR EXIT FAILURE ROLLBACK`); `TAB OFF` keeps aligned output as spaces. In an anonymous block, as in a package body, every variable is declared before the first local subprogram (PLS-00103 otherwise); run scripts are compiled only when they run, so the end-to-end suite (12.5) is what checks them.
7. Identifiers quoted in dynamic DDL (`"OWNER"."TABLE"`); all dynamic values bound or validated with `DBMS_ASSERT`.
8. ASCII only in every file; `.gitattributes` fixes line endings (CRLF for `.bat`/`.ps1`, LF elsewhere).
9. Consistent naming (4.2 rule 8) and one output vocabulary (8.2).

---

## 12. Testing and validation strategy

I cannot run Oracle in this environment, so each phase ships test scripts and expected results; you run them on a test database and paste back the run folder (`manifest.txt` + `report.txt`), which the tool makes self-checking.

### 12.1 Phase 0 verifications (before building on them)

| ID | Verify on your version |
|----|------------------------|
| V1 | `ALTER INDEX ... UNUSABLE` drops the segment, including PK-backing and partitioned indexes. |
| V2 | DML on a table whose PK index is unusable fails with ORA-01502; reads work. |
| V3 | `MOVE` / `MOVE PARTITION` preserves BASICFILE/SECUREFILE type and LOB settings with explicit LOB storage clauses. |
| V4 | `DROP TABLESPACE` without `INCLUDING CONTENTS` refuses while segmentless objects or default attributes still reference it. Not needed since D3 was revised (no drop). |
| V5 | `ALTER TABLE ... MODIFY (long_col CLOB)` with a LOB storage clause targeting another tablespace; dependents recompile. |
| V6 | SYS executing an EPFPG invoker-rights package with `INHERIT PRIVILEGES ON USER SYS TO EPFPG`, inside a PDB. |
| V7 | `ALTER TABLESPACE ... RENAME` keeps user defaults and quotas; online `ALTER DATABASE MOVE DATAFILE` to the original path. Not needed since D3 was revised (no rename, no new file). |
| V8 | `DBMS_SPACE.SPACE_USAGE` for table, index, BASICFILE and SECUREFILE LOB segments; cost on large segments. |
| V9 | `ALTER SYSTEM DISCONNECT SESSION ... POST_TRANSACTION` and account lock/unlock from inside a PDB. |
| V10 | Resumable space allocation suspends and resumes; `V$SESSION_LONGOPS` reports MOVE and REBUILD progress. |
| V11 | The copy of a table that moves goes to the lowest free space that fits (first fit), so the highest block of the file drops after each move. Lab: T18B (RT_TOP moves lower, the file shrinks). H5 (0.7.0): the copy of RT_TOP took the free space below it (file 342 -> 260 MB); it came out larger (80 -> 103 MB) and needed nearly all of that space, so its last extents lay just below its old place and it held the top again. Since 0.7.1 such a table moves again only when it fits below as it is. Set R (DATA, bigfile, 0.7.2): copies mostly landed lower, but not always. DIRECTORY_DISPATCHING (10.4 GB -> 688 MB) held the top again after its first move, left it with its second and third (21.8 -> 13.8 GB), and was back at the top once three other tables had moved off it; the file stopped there at 11.9 GB (segments 10.5 GB). 0.7.3 counts only the moves that leave a table at the top. R6 (0.7.5, a second compaction of DATA): DIRECTORY_DISPATCHING came back to the top after each of its 3 moves with 4.6 GB free below, and the file stopped at 11.5 GB. A segment that grows in 8 MB extents takes only free stretches of 8 MB (system-allocated extents: 16 x 64 KB, 63 x 1 MB, then 8 MB; its 688 MB copy is exactly that), and the gaps low in the file are mostly smaller. Since 0.7.6 such a return first makes room with the tables that have free space inside them (their segments leave 8 MB and 64 MB stretches), and MOVE_PLACEMENT records where each copy went. R7 (0.7.6): the room making moved PAYMENT first (2.1 GB to 3.0 MB; segments 10.3 to 7.5 GB, 3.5 GB free inside the file), yet DIRECTORY_DISPATCHING came back to the top after each of its 3 moves again (11.5 to 11.1 GB): Oracle does not place a copy in the lowest free space that fits. The placement data of R-000121 shows why: Oracle places the extents of a growing segment (64 KB, 1 MB, 8 MB) in partly used stretches first, wherever they are, and breaks a wholly free stretch (the lowest) only when there is none; the copy took the holes its previous copy left near the top (move 2: 10.0-11.1 GB with 6.2 GB free from 3.7 GB). Since 0.7.7 a table that came back, and one of 640 MB or more, moves with 64 MB extents (INITIAL its size rounded up to 64 MB), which take only wholly free stretches (system-allocated extents only). R8 (0.7.7, lab 2): the trim after each move kept a free MB at the top of a file whose highest extent ends on a MB boundary (highest block plus one block, rounded up to a MB), and a copy took it (RT2_TOP, file 6, 47 to 48 MB); a 4 MB table that came back was sent to the 64 MB path in a 52 MB file. Since 0.7.8 the compaction trims to the end of the highest extent, and only segments large enough for 64 MB extents (about 51 MB) use them. |
| V12 | `MOVE` with `LOB (c) STORE AS SECUREFILE (TABLESPACE t)` (or BASICFILE) keeps every other LOB attribute: chunk, retention, cache, compression, deduplication, encryption, in-row, segment name. R5 compares them on every run. |
| V13 | A killed worker session: the DDL in progress rolls back, and the restore in a new session rebuilds the released indexes, restores the growth settings and unlocks the accounts. Lab: T18D. |
| V14 | `STORAGE (INITIAL 65536)` is accepted, and sets the INITIAL, for each kind of segment created again: a table (`MOVE TABLESPACE t STORAGE ...`), an IOT index and its overflow (`OVERFLOW TABLESPACE t STORAGE ...`), a SECUREFILE and a BASICFILE LOB (inside `STORE AS ... (TABLESPACE t STORAGE ...)`), a rebuilt index (`REBUILD TABLESPACE t STORAGE ...`). Lab 2: T18G, which also checks CACHE and PCTVERSION 0 kept (V12). R5 (0.7.4): set for the table, the IOT index, both LOB kinds (a SECUREFILE segment is created with its INITIAL) and the index; the IOT overflow kept its INITIAL although the statement asked for 64 KB and ran. Since 0.7.5 the engine checks every such segment after its move or rebuild (INITIAL_KEPT), and lab 2 PROBE tries six forms of MOVE on an IOT overflow. R7: every form creates the overflow again but keeps its INITIAL; since 0.7.7 the reclaim does not ask for it and plans the overflow at its INITIAL. Probe G: a table moved with INITIAL 128 MB gets 2 extents of 64 MB (T18G checks it). R8: 2 x 64 MB in EPF_RT2_SIDE; R9: 3 extents (1 MB to 64 MB) there, after a compaction that left its datafile ending at its last extent. Since 0.7.9 probe G runs in a tablespace of its own (one wholly free 200 MB datafile that cannot grow, as during a compaction) and probe H in EPF_RT2_SIDE (recorded), each with the extents by size and where they lie. |
| V15 | A layout other than one bigfile tablespace: two datafiles with uniform extents (one not autoextensible), the indexes in a tablespace of their own, LOB and overflow segments in a third, a compressed table, a queue table: the compaction moves every table, the files shrink, nothing grows above its start size, and the queue's tables and indexes stay as they are. Lab 2: T18G (since 0.7.8 it requires R8 "5 of 5 moved"). R5 to R7 (0.7.4 to 0.7.6): passed. R8 (0.7.7): RT2_IOT stayed below where both datafiles of EPF_RT2_DATA stopped (V11). R9 (0.7.8): 5 of 5 moved; EPF_RT2_DATA 88 to 43 MB (41 MB of segments); EPF_RT2_SIDE stopped at 42.9 MB (21.3 MB of segments) because moving a LOB's table again found no room in EPF_RT2_DATA (ORA-01658); since 0.7.9 that move grows EPF_RT2_DATA within its room. |

### 12.2 Test matrix

- **Purge parity**: on a clone, current tool vs new engine: identical per-table deleted counts for the same cutoff (plus the D8 difference if chosen).
- **Purge integrity**: P1-P7 PASS; injected orphan and injected newer-than-cutoff rows are detected; a client-schema FK with ON DELETE CASCADE into a registry table is caught by preflight.
- **Reclaim layouts**: shared data/index tablespace; separate index tablespace; multi-file and bigfile tablespaces; a table in one target with its LOBs in another, and with its LOBs in a target but itself outside; client-added schema in the tablespace; partitioned table (pin); IOT with overflow; BASICFILE and SECUREFILE LOBs; LONG table (pin); recycle-bin object (requirement); UNIFORM and AUTOALLOCATE extents; TDE-encrypted tablespace; PDB and non-CDB. The lab (`reclaim_lab.sql`) covers the single-file AUTOALLOCATE case with a pin low in the file, room making, both LOB types, an IOT and the recycle bin.
- **Fault injection**: kill the worker session during COMPACT (T18D) and during REBUILD_INDEXES; the wrapper restores in the same run; `reclaim --restore` then finds nothing pending. Kill the wrapper too: the next reclaim restores first (PREPARE, adoption).
- **Concurrency**: application sessions connected and one holding an open transaction when the reclaim starts (lock + disconnect path, list shown).
- **Disk pressure**: a table at the top that does not fit (room making, then NO_ROOM with `reclaim_growth_mb` 0); an index that does not fit within the start size (rebuilt after the growth settings are restored, resumable suspend path, then space added).
- **Stop**: stop requested during purge, during compaction, during a reclaim MOVE (T18C) and during the index rebuilds (ignored until the restore path ends).

### 12.3 Acceptance

All of section 1 measured PASS on the matrix, and on one production-sized clone run end-to-end with timings recorded.

### 12.4 Target environment (survey of 2026-09-28)

| Fact | Consequence for the design |
|------|----------------------------|
| 19c EE (19.24), non-CDB `EPFPG781`, Linux x86-64; the wrapper runs on a Windows client | The non-CDB path is the primary test case. Datafiles are on the server: the wrapper never touches them; the reclaim only resizes them. |
| NOARCHIVELOG | The redo vs recovery-area check (D9) does not apply. No media recovery is possible, so the reclaim preflight shows a WARN recommending a backup. |
| No OMF; files in `/files2/oradata19/EPFPG781/`; database default permanent tablespace is SYSTEM | Named datafiles in the original directory; SYSTEM is never a target. |
| One reclaim candidate: `DATA`, **bigfile**, one 41.6 GB file, 39.5 GB of segments, autoallocate, ASSM, not encrypted, autoextend to 32 TB | Compacted in place: the single file is resized down after every move (D3 revised). |
| Segments in DATA: OPPAYMENTS 34 GB (tables 11.9, LOBs 14.0, indexes 8.1), OP 6.4 GB; OPREPORTS owns none | |
| KDCM and SUPER: default tablespace DATA with unlimited quota, no objects in DATA | Nothing to repoint in place; locked for the reclaim only if they hold DML grants on the tables in scope or a session with a lock on them (D15). |
| 82 segmentless tables in DATA (OP 81, OPPAYMENTS 1) | No segment: nothing to move in place. |
| LONG columns: `OP.PLAN_TABLE.OTHER` (0 rows), `OP.WEB_RAPPORT.REQUETE` (46 rows) | Pins until D14 is built: the two tables stay where they are, named in the report. |
| IOT `OP.ISIN_RESERVE`; no partitioned, cluster, queue or nested tables; recycle bin empty | IOT handled by MOVE (7.3); no blockers expected. |
| 27/27 registry tables present; 22 FKs into them, all inside OPPAYMENTS; `NOTIFICATION_EXECUTION.IMPORT_AUDIT_FK` is ON DELETE CASCADE | Rows of retained roots that reference rows of eligible roots must be handled explicitly by the purge engine (phase 2). |
| Largest purge tables: DIRECTORY_DISPATCHING 10.6 GB (3.8 M rows), FILE_DISPATCHING 4.4 GB, PAYMENT_ADDITIONAL_INFO 3.8 GB (56.8 M rows), TRANSMISSION_EXECUTION_AUDIT 2.3 GB, PAYMENT 2.1 GB, PAYMENT_AUDIT 1.5 GB (25.3 M rows) | Index coverage of the PAYMENT_ID children decides purge speed; listed by the phase 2 preflight. |
| Optimizer statistics of most purge tables date from 2024 | Counts always come from the key snapshot, never from statistics. |
| OPPAYMENTS owns application packages named `EPF_*` (EPF_BIND, EPF_CONTEXT, EPF_CST, EPF_MIGRATION_133, EPF_SQLBINDING, EPF_UTILS) | Objects of the previous tool are identified by exact name only (section 14). |

### 12.5 End-to-end suite (`src/tests/e2e`)

One command runs every current test against one refreshed test database and writes a single log to review: `src\tests\e2e\run_tests.bat` (Windows PowerShell 5.1, the sqlplus client and tnsnames of the tester's machine). Configuration in `src/tests/e2e/test.conf` (git-ignored; from `test.conf.example`): TNS alias, expected database name (the suite refuses any other database), `DESTRUCTIVE_OK=YES`, passwords (or asked, masked, at start), retention, stop point.

What the tester sends back is `run_tests.bat --digest` (no database, no configuration): the summary; the notes and failed checks of the reclaim tests and of every failed test, with the lines naming an error; and for each compaction of the session, each run of a failed test and each run in `logs\` after the session, one line for the run, one for its checks, and its key events one line each (a move with where its copy went, INITIAL resets, room making, where each datafile stopped, the result per tablespace, steps of 30 s or more, warnings and errors; of the moves, the first 10 and the last 40). It goes to `logs\digest.txt` and the clipboard, typically under 10 thousand characters where the log of one reclaim test alone exceeded 50 thousand. The full logs stay on disk for anything the digest leaves out.

| Test | Covers |
|------|--------|
| T00 | Static checks, no database: the wrapper and the suite parse, call only defined commands, and no `+` takes a list on its right (the comma binds tighter) |
| T01 | Precheck and safety gate: database name, non-CDB, single instance, log mode, redo logs, undo, statistics of the root tables |
| T02 | Environment survey, appended to the log |
| T03, T04 | Install through the wrapper, then again with `install.sql` (idempotent upgrade) |
| T05 | Undo tuning left from earlier work restored; nothing active |
| T06, T07 | Wrapper basics (help, status, stop without a run) and usage errors (exit 4, no run created) |
| T08, T09 | Preflight through the wrapper and `preflight.sql NEW` |
| T10 | Dry run of all modules: P1-P4, P6, P8 SKIP |
| T11, T12 | PAYMENTS through the wizard (piped answers) with redo log sizing, undo tuning and the batch size for 1 GB logs; graceful stop with the `stop` action after a few batches (exit 3, undo restored, nothing pending) |
| T13 | PAYMENTS to the end, non-interactive, undo tuning |
| T14 | LOGS with compaction |
| T15, T16 | BANK_STATEMENTS LOB clearing (mode CLOB), then FULL through the menu wizard (redo sizing idempotent, BASICFILE estimate) |
| T17, T18 | Reports (latest, stopped run) through the wrapper; `report.sql`, `status.sql`, `advice.sql` |
| T18A-T18F | Reclaim on a scratch tablespace (`src/tests/verify/reclaim_lab.sql`: tables of every kind, a pin low in the file, the top table needing room): the assessment changes nothing; the requirement gate (recycle bin); the compaction with room making and R1-R9, the file shrinks and everything is restored; a stop (STOPPED, restored); a killed worker restored in the same run, then `reclaim --restore`; the assessment of the application tablespaces (read-only); cleanup |
| T18G | Reclaim on a second layout (`src/tests/verify/reclaim_lab2.sql`: two datafiles with uniform extents, the indexes and the LOB and overflow segments in tablespaces of their own, a queue table, a segment of each kind with an INITIAL larger than it needs, its owner above its quota): the dry run finds QUOTA not met and lists the INITIALs; once the quota is raised, the compaction with R1-R9, each INITIAL set to 64 KB, the lab as before, the files smaller; the lab removes itself |
| T19 | Final state: redo logs, undo_retention as before, no active instance change, no account left locked or index left released by a reclaim, no temporary index left, no run left RUNNING |

Every step records the command (passwords masked), its full output, exit code and the manifest of each run it created; checks compare exit codes, output patterns and manifest values, and any SP2-/PLS-/compile or missing-object error fails the step. A step that times out, or whose session does not connect, is reported first: the processes it started, what the database sessions of the machine, of the runs and of any sqlplus are doing (event, blocker, SQL), from a separate SYS session, and the listener's answer (tnsping). A session that does not connect within `CONNECT_TIMEOUT_S` is then tried again, 3 attempts in all. Ctrl+C itself is not scripted (the console is redirected); the stop action exercises the same graceful stop. `--only`, `--from` re-run parts; T01 always runs.

### 12.6 Parity check (`src/tests/parity`)

The purge parity of 12.2, row by row, on two copies of the same database: one purged by the previous tool (`legacy/`), one by this tool, same cutoff, mode and depth.

- `parity.sql <label> <cutoff> [FULL|CLOB]` (SYS, read-only) is run on each copy before and after its purge (labels `LEGACY_BEFORE`, `LEGACY_AFTER`, `NEW_BEFORE`, `NEW_AFTER`; files in `logs/parity`). For the 27 tables of the previous tool it classes every row with four flags and records the row count and a checksum of the keys per class: D the previous tool deletes it (its rules, transcribed from `epf_purge_pkg`), X it is deleted through an ON DELETE CASCADE key from a D row, N this tool selects it (registry links, before holding back), C the previous tool clears its LOB values. Scope CLOB also records the non-empty LOB values per column and class. It also records the foreign keys into the tables (rows of kept trees referencing D rows: ORA-02292 for the previous tool) and the runs both tools logged.
- `compare.ps1 -Mode <mode> [-Depth <depth>]` checks that both copies started identical, that each tool changed exactly the rows its rules select, and classifies every difference: D8 (bank statement files without directory rows), D16 (rows held back, including rows the previous tool deletes through ON DELETE CASCADE), PAYMENT_AUDIT in LOB clearing (the previous tool clears it by bulk payment only). Anything else fails. Exit 0 identical, 2 explained differences only, 1 fail or unusable snapshots. With `-Before` it reads only the two BEFORE snapshots: identical start, what each tool will change, rule differences; the purges start only on READY.
- Covered: FULL, CLOB_ONLY, CLOB_N_LOGS (the previous tool adds LOGS to the depth) on all three modules. Not covered: the previous tool's reclaim, shrink, redo sizing and index scripts, which change no rows.
- The previous tool's wrapper cannot run a purge (its prompt block is missing, `wmic` is gone from Windows 11). `legacy_purge.sql` (as OPPAYMENTS) runs its purge without it: install `legacy/sql` 01-03, compilation check, `run_purge` with the wrapper's arguments. The wrapper's optional steps run as separate commands in its order: `06_optimize_db.sql` and `utility/08_undo_tune.sql` (SYS), `06b_create_purge_indexes.sql`, the purge, `06c_drop_purge_indexes.sql` (OPPAYMENTS), then undo_retention back to 900 s (SYS).

---

## 13. Implementation phases

| Phase | Deliverables | Exit criteria |
|-------|--------------|---------------|
| 0. Verify and baseline | Now: read-only environment survey (`src/tests/verify/environment.sql`). Before phase 5: behavior spikes V1-V10 on a test database; parity baseline from the previous tool on a clone. | Survey output reviewed; V1-V10 answered before reclaim work starts. |
| 1. Foundation | Layout, `.gitattributes`/`.gitignore`, `install.sql`/`uninstall.sql`, `tables.sql`, `registry_data.sql`, `grants.sql`, `epf_util`, `epf_log`, `epf_control`, `epf_registry`. | Install/upgrade/uninstall idempotent; registry validation runs. |
| 2. Purge engine | `epf_purge` (snapshot, held back D16, modes, batches, temporary indexes, counts), `epf_space` (segment, file and in-segment snapshots), `run/preflight.sql`, `run/purge.sql`. | Parity with baseline; dry-run exact counts. |
| 3. Report (purge part) | `epf_report` sections 1-3, checks P1-P8, `run/report.sql`; orphan counts per link (`EPF_LINK_STAT`); optional compaction (6.7). | Purge runs self-verify. |
| 4. Wrapper | `epf_purge.bat` launcher, `lib/epf.ps1`: CLI, config, wizard, credentials, runner, live view, run folder, exit codes; `epf_log.poll`, `run/begin_run.sql`, `attach.sql`, `poll.sql`, `finish.sql`, `advice.sql`, `status.sql`, `stop.sql`; `src/config/epf_purge.conf.example`. | End-to-end purge from the wizard and non-interactively. |
| 5. Reclaim engine | `epf_reclaim` (assessment, pins, forecast, account lock/unlock, compaction in place with room making, restore path, adoption of leftovers), `run/reclaim.sql`; reclaim state in `status`; wrapper action `reclaim`. Built in 0.7.0; LONG conversion later (D14). | Lab tests T18A-T18G, then set R on a real copy. |
| 6. Report (reclaim part) | Reclaim sections, checks R1-R9, manifest. Built in 0.7.0. | Reclaim runs self-verify. |
| 7. Hardening | Production-sized clone run, tuning of settings defaults, `tools/` diagnostics, removal of superseded files. | Acceptance 12.3. |
| 8. Linux wrapper | `bin/epf_purge.sh` (bash; same CLI, prompts, live view, run folder, exit codes). | Same run on Linux produces the same report and manifest. |
| 9. Docs | Deferred; you write them once the tool is proven. | - |

Each phase is one reviewable pull request on this branch lineage.

---

## 14. What is removed, and where everything goes

| Current | Fate |
|---------|------|
| `bin/epf_purge.bat` (1,668 lines) | Replaced by launcher + `bin/lib/epf.ps1` |
| `bin/epf_monitor.ps1` | Replaced by the in-console live view (8.1) |
| `sql/01_create_purge_log_table.sql` | `sql/install/tables.sql` (new data model) |
| `sql/02_/03_epf_purge_pkg_*` | `epf_purge`, `epf_space`, `epf_report`, `epf_log` packages |
| `sql/04_drop_epf_purge_pkg.sql` | `sql/install/uninstall.sql` |
| `sql/05_reclaim_tablespace.sql` | `epf_reclaim` package |
| `sql/05a_shrink_tables.sql` | Measurement always (6.6); opt-in compaction of purged tables only (6.7) |
| `sql/06_optimize_db.sql` | Removed (D5) |
| `sql/06b/06c_*_purge_indexes.sql` | Temporary supporting indexes inside `epf_purge` (6.4) |
| `sql/12_capture_module_sizes.sql` | `epf_space` + preflight |
| `utility/07_diagnostic_queries.sql` | Split into preflight checks and `tools/run_history.sql` |
| `utility/08_undo_tune.sql` | Removed (D5) |
| `utility/09_space_compare.sql`, `10_table_size_audit.sql`, `11_show_module_sizes.sql` | Report section 3 |
| `utility/13_dump_run_log.sql` | `report` / `status` actions, `tools/run_history.sql` |
| `utility/14_recover_indexes.sql`, `17_reclaim_recovery.sql` | Built-in restore path and `reclaim --restore` (7.8) |
| `utility/15_segment_map.sql` | `tools/segment_map.sql` (per-file) |
| `utility/16_fk_coverage_scan.sql` | `epf_registry.validate` + `tools/fk_coverage.sql` |
| Tables `EPF_PURGE_LOG`, `EPF_PURGE_SPACE_SNAPSHOT`, `EPF_DDL_BACKUP`, type `EPF_NUMBER_TAB`, package `EPF_PURGE_PKG`, their `IDX_EPF_*` indexes, `EPF_TMP_*` indexes, directory `EPF_REDO_CLEANUP`, tablespace `EPF_SCRATCH` | Replaced by section 5 tables; `install.sql` offers to remove the old objects (after checking that no reclaim is incomplete). They are identified by exact name only, never by the `EPF` prefix: the application owns `EPF_*` packages in OPPAYMENTS (12.4). |
| Flags `--reclaim-only`, `--reclaim-online`, `--reclaim-online-only`, `--max-iterations`, `--no-stall-check`, `--allow-offline-index-rebuild`, `--show-sizes`, `--optimize-db`, `--drop-pkg`, `--drop-logs`, `--truncate-logs`, `--sys-password`, `--user`, `--password` | Removed (D12); replaced by actions and the options in 10.1. Mode `CLOB_ONLY` is renamed `CLOB`. |

---

## 15. Design decisions

| ID | Decision | Answer |
|----|----------|--------|
| D1 | Where the tool's objects live | Dedicated tool schema `EPFPG` |
| D2 | Index/constraint handling during reclaim | Indexes UNUSABLE -> REBUILD; constraints never dropped |
| D3 | Reclaim strategy | Compaction in place (revised 2026-10-06; was a tablespace swap): in each target tablespace, the table holding the highest block of a datafile moves within the tablespace into the free space below, tables with free space inside them first when it does not fit; the file is resized down after every move; datafiles frozen and never above their start size plus `reclaim_growth_mb`; segments that cannot move are pins, named. Targets detected, never assumed to be DATA. Reasons in 7.1 |
| D4 | Wrapper runtime | `.bat` launcher + Windows PowerShell 5.1; bash `.sh` in phase 8 |
| D5 | Database-level operations | Only temporary supporting indexes for the purge; everything else removed; all kept operations work in a PDB. Revised by D17 (opt-in redo log sizing) and D18 (opt-in undo tuning, restored). |
| D6 | Purge modes | FULL, CLOB (renamed from CLOB_ONLY), LOGS (new: delete the log tables only), CLOB_N_LOGS |
| D7 | Showing the effect of a purge | Always measure space inside segments; compaction opt-in (purge-only runs) |
| D8 | `file_dispatching` rows without children | Purge them too |
| D9 | Redo during reclaim | Always LOGGING; preflight blocks if the recovery area cannot hold the estimated redo |
| D10 | Application activity at reclaim start | Show owners and sessions at startup for confirmation; at reclaim start lock accounts and disconnect sessions; always restore account status at the end |
| D11 | Console layout | Single console: event stream + heartbeat |
| D12 | Old CLI flags | Clean CLI, no aliases |
| D13 | Reclaim credentials | SYS, asked at startup only when reclaim is selected; purge never needs SYS; all input at the beginning |
| D14 | LONG / LONG RAW columns | Convert to CLOB/BLOB with per-item approval at startup; a skipped item stays where it is (a pin) with a recommended manual path; every conversion reported with original and new type. Not built yet: until then a table with a LONG column is a pin (7.10) |
| D15 | Accounts locked and disconnected at reclaim start | Owners of objects in the target tablespaces, plus accounts with INSERT/UPDATE/DELETE on those objects (direct or through a role), plus accounts with sessions using them; listed with the reason at startup (7.7). In place (0.7.0): the tables that move and those whose indexes are released, and also the owners of foreign keys to them |
| D16 | Kept rows that reference rows being purged (cross-references, ON DELETE CASCADE, shared audit archives) | Hold back: the referenced rows and the whole root they belong to stay until a later run; counted and reported with the referencing table; the run never fails on it and nothing newer than the cutoff is deleted (6.1.1) |
| D17 | Online redo logs too small for the purge (log file switch (checkpoint incomplete)) | Opt-in: `epf_tuning.enlarge_redo` (SYS, `run/redo_logs.sql`, later a wizard option) replaces undersized groups, default 4 x 1 GB, like the previous tool; permanent, reported, not reverted. Preflight always reports the online logs, the redo per batch (measured by earlier runs, otherwise estimated) and a recommended batch size (6.8) |
| D18 | Undo growth during a purge | Opt-in: `epf_tuning.undo_apply` (SYS, `run/undo.sql APPLY`) lowers `undo_retention` to 60 s (SCOPE=MEMORY) and limits the growth of the undo datafiles to the largest of their current size, 4 GB (`undo_cap_mb`) and 4 x the undo of one batch, for the purge; nothing is shrunk (revised 2026-09-30 after retention alone let UNDOTBS1 grow to 27.6 GB). `undo_restore` puts back the recorded original values (`EPF_INSTANCE_CHANGE`), on every exit path of the wrapper; the end-to-end suite checks the original growth limits after every run. Preflight reports undo size, undo per batch and the undo kept by retention at the measured rate (6.9). Side effect while applied: long queries of other sessions can hit ORA-01555 |
| D19 | Requirements before a purge, and how the purge follows the preflight | The preflight measures six requirements (ARCHIVE, UNDO, TEMP, INDEX_SPACE, REDO_LOGS, BACKUP), each with its reason and the ways to meet it. The user's choices and a purge plan (smaller runs by retention steps and modules) are stored with the preflight run in the database. `purge` runs the next step of the latest valid preflight (8 h) with its choices, and measures the space requirements again at start. The tool never changes the log mode. Backup can be met by a detected RMAN backup, a confirmed backup made another way, or a confirmed purge without a backup (6.10). Decided 2026-10-02 |
| D20 | Dry run | A simulation of the plan: exact counts, forecasts of time, redo, undo and space, a retention table and a predicted outcome (WOULD COMPLETE, or WOULD FAIL with where and why). It counts as a preflight (6.10). Decided 2026-10-02 |

Also settled:

- Application schemas default to `OP, OPPAYMENTS, OPREPORTS`; target tablespaces are the ones they occupy, detected from their segments and never assumed by name; every owner inside a target is inventoried and moved (7.4).
- Tool tablespace: `EPFPG_DATA`, created by the installer next to the datafile of the tablespace OPPAYMENTS uses (section 5); the installer takes only the EPFPG password.
- Datafiles keep their paths and names: the reclaim only resizes them (D3 revised).
- Run history is kept 180 days (setting).
- Row counts for the reclaim: `COUNT(*)` once the accounts are locked and again before they are unlocked (setting `reclaim_row_counts`).

## 16. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| An Oracle behavior differs on your version (e.g., V1) | Phase 0 verifies before anything is built on it; fallbacks noted per item. |
| Registry-driven engine deletes differently from the current hand-written code | Phase 2 parity test against the current tool on a clone; registry reproduces today's links and order exactly. |
| Reclaim takes longer than a maintenance window | Assessment first (forecast, what moves); a stop request ends between tables with everything restored; a later reclaim continues from the current layout. |
| Recovery area / disk pressure | Archive requirement in ARCHIVELOG; datafiles frozen and never above their start size (G4); resumable index rebuilds once the growth settings are restored. |
| Application writes during reclaim | Accounts locked and sessions disconnected (D10); unusable unique indexes make any remaining write fail instead of corrupting. |
| Accounts left locked after a crash | The wrapper restores in the same run; otherwise the next reclaim or `reclaim --restore` restores accounts recorded in `EPF_ACCOUNT_ACTION` before anything else; `status` lists them; history pruning keeps their records; uninstall refuses meanwhile. |
| LONG conversion changes an application contract | Per-item approval with dependents shown; irreversible nature stated; every conversion reported. |
| Client objects of an unsupported kind in a target tablespace | Classified as pins with their reason; the file stops shrinking at the highest one, which the report names (R7). |
| The table at the top does not fit in the free space below | Room making with the tables that have free space inside them (purged tables) first; then `reclaim_growth_mb`; otherwise MOVE_NO_ROOM names it and the file stops there (R8 WARN). |
| Oracle places a moved copy high instead of low | V11; no free space is left at the top of a file while the run compacts (trimmed to the end of its highest extent); a copy that comes back to the top moves again with 64 MB extents (segments of about 51 MB or more), which take only wholly free stretches (the lowest first), after the tables with free space inside them have moved; a table moves again only when it fits below as it is, and stops after its copy held the top again `reclaim_unit_moves` times (10 moves at most); FILE_DONE names where each file stopped. |
| A moved or rebuilt segment takes its INITIAL at once (set R: AUDIT_ARCHIVE, 3.6 MB of data, came back as 783 MB) | INITIAL larger than needed is set to 64 KB by the move or rebuild (INITIAL_RESET); lab: RT_FAT with INITIAL 40 MB. |
| Another database has another layout (several datafiles, uniform extents, separate index or LOB tablespaces, queues) | The engine handles each per datafile and per tablespace; lab 2 (T18G) runs each on Oracle; a new source starts with the dry run, which names the pins, the oversized INITIALs, the accounts and the requirements before anything changes. |
| An owner has a limited space quota | Requirement QUOTA: without a quota, or above it, the compaction does not start (an index that could not be rebuilt would stay unusable); within it, a table larger than the room stays where it is (MOVE_NO_QUOTA). |
| Tool-schema privileges considered too broad by security | EPFPG holds only purge/report rights (3.4); DBA-level work runs only as SYS, supplied per run. |
| Two wrapper implementations drift (bat/ps1 vs sh) | Logic in the database; wrappers only render events; phase 8 compares manifests from both. |

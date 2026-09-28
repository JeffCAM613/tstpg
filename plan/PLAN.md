# EPF Data Purge - Rebuild Plan

| | |
|---|---|
| Status | Draft 1 - design decisions D1-D12 pending (section 15). Recommended options are applied throughout; alternatives are noted where they change the design. |
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
| G4 | Reclaim never makes things worse | Per datafile: size after <= size before, HWM after <= HWM before. Enforced as an invariant at every checkpoint, not only at the end. |
| G5 | Reclaim reaches the achievable minimum | Final datafile size <= achievable size + max(1 %, 256 MB), where achievable = in-scope segment bytes + position of non-movable anchors. Anything short of that is explained (named anchors). |
| G6 | Zero schema drift | After reclaim: same indexes (all VALID/USABLE, same tablespace, same degree/logging), same constraints (same status/validated flags), no new invalid objects, row counts unchanged. |
| G7 | Always recoverable | Any interruption (error, kill, instance restart) leaves a state that the next `reclaim` run detects and finishes automatically. No separate recovery scripts. |
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
2. **One run, one run_id.** The wrapper creates the run first (`epf_run.start`) and passes the id explicitly to every step and to the monitor. Nothing is discovered by timestamp.
3. **The data dictionary is the source of truth for reclaim state.** The journal records intent; every step recomputes remaining work from the dictionary, so every step is idempotent and resumable.
4. **Integrity is never weakened.** Constraints are never dropped (D2).
5. **Structured facts.** Every number displayed or checked comes from a typed column (`rows_affected`, `bytes`, `pct`), never from message text.
6. **One place per fact.** Tables, modules, relationships, tunables live in registry/settings tables seeded by one install file.
7. **Tool objects never live in a tablespace being reclaimed** (removes the "relocate log tables" step and its anchor problems).
8. **Fail loud.** Any ERROR event makes the run FAILED (or WARNING for tolerated conditions) and produces a non-zero exit code.
9. **No silent instance changes.** Anything the tool changes outside the application schemas (file autoextend, parallel degree, logging) is recorded first and restored to the recorded value.

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
 +--------------------------- EPF_ADMIN schema (D1) ------------------------------+
 | packages : epf_util  epf_log  epf_run  epf_registry  epf_space                 |
 |            epf_purge  epf_reclaim  epf_report                                  |
 | tables   : EPF_SETTING EPF_MODULE EPF_TABLE EPF_LINK                           |
 |            EPF_RUN EPF_STEP EPF_EVENT EPF_WORK_KEY EPF_TABLE_STAT              |
 |            EPF_SEGMENT_SNAP EPF_FILE_SNAP EPF_OBJECT_BASELINE                  |
 |            EPF_RECLAIM_OBJECT EPF_TEMP_INDEX                                   |
 +--------------------------------------------------------------------------------+
          | DELETE / UPDATE (object grants)       | MOVE / REBUILD / RESIZE (system privileges)
          v                                       v
   OPPAYMENTS, OP tables                 data + index tablespaces, EPF_SCRATCH
```

### 3.3 Run lifecycle

```
START (epf_run.start -> run_id)
  PREFLIGHT         read-only checks, forecasts, blockers            (always)
  PURGE             SNAPSHOT_KEYS -> PROCESS_BATCHES -> TABLE_STATS   (purge actions)
  RECLAIM           BASELINE -> PREPARE -> RELEASE_INDEXES -> DRAIN -> COMPACT
                    -> REFILL -> REBUILD_INDEXES -> FINAL_RESIZE -> CLEANUP -> VERIFY
  REPORT            integrity + results + verdict                     (always)
END (status, verdict, exit code)
```

Each named step is a row in `EPF_STEP` (status PENDING/RUNNING/DONE/FAILED/SKIPPED) and emits `STEP_START` / `STEP_END` events. The console shows the step list as a checklist.

### 3.4 Privileges (with D1 = dedicated tool schema)

Installed once by a DBA (`sql/install/install.sql`, run as SYS). Runtime needs only the tool schema password - no SYS at runtime.

| Grant | Why |
|-------|-----|
| `CREATE SESSION`, `CREATE TABLE`, `CREATE PROCEDURE`, quota on its own tablespace | own objects |
| `SELECT, DELETE` on every registry table; `UPDATE` on tables with `lob_clear = Y` | purge (generated from the registry at install) |
| `ALTER ANY TABLE`, `ALTER ANY INDEX`, `CREATE ANY INDEX`, `DROP ANY INDEX` | MOVE, UNUSABLE/REBUILD, temporary supporting indexes |
| `ALTER DATABASE`, `ALTER TABLESPACE` | datafile resize / autoextend, scratch datafile management |
| direct `SELECT` on `DBA_SEGMENTS`, `DBA_EXTENTS`, `DBA_FREE_SPACE`, `DBA_DATA_FILES`, `DBA_TABLESPACES`, `DBA_TABLES`, `DBA_TAB_PARTITIONS`, `DBA_TAB_SUBPARTITIONS`, `DBA_INDEXES`, `DBA_IND_PARTITIONS`, `DBA_CONSTRAINTS`, `DBA_CONS_COLUMNS`, `DBA_LOBS`, `DBA_LOB_PARTITIONS`, `DBA_TAB_COLUMNS`, `DBA_OBJECTS`, `DBA_RECYCLEBIN`, `DBA_MVIEWS`, `DBA_RESUMABLE`, `V_$SESSION`, `V_$SESSION_LONGOPS`, `V_$LOCKED_OBJECT`, `V_$TRANSACTION`, `V_$DATABASE`, `V_$INSTANCE`, `V_$PARAMETER`, `V_$RECOVERY_FILE_DEST`, `V_$LOG` | definer-rights PL/SQL cannot use roles, so grants are direct |
| `SELECT` on every table of the scope schemas (refreshed by re-running `install`; preflight reports tables without the grant) | baseline row counts, eligibility counts |

`EPF_SCRATCH` is created **at install** (64 MB, autoextend) and quotas for the scoped schemas are granted there once. Runtime only grows, shrinks, adds or drops *datafiles* of it. This avoids giving the tool `ALTER USER` (which can change any password) or `CREATE/DROP TABLESPACE`.

If D1 = "keep in OPPAYMENTS": tool tables are created with an explicit non-data tablespace; purge/report packages live in OPPAYMENTS; the reclaim stays a SYS-run script set (`sql/run/reclaim_*.sql`, one idempotent anonymous block per step, orchestrated step by step by the wrapper) because SYS must not execute code owned by the application schema (S-02).

---

## 4. Repository layout and SQL organization rules

### 4.1 Layout

```
bin/
  epf_purge.bat              launcher only (~20 lines): finds PowerShell, forwards arguments, returns exit code
  epf_purge.sh               final phase: bash equivalent of launcher + wrapper
  lib/
    epf.ps1                  wrapper implementation (CLI, config, wizard, credentials, runner, live view, files)
config/
  epf_purge.conf.example     all keys documented; real epf_purge.conf is git-ignored
sql/
  install/
    install.sql              master installer (SYS): tool schema, grants, EPF_SCRATCH, then every file below in order
    uninstall.sql            removes tool schema and EPF_SCRATCH (refuses if a reclaim is in progress)
    tables.sql               every EPF_* table; idempotent create + column-level upgrades
    registry_data.sql        MERGE of modules, tables, links, settings - the only place table lists exist
    grants.sql               object grants generated from the registry
    epf_util.pks / .pkb      formatting, elapsed time, dictionary helpers
    epf_log.pks / .pkb       events, steps, heartbeat (module/action/client_info)
    epf_run.pks / .pkb       run lifecycle, stop requests, status
    epf_registry.pks / .pkb  registry access and validation against the FK graph
    epf_space.pks / .pkb     segment/file snapshots, per-file HWM, resize helper
    epf_purge.pks / .pkb     purge engine
    epf_reclaim.pks / .pkb   reclaim engine
    epf_report.pks / .pkb    integrity and results report
  run/                       one entry script per action; the wrapper calls only these
    start_run.sql  preflight.sql  purge.sql  reclaim.sql  report.sql  status.sql  stop.sql  poll.sql
  tools/                     read-only diagnostics (no DML, no DDL)
    segment_map.sql          physical layout / HWM anchors per datafile
    fk_coverage.sql          FK graph vs registry (coverage gaps)
    run_history.sql          last N runs with status and verdict
tests/
  fixtures/                  synthetic scope schema + data generator for a test database
  scenarios/                 reclaim layouts and fault-injection scripts (section 12)
logs/                        git-ignored; one folder per run
plan/
  PLAN.md
.gitattributes               CRLF for .bat/.ps1, LF for .sh/.sql/.md
.gitignore                   logs/, config/epf_purge.conf
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

All tables live in the tool schema, in a tablespace that is never reclaimed.

| Table | Purpose | Key columns |
|-------|---------|-------------|
| `EPF_SETTING` | Tunables with defaults (batch size, progress interval, LOB throttle, ddl_lock_timeout, resize margin, parallel threshold, history retention days, scope schemas) | `name`, `value`, `description` |
| `EPF_MODULE` | PAYMENTS, LOGS, BANK_STATEMENTS | `module_code`, `display_order`, `description` |
| `EPF_TABLE` | Every in-scope table | `table_id`, `module_code`, `owner`, `table_name`, `role` (ROOT/DEPENDENT), `key_column`, `date_column` (roots), `delete_order`, `lob_clear` Y/N, `active` Y/N |
| `EPF_LINK` | How a dependent table's keys derive from another table's keys | `link_id`, `table_id`, `match_column`, `source_table_id`, `source_column` |
| `EPF_RUN` | One row per run | `run_id`, `action`, `status`, `verdict`, `retention_days`, `cutoff_date`, `depth`, `mode`, `batch_size`, `dry_run`, `with_reclaim`, `started_at`, `ended_at`, `stop_requested`, `db_name`, `host`, `os_user`, `exit_code` |
| `EPF_STEP` | Step checklist / state | `run_id`, `step_seq`, `phase`, `step_code`, `status`, `started_at`, `ended_at`, `units_done`, `units_total`, `bytes_done`, `bytes_total` |
| `EPF_EVENT` | Event stream (replaces `epf_purge_log`) | `event_id` (identity), `run_id`, `ts`, `phase`, `step_code`, `severity` (INFO/OK/WARN/ERROR/PROGRESS), `event_code`, `object_owner`, `object_name`, `rows_affected`, `bytes`, `pct`, `elapsed_s`, `ora_code`, `message` |
| `EPF_WORK_KEY` | Key snapshot per run/table/batch | `run_id`, `table_id`, `batch_no`, `key_num`, `key_rowid`; index (`run_id`, `table_id`, `batch_no`) |
| `EPF_TABLE_STAT` | Per-table counts per phase | `run_id`, `table_id`, `phase`, `total_rows`, `eligible_rows`, `retained_rows`, `nonempty_lob_rows`, `processed_rows`, `orphan_rows` |
| `EPF_SEGMENT_SNAP` | Segment sizes per phase (BASELINE, POST_PURGE, POST_RECLAIM) | `run_id`, `phase`, `owner`, `segment_name`, `partition_name`, `segment_type`, `parent_owner`, `parent_table`, `tablespace_name`, `bytes`, `module_code` |
| `EPF_FILE_SNAP` | Datafile geometry per phase | `run_id`, `phase`, `tablespace_name`, `file_id`, `file_name`, `bytes`, `hwm_bytes`, `free_bytes`, `autoextensible`, `increment_by`, `maxbytes` |
| `EPF_OBJECT_BASELINE` | Reclaim fingerprint (indexes, constraints, invalid objects, row counts) | `run_id`, `object_type`, `owner`, `name`, `table_name`, `tablespace_name`, `status`, `validated`, `degree`, `logging`, `row_count` |
| `EPF_RECLAIM_OBJECT` | Reclaim journal per segment | `run_id`, `owner`, `table_name`, `partition_name`, `lob_column`, `original_ts`, `current_ts`, `bytes`, `drain_status`, `refill_status`, `attempts`, `last_ora`, timestamps |
| `EPF_TEMP_INDEX` | Temporary supporting indexes created by a run | `run_id`, `owner`, `index_name`, `table_name`, `column_name`, `created_at`, `dropped_at` |

History older than `history_retention_days` (default 180) is pruned at run start.

Registry content (seeded by `registry_data.sql`) reproduces today's scope exactly: 27 tables, 3 modules, and these links (dependent.column <- source.column):

| Module | Root (date) | Dependents |
|--------|-------------|------------|
| PAYMENTS | `bulk_payment.value_date` | `bulk_payment_additional_info`, `bulk_signature`, `mandatory_signers`, `oidc_request_token`, `payment_audit`, `transmission_execution_audit`, `notification_execution`, `import_audit`, `transmission_execution`, `transmission_exception`, `workflow_execution_opt`, `payment` <- `bulk_payment.bulk_payment_id`; `import_audit_messages.import_audit_id` <- `import_audit`; `approbation_execution_opt.execution_id` <- `workflow_execution_opt`; `workflow_execution`, `payment_audit`, `bulkpayment_exception`, `invoice`, `payment_additional_info` <- `payment.payment_id`; `approbation_execution.execution_id` <- `workflow_execution`; `invoice_additional_info.invoice_id` <- `invoice` |
| PAYMENTS | `file_integration.integration_date` | none |
| LOGS | `audit_trail.audit_timestamp` | `audit_archive.audit_archive_id` <- `audit_trail.audit_archive_id` |
| LOGS | `op.spec_trt_log.dtlog` | none |
| BANK_STATEMENTS | `file_dispatching.date_reception` | `directory_dispatching.file_dispatching_id` <- `file_dispatching` |

`delete_order` reproduces today's order (leaves first, roots last). At preflight `epf_registry.validate` checks it against the live FK graph: an FK from a registered table that would be violated by the order is a FAIL; an FK from an *unregistered* table into a registered one is a coverage-gap WARN (this replaces utility 16).

---

## 6. Purge engine design

Fixes F-01..F-06, F-08, P-01..P-04.

### 6.1 Flow per module

1. **Key snapshot.** Root keys older than the cutoff are inserted once into `EPF_WORK_KEY`, ordered by key and numbered into batches (`CEIL(ROWNUM / batch_size)`); single-table roots with no dependents snapshot `ROWID`s in physical order instead. One commit. Consequences:
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

### 6.2 Modes

| Mode | PAYMENTS / BANK_STATEMENTS | LOGS |
|------|----------------------------|------|
| FULL | delete | delete |
| CLOB_ONLY | set LOB columns to `EMPTY_CLOB()` / `EMPTY_BLOB()` where length > 0 (tables with `lob_clear = Y`, LOB columns discovered from the dictionary) | same as left |
| CLOB_N_LOGS | as CLOB_ONLY | delete |

Counters are per table and per mode, so reporting is exact (F-04). The LOB throttle (`lob_throttle_ms`, default 500) between LOB batches is kept as a setting (workaround for the dw00 space-management crash on unpatched 19c). Final list of modes depends on D6.

### 6.3 Errors, stop and re-run

- A failing batch is rolled back, an ERROR event records the ORA code and the batch number, and that module stops (order within a module matters). Independent modules continue. The run ends FAILED (F-02).
- `epf_purge.bat stop` sets `stop_requested`; the engine stops after the current batch; run status STOPPED; the report shows the expected residuals.
- Re-running a purge is idempotent (a new key snapshot of what is still eligible).

### 6.4 Supporting indexes and statistics (per D5)

- Preflight lists missing indexes on every link `match_column` and root `date_column` (P-03). The purge creates the missing ones as `EPF_TMP_<n>` (tracked in `EPF_TEMP_INDEX`) and drops them at the end of the purge; any left over from an interrupted run are dropped at the next run start.
- Optional statistics gathering is limited to registry tables (not the whole schema).

### 6.5 Session instrumentation

Every worker session sets `DBMS_APPLICATION_INFO` (module `EPF`, action = current step, client_info `run=<id>`) and `DBMS_SESSION.SET_IDENTIFIER('EPF:<id>')`. The monitor uses this to find the worker in `V$SESSION` (section 8.3).

Progress events are time-throttled: first batch, last batch, and at most one per `progress_interval_s` (default 5 s) per module (P-04).

---

## 7. Space reclaim engine design (deep dive)

This is the part that currently gets stuck, stops half way and sometimes grows the HWM. The redesign attacks each root cause from 2.2 and adds invariants so the tool can never silently make things worse.

### 7.1 What really limits a datafile shrink

A datafile can only be resized down to the highest allocated block **in that file**. `SHRINK SPACE` compacts rows inside a segment but cannot relocate the segment's extents, so a segment sitting at the end of the file pins the size no matter how empty it is. The only deterministic way to pack a tablespace is to **rebuild segments into empty space from the bottom up** - which is what drain/refill does. The current script has the right idea; it fails on the details listed in R-01..R-15.

### 7.2 Symptom -> cause -> fix

| Symptom | Root cause(s) | Fix in the new engine |
|---------|---------------|-----------------------|
| Gets stuck | R-07 slow dictionary queries in loops; R-08 lock/library-cache waits; R-09 archiver stuck; R-13 LOB shrink; L-02/L-04 no visibility | Per-file HWM from `DBA_FREE_SPACE` (fallback `DBA_EXTENTS` per file) computed only at checkpoints; preflight blocks on connected app sessions / active transactions; `ddl_lock_timeout` + bounded retries; redo forecast vs recovery-area headroom; post-purge shrink removed (D7); heartbeat with wait event, blocker and longops % |
| Doesn't rearrange fully | R-01 first file only; R-02 partitions/IOTs/LOB partitions not moved; R-10 disk full mid-drain; R-12 recycle bin; R-14 resize gives up | Per-file geometry everywhere; partition-level and IOT moves; peak-disk forecast + configurable scratch location; recycle-bin segments reported up front with the purge command (treated as anchors until purged); binary-search resize |
| HWM increases | R-03 LOBs relocated to the data TS; R-05 parallel index builds; R-06 autoextend forced; segments moved within the same tablespace when drain failed | Every segment returns to its **original** tablespace; serial rebuild below a size threshold; autoextend recorded and restored; invariant check "HWM must not rise" at every checkpoint |
| Inconsistent results between runs | R-04 drop/recreate from DDL; R-15 separate recovery scripts; heuristics on run_id | Constraints never dropped; indexes UNUSABLE + REBUILD; single state machine with built-in resume; explicit run_id |

### 7.3 Index and constraint strategy (D2, recommended)

Instead of capturing DDL and dropping PK/UK/FK constraints and indexes:

1. Mark every index on in-scope tables `UNUSABLE`. Since 11.2 this **drops the index segment** (space is freed immediately) while the index and its constraint stay defined.
2. Move the tables (drain, then refill). A table move would make its indexes unusable anyway, so no work is lost.
3. `ALTER INDEX ... REBUILD TABLESPACE <original>` for each unusable index, then restore its recorded degree and logging attribute.

Why this is safer:

- PK/UK/FK constraints are never dropped. There is nothing to capture, back up or replay; the `EPF_DDL_BACKUP` table and the two recovery scripts disappear.
- While a unique index is unusable, DML on that table fails with ORA-01502. The quiesced window is *enforced* (writes fail loudly) instead of *assumed* (writes accepted without uniqueness checks).
- Recovery from any failure is "rebuild whatever is UNUSABLE" - discoverable from `DBA_INDEXES`, always idempotent.
- Reads keep working throughout (full scans).

This behavior is verified in phase 0 on your target version (V1, V2 in 12.3).

### 7.4 Scope detection

- Scope schemas: setting `scope_schemas` (default `OPPAYMENTS,OP`).
- Scoped tablespaces: every permanent tablespace holding segments of the scope schemas, excluding SYSTEM, SYSAUX, UNDO and TEMP; overridable with `--tablespaces`. Data and index tablespaces are both handled; there is no "primary data file".
- Movable units: non-partitioned tables, table partitions and subpartitions, IOTs (with overflow), and all their LOB / LOB-partition segments. Each unit's **original tablespace is recorded per segment** (table and each LOB separately).
- Non-movable units (reported as anchors with their top position): tables with LONG/LONG RAW columns, clustered tables, object/nested tables, queue tables, domain-index storage, and any segment owned by a schema outside the scope ("foreign tenants").

### 7.5 Preflight (read-only; FAIL blocks the reclaim, WARN needs confirmation)

| Check | FAIL when | Output |
|-------|-----------|--------|
| Version / edition / privileges | unsupported version or missing privilege | features enabled (parallel DDL on EE only) |
| Interrupted reclaim | journal or dictionary shows work in progress | offer resume (7.8) |
| Pre-existing damage | UNUSABLE indexes or disabled constraints not caused by the tool | list; they are included in the baseline so they are not "fixed" silently |
| Application activity | sessions connected as scope schemas (other than the tool), active transactions or locks on scoped tables, running scheduler jobs owned by them | who, from where, program (D10) |
| Geometry | - | per tablespace and file: size, HWM, used, free, autoextend settings |
| Anchors | - | foreign / non-movable segments with top position; resulting **floor** per file |
| Recycle bin | - | WARN: dropped objects in scoped tablespaces, with the `PURGE` command for the DBA; they are anchors until purged (the tool never purges them, since that removes the ability to flash back a dropped table) |
| Redo | ARCHIVELOG and estimated redo > recovery-area headroom (unless D9 = NOLOGGING allowed and not FORCE LOGGING) | estimated redo, FRA free, log_mode, force_logging |
| Disk forecast | - | simulated peak extra disk (7.6) and projected final size per file |
| Materialized views WITH ROWID on scoped tables | - | WARN: they need a complete refresh after the moves |
| Dictionary speed | - | time of one HWM query; WARN with advice if slow |

Result: a **reclaim forecast** block (current size, projected final size, reclaimable GB, peak extra disk, anchors) that the wizard shows before confirmation.

### 7.6 Algorithm (in-place drain -> refill, D3 recommended)

| Step | What happens | Invariants / notes |
|------|--------------|--------------------|
| BASELINE | Record fingerprint: indexes (status, tablespace, degree, logging), constraints (status, validated), invalid objects, row count per table via PK index fast full scan (full scan if no PK), segment + file snapshots. | Basis of the VERIFY step and the report. |
| PREPARE | Session: `ddl_lock_timeout`, resumable space allocation with a timeout (a space error suspends and shows as `SUSPENDED` in the live view instead of failing). Record autoextend settings of every scoped datafile. Grow `EPF_SCRATCH` or add a datafile at `--scratch-dir` if given. | Nothing is dropped. |
| RELEASE_INDEXES | `ALTER INDEX ... UNUSABLE` for every index on movable units. Resize every scoped *index* tablespace file to its HWM immediately. | Index space is back on disk before any data moves, lowering peak disk. |
| DRAIN | Move units from each data tablespace to `EPF_SCRATCH`, ordered by top block **per file**, descending. After each unit (or every `resize_every_mb` moved) resize the affected file(s) to their HWM + margin. | Per-file HWM must never rise (it can only fall, since units only leave). A rise stops the step with ERROR. |
| COMPACT | Every scoped data file now holds only anchors. Resize each to HWM + margin. Enable autoextend with the original `MAXSIZE` and an `increment_by` of 256 MB while refilling. | Floor reached = anchors only. |
| REFILL | Move units back to their **original** tablespace, ordered by top block in `EPF_SCRATCH` descending, so scratch can shrink as it empties. The target files are empty above the anchors, so segments pack from the bottom. | After each checkpoint: file HWM <= anchor floor + bytes refilled + tolerance, otherwise WARN with the fragmentation detail. |
| REBUILD_INDEXES | `REBUILD TABLESPACE <original>` for every unusable index, largest first. Serial below `parallel_min_mb` (default 1024 MB); above it, parallel on EE only; then restore recorded degree/logging. | Serial by default avoids PX extent holes (R-05). |
| FINAL_RESIZE | Resize every scoped file to HWM + margin using binary search between target and current size (a failed RESIZE is cheap; replaces +1 GB x 10). Restore recorded autoextend settings. Shrink `EPF_SCRATCH` to its minimum, drop any added scratch datafile. | File size never above its baseline. |
| CLEANUP | Recompile objects that became invalid during the run (only those - compared to the baseline). Optional UNDO/TEMP datafile resize (resize only, never swap; per D5). | |
| VERIFY | Compare with BASELINE: every index VALID/USABLE in its original tablespace with original degree/logging; constraints identical; no new invalid objects; row counts identical; nothing left in scratch; per-file size and HWM <= baseline. | Any mismatch = FAIL with the exact object list. |

The engine logs the reason for every unit it does not move (anchor type, lock timeout, error), so "didn't rearrange fully" is always explained by name.

**Peak disk simulation.** Before running, the preflight replays DRAIN on the extent map: after moving unit *k*, file size = top of the highest remaining unit, scratch = sum of moved units. The maximum over *k* is the peak extra disk. Refill is estimated the same way on the scratch side. This number is shown in the forecast; with `--scratch-dir` the scratch share can go to another disk.

**Alternative (D3 = "move once and swap").** Move units once into a new tablespace, drop the old one, rename the new one to the old name. Half the data movement; but datafile paths change, quotas must be re-granted, and it is impossible when foreign tenants share the tablespace (falls back to drain/refill). Only the DRAIN/COMPACT/REFILL rows above change.

### 7.7 Lock, wait and space handling

- `ddl_lock_timeout` (setting, default 30 s) on every DDL; ORA-00054 is retried `ddl_retries` times (default 3, backoff 30/60/120 s). A unit that still cannot be locked is skipped in DRAIN (it stays in place as an anchor, reported), and retried until success in REFILL (a unit must never be left in scratch; the step pauses with a clear message and the live view shows the blocker).
- Resumable space allocation (setting `resumable_timeout_s`, default 1800): a full disk suspends the statement, the live view shows `SUSPENDED: unable to extend EPF_SCRATCH by 1024 MB`; adding space lets it continue by itself.
- The live view always shows the wait event and the blocking session (8.3); the tool never kills sessions.

### 7.8 Interruption, stop and resume

- **Stop request during DRAIN**: the engine switches to the restore path (skip remaining drain, then REFILL -> REBUILD_INDEXES -> FINAL_RESIZE -> CLEANUP -> VERIFY). A stop therefore always ends with every table in its original tablespace and every index usable.
- **Hard interruption** (killed session, lost connection, instance restart): tables are intact (a MOVE is atomic), some units may be in scratch, some indexes unusable (writes fail, reads work). The next `reclaim` detects this from the dictionary + journal and offers **Resume** (continue from the current step) or **Restore** (take the restore path). Non-interactive runs need `--resume` or `--restore`, otherwise they exit with code 3 and a clear message.
- `status` action prints the exact degraded objects at any time.

### 7.9 UNDO/TEMP and instance-level items

Removed from the reclaim: redo log enlargement, `undo_retention` changes, UNDO tablespace swap (R-11). Optional, per D5: resize UNDO/TEMP datafiles to their minimum usable size (resize only). No instance parameter is changed.

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
3. When the worker exits, one final poll drains the remaining events. No sleeps, no timestamp guessing.
4. The worker's exit code (`WHENEVER SQLERROR EXIT FAILURE`) and `EPF_RUN.status` decide what happens next.

Only one process writes the console log file (no file-sharing workarounds, no per-line PowerShell launches).

### 8.2 Console layout (mockup)

```
 EPF Data Purge                                                     run R-000124
 --------------------------------------------------------------------------------
 Database  EPFPROD 19.21 EE on dbsrv01        tool schema EPF_ADMIN
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

 RECLAIM  tablespaces OPPAY_DATA (1 file), OPPAY_IDX (1 file)
 [ OK ] Forecast: 118.0 GB -> ~41.6 GB . peak extra disk 9.8 GB . anchors: none
 11:02:10  RELEASE    214 indexes unusable . OPPAY_IDX 38.2 GB -> 0.3 GB
 11:03:55  DRAIN      [ 41/212] OPPAYMENTS.AUDIT_TRAIL  3.2 GB   DATA 88.4 GB  SCRATCH 22.1 GB
 ..        DRAIN      MOVE OPPAYMENTS.SPEC_TRT_LOG  62% (4m12s left) . direct path write
 [WARN] 11:21:40  DRAIN waiting 45s on enq: TM - contention . blocked by SID 812 APPUSER@appsrv01 (java.exe)
 ...
 [ OK ] VERIFY  indexes 214/214 usable . constraints identical . rows identical . HWM never rose

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
4. **Reclaim verification** (when a reclaim ran): index/constraint/object/row-count parity, anchors, efficiency vs achievable.
5. **Checks and verdict**.

### 9.2 Checks

| ID | Check | PASS | WARN | FAIL |
|----|-------|------|------|------|
| P1 | Residual eligible rows (FULL) / residual non-empty LOBs (CLOB modes) | 0 | - | > 0 (unless run STOPPED: WARN) |
| P2 | Accounting: processed = eligible at start, per table | equal | - | differs |
| P3 | Retention safety: retained rows (newer than cutoff, or linked to retained roots) not reduced | not reduced | - | reduced |
| P4 | Orphans on every registry link (links protected by an enabled validated FK pass by constraint) | 0 | - | > 0 |
| P5 | Errors during the run | none | tolerated warnings | any ERROR event |
| P6 | Temporary supporting indexes dropped | all dropped | - | leftovers |
| R1 | Indexes: same set, all VALID/USABLE, original tablespace, degree, logging | identical | - | any difference |
| R2 | Constraints: same set, same status/validated | identical | - | any difference |
| R3 | Invalid objects: none new | none new | - | new invalid objects |
| R4 | Row counts per table unchanged across reclaim | identical | - | differs |
| R5 | Nothing left in `EPF_SCRATCH`, added scratch files removed | clean | - | segments left |
| R6 | Per file: size and HWM <= baseline; autoextend settings restored | yes | - | no |
| R7 | Efficiency: final size within max(1 %, 256 MB) of achievable | yes | no, anchors named | - |

Verdict: `PASS`, `PASS WITH WARNINGS`, `FAIL`. Exit code follows the verdict.

### 9.3 Output format (mockup, end of report.txt)

```
 CHECKS                                                              run R-000124
 ------------------------------------------------------------------------------------
 P1  Residual eligible rows ................................ PASS   0 in 27 tables
 P2  Processed = eligible at start ......................... PASS   27/27 tables
 P3  Retention safety ...................................... PASS   retained rows unchanged
 P4  Orphans ............................................... PASS   22 links (9 by FK, 13 scanned)
 R1  Indexes identical and usable .......................... PASS   214/214
 R6  Datafiles never grew, HWM never rose .................. PASS   2 files
 R7  Efficiency ............................................ PASS   41.7 GB vs 41.4 GB achievable
 ------------------------------------------------------------------------------------
 VERDICT  PASS

EPF_CHECK|R-000124|P1|PASS|0|residual eligible rows
EPF_CHECK|R-000124|P2|PASS|27/27|processed equals eligible
...
EPF_VERDICT|R-000124|PASS|exit=0
```

---

## 10. CLI, configuration and interaction flow

### 10.1 Command line

```
epf_purge.bat [action] [options]

Actions
  (none)       interactive wizard
  purge        purge; add --reclaim to reclaim afterwards
  reclaim      space reclaim only (detects and offers resume/restore)
  preflight    read-only checks and forecasts; changes nothing
  report       report for a run (default: latest)          --run R-000124
  status       state of the latest/current run, degraded objects if any
  stop         request a graceful stop of the running run
  install      install or upgrade database objects (needs SYS once)
  uninstall    remove database objects (refuses while a reclaim is incomplete)

Options
  --config FILE           configuration file (CLI overrides file values)
  --tns NAME              TNS alias or EZConnect string
  --retention DAYS        default 30
  --depth LIST            ALL | PAYMENTS | LOGS | BANK_STATEMENTS (comma-separated)
  --mode MODE             FULL | CLOB_ONLY | CLOB_N_LOGS (per D6)
  --batch-size N          default 1000
  --dry-run               snapshot and count only
  --reclaim               run reclaim after a successful purge
  --tablespaces LIST      override scoped tablespaces for reclaim
  --scratch-dir PATH      directory for an additional scratch datafile
  --resume | --restore    how to continue an interrupted reclaim (non-interactive)
  --yes                   no confirmation prompt
  --non-interactive       never prompt; missing input is an error (exit 4)
  --log-dir DIR           default .\logs
  --no-color
  --help

Environment
  EPF_PASSWORD            tool schema password
  EPF_SYS_PASSWORD        SYS password (install/uninstall only)
```

Exit codes: `0` PASS, `1` FAIL, `2` PASS WITH WARNINGS, `3` aborted (user, preflight blocker, interrupted reclaim without --resume/--restore), `4` usage/configuration error.

The configuration file uses the same names as the options (`RETENTION_DAYS=30`, `DEPTH=ALL`, ...). Passwords in the file are allowed but discouraged; the file is git-ignored.

### 10.2 Credentials

- Read with a masked prompt or from the environment; never placed in a command line, temp file or child environment (S-01).
- Every `sqlplus` starts as `sqlplus -S -L /nolog`; the wrapper writes `CONNECT user/"password"@tns` to its stdin with echo off.
- Values are cleared from memory at exit.

### 10.3 Interactive flow ("smooth transitions")

All questions come first, then the run proceeds to the end without further input.

1. **Connect**: TNS, password; connection test; version and install check (offers `install` if objects are missing or outdated).
2. **Choose action**: Purge / Purge + reclaim / Reclaim / Preflight only / Report / Status. If an interrupted reclaim exists, the choices are Resume / Restore / Cancel instead.
3. **Purge parameters**, each with its default and a live preview:
   - retention -> shows the cutoff date and eligible roots per module,
   - depth -> shows per-module size and estimated reclaimable space,
   - mode, batch size, dry run.
4. **Reclaim options** (if chosen): scoped tablespaces, scratch location; the reclaim forecast (7.5) and any blockers are shown here.
5. **Review screen**: every parameter, forecasts, warnings, what will change. One confirmation (`Proceed? [y/N]`; destructive actions require typing `yes` unless `--yes`).
6. **Run**: live view (8.2) through to the verdict.

Every prompt validates immediately and re-asks on invalid input, shows `[default]`, and accepts Enter. Supplying an option on the command line skips its prompt.

---

## 11. Code, comment and formatting standards

"Official-only script comments and descriptions" is applied as follows:

1. **Header block** in every file: name, purpose, usage/parameters, privileges required, side effects. Written as reference documentation.
2. **Comments describe what the code does and why, in present tense.** No history, no narration of earlier versions or attempts, no "previously", "old", "legacy", "new", "v2", "fix for", "rework", no author notes or TODOs in delivered code.
3. **No dead code**: no commented-out blocks, no accepted-but-ignored parameters.
4. Every package procedure has a spec comment: purpose, parameters, exceptions raised, events emitted.
5. Error handling: never `WHEN OTHERS THEN NULL`; every handler logs an ERROR/WARN event with ORA code and re-raises or returns a status the caller checks.
6. SQL*Plus entry scripts start with a fixed settings block (`SET ECHO OFF FEEDBACK OFF VERIFY OFF SERVEROUTPUT ON SIZE UNLIMITED`, `WHENEVER SQLERROR EXIT FAILURE ROLLBACK`).
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
| V3 | `MOVE` / `MOVE PARTITION` preserves BASICFILE/SECUREFILE type and LOB settings; LOB tablespaces can be targeted individually. |
| V4 | Per-file HWM from `DBA_FREE_SPACE` equals `DBA_EXTENTS` (with recycle-bin segments accounted for); timing of both on a production-sized dictionary. |
| V5 | Resumable space allocation suspends and resumes; visible in `DBA_RESUMABLE`. |
| V6 | `V$SESSION_LONGOPS` reports progress for MOVE and index REBUILD. |
| V7 | Extent placement when refilling an emptied file (AUTOALLOCATE and UNIFORM). |
| V8 | The tool-schema privilege set performs every reclaim operation without SYS. |

### 12.2 Test matrix

- **Purge parity**: on a clone, current tool vs new engine: identical per-table deleted counts for the same cutoff (plus the D8 difference if chosen).
- **Purge integrity**: P1-P6 PASS; injected orphan and injected newer-than-cutoff rows are detected.
- **Reclaim layouts**: shared data/index tablespace; separate index tablespace; multi-file tablespace; bigfile tablespace; foreign-tenant segment near the top; LONG table; partitioned table with LOB partitions; IOT; BASICFILE and SECUREFILE LOBs; LOB in a separate tablespace; recycle-bin objects; autoextend capped.
- **Fault injection**: kill the worker session in each reclaim step, then `reclaim` -> resume and -> restore; both must end with VERIFY PASS.
- **Concurrency**: an application session holding a row lock on a scoped table during DRAIN and REFILL (lock timeout path, blocker shown).
- **Disk pressure**: scratch limited so drain hits the limit (resumable suspend path, then space added).
- **Stop**: stop requested during purge and during drain.

### 12.3 Acceptance

All of section 1 measured PASS on the matrix, and on one production-sized clone run end-to-end with timings recorded.

---

## 13. Implementation phases

| Phase | Deliverables | Exit criteria |
|-------|--------------|---------------|
| 0. Verify and baseline | Spike scripts for V1-V8; parity baseline from the current tool on a clone; test fixtures generator. | V1-V8 answered; baseline numbers stored. |
| 1. Foundation | Layout, `.gitattributes`/`.gitignore`, `install.sql`/`uninstall.sql`, `tables.sql`, `registry_data.sql`, `grants.sql`, `epf_util`, `epf_log`, `epf_run`, `epf_registry`. | Install/upgrade/uninstall idempotent; registry validation runs. |
| 2. Purge engine | `epf_purge`, `epf_space` snapshots, `run/preflight.sql`, `run/purge.sql`. | Parity with baseline; dry-run exact counts. |
| 3. Report (purge part) | `epf_report` sections 1-3, checks P1-P6, `run/report.sql`. | Purge runs self-verify. |
| 4. Wrapper | `epf_purge.bat` launcher, `lib/epf.ps1`: CLI, config, wizard, credentials, runner, live view, run folder, exit codes. | End-to-end purge from the wizard and non-interactively. |
| 5. Reclaim engine | `epf_reclaim` (preflight checks, forecast, state machine, resume/restore), `run/reclaim.sql`, `run/status.sql`, `run/stop.sql`. | Full test matrix 12.2 for reclaim. |
| 6. Report (reclaim part) | Sections 4-5, checks R1-R7, manifest. | Reclaim runs self-verify. |
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
| `sql/05a_shrink_tables.sql` | Removed (D7) |
| `sql/06_optimize_db.sql` | Redo enlargement removed; stats gathering becomes an option (D5) |
| `sql/06b/06c_*_purge_indexes.sql` | Temporary supporting indexes inside `epf_purge` (6.4) |
| `sql/12_capture_module_sizes.sql` | `epf_space` + preflight |
| `utility/07_diagnostic_queries.sql` | Split into preflight checks and `tools/run_history.sql` |
| `utility/08_undo_tune.sql` | Removed (D5) |
| `utility/09_space_compare.sql`, `10_table_size_audit.sql`, `11_show_module_sizes.sql` | Report section 3 |
| `utility/13_dump_run_log.sql` | `report` / `status` actions, `tools/run_history.sql` |
| `utility/14_recover_indexes.sql`, `17_reclaim_recovery.sql` | Built-in resume/restore (7.8) |
| `utility/15_segment_map.sql` | `tools/segment_map.sql` (per-file) |
| `utility/16_fk_coverage_scan.sql` | `epf_registry.validate` + `tools/fk_coverage.sql` |
| Tables `EPF_PURGE_LOG`, `EPF_PURGE_SPACE_SNAPSHOT`, `EPF_DDL_BACKUP`, type `EPF_NUMBER_TAB` | Replaced by section 5 tables; `install.sql` offers to remove the old objects from OPPAYMENTS (after checking that no reclaim is incomplete) |
| Flags `--reclaim-only`, `--reclaim-online`, `--reclaim-online-only`, `--max-iterations`, `--no-stall-check`, `--allow-offline-index-rebuild`, `--show-sizes`, `--optimize-db`, `--drop-pkg`, `--drop-logs`, `--truncate-logs`, `--sys-password`, `--user`, `--password` | Removed (D12); replaced by actions and the options in 10.1 |

---

## 15. Design decisions (need your answers)

Recommended options are already applied in this plan. Each row states what changes if you choose otherwise.

| ID | Decision | Recommended | If you choose the alternative |
|----|----------|-------------|-------------------------------|
| D1 | Where the tool's objects live | Dedicated tool schema `EPF_ADMIN` (name configurable); SYS only at install | Keep in OPPAYMENTS: tool tables in a non-data tablespace; reclaim stays a SYS-run step script (3.4) |
| D2 | Index/constraint handling during reclaim | Indexes UNUSABLE -> REBUILD; constraints never dropped | Drop/recreate from captured DDL (current): DDL backup table and recovery path stay |
| D3 | Relocation strategy | In-place drain -> refill (keeps tablespace and datafile identity) | Move once into a new tablespace and swap (7.6 alternative) |
| D4 | Wrapper runtime | `.bat` launcher + Windows PowerShell 5.1; bash `.sh` in phase 8 | PowerShell 7 on both OSes (one script, `pwsh` required on Linux) |
| D5 | Database-level operations kept | Temporary supporting indexes (on by default); UNDO/TEMP resize-only (opt-in); registry-table stats (opt-in); remove redo enlargement, `undo_retention` tuning, UNDO swap | Any removed item can be kept as an opt-in option |
| D6 | Purge modes | Keep FULL, CLOB_ONLY, CLOB_N_LOGS (the engine handles them uniformly) | FULL only, or FULL + CLOB_ONLY |
| D7 | Post-purge SHRINK SPACE | Remove; disk is returned only by reclaim; purge-only runs report freed-inside-segment space | Keep as opt-in `--compact`, limited to purged tables, SECUREFILE LOBs only |
| D8 | `file_dispatching` rows without `directory_dispatching` children | Purge them too (all rows older than the cutoff) | Keep current behavior (only parents that have children) |
| D9 | NOLOGGING for reclaim moves/rebuilds | No: always LOGGING; preflight blocks if redo would exceed recovery-area headroom | Allowed when the DB is not in FORCE LOGGING; much less redo; a backup is required afterwards |
| D10 | Quiesce enforcement for reclaim | Preflight blocks when application sessions / transactions / jobs are active | Also lock the application accounts for the window (unlocked at the end), or warn only |
| D11 | Console layout | Single console: event stream + heartbeat | Keep a separate monitor window (same data source) |
| D12 | Old CLI flags | Clean CLI, no aliases | Keep aliases for existing scheduled jobs |

Decided without asking (tell me if you disagree):

- Scope schemas and scoped tablespaces are auto-detected and overridable (7.4).
- `EPF_SCRATCH` is created at install and kept small between runs (3.4).
- Run history is kept 180 days (setting).
- Row-count parity for reclaim uses PK index fast full scans (7.6 BASELINE).

---

## 16. Risks and mitigations

| Risk | Mitigation |
|------|------------|
| An Oracle behavior differs on your version (e.g., V1) | Phase 0 verifies before anything is built on it; fallbacks noted per item. |
| Registry-driven engine deletes differently from the current hand-written code | Phase 2 parity test against the current tool on a clone; registry reproduces today's links and order exactly. |
| Reclaim takes longer than a maintenance window | Forecast with throughput sampling; stop request always ends in a consistent state (restore path); resume later. |
| Recovery area / disk pressure | Preflight redo and peak-disk forecasts; resumable suspend instead of failure; `--scratch-dir`. |
| Application writes during reclaim | Preflight blocks (D10); unusable unique indexes make writes fail instead of corrupting. |
| Tool-schema privileges considered too broad by security | Privilege list is explicit (3.4), no `ALTER USER`, no `CREATE/DROP TABLESPACE`; alternative D1 keeps SYS for reclaim only. |
| Two wrapper implementations drift (bat/ps1 vs sh) | Logic in the database; wrappers only render events; phase 8 compares manifests from both. |

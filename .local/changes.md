# Change history

Newest first. Each entry: date, what changed, why, and how to test when relevant.

## 2026-09-28 - Phase 2: undo retention only, output fixes

Results (EPFPG782, 0.2.2)
- `install.sql`: EPF_INSTANCE_CHANGE created, EPF_REDO dropped, all objects valid. PASS.
- `preflight.sql NEW`: 12 temporary indexes planned (10 FK columns, TRANSMISSION_EXECUTION_AUDIT link, NOTIFICATION_EXECUTION and TRANSMISSION_EXECUTION FK columns), 2 small tables scanned per batch. Redo estimate for BULK_PAYMENT 988.6 KB per root (measured on EPFPG781: about 930 KB); recommended batch size 100 with 3 x 150 MB logs (WARN). UNDOTBS1 450 MB, can grow to 32 GB, undo_retention 900 s, tuned up to 2,427 s in the last 24 hours. PASS.
- `redo_logs.sql 1024 4`: groups 4-7 of 1024 MB added, groups 1-3 dropped and their files removed. PASS.
- `undo.sql APPLY` (0.2.2): undo_retention 900 -> 60 s, undotbs01.dbf growth limit 32768 -> 8192 MB. PASS.
- `purge.sql NEW 30 PAYMENTS FULL 1000 N` (R-000002, undo tuning active, 4 x 1 GB redo logs): SUCCESS in 00:46:47. PROCESS_BATCHES 151 batches in 00:44:26 (about 19 s per bulk-payment batch, 34,000 rows/s; R-000008 without the FK indexes and with 150 MB logs: about 62 s per batch; previous tool: about 2 hours). 90,522,793 rows deleted; deleted = eligible and residual 0 for every table; retained rows unchanged. 12 temporary indexes created in 3 s and dropped. Redo 92.6 GB (701.8 KB per bulk payment, estimate was 988.6 KB), undo 42.1 GB (318.8 KB per bulk payment, 16.2 MB/s, 45% of redo). Used space inside segments 31.6 -> 17.8 GB.

Decision
- D18 revised: undo tuning lowers undo_retention only; the undo datafiles' size and growth limit are left unchanged.

Changes
- `epf_tuning.undo_apply`: undo_retention only. `undo_restore` still puts back any recorded datafile growth limit (the one applied on EPFPG782 by 0.2.2).
- `registry_data.sql`: setting `undo_max_mb` removed; settings no longer listed are deleted on install. Tool version 0.2.3.
- `epf_util.fmt_bytes`: values below 1 KB are rounded (an undo estimate printed 36 decimals).
- Run scripts: LINESIZE 32767, so long event lines are no longer wrapped (words were joined at the wrap point).
- `epf_purge`: an index need that is both a link column and an FK column names both in its detail.

How to test
1. After the PAYMENTS run: `undo.sql RESTORE` as SYS (restores undo_retention 900 s and the 32768 MB growth limit).
2. `git pull`, `install.sql`: tool version 0.2.3.
3. `undo.sql APPLY`: only UNDO_RETENTION_SET; `undo.sql STATUS` shows the datafile limit unchanged. Then `undo.sql RESTORE`.
4. `preflight.sql NEW`: REDO_ESTIMATE and UNDO_ESTIMATE measured by the PAYMENTS run; no wrapped lines.

## 2026-09-28 - Phase 2: undo tuning (D18), compile fix

Results
- EPFPG782 install of 64ae529: EPF_PURGE body did not compile (PLS-00103 at the index-needs types: PL/SQL requires every type declaration of a package body before its first subprogram). The types moved to the top of the body.

Decision
- D18: keep the previous tool's undo handling as an opt-in for the duration of a purge (undo_retention 60 s, undo datafiles capped at 8 GB) and restore the original values afterwards.

Changes
- `epf_redo` renamed `epf_tuning` (instance tuning for purges): `enlarge_redo` (as before), `undo_apply`, `undo_restore`, `undo_status`. Undo changes are recorded in the new table `EPF_INSTANCE_CHANGE` before they are made (retention SCOPE=MEMORY; datafile MAXSIZE never below the current size; refused with RETENTION GUARANTEE); restore puts back the recorded values.
- `run/undo.sql` (new): `APPLY | RESTORE | STATUS`. `run/redo_logs.sql` calls `epf_tuning.enlarge_redo`.
- `epf_purge`: undo measured per root tree (`TREE_UNDO`, with elapsed time) and per batch; preflight step `UNDO` (undo size and limit, retention, active tuning, `UNDO_ESTIMATE` per tree with undo per batch and the undo kept at the measured rate; WARN when the tablespace would grow without tuning or a batch needs more than half of it); `UNDO_TUNING` at the start and end of a run.
- `install.sql`: tool packages not delivered by this version are dropped (removes `EPF_REDO`). `uninstall.sql` refuses while undo tuning is active.
- Settings `undo_retention_s` (60), `undo_max_mb` (8192); grant on V_$UNDOSTAT; tool version 0.2.2.
- Plan: 3 (principle 9), 4.1, 6.9, 10.3, 15 (D5, D18).

## 2026-09-28 - Phase 2: redo logs (D17), redo measurement, batch size recommendation

Findings
- EPFPG781 has 3 online redo log groups of 150 MB; the PAYMENTS purge writes about 930 MB of redo per batch of 1,000 bulk payments, so each batch switches logs about six times and the session waits on `log file switch (checkpoint incomplete)`. The previous tool's optimize option replaced the logs with 4 x 1 GB.
- An external review of R-000008 counted PAYMENT_AUDIT rows as roots ("26,153 batches, 18 days"); the module has 151 batches. Redo per deleted row (about 1.1 KB) is normal for deletes that maintain several indexes.

Decision
- D17: redo log sizing becomes an opt-in, permanent, reported action (D5 revised).

Changes
- `epf_redo` (new, invoker rights, run as SYS): `enlarge(size_mb, groups)` adds groups (same directories and multiplexing, or Oracle-managed), switches and checkpoints until the smaller groups are inactive (archived in ARCHIVELOG), drops them and deletes their files through a temporary directory object. Non-CDB single instance only.
- `run/redo_logs.sql` (new): `<size_mb|-> <groups|->`, default 1024 MB x 4.
- `epf_purge`: redo measured per root tree (`TREE_REDO`), per batch in progress events, per module in `MODULE_END`; preflight step `REDO_LOGS` (`REDO_LOGS`, `REDO_ESTIMATE` per tree, `REDO_SUMMARY` with the recommended batch size; WARN when a batch exceeds a whole online log).
- `grants.sql`: SELECT on V_$LOG, V_$LOGFILE, V_$LOG_HISTORY, V_$MYSTAT, V_$STATNAME; EXECUTE on UTL_FILE. Tool version 0.2.1.
- Plan: 3 (principle 9), 4.1, 6.8, 10.3, 15 (D5, D17).

How to test (covers the FK index fix below as well)
1. Stop R-000008 (`EXEC epfpg.epf_control.request_stop(8)` as EPFPG) or recreate the instance.
2. `git pull`; `install.sql` as SYS: packages valid, tool version 0.2.1.
3. `preflight.sql NEW`: IDX_MISSING lists the FK columns; REDO_LOGS shows 3 x 150 MB; REDO_ESTIMATE per tree (estimated); REDO_SUMMARY WARN with the recommended batch size.
4. `redo_logs.sql 1024 4` as SYS: groups before/after, 4 x 1024 MB, old files removed.
5. `preflight.sql NEW` again: REDO_LOGS 4 x 1 GB; recommended batch size.
6. Purges (fresh instance: dry run, LOGS, BANK_STATEMENTS first; same instance: PAYMENTS only). PAYMENTS shows TEMP_INDEX_CREATED for the FK columns, redo per batch in BATCH_PROGRESS, TREE_REDO; then `preflight.sql NEW` shows the measured redo per root.

## 2026-09-28 - Phase 2: real runs and FK index fix

Results (EPFPG781, retention 30, batch 1000)
- LOGS (R-000005): SUCCESS in 00:01:36; AUDIT_TRAIL 1,658,823, AUDIT_ARCHIVE 252, SPEC_TRT_LOG 63,071 deleted, residual 0; about 24,000 rows/s.
- BANK_STATEMENTS CLOB (R-000006): SUCCESS in 00:03:27; 198,889 + 2,227,192 LOB values to clear; used space inside segments 31.4 -> 29.3 GB.
- BANK_STATEMENTS FULL (R-000007): SUCCESS in 00:01:35; FILE_DISPATCHING 198,890 (childless rows included) and DIRECTORY_DISPATCHING 3,781,765 deleted, residual 0; about 44,000 rows/s.
- PAYMENTS FULL (R-000008): about 3 minutes per batch of 1,000 bulk payments (151 batches), CPU-bound with heavy reads; roughly 1 GB of redo per batch. Stop requested.

Cause
- Deleting a parent row makes Oracle look for child rows through each FK; when the FK columns are not indexed it scans the child table once per deleted parent row. `bulk_payment_additional_info.bulk_payment_id` (46 MB) was not indexed and was skipped by the 64 MB threshold, so each batch scanned it about 1,000 times. The threshold only considered the engine's own per-batch lookups.
- Confirmed from V$SQL after 47-48 batches (per batch): DELETE BULK_PAYMENT 25.6 s and 5.9 M buffer gets for 1,000 rows (1,000 full scans of the 5,900-block child table); DELETE PAYMENT_ADDITIONAL_INFO 19 s for 534,000 rows (disk-bound, same work as the previous tool); DELETE PAYMENT 8 s, inflated by unindexed BULKPAYMENT_EXCEPTION and INVOICE. Unindexed FK columns into purge tables: BULK_PAYMENT_ADDITIONAL_INFO, BULK_SIGNATURE, MANDATORY_SIGNERS, OIDC_REQUEST_TOKEN, TRANSMISSION_EXCEPTION (BULK_PAYMENT_ID); BULKPAYMENT_EXCEPTION, INVOICE (PAYMENT_ID); INVOICE_ADDITIONAL_INFO (INVOICE_ID); NOTIFICATION_EXECUTION (IMPORT_AUDIT_ID, TRANSMISSION_EXECUTION_ID); TRANSMISSION_EXECUTION (TRANSMISSION_EXCEPTION_ID).
- Redo per deleted row is the same as with the previous tool and is not the cause.
- Copy-and-truncate for high-eligibility tables was considered and rejected: monthly purges keep most rows, so DELETE is the path that must be fast.

Fix (`epf_purge`)
- Supporting indexes also cover the columns of every enabled FK into a table the module deletes from, whatever the table size (composite FKs supported; an existing index whose leading columns are the FK columns counts). Child tables outside the registry cannot be indexed: WARN `IDX_MISSING` in preflight, `FK_UNINDEXED` in the purge.
- Preflight `SUPPORTING_INDEXES` lists link and FK columns per module.

How to test
1. Stop R-000008 if still running: as EPFPG, `EXEC epfpg.epf_control.request_stop(8)`; it ends STOPPED after the current batch.
2. `git pull`, re-run `install.sql` as SYS.
3. `preflight.sql NEW`: IDX_MISSING lines now include FK columns (at least BULK_PAYMENT_ADDITIONAL_INFO.BULK_PAYMENT_ID).
4. `purge.sql NEW 30 PAYMENTS FULL 1000 N`: TEMP_INDEX_CREATED for the FK columns; compare batch pace with R-000008.

## 2026-09-28 - Phase 2: dry run results

- `purge.sql NEW 30 ALL FULL 1000 Y` (R-000004): SUCCESS in 00:03:50. Baseline 96 segments, 33.0 GB allocated, 31.6 GB used. Snapshot: BULK_PAYMENT 138,296 roots in 139 batches with 5,543,406 derived keys; FILE_INTEGRATION 11,794 (ROWID, 12 batches); AUDIT_TRAIL 1,658,823 (1,659 batches); SPEC_TRT_LOG 63,071 (ROWID, 64 batches); FILE_DISPATCHING 198,890 (199 batches). No held roots, no shared batches, no held AUDIT_ARCHIVE rows.
- Rows not reachable from any root stay (same as the previous tool): PAYMENT 7,038, PAYMENT_ADDITIONAL_INFO 83,926, WORKFLOW_EXECUTION 7,027, APPROBATION_EXECUTION 3,453, IMPORT_AUDIT 4,093, IMPORT_AUDIT_MESSAGES 57,644, NOTIFICATION_EXECUTION 7,918, PAYMENT_AUDIT 13,949. Open scope question for later: whether rows without a bulk payment should be purged by their own date.

## 2026-09-28 - Phase 2: batch numbering fix

Results so far (EPFPG781)
- `install.sql` upgrade: columns, indexes and EPF_HELD_ROOT added; CREATE/DROP ANY INDEX revoked; all packages valid, tool version 0.2.0. PASS.
- `preflight.sql NEW` (R-000002): registry 0 errors / 0 warnings; 13/24 link columns indexed, 1 temporary index planned (TRANSMISSION_EXECUTION_AUDIT.BULK_PAYMENT_ID, 445 MB), 10 small tables scanned; every root row is older than the 30-day cutoff (BULK_PAYMENT 138,296, FILE_INTEGRATION 11,794, AUDIT_TRAIL 1,658,823, SPEC_TRT_LOG 63,071, FILE_DISPATCHING 198,890). PASS.
- Dry run `purge.sql NEW 30 ALL FULL 1000 Y`: did not finish. The batch-numbering MERGE joined EPF_WORK_KEY to itself on group_key (no index), so every root rescanned all roots of its table; with 1.66 M AUDIT_TRAIL roots this never completes. Cancelled; nothing in the application schemas was changed.

Fix (`epf_purge`)
- Batch numbers are assigned in the root snapshot INSERT (`ROW_NUMBER` in key order); the MERGE is removed.
- Roots grouped because their trees reference each other are moved to the batch of the group's smallest key, updated by root key (index).
- EPF_WORK_KEY statistics are gathered after each tree's snapshot, before the held-back and grouping queries run.

How to test
1. `git pull`, re-run `install.sql` as SYS (packages only change).
2. Repeat the dry runs of the phase 2 test (FULL, then CLOB). Expected duration: minutes, mostly the exact counts of the largest tables (PAYMENT_ADDITIONAL_INFO 57 M rows, PAYMENT_AUDIT 25 M rows).

## 2026-09-28 - Phase 2 (purge engine)

Decision
- D16: kept rows that reference rows being purged are protected by holding back the referenced root (plan 6.1.1).

Database objects (`src/sql/install/`)
- `epf_purge` (new): registry-driven purge. Key snapshot with derived keys per root; held-back roots through every enabled FK (any schema) and held rows through reverse links (shared `audit_archive`); roots that reference each other share a batch; modes FULL / CLOB / LOGS / CLOB_N_LOGS; one transaction per batch, leaves first; failing batch rolled back, module stops, other modules continue; stop requests between batches; progress events; counts BEFORE / AFTER per table; temporary supporting indexes; `preflight` for the read-only checks.
- `epf_space` (new): segment, datafile and in-segment snapshots (DBMS_SPACE.SPACE_USAGE for ASSM and SECUREFILE, statistics estimate for manual segment space management).
- `epf_registry`: checks REG_KEY_TYPE, REG_KEY_UNIQUE, REG_DATE_TYPE, REG_SOURCE_KEY, REG_REVERSE_SOURCE, REG_ROOT_KEY_FK; grant check includes INDEX.
- `epf_log`: `current_step`, `step_skip_pending`.
- `epf_control`: `start_run` refuses `with_compact = Y` (compaction comes with phase 3).
- `tables.sql`: column-level upgrade (`add_column`); `EPF_WORK_KEY.root_key/group_key` and two indexes; `EPF_HELD_ROOT`; `EPF_TABLE_STAT.held_rows`; `EPF_TEMP_INDEX.table_owner`.
- `grants.sql`: `INDEX` on registry tables and `EXECUTE` on `DBMS_SPACE`; `CREATE ANY INDEX` / `DROP ANY INDEX` revoked (temporary indexes are created in EPFPG's own schema and tablespace); `SELECT` on tables outside the registry with an FK into it.
- `registry_data.sql`: setting `temp_index_min_mb` (64); tool version 0.2.0.
- `uninstall.sql`: no longer refuses because of temporary indexes (EPFPG owns them; they go with the user).

Entry scripts (`src/sql/run/`)
- `purge.sql` (new): `<run_id> - - - - -` or `NEW <retention> <depth> <mode> <batch_size> <dry_run>`.
- `preflight.sql`: calls `epf_purge.preflight` (registry, supporting indexes, eligible roots).

Plan: 3.4 (privileges), 5 (tables), 6.1 / 6.1.1 (snapshot, held back), 6.4 (temporary indexes in EPFPG_DATA, no date-column indexes), 6.7 and 13 (compaction in phase 3), 15 (D16).

How to test
1. `git pull`, then `sqlplus -L "sys@<pdb_service> AS SYSDBA" @src/sql/install/install.sql <epfpg_password>` (upgrade). Expected: added columns and indexes, `created table EPF_HELD_ROOT`, `revoke CREATE ANY INDEX` / `DROP ANY INDEX`, `EPFPG objects valid, tool version 0.2.0`. If a package does not compile, the errors are listed just above.
2. `sqlplus -L -S "epfpg/<password>@<pdb_service>" @src/sql/run/preflight.sql NEW`. Expected: PURGE_SCOPE, REG_SUMMARY, IDX_MISSING lines, IDX_SUMMARY, one ROOTS_ELIGIBLE per root table.
3. Dry run, FULL: `sqlplus -L -S "epfpg/<password>@<pdb_service>" @src/sql/run/purge.sql NEW 30 ALL FULL 1000 Y`. Expected: SPACE_CAPTURED BASELINE, KEYS_SNAPSHOT per root, ROOTS_HELD / ROWS_HELD if any, TABLE_ELIGIBLE for 27 tables, MODULE_END per module, PURGE_END. Changes nothing in the application schemas.
4. Dry run, CLOB: same with `CLOB` instead of `FULL`: TABLE_ELIGIBLE shows non-empty LOB values.
5. Only on a test copy of the database (NOARCHIVELOG: take a backup or export first): a real purge, smallest module first, e.g. `purge.sql NEW 30 - LOGS 1000 N`, then `purge.sql NEW 30 BANK_STATEMENTS FULL 1000 N`, then `purge.sql NEW 30 ALL FULL 1000 N`. Expected: TEMP_INDEX_CREATED/DROPPED, BATCH_PROGRESS, TABLE_RESULT with residual eligible 0, SPACE_CAPTURED POST_PURGE.
6. Return the console output of each step.

## 2026-09-28 - Phase 1 test results and survey review

Results (database EPFPG781, 19c EE 19.24, non-CDB)
- `install.sql`, first run: reference tablespace DATA (largest share of OPPAYMENTS segments), `EPFPG_DATA` created at `/files2/oradata19/EPFPG781/epfpg_data01.dbf`; user, 18 tables, registry (27 tables, 23 links), 72 grants, packages valid. PASS.
- `install.sql`, second run: tablespace, tables and user reused, same result. PASS (idempotent).
- `preflight.sql NEW`: run R-000001, 27/27 tables present, 22 FKs into registry tables, all covered by the processing order, 0 errors, 0 warnings. PASS.
- `environment.sql`: reviewed; the facts and their design consequences are in plan section 12.4.
- Not yet run: `uninstall.sql` followed by a new install.

Changes
- `environment.sql` section 14 lists the previous tool's objects by exact name. The `EPF%` prefix matched the application's own packages in OPPAYMENTS (EPF_BIND, EPF_CONTEXT, ...), which are not tool objects.
- Plan: 7.3 (IOT primary key index moved with the table, never UNUSABLE), 12.4 (target environment), 14 (previous tool objects identified by exact name only).
- Decision D15 (plan 7.6, 15): the reclaim locks and disconnects owners of objects in the target tablespaces plus accounts with INSERT/UPDATE/DELETE on those objects (direct or through a role) or sessions using them, each listed with the reason at startup.

## 2026-09-28 - Phase 1: tool tablespace created by the installer

What changed
- `install.sql` takes one argument (the EPFPG password). It creates tablespace `EPFPG_DATA` when missing: one datafile (128 MB, autoextend 128 MB, maxsize unlimited) in the directory of the first datafile of the tablespace holding most of the OPPAYMENTS segments. Fallbacks: OP, OPREPORTS, their default tablespaces, the database default tablespace, SYSTEM. ASM: same disk group, Oracle-named file. File name `epfpg_data01.dbf` in the letter case of the reference file; a name already on disk is skipped (`02`, `03`, ...), an existing file is never reused. On re-run an existing `EPFPG_DATA` is reused after checking it is online, permanent and holds no segments of other owners.
- The installer prints the reference tablespace, the reason it was chosen and the reference datafile.
- `uninstall.sql` drops `EPFPG_DATA` with its datafiles after the user, only when no segment, segmentless object, partition default, recycle-bin object, user default or database default references it; otherwise it keeps it with a WARN.
- `environment.sql`: section 16 lists the datafiles of `EPFPG_DATA` and the owners of its segments.
- Plan: sections 3.4, 5, 7, 7.7 and 15 state that the application tablespace is detected from where OPPAYMENTS (then OP, OPREPORTS) segments live and is never assumed to be named DATA.

Why
- The tool's objects get a tablespace of their own that can never be a reclaim target, without asking the operator to choose one.
- Installations where the application data is not in a tablespace named DATA.

How to test (replaces step 1 of the phase 1 test)
1. `sqlplus -L "sys@<pdb_service> AS SYSDBA" @src/sql/install/install.sql <epfpg_password>`. Check the `reference tablespace` / `reference datafile` lines and the `created tablespace EPFPG_DATA, datafile ...` line. Run it a second time: it must print `present tablespace EPFPG_DATA` and succeed.
2. Steps 2-4 of the phase 1 test unchanged; `epf_environment.txt` now includes section 16.
3. Optional: `@src/sql/install/uninstall.sql` as SYS must end with `EPFPG_DATA and its datafiles removed.`; then install again.

## 2026-09-28 - Phase 1 (foundation)

Repository
- New implementation in `src/`; the previous implementation moved unchanged to `legacy/` (`legacy/bin`, `legacy/sql`, `legacy/config`) for comparison.
- `.gitattributes` (line endings per file type), `.gitignore` (run logs, local config, survey output).

Database objects (`src/sql/install/`)
- `install.sql` (SYS): checks (SYS, not CDB$ROOT, 12.2+, tool tablespace not used by OP/OPPAYMENTS/OPREPORTS), creates or updates user EPFPG, then tables, registry, grants, packages; fails if any EPFPG object is invalid.
- `uninstall.sql` (SYS): refuses while a run is active, while accounts locked by a reclaim are not restored, or while temporary purge indexes exist; then drops EPFPG.
- `tables.sql`: all tables of plan section 5 (idempotent).
- `registry_data.sql`: 3 modules, 27 tables, 23 links (today's scope and processing order), 16 settings. Settings keep operator values on upgrade.
- `grants.sql`: system privileges, direct SELECT on dictionary views, DBMS_LOCK, INHERIT PRIVILEGES ON USER SYS (warning only if refused), SELECT/DELETE/UPDATE on registry tables present.
- Packages: `epf_util` (formatting, settings, dictionary helpers), `epf_log` (events, steps, session tagging), `epf_control` (run lifecycle with an exclusive run lock, stop requests, parameter normalisation), `epf_registry` (registry validation, including FKs from any schema into purge tables).
- The run package is named `epf_control` because a package cannot share the name of table `EPF_RUN` in the same schema.

Entry scripts (`src/sql/run/`)
- `start_run.sql`: validates parameters, creates a run, prints `EPF_RUN_ID=<n>`.
- `preflight.sql`: registry validation (grows in phase 2). `NEW` runs it standalone and prints the events.

Verification (`src/tests/verify/`)
- `environment.sql`: read-only survey of the target database; writes `epf_environment.txt`.

How to test
1. `sqlplus -L "sys@<pdb_service> AS SYSDBA" @src/sql/install/install.sql <epfpg_password> <tool_tablespace>`
   (tool tablespace: e.g. USERS, as long as OP/OPPAYMENTS/OPREPORTS have no segments there). Run it a second time: it must succeed again (idempotent).
2. `sqlplus -L -S "epfpg/<password>@<pdb_service>" @src/sql/run/preflight.sql NEW`
3. `sqlplus -L "sys@<pdb_service> AS SYSDBA" @src/tests/verify/environment.sql`
4. Return: the console output of 1 (both runs) and 2, and the file `epf_environment.txt`.
5. Optional: `@src/sql/install/uninstall.sql` as SYS, then install again.

## 2026-09-28 - Plan draft 3

- Plan moved from `plan/PLAN.md` to `.local/PLAN.md`; this change log added.
- Layout: `src/` (new), `legacy/` (previous implementation, unchanged).
- Reclaim: REFERENCE_CHECK step before DROP_OLD; REVERT path when the check fails or Oracle refuses the drop (moves everything back, drops the empty clone).
- LONG conversion confirmation shows owner, column, source tablespace and target LOB tablespace per item.
- Phase 0 split: environment survey now; behavior spikes V1-V10 before phase 5.

## 2026-09-28 - Plan draft 2

- Decisions D1-D14 applied: EPFPG tool schema; indexes UNUSABLE + REBUILD; tablespace swap with all owners; bat + PowerShell 5.1; temporary purge indexes only; modes FULL / CLOB / LOGS / CLOB_N_LOGS; purge effect always measured, compaction opt-in; childless `file_dispatching` rows purged; always LOGGING; accounts locked and sessions disconnected at reclaim start after startup confirmation; clean CLI; SYS asked at startup when reclaim is selected; LONG columns converted with per-item approval.

## 2026-09-28 - Plan draft 1

- Assessment of the previous implementation (findings F/R/L/A/S/P) and target design.

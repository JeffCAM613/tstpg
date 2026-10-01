# Change history

Newest first. Each entry: date, what changed, why, and how to test when relevant.

## 2026-10-01 - Parity check against the previous tool

Closes the open exit criterion of phase 2 (parity with the previous tool), row by row, on two copies of the same database (plan 12.6).

- `src/tests/parity/parity.sql` (SYS, read-only; steps in `parity_step.sql`): for the 27 tables of the previous tool, every row is classed by four flags and counted with a checksum of its key (primary key, otherwise unique key, otherwise every column that is not a LOB or LONG) per class:
  - D: the previous tool deletes it. Its rules, transcribed from `legacy/sql/03_epf_purge_pkg_body.sql`: bulk payments by value date and their 20 dependent tables (payment_audit by bulk payment and by payment), file_integration by integration date, audit_trail by timestamp with the audit_archive rows it references, spec_trt_log by date, file_dispatching by reception date only when it has directory rows, with those rows.
  - X: deleted through an ON DELETE CASCADE foreign key from a D row (NOTIFICATION_EXECUTION.IMPORT_AUDIT_FK).
  - N: this tool selects it (registry links, before holding back).
  - C: the previous tool clears its LOB values in CLOB_ONLY and CLOB_N_LOGS (payment_audit by bulk payment only).
  - Scope CLOB also records the non-empty LOB values per column and class.
- The snapshot also records every enabled foreign key into the 27 tables. When kept rows reference D rows, the count is reported: the previous tool's delete fails with ORA-02292 there, and the module stops.
- It records the last runs of both tools as well: `OPPAYMENTS.EPF_PURGE_LOG` with its errors, and `EPFPG.EPF_RUN` with the held rows.
- `src/tests/parity/compare.ps1` reads the four snapshots. It checks:
  - both copies started identical (every class, count and checksum), and both purges used the snapshot cutoff;
  - the previous tool deleted or cleared exactly what its rules select, or the rows it left are listed with its errors;
  - this tool kept every row it does not select.

  Every difference between the two results is classified: D8, D16 (held back, cascade rows of kept roots), PAYMENT_AUDIT (LOB clearing through the payment). Anything else fails.
- `compare.ps1 -Before` reads only the two BEFORE snapshots, before any purge is started. It checks that both copies start identical and lists, per table, what each tool will change. It also lists the expected differences, the rule differences and the foreign keys that will stop the previous tool. Exit 0 READY, 1 INVALID or rule differences.
- Checked locally with synthetic snapshots: identical results (exit 0), explained differences (exit 2), a kept row deleted (exit 1), different starting data (exit 1), LOB clearing with the PAYMENT_AUDIT and D8 differences (exit 2), CLOB mode on snapshots without LOB values (refused). The SQL has not run on a database yet.

How to test (EPFPG783 for the previous tool, EPFPG782 for this tool, both refreshed from the same source; both purges on the same day with the same retention, so cutoff = that day minus the retention)
1. In the tool folder: `sqlplus -L "sys@EPFPG783 AS SYSDBA" @src\tests\parity\parity.sql LEGACY_BEFORE <cutoff>` and `sqlplus -L "sys@EPFPG782 AS SYSDBA" @src\tests\parity\parity.sql NEW_BEFORE <cutoff>` (two windows can run at once). Do not run the end-to-end suite on these copies: it purges them.
1b. `powershell -NoProfile -ExecutionPolicy Bypass -File src\tests\parity\compare.ps1 -Mode FULL -Before`: purge only on RESULT READY; send `logs\parity\parity_before_report.txt`.
2. Previous tool on EPFPG783: `legacy\bin\epf_purge.bat --tns EPFPG783 --user oppayments --retention <days> --depth ALL --mode FULL`, without reclaim. This tool on EPFPG782: `src\bin\epf_purge.bat install --tns EPFPG782`, then `src\bin\epf_purge.bat purge --tns EPFPG782 --retention <days> --depth ALL --mode FULL --redo-logs --undo-tuning`.
3. `parity.sql LEGACY_AFTER <cutoff>` on EPFPG783 and `parity.sql NEW_AFTER <cutoff>` on EPFPG782.
4. `powershell -NoProfile -ExecutionPolicy Bypass -File src\tests\parity\compare.ps1 -Mode FULL`; send `logs\parity\parity_report.txt`.

## 2026-09-30 - End-to-end run on EPFPG781 (0.4.4): 19/19 passed

Results (EPFPG781 as the 0.4.3 run left it: PAYMENTS untouched, LOGS purged, BANK_STATEMENTS LOB values cleared; RETENTION_DAYS=365; 01:01:21; log kept on the test machine only, `logs/tests/2026-09-30_172149_EPFPG781/`)
- All 19 tests passed, no check failed. Every wrapper step ended with no sqlplus session left running (0 ended); T16 completed in 00:04:08.
- Undo growth cap: at T05 UNDOTBS1 was 3,435 MB with a growth limit of 32,768 MB. T11 and T13 set the cap to 4,096 MB (setting `undo_cap_mb`; 4 x the undo of one batch was 920 MB and 540 MB) and limited the datafile 32,768 -> 4,096 MB. The PAYMENTS purge to the end (R-000015: 87,309,042 rows, 275/275 batches in 00:26:44, 67.6 GB redo, 33.2 GB undo, verdict PASS) completed within the cap: UNDOTBS1 3,435 -> 4,096 MB (27.6 GB on EPFPG783 without the cap, 00:27:07). T16 (BANK_STATEMENTS full purge, R-000019: 3,980,655 rows, 1.6 GB undo) ran with the cap at the current size (4,096 MB, no growth left) and completed. After every run the growth limit was back at 32,768 MB (T12, T13, T19) and undo_retention at 900 s.
- The stopped run (R-000014, after batch 9 of 284, 1.2 GB undo) and the dry run (T10, work keys in TEMP) did not grow the undo tablespace.
- Undo per batch: the preflight before any measured purge estimated 230 MB (measured: 1.2 GB / 9 batches, about 136 MB); after that run 135 MB (measured in R-000015: 33.2 GB / 275, about 124 MB).
- T14 (LOGS) and T15 (BANK_STATEMENTS clearing) had nothing to process (0 rows; 0 LOB values in 199 batches): the 0.4.3 run had purged them (1,659,623 rows; 2,426,081 LOB values), and their code is unchanged in 0.4.4.
- Space used inside segments: PAYMENTS 28.9 -> 13.7 GB, BANK_STATEMENTS 15.5 -> 3.2 GB.

## 2026-09-30 - End-to-end run on EPFPG781 (0.4.3): undo apply error, hang at T16; fixes (0.4.4)

Results (EPFPG781, fresh copy, RETENTION_DAYS=365; partial log `logs/tests/2026-09-30_143658_EPFPG781/`)
- T01-T10, T14, T15 passed (install, redo logs 3 x 150 MB -> 4 x 1 GB, preflights with UNDO_CAP for the planned undo tuning, dry run, LOGS with compaction, BANK_STATEMENTS clearing).
- T11, T13: `undo.sql APPLY` failed with ORA-00923 in `epf_tuning` (line 309): the new growth-limit query used the reserved word INCREMENT as a column alias; the SQL of an invoker-rights package is checked when it runs, not at install. The failure path worked: no datafile had been changed, the purge was not started, undo_retention was restored, the runs ended FAILED with their reports. T12 failed as a consequence (no stopped run). PAYMENTS was not purged.
- T16: after the wizard's preflight (R-000009) and the confirmation, the new monitor session did not answer `begin_run.sql` within 120 s (cause not visible in the log: the session's output and database state were not captured). The wrapper stopped with an error but left that sqlplus running; it held the output pipe of the wrapper, so the test suite waited indefinitely.

Changes
- `epf_tuning`: alias `incr_bytes` (all SQL searched for reserved words used as aliases; this was the only one).
- Wrapper: every sqlplus it starts is registered and ended when the wrapper exits, on every exit path; when `begin_run` does not answer, the monitor session is ended, the message includes what the session printed, `status` is shown, and the exit code is 1.
- `epf_report.print_status` (`status`): lists the other sessions of the tool schema with status, wait event, seconds, blocking session (user, machine, program) and SQL_ID, so a stuck monitor or worker shows why.
- Test suite: once a process has exited its output is read for 15 more seconds at most; sqlplus processes left behind by a step (parent ended) are ended and fail the step ("no sqlplus session left running by the wrapper"); only T01 runs whatever the selection (T03 no longer runs with `--only`); T14 checks that the COMPACT step ran (nothing to compact on data an earlier run compacted).
- Checked locally: a `begin_run` that never answers (stand-in for sqlplus) now ends in 2 minutes with the diagnosis, exit 1, no sqlplus left, and the suite continues.
- Tool version 0.4.4.

How to test
1. EPFPG781 as it is (PAYMENTS untouched, LOGS purged, BANK_STATEMENTS LOB values cleared) or a fresh copy: `git pull`, `src\tests\e2e\run_tests.bat`.

## 2026-09-30 - Second end-to-end run on EPFPG783: 19/19 passed; review fixes (0.4.3)

Results (EPFPG783, 0.4.2, RETENTION_DAYS=365; log `logs/tests/2026-09-29_205549_EPFPG783/`, 01:06:04)
- All 19 tests passed: install (wrapper and install.sql), wrapper basics and usage errors, preflights, dry run, PAYMENTS through the wizard with redo sizing (3 x 150 MB -> 4 x 1 GB), undo tuning and a graceful stop after batch 9 (R-000025, exit 3, 12 temporary indexes dropped, undo restored), PAYMENTS to the end (R-000026: 87,309,042 rows in 00:27:07, 53,662 rows/s, 67.6 GB redo, 33.2 GB undo, used inside segments 31.2 -> 16.0 GB), LOGS with compaction (R-000027: 1.66 M rows in 00:00:43, 1.2 GB returned, verdict PASS), BANK_STATEMENTS clearing (R-000028: 2,426,081 LOB values) and full purge through the menu wizard (R-000030: 3,980,655 rows, verdict PASS), reports, final state clean.
- Live view: heartbeat lines showed wait events, blocking background processes (CKPT, LGWR, DBWn) and longops progress; pre-existing orphans are INFO.

Findings
- Undo: with undo tuning (undo_retention 60 s) UNDOTBS1 still grew 450 MB -> 2.1 GB (dry run: 5.5 M work keys) -> 5.2 GB (stopped run) -> 27.6 GB (PAYMENTS), and an autoextended datafile does not shrink. With autoextensible undo Oracle tunes retention to the longest running statement, and the purge is one PL/SQL call of about 30 minutes, so lowering undo_retention alone does not stop the growth. On EPFPG782 the 0.2.2 tuning also capped the datafile growth (8 GB) and the file stayed at 8 GB. Open decision (growth cap).
- BASICFILE estimate for clearing runs: DIRECTORY_DISPATCHING read 3.9 GB used after all its non-empty LOB values were cleared: the estimate scaled by rows, and 1.55 M of its 3.78 M rows had no LOB value.
- Measurements reused across kinds of purge: the wizard offered batch 30,000 for the BANK_STATEMENTS full purge from the redo measured by the clearing run.
- A stopped run logged a WARN TABLE_RESULT for every table with residual rows (17 in R-000025), counted in P5 although P1 and P2 already report the residual.
- Console clocks: section headers showed this machine's time (21:00), events the database time (15:00).
- A full purge after a clearing run of the same rows counts the cleared BASICFILE LOB space again (its baseline reads it as used); only when both run on the same rows.

Changes
- `epf_space`: BASICFILE estimate for clearing runs uses the values cleared out of the non-empty values of the eligible rows (R-000028 would read about 0 GB of LOB data left instead of 3.3 GB).
- `epf_purge`: redo and undo per root are taken only from earlier purges that did the same (deleting or clearing); TABLE_RESULT is a WARN for residual rows only when the module processed every batch (INFO after a stop or a failure).
- Wrapper: section headers use the database clock (the connection test reads it); the run header shows the offset when the clocks differ.
- Report: the BASICFILE note names the share of LOB data left.
- `EPF_WORK_KEY` becomes a global temporary table (ON COMMIT PRESERVE ROWS) and the purge session sets `temp_undo_enabled`: the key snapshot (5.5 M keys for PAYMENTS) writes no redo and no longer grows the undo tablespace, also in dry runs; it uses the temporary tablespace instead. Install replaces a permanent EPF_WORK_KEY (transient data only). Decided 2026-09-30.
- Undo tuning limits undo growth again (D18 revised, decided 2026-09-30, 4 GB): `epf_tuning.undo_apply(run_id, preflight_run_id)` also sets the growth limit (MAXSIZE) of the autoextensible undo datafiles to `undo_cap`: the largest of the undo tablespace's current size, setting `undo_cap_mb` (4096, new) and 4 x the undo of one batch; the limit is recorded in EPF_INSTANCE_CHANGE (UNDO_DATAFILE) before it is set and `undo_restore` puts it back. No file is resized. `run/undo.sql APPLY [run_id [preflight_run_id]]` (optional arguments). `EPF_RUN.with_undo_tuning` (new column; `start_run` parameter; `begin_run.sql` 9th argument, passed by the wrapper): the preflight of such a run reports the limit (`UNDO_CAP`) instead of a growth warning. The undo tablespace's datafiles are part of the report's DATAFILES section (size before and after), and the report shows the undo tuning the purge ran with.
- Test suite: T05 records the undo datafiles' growth limits; T12, T13 and T19 check they are back; T11 and T13 check the limit was applied; T13 checks the undo tablespace stayed within the larger of its size and 4 GB; any `Enter value for` prompt fails a step.
- Tool version 0.4.3.

How to test (a refreshed test database with unpurged data)
1. `src\tests\e2e\run_tests.bat`.
2. In the log: T11/T13 `UNDO_CAP` and `UNDO_GROWTH_LIMITED` in the undo tuning section, `UNDO_GROWTH_RESTORED` in the restore; T13 check "undo tablespace ... within ... MB"; T12/T13/T19 "original growth limit"; the purge report's DATAFILES section with the undo datafile; the dry run (T10) without undo growth (work keys in TEMP).

## 2026-09-29 - First end-to-end run on EPFPG783; fixes (0.4.2)

Results (EPFPG783, fresh copy of the same data as EPFPG782; RETENTION_DAYS=365; log `logs/tests/2026-09-29_193038_EPFPG783/test.log`)
- 10 passed, 9 failed. Install through the wrapper (new tablespace, user, 23 tables) and again with `install.sql`, undo restore, wrapper basics, usage errors (exit 4, no run created), `preflight.sql NEW`, reports, `status.sql`, final state: as expected.
- T08, T10-T16: every run through the wrapper failed at `begin_run.sql`: PLS-00103, the variable `l_run_id` was declared after the local function `arg` (PL/SQL requires variables before subprograms, also in anonymous blocks). `start_run.sql` had the same order. Run scripts are compiled only when they run, so neither install nor the stand-in for sqlplus could show it. No purge ran; the data of EPFPG783 is unchanged.
- T12 failed as a consequence (no stopped run); T18 skipped `advice.sql` (no preflight run from T08).
- T04 failed on the test itself: the installer prints `present  tablespace` (two spaces).
- Preflight on the fresh data (T09): all modules eligible (138,296 bulk payments, 1.7 M audit trail rows, 198,890 bank statement files); redo WARN with 3 x 150 MB logs (recommended batch 100); undo estimated 58.7 GB for PAYMENTS but no warning, because nothing was measured on this database yet (no rate).
- Output: sqlplus replaced runs of spaces with tabs (`SET TAB` defaults to ON); `UNDO_NOTHING_TO_RESTORE` was cut to 22 characters; `status` showed verdict `-` for a `preflight.sql NEW` run.
- Every sqlplus connection from the test machine took 13-15 s.

Changes
- `run/begin_run.sql`, `run/start_run.sql`: variable declared before the local function.
- Every entry script, `install.sql`, `uninstall.sql`, `environment.sql`: `SET TAB OFF`.
- `epf_purge` preflight: without a measured undo rate (first purge of a tree on the database) the undo kept by retention can be up to the undo of all eligible roots; UNDO_ESTIMATE warns ("may grow") when that exceeds the undo tablespace and undo tuning is not applied, so the wizard offers undo tuning on a first purge too.
- `run/preflight.sql NEW`: the run is ended with `epf_report.close_run` (checks and verdict recorded, as for wrapper runs).
- `epf_tuning`: event codes are padded, never cut.
- Wrapper: a run that cannot be created exits 1 unless the database refused it with one of the tool's own errors (ORA-20xxx: parameters, another active run), which stays 4.
- Test suite T04: pattern `present\s+tablespace`.
- Tool version 0.4.2.

How to test
1. `git pull`, then `src\tests\e2e\run_tests.bat` again on EPFPG783 (T03 upgrades it to 0.4.2; its data is untouched).
2. Return the new `test.log`.

## 2026-09-29 - End-to-end test suite; UTF-8 console fix

Changes
- `src/tests/e2e/run_tests.bat` + `run_tests.ps1` (new): runs tests T01-T19 (plan 12.5) against one test database without further input and writes `logs\tests\<timestamp>_<db>\test.log` with every command, output, exit code, run manifest, check and a summary. Safety: refuses to start unless `DESTRUCTIVE_OK=YES`, and T01 stops everything when the database name is not `EXPECTED_DB`, when it is a CDB or has more than one instance. `test.conf.example` documents the settings; `test.conf` is git-ignored.
- Wrapper (fix): with a UTF-8 console (code page 65001) .NET began the standard input of every sqlplus session with a byte order mark, so sqlplus would have rejected the CONNECT line of every session (not visible in the earlier checks because the stand-in for sqlplus ignored it). The wrapper now keeps UTF-8 input without the mark. Found by the suite: piped wizard answers arrived as `?30`.
- Checked locally: the whole suite against a stand-in for sqlplus that rejects a byte order mark, answers the precheck queries and keeps run state (stop, dry run, clearing and compaction events); all steps behave as intended, and no password appears in any output file.

How to test
1. Refresh a test database (not yet purged at 30 days), set `src\tests\e2e\test.conf`, run `src\tests\e2e\run_tests.bat`.
2. Return `test.log` from the session folder.

## 2026-09-29 - Phase 3 test results (EPFPG782), fixes (0.4.1)

Results (EPFPG782, 0.4.0)
- `install.sql`: EPF_TABLE_STAT.ACTION added, EPF_LINK_STAT and EPF_CHECK created, 78 grants, all objects valid. PASS.
- `undo.sql STATUS / RESTORE / STATUS`: the tuning applied by 0.2.2 (undo_retention 60 s, undotbs01 limit 8192 MB) restored to 900 s and 32768 MB; no active change left. PASS.
- `report.sql 2` (R-000002, PAYMENTS, 0.2.2): report printed, verdict PASS; P4 0 links (not counted by 0.2.x), Action column empty (not recorded by 0.2.x). OIDC_REQUEST_TOKEN appeared twice in the pasted results while P1 counts 22 tables; the query cannot return a table twice (one registry row, one stat row per phase), so this is taken as a copy artifact, to be checked in a saved report.
- `preflight.sql NEW` (R-000021): REDO_ESTIMATE and UNDO_ESTIMATE measured by R-000002. PASS, with one false warning: UNDO_ESTIMATE WARN for BULK_PAYMENT although PAYMENTS had 0 eligible roots (all purged), and the recommended batch size (740) came from that tree.
- `purge.sql NEW 30 LOGS LOGS - N Y` (R-000022, real purge with compaction): 1,722,146 rows in 00:00:48 (35,000 rows/s); residual 0; compaction of AUDIT_ARCHIVE, AUDIT_TRAIL and SPEC_TRT_LOG returned 1.2 GB to the tablespace (free 2.1 -> 3.3 GB). Verdict PASS WITH WARNINGS only because 1,195,572 AUDIT_TRAIL rows pointed at no AUDIT_ARCHIVE row before the purge (LINK_ORPHANS WARN, phase BEFORE); none after.
- `purge.sql NEW 30 BANK_STATEMENTS FULL 100 N N` (R-000023, undo tuning applied beforehand): 3,980,655 rows in 00:01:35 (1,989 batches); verdict PASS. Too fast to test the stop request. Space: 14.7 GB used before, 12.2 GB after although both tables are empty; to be diagnosed (LOB segments of deleted rows still counted as used).
- `status.sql`: severity PROGRESS ran into the event code (`PROGRESSBATCH_PROGRESS`).
- Words joined in the pasted output (`scansthis`, `0-`, `00`) are line wraps of the terminal when copying, not in the output.

Changes
- `epf_purge` preflight: REDO_ESTIMATE and UNDO_ESTIMATE skip trees with no eligible roots ("No rows before the cutoff"), a batch counts at most the eligible roots, and the undo kept by retention is at most the undo of all eligible roots (also shown). A module with nothing to purge no longer warns or lowers the recommended batch size.
- `epf_purge` orphans: LINK_ORPHANS is INFO before the purge and for orphans that were already there, WARN only for orphans the purge added (P4 still fails on those). Orphans in the application data no longer make P5 a warning.
- `epf_report`: column helpers never cut a value and always keep one space between columns; table column 45 characters (OPPAYMENTS.TRANSMISSION_EXECUTION_AUDIT has 39), Held 10, Orphans 12, status event columns 9 and 24.
- Wrapper: Ctrl+C requests a graceful stop also with `--non-interactive` when the console input is a keyboard (before: it ended the wrapper and left the worker running).
- Space diagnosis (per segment, R-000022 and R-000023): the LOB segments of DIRECTORY_DISPATCHING (7,986 MB) and FILE_DISPATCHING (4,254 MB) are BASICFILE (RETENTION 900) and read 7,947 MB and 4,189 MB used before and after the purge that emptied both tables; the table and index segments dropped as expected. `epf_space`: after a purge a BASICFILE LOB segment's use is the BASELINE measurement scaled by the share of rows the purge did not process (method `BASICFILE_EST`, the measured value when lower); `SPACE_CAPTURED` and P7 name these segments; the space section of the report explains them. R-000023 would read used 14.7 GB -> about 0.3 GB instead of 12.2 GB.
- Wizard: when the redo log sizing is chosen, the default batch size is computed for the new 1 GB logs from the largest redo per root (`EPF_ADVICE|REDO_PER_ROOT`), not from the current small logs (on 3 x 150 MB logs the recommendation is 100, with 1 GB about 530 for bulk payments).
- Tool version 0.4.1.

How to test (wrapper, new instance EPFPG783, from the Windows clone)
1. `epf_purge.bat install --tns <783>`: tool version 0.4.1. Optional: `environment.sql` survey of the new instance.
2. `--help`, `status` (no run recorded), `stop` (no active run: exit 1).
3. `preflight`: live events, report, run folder; exit 0 or 2.
4. `purge --depth PAYMENTS --undo-tuning` through the wizard: preflight run, redo sizing question (accept), batch size default for 1 GB logs, SYS password, review, `yes`; Ctrl+C after a few batches: STOPPED, undo restored, exit 3.
5. `status` after the stop.
6. Non-interactive rerun of PAYMENTS to the end with `--yes --undo-tuning` (passwords from EPF_PASSWORD / EPF_SYS_PASSWORD): in-run preflight, purge, restore, report; exit 0 or 2.
7. Wizard purge of LOGS,BANK_STATEMENTS: report shows the BASICFILE note, P7 names the scaled LOB segments.
8. Dry run with retention 1 (P1-P4, P6, P8 SKIP); `report` latest and by run id.
9. Usage errors: exit 4.
Return: console output, exit codes, `manifest.txt` and `report.txt` of each run folder.

## 2026-09-28 - Phases 3 and 4: report, compaction, wrapper (0.4.0)

Open questions answered with the plan defaults (to confirm)
- Compaction is delivered (opt-in, purge-only runs, default No).
- Rows not attached to any bulk payment (7,038 payments, 4,093 import audits and their children on EPFPG782) are kept, as today; they count as retained rows.

Phase 3 - report and compaction
- `epf_report` (new package): `evaluate` writes checks P1-P8 into the new table `EPF_CHECK` and derives the verdict (FAIL / PASS WITH WARNINGS / PASS, exit 1 / 2 / 0; 3 when the run was stopped); `close_run` evaluates and ends the run with the verdict; `print_report` prints header, steps, purge results per table, held roots, space inside segments per table, datafiles, redo and undo, checks, verdict and the machine-readable lines `EPF_CHECK|...`, `EPF_STEP|...`, `EPF_VERDICT|...`; `print_advice` (wizard) and `print_status`. A run ended FAILED fails P5 even without an ERROR event (a step outside the database failed, or the worker session ended).
- Orphans: after the purge (and before, for comparison) every registry link is checked for rows on the pointing side whose value no longer exists on the pointed side (new table `EPF_LINK_STAT`; `EPF_TABLE_STAT.orphan_rows`; `LINK_ORPHANS` WARN). A link protected by an enabled, validated FK is not scanned. P4 fails on new orphans only.
- Compaction (6.7): step `COMPACT` and `SPACE_POST_COMPACT` (phase `POST_COMPACT`). `start_run` accepts `with_compact = Y` for a PURGE that is not a dry run and does not reclaim. Events `COMPACTED` (bytes returned), `COMPACT_SKIPPED` (reason), `COMPACT_FAILED`, `ROW_MOVEMENT_KEPT`; check P8.
- `EPF_TABLE_STAT.action` (DELETE / CLEAR) so the report distinguishes residual rows from residual LOB values.
- `run/report.sql <run_id|LATEST>` (new). `run/purge.sql` takes a 7th argument `<compact>`; with NEW it ends the run with the report's verdict and prints the report (exit code = verdict). `run/preflight.sql` exits 2 when it finds warnings only (was 0).
- `install.sql` compiles `epf_report`; tool version 0.4.0.

Phase 4 - wrapper
- `src/bin/epf_purge.bat` (launcher) and `src/bin/lib/epf.ps1` (Windows PowerShell 5.1): actions purge, preflight, report, status, stop, install, uninstall and the wizard; options and exit codes as in plan 10.1; configuration file `src/config/epf_purge.conf` (example `epf_purge.conf.example`).
- Passwords: environment (`EPF_PASSWORD`, `EPF_SYS_PASSWORD`), configuration file or masked prompt; kept as SecureString; written only to sqlplus stdin (`CONNECT user/"pw"@tns`); never on a command line.
- One run = one monitor session (holds the run lock: `begin_run.sql`, then `poll.sql` every 2 s, `finish.sql` at the end; restarted and re-attached with `attach.sql` when a poll does not answer within 60 s) and one-shot worker sessions (`preflight.sql`, `purge.sql`, `report.sql`, SYS `redo_logs.sql` / `undo.sql`). `epf_log.poll` prints events, running steps, the worker's heartbeat (wait event, blocker, SQL_ID, longops, resumable suspension) and the run status.
- Live view: one line per event with `[ OK ]`, `[INFO]`, `[WARN]`, `[FAIL]`; heartbeat line `..` after 15 s without an event (console only unless it reports a suspension). Ctrl+C requests a graceful stop (`stop.sql`) instead of ending the wrapper.
- Wizard purge flow: connection, retention, mode, depth, dry run, compaction; a read-only PREFLIGHT run with these parameters; `advice.sql` findings drive the redo sizing and undo tuning questions and the batch size default (the recommendation); SYS password only when a SYS step was chosen; review; typed `yes` for a purge that deletes. The PURGE run refers to that preflight instead of repeating it. Undo tuning applied by the wrapper is restored in a `finally` block on every exit path.
- Run folder `logs/<yyyy-MM-dd_HHmmss>_R-<id>/`: `console.log`, `report.txt`, `manifest.txt` (parameters, step statuses, checks, verdict, exit code), `sqlplus_*.log` (raw worker output).
- `run/begin_run.sql`, `attach.sql`, `poll.sql`, `finish.sql` (monitor session; no EXIT), `advice.sql`, `status.sql`, `stop.sql <run_id|ACTIVE>` (new).
- Checked locally: PowerShell parser, ASCII only, and end-to-end runs of the wizard, non-interactive purge, failure paths and exit codes against a stand-in for sqlplus (no database here).
- Plan: 4.1, 6.7, 6.9, 8.1, 9.2, 9.3, 10.1, 10.2, 10.3, 13 (preflight errors exit 1, not 3).

How to test (EPFPG782)
SQL level, on the database machine:
1. If not done yet: `undo.sql RESTORE` as SYS (undo tuning from the PAYMENTS run is still active).
2. `git pull`, `install.sql`: tool version 0.4.0, `created  table EPF_LINK_STAT` and `EPF_CHECK`, all objects valid.
3. `report.sql LATEST` and `report.sql 2` (the PAYMENTS run R-000002): the report prints; P4 shows 0 links for runs of 0.2.x (orphans were not counted then).
4. `purge.sql NEW 30 LOGS LOGS - Y N` (dry run): report at the end, P1-P4, P6, P8 SKIP; exit 0 or 2 (`echo $?`).
5. `purge.sql NEW 30 LOGS LOGS - N Y` (LOGS purge with compaction): steps COMPACT and SPACE_POST_COMPACT, events COMPACTED / COMPACT_SKIPPED, P4 links counted, P8 with the bytes returned.
6. Stop: start `purge.sql NEW 30 BANK_STATEMENTS FULL 100 N N` in one session; once batches run, `stop.sql ACTIVE` from a second session; the first stops after its current batch and ends STOPPED (P1 WARN, exit 3). `status.sql` shows the run. Step 9 purges the rest.
Wrapper, on a Windows machine with sqlplus and a TNS alias for the PDB:
7. `src\bin\epf_purge.bat --help`; `src\bin\epf_purge.bat status --tns <alias>` (password prompt).
8. `src\bin\epf_purge.bat preflight --tns <alias>`: live events, report, run folder with `console.log`, `report.txt`, `manifest.txt`.
9. `src\bin\epf_purge.bat` (wizard) -> 1 Purge, BANK_STATEMENTS, FULL, dry run N, compact Y: preflight run, redo/undo questions if the findings call for them, batch size default = recommendation, review, `yes`. Watch the live view; `echo %ERRORLEVEL%` afterwards.
10. Ctrl+C during a purge run from the wrapper: `Stop requested`, run ends STOPPED, exit 3.
11. Return: console output of each step, and `manifest.txt` + `report.txt` of the wrapper runs.

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

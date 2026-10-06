CREATE OR REPLACE PACKAGE epf_report AUTHID DEFINER AS
-- ============================================================================
-- EPF Data Purge - Integrity and results report
-- ============================================================================
-- Evaluates the checks of a run from the structured data it recorded
-- (EPF_TABLE_STAT, EPF_LINK_STAT, EPF_SPACE_USAGE, EPF_TEMP_INDEX, EPF_EVENT)
-- into EPF_CHECK, derives the verdict, and prints the report.
--
-- Checks (status PASS, WARN, FAIL or SKIP)
--   P1  Residual: eligible rows left in deleting modules, non-empty LOB values
--       left in clearing modules. 0 PASS; otherwise FAIL (WARN when the purge
--       was stopped or failed).
--   P2  Accounting: rows processed = rows eligible at start, per table. Equal
--       PASS; more processed WARN (rows added during the run); fewer FAIL
--       (WARN when the purge was stopped or failed).
--   P3  Retention safety: rows kept (not eligible) after the purge >= before,
--       per table. PASS; fewer FAIL.
--   P4  Orphans on every registry link after the purge. None PASS; orphans
--       that already existed before WARN; new orphans FAIL. Links protected by
--       an enabled, validated FK pass by constraint.
--   P5  Errors: no ERROR event PASS; WARN events WARN; ERROR events FAIL
--       (RUN_END excluded). A run ended as FAILED fails P5 even without an
--       ERROR event (a step outside the database failed, or the worker
--       session ended).
--   P6  Temporary indexes of the run all dropped. PASS; still present FAIL.
--   P7  Space measured inside segments before and after the purge. PASS;
--       estimated or unsupported segments WARN; phase missing WARN.
--       BASICFILE LOB segments scaled by the rows kept (epf_space) are named
--       in the value, not a warning.
--   P8  Compaction (when requested): every candidate compacted PASS; skipped
--       or failed tables WARN.
-- Dry runs and runs without a purge: P1-P4, P6, P8 SKIP.
--
-- Reclaim runs: P5, and R1-R9 from the fingerprint the run took when the
-- accounts were locked and again before unlocking them
-- (EPF_OBJECT_BASELINE), its items (EPF_RECLAIM_OBJECT, EPF_RECLAIM_TS),
-- datafile snapshots and account actions. An assessment (dry run) skips R1-R9; a restore run checks
-- R1, R6 and R9 for what every reclaim left pending.
--   R1  Indexes the run released: every attribute identical and usable
--       again (one unusable before and left as found keeps its status).
--       PASS; an index dropped meanwhile WARN; unusable or different FAIL.
--   R2  Constraints of the tables in scope and foreign keys to the tables
--       that move: status, validated, deferral identical. Else FAIL.
--   R3  No object invalid after the recompilation that was valid before.
--       Else FAIL.
--   R4  Row counts of the tables that move identical (setting
--       reclaim_row_counts). A table not counted after WARN; different FAIL.
--   R5  Table and LOB attributes kept. A LOB stored as SECUREFILE, a new
--       LOB retention or segment name WARN; any other difference FAIL.
--   R6  Datafiles: growth settings restored as at the start; each tablespace
--       at most its start size plus reclaim_growth_mb per datafile at its
--       peak, and at most its start size at the end. Above the start size at
--       the end, or at the peak for an index that did not fit, WARN; a
--       setting not restored or any other excess FAIL.
--   R7  Efficiency: each tablespace ends within max(1 %, 256 MB) of its
--       segments plus reclaim_margin_mb per datafile. Else WARN, naming the
--       segment that stays at the top.
--   R8  Tables: every table above the highest segment that stays moved.
--       Tables that did not fit, were busy or not reached WARN; a failed
--       move FAIL.
--   R9  Accounts the run locked unlocked again. Else FAIL.
-- Without a baseline (nothing to move, or the run ended before the
-- compaction), R2-R5 and R8 SKIP; when the run ended before it took the
-- fingerprint again, R2-R5 WARN and R1 checks the indexes as they are now.
--
-- Verdict: FAIL when a check fails, PASS WITH WARNINGS when a check warns,
-- otherwise PASS; exit code 1, 2, 0.
-- ============================================================================

    -- Evaluates the checks of run p_run_id (replacing earlier results).
    -- p_status is the final status the run is about to be ended with; NULL
    -- evaluates against the stored status.
    PROCEDURE evaluate(p_run_id IN NUMBER, p_verdict OUT VARCHAR2, p_exit_code OUT NUMBER,
                       p_status IN VARCHAR2 DEFAULT NULL);

    -- Evaluates the checks, then ends the run (epf_control.finish) with
    -- p_status and the verdict. Exit code 3 when p_status is STOPPED,
    -- otherwise the verdict's. Called in the session holding the run lock.
    PROCEDURE close_run(p_run_id IN NUMBER, p_status IN VARCHAR2, p_exit_code OUT NUMBER);

    -- Prints the report of run p_run_id through DBMS_OUTPUT: run header,
    -- steps, purge results per module and table, held roots, then
    --   dry run   SIMULATION (forecast per module), held roots, triggers and
    --             sessions, RETENTION OPTIONS, REQUIREMENTS, EXPECTED outcome
    --   purge     FORECAST AND RESULT (the latest forecast with the same
    --             cutoff against the result, per module), REQUIREMENTS
    --   preflight ESTIMATE, RETENTION OPTIONS, REQUIREMENTS
    --   reclaim   TABLESPACES (sizes, forecast, end values), TABLES,
    --             INDEXES, SEGMENTS THAT STAY, ACCOUNTS, DATAFILES,
    --             REQUIREMENTS
    -- space inside segments, datafiles, redo and undo (purge), checks,
    -- verdict, and the machine-readable lines. Evaluates first.
    --   EPF_CHECK|<run>|<check_id>|<status>|<value>|<title>
    --   EPF_STEP|<run>|<phase>|<step>|<scope>|<status>|<elapsed seconds>
    --   EPF_REQ|<run>|<requirement>|<MET|NOT_MET|NOT_APPLICABLE>|<blocking Y|N>|<met by>
    --   EPF_EXPECTED|<run>|<COMPLETE|FAIL|MAY_FAIL>|<deleting seconds>|<bytes freed>|<redo bytes>
    --   EPF_FORECAST|<run>|<module>|<ROWS|REDO|UNDO|SECONDS|FREED>|<forecast>|<actual>|<forecast run>|<origin>
    --   EPF_VERDICT|<run>|<verdict>|exit=<n>
    --   EPF_PLAN|... and EPF_PLAN_STEP|... for the plan of the run (print_plan)
    --   EPF_PLAN_KEPT|<plan> when a preflight planned nothing: that plan of
    --                        another scope is in progress
    --   EPF_RECLAIM_TS|<run>|<tablespace>|<status>|<start bytes>|<end bytes>|
    --                  <peak bytes>|<forecast bytes>|<tables>|<indexes>|<moved>|
    --                  <pins>
    PROCEDURE print_report(p_run_id IN NUMBER);

    -- Prints the preflight findings of run p_run_id as machine-readable lines
    -- for the wizard:
    --   EPF_ADVICE|BATCH_SIZE|<n>          recommended batch size (REDO_SUMMARY)
    --   EPF_ADVICE|REDO_WARN|Y|N           a batch exceeds a whole online log
    --   EPF_ADVICE|REDO_PER_ROOT|<bytes>   largest redo per root of the trees
    --                                      with eligible roots
    --   EPF_ADVICE|UNDO_WARN|Y|N           the undo tablespace would grow
    --   EPF_ADVICE|UNDO_ACTIVE|Y|N         undo tuning currently applied
    --   EPF_ADVICE|ERRORS|<n> and WARNINGS|<n>
    --   EPF_ADVICE|ROOTS|<owner.table>|<eligible rows>   per root table
    --   EPF_ADVICE|READY|Y|N|-             every blocking requirement met
    --                                      (- when none was measured)
    --   EPF_ADVICE|REQ|<requirement>|<status>|<blocking>|<met by>
    --   EPF_ADVICE|REQTEXT|<requirement>|<title>|<measured>
    --   EPF_ADVICE|OPT|<requirement>|<option>|<met Y|N>|<detail>
    --   EPF_ADVICE|RUN_BATCH|<n>           batch size of the run
    --   EPF_ADVICE|UNDO_MAX_BATCH|<n>      largest batch whose undo the undo
    --                                      tablespace holds 4 times
    PROCEDURE print_advice(p_run_id IN NUMBER);

    -- Prints the other sessions of the tool schema (wait event, blocker,
    -- SQL_ID), then the state of the active run (or the latest one): status,
    -- steps not DONE, the last events, temporary indexes still present,
    -- active undo tuning, and what a reclaim left pending: datafile growth
    -- settings, indexes still released (unusable), accounts still locked.
    PROCEDURE print_status;

    -- Prints a plan of smaller runs with its steps: the open plan (p_which
    -- OPEN), the open plan or else the latest one (CURRENT), the latest plan
    -- (LATEST) or plan p_which (its number, or P-000123). Machine lines
    -- EPF_PLAN and EPF_PLAN_STEP (see the report's PLAN section); 'No open
    -- plan.' when there is none.
    PROCEDURE print_plan(p_which IN VARCHAR2);

END epf_report;
/

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
    -- steps, purge results per module and table, held roots, space inside
    -- segments, datafiles, redo and undo, checks, verdict, and the
    -- machine-readable lines. Evaluates first.
    --   EPF_CHECK|<run>|<check_id>|<status>|<value>|<title>
    --   EPF_STEP|<run>|<phase>|<step>|<scope>|<status>|<elapsed seconds>
    --   EPF_VERDICT|<run>|<verdict>|exit=<n>
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
    PROCEDURE print_advice(p_run_id IN NUMBER);

    -- Prints the state of the active run (or the latest one): status, steps
    -- not DONE, the last events, temporary indexes still present, active
    -- undo tuning, accounts still locked by a reclaim.
    PROCEDURE print_status;

END epf_report;
/

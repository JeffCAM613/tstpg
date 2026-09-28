CREATE OR REPLACE PACKAGE epf_control AUTHID DEFINER AS
-- ============================================================================
-- EPF Data Purge - Run lifecycle
-- ============================================================================
-- A run is created by start_run and returns its run_id. One session attaches
-- to the run (attach) and holds the exclusive run lock for its whole life;
-- normally this is the wrapper's monitor session. Worker sessions bind to the
-- run with enter. Only one run can be attached at a time in a database.
--
-- Statuses: CREATED -> RUNNING -> SUCCESS | WARNING | FAILED | STOPPED.
-- A CREATED or RUNNING run whose lock is no longer held is marked ABANDONED
-- when the next run starts.
--
-- Error codes
--   ORA-20121  invalid action
--   ORA-20122  another run is active
--   ORA-20123  run lock held by another session
--   ORA-20124  run not found or not running
--   ORA-20125  invalid depth
--   ORA-20126  invalid mode
--   ORA-20127  invalid parameter value
-- ============================================================================

    -- Creates a run. Purge parameters are validated and normalised for
    -- actions PURGE and PREFLIGHT; missing values take their setting default.
    -- Before inserting, stale runs are marked ABANDONED and history older
    -- than history_retention_days is removed.
    FUNCTION start_run(
        p_action         IN VARCHAR2,
        p_retention_days IN NUMBER   DEFAULT NULL,
        p_depth          IN VARCHAR2 DEFAULT NULL,
        p_mode           IN VARCHAR2 DEFAULT NULL,
        p_batch_size     IN NUMBER   DEFAULT NULL,
        p_dry_run        IN VARCHAR2 DEFAULT 'N',
        p_with_reclaim   IN VARCHAR2 DEFAULT 'N',
        p_with_compact   IN VARCHAR2 DEFAULT 'N'
    ) RETURN NUMBER;

    -- Takes the run lock in this session, sets the run RUNNING and binds the
    -- session to it. Emits RUN_START.
    PROCEDURE attach(p_run_id IN NUMBER);

    -- Binds a worker session to a RUNNING run and sets its phase.
    PROCEDURE enter(p_run_id IN NUMBER, p_phase IN VARCHAR2 DEFAULT NULL);

    -- Ends a run with SUCCESS, WARNING, FAILED or STOPPED, records verdict and
    -- exit code, emits RUN_END, and releases the lock if held here.
    PROCEDURE finish(
        p_run_id    IN NUMBER,
        p_status    IN VARCHAR2,
        p_verdict   IN VARCHAR2 DEFAULT NULL,
        p_exit_code IN NUMBER   DEFAULT NULL,
        p_message   IN VARCHAR2 DEFAULT NULL
    );

    -- Requests a graceful stop; engines check stop_requested at safe points.
    PROCEDURE request_stop(p_run_id IN NUMBER);
    FUNCTION stop_requested(p_run_id IN NUMBER) RETURN BOOLEAN;

    -- Latest run (any status), and the run currently holding the lock.
    FUNCTION latest_run_id RETURN NUMBER;
    FUNCTION active_run_id RETURN NUMBER;

    -- Normalised depth: 'ALL' or module codes in display order, comma-separated.
    FUNCTION normalize_depth(p_depth IN VARCHAR2) RETURN VARCHAR2;

    -- Normalised mode: FULL, CLOB, LOGS or CLOB_N_LOGS.
    FUNCTION normalize_mode(p_mode IN VARCHAR2) RETURN VARCHAR2;

END epf_control;
/

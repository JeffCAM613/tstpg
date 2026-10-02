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
    -- The cutoff is TRUNC(SYSDATE) - p_retention_days, or p_cutoff_date when
    -- given (the retention is then the days between them; giving both is an
    -- error), so a purge run on a later day can keep the cutoff of its
    -- preflight. p_with_undo_tuning: undo tuning is planned for the purge
    -- (PURGE: the caller applies it unless dry run; PREFLIGHT and dry runs
    -- check the requirements as if it were applied). p_backup_choice: CONFIRMED or NONE, how the
    -- operator meets the BACKUP requirement without a recent RMAN backup.
    -- p_confirm: blocking requirements (ARCHIVE, UNDO, TEMP, separated by
    -- commas) the operator confirms are handled although the preflight finds
    -- them not met. p_with_redo_logs: the online redo logs are enlarged when
    -- the purge starts (the caller does it unless dry run; PREFLIGHT and dry
    -- runs check as if it were done). Before inserting, stale runs are marked
    -- ABANDONED and history older than history_retention_days is removed.
    FUNCTION start_run(
        p_action           IN VARCHAR2,
        p_retention_days   IN NUMBER   DEFAULT NULL,
        p_depth            IN VARCHAR2 DEFAULT NULL,
        p_mode             IN VARCHAR2 DEFAULT NULL,
        p_batch_size       IN NUMBER   DEFAULT NULL,
        p_dry_run          IN VARCHAR2 DEFAULT 'N',
        p_with_reclaim     IN VARCHAR2 DEFAULT 'N',
        p_with_compact     IN VARCHAR2 DEFAULT 'N',
        p_with_undo_tuning IN VARCHAR2 DEFAULT 'N',
        p_backup_choice    IN VARCHAR2 DEFAULT NULL,
        p_cutoff_date      IN DATE     DEFAULT NULL,
        p_confirm          IN VARCHAR2 DEFAULT NULL,
        p_with_redo_logs   IN VARCHAR2 DEFAULT 'N'
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

    -- The operator's choices for a running PURGE or PREFLIGHT run, validated
    -- as in start_run: batch size, undo tuning and redo log sizing planned,
    -- backup choice and confirmed requirements. A preflight keeps them as the
    -- choices a later purge with the same scope follows.
    PROCEDURE set_choices(
        p_run_id           IN NUMBER,
        p_batch_size       IN NUMBER,
        p_with_undo_tuning IN VARCHAR2,
        p_with_redo_logs   IN VARCHAR2,
        p_backup_choice    IN VARCHAR2,
        p_confirm          IN VARCHAR2
    );

    -- The choices saved with the latest PREFLIGHT run of the scope (cutoff
    -- from p_cutoff_date or p_retention_days, mode, depth), ended SUCCESS or
    -- WARNING within preflight_valid_h, through DBMS_OUTPUT:
    --   EPF_SAVED|<run>|<run_id>|<batch>|<undo Y|N>|<redo logs Y|N>|<backup|->
    --            |<confirmed|->|<ready Y|N|->|<created HH24:MI>|<valid until>
    -- Nothing is printed when there is no such run.
    PROCEDURE print_saved_choices(
        p_retention_days IN NUMBER,
        p_cutoff_date    IN DATE,
        p_mode           IN VARCHAR2,
        p_depth          IN VARCHAR2
    );

END epf_control;
/

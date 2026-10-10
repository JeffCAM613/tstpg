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
--   ORA-20128  a plan is in progress, or the plan step is not open
--
-- Plans (EPF_PLAN, EPF_PLAN_STEP): a PREFLIGHT run creates the plan of its
-- scope or checks the open plan again (epf_purge); at most one plan is open.
-- A purge that deletes either carries out the next step of the open plan
-- (plan_id, plan_step), or replaces a plan not started yet; a plan in
-- progress is closed only on request (new_plan, or close_plan). A purge run
-- ending without residual rows completes its step; the last step completes
-- the plan (DONE).
-- ============================================================================

    -- Creates a run. Purge parameters are validated and normalised for
    -- actions PURGE and PREFLIGHT; missing values take their setting default.
    -- The cutoff is TRUNC(SYSDATE) - p_retention_days, or p_cutoff_date when
    -- given (the retention is then the days between them; giving both is an
    -- error), so a purge run on a later day can keep the cutoff of its
    -- preflight. Every PURGE and PREFLIGHT run is created with undo tuning
    -- planned (with_undo_tuning Y, whatever p_with_undo_tuning says): a purge
    -- that deletes starts only once the caller applied it (epf_tuning, SYS);
    -- PREFLIGHT and dry runs check the requirements as if it were applied;
    -- p_with_undo_tuning Y for another action is an error. p_backup_choice: CONFIRMED or NONE, how the
    -- operator meets the BACKUP requirement without a recent RMAN backup.
    -- p_confirm: blocking requirements the operator confirms are handled
    -- although the preflight finds them not met, separated by commas: ARCHIVE,
    -- UNDO, TEMP for a purge or preflight; ARCHIVE, TEMP, RECYCLEBIN for a
    -- reclaim (whose dry run is its assessment). p_with_redo_logs: the online redo logs are enlarged when
    -- the purge starts (the caller does it unless dry run; PREFLIGHT and dry
    -- runs check as if it were done). p_max_redo_bytes: the most redo one
    -- run of the plan may write (a preflight plans its steps with it).
    -- p_new_plan Y: the run starts over: the open plan is closed (a preflight
    -- then creates a new one). p_plan_id, p_plan_step: the plan step a purge
    -- run carries out (a dry run rehearses it); its mode, depth and cutoff
    -- must be the step's. Before inserting, stale runs are marked ABANDONED
    -- and history older than history_retention_days is removed.
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
        p_with_redo_logs   IN VARCHAR2 DEFAULT 'N',
        p_max_redo_bytes   IN NUMBER   DEFAULT NULL,
        p_new_plan         IN VARCHAR2 DEFAULT 'N',
        p_plan_id          IN NUMBER   DEFAULT NULL,
        p_plan_step        IN NUMBER   DEFAULT NULL
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
    -- as in start_run: batch size, redo log sizing planned, backup choice and
    -- confirmed requirements; undo tuning stays planned (every purge runs
    -- with it; p_with_undo_tuning is only validated). A preflight keeps them
    -- as the choices a later purge with the same scope follows.
    PROCEDURE set_choices(
        p_run_id           IN NUMBER,
        p_batch_size       IN NUMBER,
        p_with_undo_tuning IN VARCHAR2,
        p_with_redo_logs   IN VARCHAR2,
        p_backup_choice    IN VARCHAR2,
        p_confirm          IN VARCHAR2
    );

    -- The open plan (READY or IN_PROGRESS); NULL when none.
    FUNCTION open_plan_id RETURN NUMBER;

    -- Closes the open plan (CLOSED, with the OS user and p_reason); p_plan_id
    -- returns it, NULL when no plan was open. Completed steps stay done.
    PROCEDURE close_plan(p_reason IN VARCHAR2, p_plan_id OUT NUMBER);

    -- At the end of purge run p_run_id: when it carried out a plan step and
    -- p_complete (ended SUCCESS or WARNING without residual rows), the step
    -- is DONE, and the plan too after its last step. A stopped or failed
    -- step stays PENDING and is offered again. Emits PLAN_STEP.
    PROCEDURE end_plan_step(p_run_id IN NUMBER, p_complete IN BOOLEAN);

    -- At the end of preflight run p_run_id with status p_status: a preflight
    -- that did not end SUCCESS or WARNING leaves no plan to follow. The plan
    -- it made is closed; a plan it checked again keeps its previous check.
    -- Emits PLAN.
    PROCEDURE end_plan_check(p_run_id IN NUMBER, p_status IN VARCHAR2);

END epf_control;
/

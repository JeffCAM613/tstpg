CREATE OR REPLACE PACKAGE epf_log AUTHID DEFINER AS
-- ============================================================================
-- EPF Data Purge - Events and steps
-- ============================================================================
-- Writes the event stream (EPF_EVENT) and the step checklist (EPF_STEP) of a
-- run. Every write is an autonomous transaction, so events are visible to the
-- live monitor immediately and survive a rollback of the caller.
--
-- A session is bound to a run with set_context (normally through
-- epf_control.attach / epf_control.enter). Events carry the current phase and step
-- of the session. The session is also tagged for V$SESSION:
--   MODULE = 'EPF', ACTION = current step, CLIENT_INFO = 'run=<id>',
--   CLIENT_IDENTIFIER = 'EPF:<id>'.
--
-- Errors while writing an event are raised to the caller: a run that cannot
-- record what it does must not continue.
-- ============================================================================

    c_info     CONSTANT VARCHAR2(10) := 'INFO';
    c_ok       CONSTANT VARCHAR2(10) := 'OK';
    c_warn     CONSTANT VARCHAR2(10) := 'WARN';
    c_error    CONSTANT VARCHAR2(10) := 'ERROR';
    c_progress CONSTANT VARCHAR2(10) := 'PROGRESS';

    -- Binds the session to a run and phase; clears the current step.
    PROCEDURE set_context(p_run_id IN NUMBER, p_phase IN VARCHAR2 DEFAULT NULL);

    -- Changes the phase of the bound session.
    PROCEDURE set_phase(p_phase IN VARCHAR2);

    -- Run bound to this session (NULL when none).
    FUNCTION current_run RETURN NUMBER;

    -- Writes one event. p_run_id defaults to the bound run; ORA-20110 when
    -- neither is available, ORA-20111 for an unknown severity.
    PROCEDURE event(
        p_severity     IN VARCHAR2,
        p_event_code   IN VARCHAR2,
        p_message      IN VARCHAR2,
        p_object_owner IN VARCHAR2 DEFAULT NULL,
        p_object_name  IN VARCHAR2 DEFAULT NULL,
        p_sub_name     IN VARCHAR2 DEFAULT NULL,
        p_rows         IN NUMBER   DEFAULT NULL,
        p_bytes        IN NUMBER   DEFAULT NULL,
        p_pct          IN NUMBER   DEFAULT NULL,
        p_elapsed_s    IN NUMBER   DEFAULT NULL,
        p_ora_code     IN NUMBER   DEFAULT NULL,
        p_run_id       IN NUMBER   DEFAULT NULL
    );

    -- Shorthands for event() with a fixed severity.
    PROCEDURE info (p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                    p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL);
    PROCEDURE ok   (p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                    p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL);
    PROCEDURE warn (p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                    p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL);
    PROCEDURE error(p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                    p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL,
                    p_ora_code IN NUMBER DEFAULT NULL);

    -- Registers a step as PENDING so it appears in the checklist before it
    -- starts. The phase defaults to the session phase.
    PROCEDURE step_plan(p_step_code IN VARCHAR2, p_scope IN VARCHAR2 DEFAULT NULL,
                        p_phase IN VARCHAR2 DEFAULT NULL);

    -- Starts a step (registering it if needed) and makes it the session's
    -- current step. Emits STEP_START.
    PROCEDURE step_start(p_step_code IN VARCHAR2, p_scope IN VARCHAR2 DEFAULT NULL,
                         p_units_total IN NUMBER DEFAULT NULL, p_bytes_total IN NUMBER DEFAULT NULL);

    -- Updates progress counters of the current step.
    PROCEDURE step_progress(p_units_done IN NUMBER, p_bytes_done IN NUMBER DEFAULT NULL);

    -- Ends the current step with DONE, FAILED or SKIPPED. Emits STEP_END.
    -- ORA-20112 when no step is running in this session.
    PROCEDURE step_end(p_status IN VARCHAR2 DEFAULT 'DONE', p_message IN VARCHAR2 DEFAULT NULL);

    -- Prints the events of a run through DBMS_OUTPUT, one line per event.
    PROCEDURE print_events(p_run_id IN NUMBER, p_after_event_id IN NUMBER DEFAULT 0);

END epf_log;
/

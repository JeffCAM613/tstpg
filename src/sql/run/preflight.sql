-- ============================================================================
-- EPF Data Purge - Preflight
-- ============================================================================
-- Purpose : Read-only checks before a run. Current checks: registry
--           validation against the live database (epf_registry.validate).
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/preflight.sql <run_id|NEW>
--             <run_id>  bind to a run created by start_run.sql and attached by
--                       the caller's monitor session
--             NEW       create, attach and finish a standalone PREFLIGHT run in
--                       this session (manual use)
-- Requires: EPFPG (or SYS).
-- Effects : Writes events and steps of the run; changes nothing else.
--           Exit code 0 when no check failed, 1 otherwise.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 400 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE run_arg = "&1"

VARIABLE run_id NUMBER
VARIABLE rc     NUMBER

BEGIN
    IF UPPER('&run_arg') = 'NEW' THEN
        :run_id := epfpg.epf_control.start_run(p_action => 'PREFLIGHT');
        epfpg.epf_control.attach(:run_id);
    ELSE
        :run_id := TO_NUMBER('&run_arg');
    END IF;
    epfpg.epf_control.enter(:run_id, 'PREFLIGHT');
END;
/

DECLARE
    l_errors   PLS_INTEGER;
    l_warnings PLS_INTEGER;
BEGIN
    epfpg.epf_log.step_start('REGISTRY');
    epfpg.epf_registry.validate(l_errors, l_warnings);
    epfpg.epf_log.step_end(CASE WHEN l_errors > 0 THEN 'FAILED' ELSE 'DONE' END,
                           l_errors || ' errors, ' || l_warnings || ' warnings');
    :rc := CASE WHEN l_errors > 0 THEN 1 ELSE 0 END;

    IF UPPER('&run_arg') = 'NEW' THEN
        epfpg.epf_control.finish(
            p_run_id    => :run_id,
            p_status    => CASE WHEN l_errors > 0 THEN 'FAILED'
                                WHEN l_warnings > 0 THEN 'WARNING'
                                ELSE 'SUCCESS' END,
            p_exit_code => CASE WHEN l_errors > 0 THEN 1 WHEN l_warnings > 0 THEN 2 ELSE 0 END);
        epfpg.epf_log.print_events(:run_id);
    END IF;
END;
/

EXIT :rc

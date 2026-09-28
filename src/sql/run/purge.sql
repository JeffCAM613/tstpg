-- ============================================================================
-- EPF Data Purge - Purge
-- ============================================================================
-- Purpose : Runs the purge phase of a run (epf_purge.run).
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/purge.sql
--             <run_id|NEW> <retention_days> <depth> <mode> <batch_size> <dry_run>
--           <run_id> - - - - -
--               purge phase of a run created by start_run.sql and attached by
--               the caller's monitor session; the parameters are those of
--               the run, so the other five arguments must be -
--           NEW <retention_days> <depth> <mode> <batch_size> <dry_run>
--               create, attach and finish a standalone PURGE run in this
--               session (manual use); - takes the default of an argument
--               retention_days  whole number of days
--               depth           ALL or modules separated by commas
--               mode            FULL | CLOB | LOGS | CLOB_N_LOGS
--               batch_size      root rows per batch
--               dry_run         Y (snapshot and counts only) | N
-- Requires: EPFPG.
-- Effects : Deletes or clears LOBs of eligible rows as described in the
--           epf_purge package, and writes events, steps and counts.
--           Exit code 0 SUCCESS, 2 WARNING, 3 STOPPED, 1 FAILED.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE run_arg    = "&1"
DEFINE retention  = "&2"
DEFINE depth      = "&3"
DEFINE purge_mode = "&4"
DEFINE batch_size = "&5"
DEFINE dry_run    = "&6"

VARIABLE run_id NUMBER
VARIABLE rc     NUMBER

DECLARE
    FUNCTION arg(p_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN TRIM(p_value) = '-' THEN NULL ELSE TRIM(p_value) END;
    END arg;
BEGIN
    IF UPPER('&run_arg') = 'NEW' THEN
        :run_id := epfpg.epf_control.start_run(
            p_action         => 'PURGE',
            p_retention_days => TO_NUMBER(arg('&retention')),
            p_depth          => arg('&depth'),
            p_mode           => arg('&purge_mode'),
            p_batch_size     => TO_NUMBER(arg('&batch_size')),
            p_dry_run        => NVL(arg('&dry_run'), 'N'));
        epfpg.epf_control.attach(:run_id);
    ELSE
        IF COALESCE(arg('&retention'), arg('&depth'), arg('&purge_mode'),
                    arg('&batch_size'), arg('&dry_run')) IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20127, 'With a run id the other arguments must be -: '
                                            || 'the purge parameters are those of the run.');
        END IF;
        :run_id := TO_NUMBER('&run_arg');
    END IF;
    epfpg.epf_control.enter(:run_id, 'PURGE');
END;
/

DECLARE
    l_status VARCHAR2(20);
BEGIN
    epfpg.epf_purge.run(:run_id, l_status);
    :rc := CASE l_status WHEN 'SUCCESS' THEN 0 WHEN 'WARNING' THEN 2 WHEN 'STOPPED' THEN 3 ELSE 1 END;

    IF UPPER('&run_arg') = 'NEW' THEN
        epfpg.epf_control.finish(p_run_id => :run_id, p_status => l_status, p_exit_code => :rc);
        epfpg.epf_log.print_events(:run_id);
    END IF;
END;
/

EXIT :rc

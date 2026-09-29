-- ============================================================================
-- EPF Data Purge - Stop
-- ============================================================================
-- Purpose : Requests a graceful stop of a run (epf_control.request_stop); the
--           purge stops after its current batch.
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/stop.sql <run_id|ACTIVE>
-- Requires: EPFPG.
-- Effects : Sets the stop request of the run. Exit code 1 when no run is
--           running.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

DECLARE
    l_run_id NUMBER;
BEGIN
    IF UPPER(TRIM('&1')) = 'ACTIVE' THEN
        l_run_id := epfpg.epf_control.active_run_id;
    ELSE
        l_run_id := TO_NUMBER('&1');
    END IF;
    IF l_run_id IS NULL THEN
        RAISE_APPLICATION_ERROR(-20124, 'No run is active.');
    END IF;
    epfpg.epf_control.request_stop(l_run_id);
    DBMS_OUTPUT.PUT_LINE('Stop requested for ' || epfpg.epf_util.run_label(l_run_id)
                         || '; it stops after the current batch.');
END;
/

EXIT SUCCESS

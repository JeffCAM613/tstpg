-- ============================================================================
-- EPF Data Purge - Finish a run in the monitor session
-- ============================================================================
-- Purpose : Evaluates the checks of the run and ends it with the given status
--           and the verdict (epf_report.close_run); releases the run lock.
-- Usage   : @src/sql/run/finish.sql <run_id> <SUCCESS|WARNING|FAILED|STOPPED>
--           in the monitor session that attached the run.
-- Requires: EPFPG.
-- Effects : Writes the checks and the final run status; prints
--           EPF_EXIT=<exit_code>. Does not exit; errors are printed and the
--           session continues.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
    l_exit NUMBER;
BEGIN
    epfpg.epf_report.close_run(TO_NUMBER('&1'), UPPER('&2'), l_exit);
    DBMS_OUTPUT.PUT_LINE('EPF_EXIT=' || l_exit);
END;
/

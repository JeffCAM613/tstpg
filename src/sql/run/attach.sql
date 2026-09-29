-- ============================================================================
-- EPF Data Purge - Re-attach a run in a new monitor session
-- ============================================================================
-- Purpose : Takes the run lock of a RUNNING run in this session (used when the
--           wrapper restarts its monitor session).
-- Usage   : @src/sql/run/attach.sql <run_id>
--           in a connected, persistent sqlplus session (EPFPG).
-- Requires: EPFPG.
-- Effects : Prints EPF_ATTACHED=<run_id>. Does not exit; errors are printed
--           and the session continues.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

BEGIN
    epfpg.epf_control.attach(TO_NUMBER('&1'));
    DBMS_OUTPUT.PUT_LINE('EPF_ATTACHED=&1');
END;
/

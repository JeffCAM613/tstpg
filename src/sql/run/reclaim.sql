-- ============================================================================
-- EPF Data Purge - Reclaim
-- ============================================================================
-- Purpose : Runs a reclaim run in this session (epf_reclaim.run): the
--           assessment, the compaction in place of the tablespaces, or the
--           restore path of an interrupted reclaim.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/run/reclaim.sql <run_id> <mode> <tablespaces>
--             run_id       a RECLAIM run created by begin_run.sql and attached
--                          by the caller's monitor session
--             mode         ASSESS (the run is a dry run), COMPACT, or RESTORE
--                          (restores what a reclaim left pending: released
--                          indexes, datafile settings, locked accounts)
--             tablespaces  tablespaces separated by commas; - for every
--                          candidate
-- Requires: SYS AS SYSDBA (the package runs with the caller's rights);
--           single-instance database.
-- Effects : As described in the epf_reclaim package. Prints
--           EPF_RECLAIM_STATUS=<status> when the run ended in this session
--           (without it, the session ended first: the caller restores in mode
--           RESTORE). Exit code 0 SUCCESS, 2 WARNING, 3 STOPPED, 1 FAILED.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE run_arg     = "&1"
DEFINE mode_arg    = "&2"
DEFINE scope_arg   = "&3"

VARIABLE rc NUMBER

BEGIN
    epfpg.epf_control.enter(TO_NUMBER('&run_arg'), 'RECLAIM');
END;
/

DECLARE
    l_status VARCHAR2(20);
BEGIN
    epfpg.epf_reclaim.run(TO_NUMBER('&run_arg'), '&mode_arg', NULLIF(TRIM('&scope_arg'), '-'), l_status);
    DBMS_OUTPUT.PUT_LINE('EPF_RECLAIM_STATUS=' || l_status);
    :rc := CASE l_status WHEN 'SUCCESS' THEN 0 WHEN 'WARNING' THEN 2 WHEN 'STOPPED' THEN 3 ELSE 1 END;
END;
/

EXIT :rc

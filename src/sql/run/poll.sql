-- ============================================================================
-- EPF Data Purge - Monitor poll
-- ============================================================================
-- Purpose : One poll of the live view (epf_log.poll): new events, running
--           steps, heartbeat of the worker sessions, run status.
-- Usage   : @src/sql/run/poll.sql <run_id> <after_event_id>
--           in a connected, persistent sqlplus session (EPFPG).
-- Requires: EPFPG.
-- Effects : None (reads only). Does not exit; errors are printed and the
--           session continues.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

BEGIN
    epfpg.epf_log.poll(TO_NUMBER('&1'), TO_NUMBER('&2'));
END;
/

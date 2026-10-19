-- ============================================================================
-- EPF Data Purge - What the database's files take on disk
-- ============================================================================
-- Purpose : NOW: prints what the database's files take on disk now
--           (datafiles, temporary files, online redo logs) as
--           EPF_DISK|NOW|<bytes>. <run_id>: records what they took during
--           that purge (DISK_PEAK), from the size at its start and the most
--           the monitor saw, with the size now (epf_purge.record_disk).
-- Usage   : @src/sql/run/disk.sql NOW - -
--           @src/sql/run/disk.sql <run_id> <bytes at the start> <most seen>
--           in a connected, persistent sqlplus session (EPFPG): the
--           wrapper's monitor.
-- Requires: EPFPG.
-- Effects : NOW reads only. <run_id> writes one event of that run.
--           Does not exit; errors are printed and the session continues.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

BEGIN
    IF UPPER('&1') = 'NOW' THEN
        DBMS_OUTPUT.PUT_LINE('EPF_DISK|NOW|' || epfpg.epf_util.files_bytes);
    ELSE
        epfpg.epf_purge.record_disk(TO_NUMBER('&1'), TO_NUMBER(NULLIF('&2', '-')), TO_NUMBER(NULLIF('&3', '-')));
    END IF;
END;
/

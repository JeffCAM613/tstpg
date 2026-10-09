-- ============================================================================
-- EPF Data Purge - Online redo log sizing for a purge (opt-in)
-- ============================================================================
-- Purpose : Before a purge, replaces undersized online redo log groups with
--           larger ones (epf_tuning.enlarge_redo), so that the purge does not
--           wait on 'log file switch (checkpoint incomplete)'; after it, puts
--           the original groups back (epf_tuning.redo_restore).
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/run/redo_logs.sql <size_mb|-> <groups|-> [<run_id>]
--           sqlplus -L "sys@<service> AS SYSDBA" @src/sql/run/redo_logs.sql RESTORE
--             size_mb  size of each group in MB (- for 1024)
--             groups   number of groups to keep (- for 4)
--             run_id   the purge run: nothing changes when one batch of it
--                      fits in the smallest online log
--             RESTORE  put the recorded original groups back
-- Requires: SYS AS SYSDBA; single-instance, non-CDB database; free space in
--           the redo log directory for the new files (size_mb x groups x
--           members per group).
-- Effects : Adds the new groups, drops the smaller groups once inactive and
--           deletes their files; every group dropped and added is recorded in
--           EPFPG.EPF_INSTANCE_CHANGE first. RESTORE adds the original groups
--           again (same numbers, names and sizes) and drops the added ones.
--           Printed line by line.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

-- Optional arguments 2 and 3: defined as empty when not given (a query
-- without rows defines a NEW_VALUE variable that is not defined yet and keeps
-- the value of one that is).
SET TERMOUT OFF
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
SELECT NULL AS "2", NULL AS "3" FROM dual WHERE 1 = 0;
SET TERMOUT ON

DEFINE size_mb = "&1"
DEFINE groups  = "&2"
DEFINE run_arg = "&3"

DECLARE
    FUNCTION arg(p_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN TRIM(p_value) = '-' THEN NULL ELSE TRIM(p_value) END;
    END arg;
BEGIN
    IF UPPER(TRIM('&size_mb')) = 'RESTORE' THEN
        epfpg.epf_tuning.redo_restore;
    ELSE
        epfpg.epf_tuning.enlarge_redo(p_size_mb => NVL(TO_NUMBER(arg('&size_mb')), 1024),
                                      p_groups  => NVL(TO_NUMBER(arg('&groups')), 4),
                                      p_run_id  => TO_NUMBER(arg('&run_arg')));
    END IF;
END;
/

EXIT SUCCESS

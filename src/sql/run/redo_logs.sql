-- ============================================================================
-- EPF Data Purge - Online redo log sizing (opt-in)
-- ============================================================================
-- Purpose : Replaces undersized online redo log groups with larger ones
--           (epf_tuning.enlarge_redo), so that a purge does not wait on 'log file
--           switch (checkpoint incomplete)'.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/run/redo_logs.sql <size_mb|-> <groups|->
--             size_mb  size of each group in MB (- for 1024)
--             groups   number of groups to keep (- for 4)
-- Requires: SYS AS SYSDBA; single-instance, non-CDB database; free space in
--           the redo log directory for the new files (size_mb x groups x
--           members per group).
-- Effects : Adds the new groups, drops the smaller groups once inactive and
--           deletes their files. Permanent; printed line by line.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

DEFINE size_mb = "&1"
DEFINE groups  = "&2"

DECLARE
    FUNCTION arg(p_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN TRIM(p_value) = '-' THEN NULL ELSE TRIM(p_value) END;
    END arg;
BEGIN
    epfpg.epf_tuning.enlarge_redo(p_size_mb => NVL(TO_NUMBER(arg('&size_mb')), 1024),
                                  p_groups  => NVL(TO_NUMBER(arg('&groups')), 4));
END;
/

EXIT SUCCESS

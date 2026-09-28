-- ============================================================================
-- EPF Data Purge - Create a run
-- ============================================================================
-- Purpose : Validates the run parameters and creates the run.
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/start_run.sql
--             <action> <retention_days> <depth> <mode> <batch_size> <dry_run> <reclaim> <compact>
--           action          PURGE | RECLAIM | PREFLIGHT
--           retention_days  whole number of days, or - for the default
--           depth           ALL or modules separated by commas, or - for ALL
--           mode            FULL | CLOB | LOGS | CLOB_N_LOGS, or - for FULL
--           batch_size      rows per batch, or - for the default
--           dry_run, reclaim, compact   Y | N
-- Requires: EPFPG.
-- Effects : Inserts the run (status CREATED). Prints one line
--           EPF_RUN_ID=<run_id>. Invalid parameters end with ORA-2012x and
--           exit code 1.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 400 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DECLARE
    FUNCTION arg(p_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN TRIM(p_value) = '-' THEN NULL ELSE TRIM(p_value) END;
    END arg;
    l_run_id NUMBER;
BEGIN
    l_run_id := epfpg.epf_control.start_run(
        p_action         => arg('&1'),
        p_retention_days => TO_NUMBER(arg('&2')),
        p_depth          => arg('&3'),
        p_mode           => arg('&4'),
        p_batch_size     => TO_NUMBER(arg('&5')),
        p_dry_run        => arg('&6'),
        p_with_reclaim   => arg('&7'),
        p_with_compact   => arg('&8'));
    DBMS_OUTPUT.PUT_LINE('EPF_RUN_ID=' || l_run_id);
END;
/

EXIT SUCCESS

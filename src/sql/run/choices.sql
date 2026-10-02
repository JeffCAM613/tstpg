-- ============================================================================
-- EPF Data Purge - Operator's choices for a run
-- ============================================================================
-- Purpose : Saves the operator's choices with a running PREFLIGHT or PURGE
--           run (epf_control.set_choices) and checks the requirements again
--           with them (epf_purge.recheck), without scanning any table.
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/choices.sql
--             <run_id> <batch_size> <undo_tuning> <redo_logs> <backup> <confirm>
--           run_id       a run created by begin_run.sql and attached by the
--                        caller's monitor session, after its preflight
--           batch_size   root rows per batch, or - for the default
--           undo_tuning  Y when undo tuning is planned for the purge
--           redo_logs    Y when the online redo logs are enlarged when the
--                        purge starts
--           backup       CONFIRMED, NONE, or - for a recent RMAN backup
--           confirm      requirements the DBA confirms (ARCHIVE, UNDO, TEMP
--                        separated by commas), or -
-- Requires: EPFPG.
-- Effects : Updates the run's choices and writes its requirements and
--           forecast again; changes nothing else. Exit code 0, or 2 when the
--           checks warn.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

VARIABLE rc NUMBER

DECLARE
    l_run_id   NUMBER := TO_NUMBER('&1');
    l_warnings PLS_INTEGER;

    FUNCTION arg(p_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN TRIM(p_value) = '-' THEN NULL ELSE TRIM(p_value) END;
    END arg;
BEGIN
    epfpg.epf_control.enter(l_run_id, 'PREFLIGHT');
    epfpg.epf_control.set_choices(
        p_run_id           => l_run_id,
        p_batch_size       => TO_NUMBER(arg('&2')),
        p_with_undo_tuning => NVL(arg('&3'), 'N'),
        p_with_redo_logs   => NVL(arg('&4'), 'N'),
        p_backup_choice    => arg('&5'),
        p_confirm          => arg('&6'));
    epfpg.epf_purge.recheck(l_run_id, l_warnings);
    :rc := CASE WHEN l_warnings > 0 THEN 2 ELSE 0 END;
END;
/

EXIT :rc

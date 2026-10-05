-- ============================================================================
-- EPF Data Purge - Begin a run in the monitor session
-- ============================================================================
-- Purpose : Creates a run and attaches this session to it, so this session
--           holds the run lock for the whole run (the wrapper's monitor).
-- Usage   : @src/sql/run/begin_run.sql <action> <retention_days> <depth> <mode> <batch_size> <dry_run> <reclaim> <compact> <undo_tuning> <backup> <cutoff> <confirm> <redo_logs> <max_redo> <new_plan> <plan_id> <plan_step>
--           in a connected, persistent sqlplus session (EPFPG); the
--           arguments of start_run.sql ('-' for a default), plus
--           undo_tuning Y when the caller applies undo tuning for the purge,
--           backup CONFIRMED or NONE (how the BACKUP requirement is met
--           without a recent RMAN backup), cutoff YYYY-MM-DD instead of
--           the retention (retention_days is then -), and confirm: blocking
--           requirements the operator confirms are handled (ARCHIVE, UNDO,
--           TEMP separated by commas), and redo_logs Y when the caller
--           enlarges the online redo logs for the purge; max_redo: the most
--           redo in bytes one run of the plan may write (preflight), new_plan
--           Y to start over (the open plan is closed), and plan_id and
--           plan_step: the plan step a purge run carries out or a dry run
--           rehearses. Every argument is given ('-' when not used): a
--           missing one would be prompted for.
-- Requires: EPFPG.
-- Effects : Inserts and attaches the run; prints EPF_RUN_ID=<run_id>. Does not
--           exit, so the session stays connected; errors are printed and the
--           session continues.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
    l_run_id NUMBER;

    FUNCTION arg(p_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN TRIM(p_value) = '-' THEN NULL ELSE TRIM(p_value) END;
    END arg;
BEGIN
    l_run_id := epfpg.epf_control.start_run(
        p_action           => arg('&1'),
        p_retention_days   => TO_NUMBER(arg('&2')),
        p_depth            => arg('&3'),
        p_mode             => arg('&4'),
        p_batch_size       => TO_NUMBER(arg('&5')),
        p_dry_run          => NVL(arg('&6'), 'N'),
        p_with_reclaim     => NVL(arg('&7'), 'N'),
        p_with_compact     => NVL(arg('&8'), 'N'),
        p_with_undo_tuning => NVL(arg('&9'), 'N'),
        p_backup_choice    => arg('&10'),
        p_cutoff_date      => TO_DATE(arg('&11'), 'YYYY-MM-DD'),
        p_confirm          => arg('&12'),
        p_with_redo_logs   => NVL(arg('&13'), 'N'),
        p_max_redo_bytes   => TO_NUMBER(arg('&14')),
        p_new_plan         => NVL(arg('&15'), 'N'),
        p_plan_id          => TO_NUMBER(arg('&16')),
        p_plan_step        => TO_NUMBER(arg('&17')));
    epfpg.epf_control.attach(l_run_id);
    DBMS_OUTPUT.PUT_LINE('EPF_RUN_ID=' || l_run_id);
END;
/

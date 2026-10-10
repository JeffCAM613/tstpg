-- ============================================================================
-- EPF Data Purge - Undo tuning for a purge (every purge)
-- ============================================================================
-- Purpose : Before a purge, lowers undo_retention and limits the growth of the
--           undo datafiles, so committed undo is reused instead of growing the
--           undo tablespace; after the purge, restores the recorded original
--           values (epf_tuning.undo_apply / undo_restore / undo_status).
--           epf_purge.bat does both; a purge started with purge.sql does not
--           start without APPLY first (UNDO_TUNING_MISSING).
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/run/undo.sql <APPLY|RESTORE|STATUS> [<run_id> [<preflight_run_id>]]
--             APPLY    record, then set undo_retention to setting
--                      undo_retention_s (SCOPE=MEMORY) and limit the growth of
--                      the undo tablespace to the largest of its current size,
--                      setting undo_cap_mb and 4 x the undo of one batch of
--                      run_id (estimated by preflight_run_id, default run_id)
--             RESTORE  put back every recorded original value
--             STATUS   print the undo tablespace and the active changes
-- Requires: SYS AS SYSDBA; single-instance, non-CDB database.
-- Effects : APPLY/RESTORE change undo_retention (memory only) and the growth
--           limit (MAXSIZE) of the undo datafiles; RESTORE then resizes the
--           undo datafiles and temporary tablespaces back towards their size
--           before, as far as Oracle has released them. Every change is
--           recorded in EPFPG.EPF_INSTANCE_CHANGE. While applied, long
--           queries of other sessions can fail with ORA-01555.
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

DEFINE undo_action = "&1"
DEFINE run_arg     = "&2"
DEFINE pre_arg     = "&3"

BEGIN
    CASE UPPER(TRIM('&undo_action'))
        WHEN 'APPLY'   THEN epfpg.epf_tuning.undo_apply(TO_NUMBER(NULLIF(TRIM('&run_arg'), '-')),
                                                        TO_NUMBER(NULLIF(TRIM('&pre_arg'), '-')));
        WHEN 'RESTORE' THEN epfpg.epf_tuning.undo_restore;
        WHEN 'STATUS'  THEN epfpg.epf_tuning.undo_status;
        ELSE RAISE_APPLICATION_ERROR(-20150, 'Unknown action: &undo_action. Valid values: APPLY, RESTORE, STATUS');
    END CASE;
END;
/

EXIT SUCCESS

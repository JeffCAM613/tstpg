-- ============================================================================
-- EPF Data Purge - Undo tuning for a purge (opt-in)
-- ============================================================================
-- Purpose : Before a purge, lowers undo_retention so committed undo is reused
--           sooner instead of growing the undo tablespace; after the purge,
--           restores the recorded original value (epf_tuning.undo_apply /
--           undo_restore / undo_status).
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/run/undo.sql <APPLY|RESTORE|STATUS>
--             APPLY    record, then set undo_retention to setting
--                      undo_retention_s (SCOPE=MEMORY)
--             RESTORE  put back every recorded original value
--             STATUS   print the undo tablespace and the active changes
-- Requires: SYS AS SYSDBA; single-instance, non-CDB database.
-- Effects : APPLY/RESTORE change undo_retention (memory only); the size and
--           growth limit of the undo datafiles are not changed. Every change
--           is recorded in EPFPG.EPF_INSTANCE_CHANGE. While applied, long
--           queries of other sessions can fail with ORA-01555.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

DEFINE undo_action = "&1"

BEGIN
    CASE UPPER(TRIM('&undo_action'))
        WHEN 'APPLY'   THEN epfpg.epf_tuning.undo_apply;
        WHEN 'RESTORE' THEN epfpg.epf_tuning.undo_restore;
        WHEN 'STATUS'  THEN epfpg.epf_tuning.undo_status;
        ELSE RAISE_APPLICATION_ERROR(-20150, 'Unknown action: &undo_action. Valid values: APPLY, RESTORE, STATUS');
    END CASE;
END;
/

EXIT SUCCESS

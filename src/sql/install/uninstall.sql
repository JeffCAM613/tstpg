-- ============================================================================
-- EPF Data Purge - Uninstaller
-- ============================================================================
-- Purpose : Removes the EPFPG tool schema and everything it owns.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/install/uninstall.sql
-- Requires: SYS AS SYSDBA; in a multitenant database, the PDB service.
-- Effects : Refuses while a run holds the run lock, while application accounts
--           locked by a reclaim are not yet restored, or while temporary purge
--           indexes are still present. Otherwise drops user EPFPG CASCADE.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

PROMPT
PROMPT == EPF uninstall
DECLARE
    l_count  PLS_INTEGER;
    l_active NUMBER;
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') <> 'SYS' THEN
        RAISE_APPLICATION_ERROR(-20900, 'Run uninstall.sql as SYS AS SYSDBA.');
    END IF;
    IF SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20900, 'Connected to CDB$ROOT. Connect to the PDB service instead.');
    END IF;

    SELECT COUNT(*) INTO l_count FROM dba_users WHERE username = 'EPFPG';
    IF l_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  EPFPG is not installed; nothing to remove.');
        RETURN;
    END IF;

    SELECT COUNT(*) INTO l_count
      FROM dba_objects
     WHERE owner = 'EPFPG' AND object_name = 'EPF_CONTROL' AND object_type = 'PACKAGE BODY'
       AND status = 'VALID';
    IF l_count > 0 THEN
        EXECUTE IMMEDIATE 'BEGIN :r := epfpg.epf_control.active_run_id; END;' USING OUT l_active;
        IF l_active IS NOT NULL THEN
            RAISE_APPLICATION_ERROR(-20902, 'Run R-' || LPAD(l_active, 6, '0')
                                            || ' is active. Stop it before uninstalling.');
        END IF;
    ELSE
        DBMS_OUTPUT.PUT_LINE('  EPF_CONTROL is not valid; the active-run check is skipped.');
    END IF;

    SELECT COUNT(*) INTO l_count FROM dba_tables WHERE owner = 'EPFPG' AND table_name = 'EPF_ACCOUNT_ACTION';
    IF l_count > 0 THEN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM epfpg.epf_account_action '
                       || 'WHERE locked_at IS NOT NULL AND unlocked_at IS NULL' INTO l_count;
        IF l_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20903, l_count || ' application accounts locked by a reclaim are not '
                                            || 'restored yet. Run the reclaim resume first.');
        END IF;
    END IF;

    SELECT COUNT(*) INTO l_count FROM dba_tables WHERE owner = 'EPFPG' AND table_name = 'EPF_TEMP_INDEX';
    IF l_count > 0 THEN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM epfpg.epf_temp_index t WHERE t.dropped_at IS NULL '
                       || 'AND EXISTS (SELECT 1 FROM dba_indexes i '
                       || 'WHERE i.owner = t.owner AND i.index_name = t.index_name)' INTO l_count;
        IF l_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20904, l_count || ' temporary purge indexes still exist. '
                                            || 'Finish or re-run the purge first.');
        END IF;
    END IF;

    EXECUTE IMMEDIATE 'DROP USER epfpg CASCADE';
    DBMS_OUTPUT.PUT_LINE('  EPFPG removed.');
END;
/
EXIT SUCCESS

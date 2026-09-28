-- ============================================================================
-- EPF Data Purge - Uninstaller
-- ============================================================================
-- Purpose : Removes the EPFPG tool schema, everything it owns, and the tool
--           tablespace EPFPG_DATA.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/install/uninstall.sql
-- Requires: SYS AS SYSDBA; in a multitenant database, the PDB service.
-- Effects : Refuses while a run holds the run lock or while application
--           accounts locked by a reclaim are not yet restored. Otherwise drops
--           user EPFPG CASCADE (temporary purge indexes are owned by EPFPG
--           and are dropped with it), then
--           drops EPFPG_DATA and its datafiles when nothing else references
--           the tablespace; otherwise the tablespace is kept and the remaining
--           references are counted in the output.
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

    EXECUTE IMMEDIATE 'DROP USER epfpg CASCADE';
    DBMS_OUTPUT.PUT_LINE('  EPFPG removed.');
END;
/

PROMPT == EPF uninstall: tool tablespace
DECLARE
    c_ts    CONSTANT VARCHAR2(30) := 'EPFPG_DATA';
    l_count PLS_INTEGER;
BEGIN
    SELECT COUNT(*) INTO l_count FROM dba_tablespaces WHERE tablespace_name = c_ts;
    IF l_count = 0 THEN
        DBMS_OUTPUT.PUT_LINE('  ' || c_ts || ' is not present; nothing to remove.');
        RETURN;
    END IF;

    -- Every dictionary reference to the tablespace: segments, segmentless
    -- objects, partition defaults, recycle bin, user and database defaults.
    SELECT COUNT(*)
      INTO l_count
      FROM (SELECT 1 FROM dba_segments          WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_tables            WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_indexes           WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_lobs              WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_tab_partitions    WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_tab_subpartitions WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_ind_partitions    WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_ind_subpartitions WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_lob_partitions    WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_lob_subpartitions WHERE tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_part_tables       WHERE def_tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_part_indexes      WHERE def_tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_part_lobs         WHERE def_tablespace_name = c_ts
            UNION ALL SELECT 1 FROM dba_recyclebin        WHERE ts_name = c_ts
            UNION ALL SELECT 1 FROM dba_users             WHERE default_tablespace = c_ts
            UNION ALL SELECT 1 FROM database_properties
                       WHERE property_name = 'DEFAULT_PERMANENT_TABLESPACE' AND property_value = c_ts);
    IF l_count > 0 THEN
        DBMS_OUTPUT.PUT_LINE('  WARN  ' || c_ts || ' kept: ' || l_count
                             || ' objects or settings of other owners still reference it.');
        RETURN;
    END IF;

    -- Nothing references the tablespace, so INCLUDING CONTENTS removes no
    -- object; it is required by AND DATAFILES, which deletes the files.
    EXECUTE IMMEDIATE 'DROP TABLESPACE ' || c_ts || ' INCLUDING CONTENTS AND DATAFILES';
    DBMS_OUTPUT.PUT_LINE('  ' || c_ts || ' and its datafiles removed.');
END;
/
EXIT SUCCESS

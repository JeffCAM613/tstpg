-- ============================================================================
-- EPF Data Purge - Privileges of the tool schema
-- ============================================================================
-- Purpose : Grants EPFPG the privileges it needs for purge, preflight and
--           reporting, and lets SYS run the tool's invoker-rights reclaim code.
-- Usage   : Called by install.sql as SYS, after registry_data.sql.
-- Effects : System privileges, direct SELECT on dictionary views (definer-
--           rights PL/SQL cannot use roles), EXECUTE on DBMS_LOCK and
--           DBMS_SPACE, and SELECT/DELETE/INDEX (UPDATE for LOB clearing) on
--           every registry table present in the database, and SELECT on every
--           other table with an FK into a registry table. Temporary purge
--           indexes are created in the tool schema, so CREATE ANY INDEX and
--           DROP ANY INDEX are revoked when present. A registry table that
--           does not exist is reported and skipped. Any other failed grant
--           stops the installation.
-- ============================================================================

DECLARE
    l_granted PLS_INTEGER := 0;
    l_skipped PLS_INTEGER := 0;

    PROCEDURE run_grant(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
        l_granted := l_granted + 1;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE_APPLICATION_ERROR(-20910, 'Grant failed: ' || p_sql || ' - ' || SQLERRM);
    END run_grant;
BEGIN
    -- System privileges
    FOR p IN (SELECT column_value AS priv
                FROM TABLE(SYS.ODCIVARCHAR2LIST(
                         'CREATE SESSION', 'CREATE TABLE', 'CREATE PROCEDURE', 'CREATE SEQUENCE',
                         'ANALYZE ANY', 'ALTER ANY TABLE'))) LOOP
        run_grant('GRANT ' || p.priv || ' TO epfpg');
    END LOOP;
    FOR p IN (SELECT privilege
                FROM dba_sys_privs
               WHERE grantee = 'EPFPG'
                 AND privilege IN ('CREATE ANY INDEX', 'DROP ANY INDEX')) LOOP
        EXECUTE IMMEDIATE 'REVOKE ' || p.privilege || ' FROM epfpg';
        DBMS_OUTPUT.PUT_LINE('  revoke ' || p.privilege || ' (not needed)');
    END LOOP;

    -- Dictionary views read by preflight, monitor, report and the reclaim
    -- assessment (the reclaim package is compiled with these grants and run
    -- by SYS)
    FOR v IN (SELECT column_value AS view_name
                FROM TABLE(SYS.ODCIVARCHAR2LIST(
                         'DBA_USERS', 'DBA_TS_QUOTAS', 'DBA_TABLESPACES', 'DBA_DATA_FILES',
                         'DBA_FREE_SPACE', 'DBA_SEGMENTS', 'DBA_EXTENTS', 'DBA_RECYCLEBIN',
                         'DBA_OBJECTS', 'DBA_TABLES', 'DBA_TAB_COLUMNS', 'DBA_TAB_PARTITIONS',
                         'DBA_TAB_SUBPARTITIONS', 'DBA_PART_TABLES', 'DBA_INDEXES', 'DBA_IND_COLUMNS',
                         'DBA_IND_PARTITIONS', 'DBA_PART_INDEXES', 'DBA_LOBS', 'DBA_LOB_PARTITIONS',
                         'DBA_PART_LOBS', 'DBA_CONSTRAINTS', 'DBA_CONS_COLUMNS', 'DBA_DEPENDENCIES',
                         'DBA_TAB_PRIVS', 'DBA_RESUMABLE', 'DATABASE_PROPERTIES',
                         'V_$SESSION', 'V_$SESSION_LONGOPS', 'V_$TRANSACTION', 'V_$LOCKED_OBJECT',
                         'V_$DATABASE', 'V_$INSTANCE', 'V_$VERSION', 'V_$PARAMETER',
                         'V_$LOG', 'V_$LOGFILE', 'V_$LOG_HISTORY', 'V_$MYSTAT', 'V_$STATNAME',
                         'V_$UNDOSTAT', 'DBA_UNDO_EXTENTS', 'V_$ARCHIVE_DEST', 'V_$RECOVERY_FILE_DEST', 'V_$ASM_DISKGROUP',
                         'V_$RMAN_BACKUP_JOB_DETAILS', 'DBA_TEMP_FREE_SPACE', 'DBA_TEMP_FILES',
                         'DBA_TRIGGERS', 'DBA_ROLES', 'DBA_ROLE_PRIVS', 'DBA_SYS_PRIVS', 'DBA_OBJECT_TABLES',
                         'DBA_QUEUE_TABLES', 'DBA_MVIEWS', 'DBA_MVIEW_LOGS', 'DBA_FLASHBACK_ARCHIVE_TABLES'))) LOOP
        run_grant('GRANT SELECT ON sys.' || v.view_name || ' TO epfpg');
    END LOOP;

    run_grant('GRANT EXECUTE ON sys.dbms_lock TO epfpg');
    run_grant('GRANT EXECUTE ON sys.dbms_space TO epfpg');
    -- epf_tuning (invoker rights, run by SYS) removes retired redo log files.
    run_grant('GRANT EXECUTE ON sys.utl_file TO epfpg');

    -- Allows SYS to execute EPFPG invoker-rights code (reclaim) with SYS rights.
    BEGIN
        EXECUTE IMMEDIATE 'GRANT INHERIT PRIVILEGES ON USER sys TO epfpg';
        l_granted := l_granted + 1;
    EXCEPTION
        WHEN OTHERS THEN
            DBMS_OUTPUT.PUT_LINE('  WARN  INHERIT PRIVILEGES ON USER SYS not granted: ' || SQLERRM);
            DBMS_OUTPUT.PUT_LINE('        Purge is not affected; reclaim will report this at preflight.');
    END;

    -- Registry tables
    FOR t IN (SELECT e.owner, e.table_name, e.lob_clear,
                     (SELECT COUNT(*) FROM dba_tables d
                       WHERE d.owner = e.owner AND d.table_name = e.table_name) AS present
                FROM epfpg.epf_table e
               WHERE e.active = 'Y'
               ORDER BY e.table_id) LOOP
        IF t.present = 0 THEN
            l_skipped := l_skipped + 1;
            DBMS_OUTPUT.PUT_LINE('  skip  ' || t.owner || '.' || t.table_name || ' (not present in this database)');
        ELSE
            run_grant('GRANT SELECT, DELETE, INDEX' || CASE WHEN t.lob_clear = 'Y' THEN ', UPDATE' END
                      || ' ON ' || DBMS_ASSERT.ENQUOTE_NAME(t.owner, FALSE) || '.'
                      || DBMS_ASSERT.ENQUOTE_NAME(t.table_name, FALSE) || ' TO epfpg');
        END IF;
    END LOOP;

    -- Tables outside the registry with an FK into a registry table: read by
    -- the purge to hold back roots whose rows they reference.
    FOR t IN (SELECT DISTINCT c.owner, c.table_name
                FROM dba_constraints c
                JOIN dba_constraints p
                  ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
                JOIN epfpg.epf_table e
                  ON e.owner = p.owner AND e.table_name = p.table_name AND e.active = 'Y'
               WHERE c.constraint_type = 'R'
                 AND NOT EXISTS (SELECT 1 FROM epfpg.epf_table x
                                  WHERE x.owner = c.owner AND x.table_name = c.table_name AND x.active = 'Y')
               ORDER BY c.owner, c.table_name) LOOP
        run_grant('GRANT SELECT ON ' || DBMS_ASSERT.ENQUOTE_NAME(t.owner, FALSE) || '.'
                  || DBMS_ASSERT.ENQUOTE_NAME(t.table_name, FALSE) || ' TO epfpg');
    END LOOP;

    DBMS_OUTPUT.PUT_LINE('  grants: ' || l_granted || ' applied, ' || l_skipped || ' registry tables skipped');
END;
/

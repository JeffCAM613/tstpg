CREATE OR REPLACE PACKAGE BODY epf_redo AS

    c_rounds    CONSTANT PLS_INTEGER  := 12;
    c_directory CONSTANT VARCHAR2(30) := 'EPF_REDO_OLD';

    PROCEDURE say(p_severity IN VARCHAR2, p_code IN VARCHAR2, p_message IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_code, 20) || ' ' || p_message);
        IF epfpg.epf_log.current_run IS NOT NULL THEN
            epfpg.epf_log.event(p_severity, p_code, p_message);
        END IF;
    END say;

    PROCEDURE show_groups(p_label IN VARCHAR2) IS
    BEGIN
        FOR g IN (SELECT l.group#, ROUND(l.bytes / 1048576) AS mb, l.status,
                         (SELECT LISTAGG(f.member, ', ') WITHIN GROUP (ORDER BY f.member)
                            FROM v$logfile f
                           WHERE f.group# = l.group#) AS files
                    FROM v$log l
                   ORDER BY l.group#) LOOP
            DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_label, 20) || ' group ' || g.group# || ': ' || g.mb || ' MB, '
                                 || g.status || ', ' || g.files);
        END LOOP;
    END show_groups;

    FUNCTION dir_of(p_file IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN SUBSTR(p_file, 1, GREATEST(INSTR(p_file, '/', -1), INSTR(p_file, '\', -1)));
    END dir_of;

    -- Deletes a file of the database server through a temporary directory
    -- object; a failure is reported with the path and does not stop the call.
    PROCEDURE remove_file(p_file IN VARCHAR2) IS
        l_dir    VARCHAR2(4000) := dir_of(p_file);
        l_name   VARCHAR2(4000) := SUBSTR(p_file, LENGTH(dir_of(p_file)) + 1);
        l_exists BOOLEAN;
        l_length NUMBER;
        l_block  BINARY_INTEGER;
    BEGIN
        EXECUTE IMMEDIATE 'CREATE OR REPLACE DIRECTORY ' || c_directory || ' AS '''
                          || REPLACE(RTRIM(l_dir, '/\'), '''', '''''') || '''';
        UTL_FILE.FGETATTR(c_directory, l_name, l_exists, l_length, l_block);
        IF l_exists THEN
            UTL_FILE.FREMOVE(c_directory, l_name);
            say('OK', 'REDO_FILE_REMOVED', p_file);
        ELSE
            say('INFO', 'REDO_FILE_REMOVED', p_file || ' (already removed by Oracle)');
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            say('WARN', 'REDO_FILE_KEPT', p_file || ' could not be deleted (' || SQLERRM || '); delete it manually');
    END remove_file;

    PROCEDURE enlarge(p_size_mb IN NUMBER DEFAULT 1024, p_groups IN NUMBER DEFAULT 4) IS
        l_bytes      NUMBER;
        l_cdb        VARCHAR2(3);
        l_log_mode   VARCHAR2(12);
        l_threads    NUMBER;
        l_big        NUMBER;
        l_small      NUMBER;
        l_next       NUMBER;
        l_omf        VARCHAR2(4000);
        l_ref        SYS.ODCIVARCHAR2LIST;
        l_files      SYS.ODCIVARCHAR2LIST;
        l_old_files  SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        l_added      SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        l_candidates SYS.ODCINUMBERLIST;
        l_members    VARCHAR2(4000);
        l_error      VARCHAR2(4000);
        l_left       NUMBER;
        l_removed    BOOLEAN := FALSE;
    BEGIN
        IF SYS_CONTEXT('USERENV', 'SESSION_USER') <> 'SYS' THEN
            RAISE_APPLICATION_ERROR(-20150, 'Run as SYS AS SYSDBA.');
        END IF;
        IF p_size_mb IS NULL OR p_size_mb <> TRUNC(p_size_mb) OR p_size_mb NOT BETWEEN 64 AND 16384 THEN
            RAISE_APPLICATION_ERROR(-20150, 'Log size must be a whole number of MB between 64 and 16384, got: '
                                            || p_size_mb);
        END IF;
        IF p_groups IS NULL OR p_groups <> TRUNC(p_groups) OR p_groups NOT BETWEEN 2 AND 16 THEN
            RAISE_APPLICATION_ERROR(-20150, 'Group count must be a whole number between 2 and 16, got: ' || p_groups);
        END IF;
        l_bytes := p_size_mb * 1048576;

        SELECT cdb, log_mode INTO l_cdb, l_log_mode FROM v$database;
        IF l_cdb = 'YES' THEN
            RAISE_APPLICATION_ERROR(-20150, 'Multitenant database: the online redo logs belong to the CDB and are '
                                            || 'sized by the DBA in CDB$ROOT.');
        END IF;
        SELECT COUNT(DISTINCT thread#) INTO l_threads FROM v$log;
        IF l_threads > 1 THEN
            RAISE_APPLICATION_ERROR(-20150, 'Several redo threads (RAC): size the online redo logs of each thread '
                                            || 'manually.');
        END IF;

        show_groups('before');
        SELECT COUNT(CASE WHEN bytes >= l_bytes THEN 1 END), COUNT(CASE WHEN bytes < l_bytes THEN 1 END), MAX(group#)
          INTO l_big, l_small, l_next
          FROM v$log;
        IF l_big >= p_groups AND l_small = 0 THEN
            say('OK', 'REDO_UNCHANGED', 'All ' || l_big || ' groups already have at least ' || p_size_mb || ' MB.');
            RETURN;
        END IF;

        -- New groups: Oracle-managed when a destination is set, otherwise one
        -- member next to each member of the lowest-numbered existing group.
        SELECT MAX(value)
          INTO l_omf
          FROM v$parameter
         WHERE name IN ('db_create_online_log_dest_1', 'db_create_file_dest')
           AND value IS NOT NULL;
        SELECT member BULK COLLECT INTO l_ref
          FROM v$logfile
         WHERE group# = (SELECT MIN(group#) FROM v$log)
         ORDER BY member;
        say('INFO', 'REDO_PLAN', 'adding ' || GREATEST(p_groups - l_big, 0) || ' groups of ' || p_size_mb || ' MB ('
                                 || GREATEST(p_groups - l_big, 0) * l_ref.COUNT * p_size_mb
                                 || ' MB of new files), then dropping ' || l_small || ' smaller groups');

        FOR i IN 1 .. GREATEST(p_groups - l_big, 0) LOOP
            l_next := l_next + 1;
            l_members := NULL;
            IF l_omf IS NULL THEN
                FOR m IN 1 .. l_ref.COUNT LOOP
                    l_members := l_members || CASE WHEN m > 1 THEN ', ' END || ''''
                                 || CASE WHEN SUBSTR(l_ref(m), 1, 1) = '+'
                                         THEN SUBSTR(l_ref(m), 1, INSTR(l_ref(m) || '/', '/') - 1)
                                         ELSE dir_of(l_ref(m)) || 'redo' || LPAD(l_next, 2, '0')
                                              || CASE WHEN l_ref.COUNT > 1 THEN CHR(96 + m) END || '.log'
                                    END || '''';
                END LOOP;
            END IF;
            BEGIN
                EXECUTE IMMEDIATE 'ALTER DATABASE ADD LOGFILE GROUP ' || l_next
                                  || CASE WHEN l_members IS NOT NULL THEN ' (' || l_members || ')' END
                                  || ' SIZE ' || p_size_mb || 'M';
                l_added.EXTEND;
                l_added(l_added.COUNT) := l_next;
                say('INFO', 'REDO_GROUP_ADDED', 'group ' || l_next || ', ' || p_size_mb || ' MB: '
                                                || NVL(l_members, 'Oracle-managed file'));
            EXCEPTION
                WHEN OTHERS THEN
                    l_error := SQLERRM;
                    FOR k IN 1 .. l_added.COUNT LOOP
                        EXECUTE IMMEDIATE 'ALTER DATABASE DROP LOGFILE GROUP ' || l_added(k);
                        say('WARN', 'REDO_GROUP_DROPPED', 'group ' || l_added(k)
                                                          || ' (added by this call; its files remain on disk)');
                    END LOOP;
                    RAISE_APPLICATION_ERROR(-20151, 'Group ' || l_next || ' could not be added: ' || l_error);
            END;
        END LOOP;

        -- Retire the smaller groups once Oracle no longer needs them.
        FOR r IN 1 .. c_rounds LOOP
            SELECT group# BULK COLLECT INTO l_candidates
              FROM v$log
             WHERE bytes < l_bytes
               AND status IN ('INACTIVE', 'UNUSED')
               AND (l_log_mode = 'NOARCHIVELOG' OR archived = 'YES')
             ORDER BY group#;
            FOR k IN 1 .. l_candidates.COUNT LOOP
                SELECT member BULK COLLECT INTO l_files FROM v$logfile WHERE group# = l_candidates(k);
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER DATABASE DROP LOGFILE GROUP ' || l_candidates(k);
                    FOR f IN 1 .. l_files.COUNT LOOP
                        l_old_files.EXTEND;
                        l_old_files(l_old_files.COUNT) := l_files(f);
                    END LOOP;
                    say('INFO', 'REDO_GROUP_DROPPED', 'group ' || l_candidates(k));
                EXCEPTION
                    WHEN OTHERS THEN
                        -- ORA-01623 current, ORA-01624 needed for crash recovery,
                        -- ORA-00350 not archived yet: retried after the next switch.
                        IF SQLCODE NOT IN (-1623, -1624, -350) THEN
                            RAISE;
                        END IF;
                END;
            END LOOP;
            SELECT COUNT(*) INTO l_left FROM v$log WHERE bytes < l_bytes;
            EXIT WHEN l_left = 0;
            EXECUTE IMMEDIATE CASE WHEN l_log_mode = 'ARCHIVELOG' THEN 'ALTER SYSTEM ARCHIVE LOG CURRENT'
                                   ELSE 'ALTER SYSTEM SWITCH LOGFILE' END;
            EXECUTE IMMEDIATE 'ALTER SYSTEM CHECKPOINT';
        END LOOP;
        FOR g IN (SELECT group#, status FROM v$log WHERE bytes < l_bytes ORDER BY group#) LOOP
            say('WARN', 'REDO_GROUP_KEPT', 'group ' || g.group# || ' (' || g.status || ') is still in use; drop it '
                                           || 'later with ALTER DATABASE DROP LOGFILE GROUP ' || g.group#);
        END LOOP;

        -- Files of the dropped groups (Oracle removes Oracle-managed files itself).
        FOR k IN 1 .. l_old_files.COUNT LOOP
            IF SUBSTR(l_old_files(k), 1, 1) = '+' THEN
                say('INFO', 'REDO_FILE_KEPT', l_old_files(k) || ' is an ASM file; remove it with ASMCMD if it remains');
            ELSE
                remove_file(l_old_files(k));
                l_removed := TRUE;
            END IF;
        END LOOP;
        IF l_removed THEN
            BEGIN
                EXECUTE IMMEDIATE 'DROP DIRECTORY ' || c_directory;
            EXCEPTION
                WHEN OTHERS THEN
                    -- ORA-04043: the directory was never created (every removal failed before it).
                    IF SQLCODE <> -4043 THEN
                        RAISE;
                    END IF;
            END;
        END IF;

        show_groups('after');
        SELECT COUNT(*), MIN(bytes) INTO l_big, l_bytes FROM v$log;
        say('OK', 'REDO_ENLARGED', l_big || ' online redo log groups, smallest ' || ROUND(l_bytes / 1048576) || ' MB');
    END enlarge;

END epf_redo;
/

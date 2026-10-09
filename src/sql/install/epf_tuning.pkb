CREATE OR REPLACE PACKAGE BODY epf_tuning AS

    c_rounds    CONSTANT PLS_INTEGER  := 12;
    c_directory CONSTANT VARCHAR2(30) := 'EPF_REDO_OLD';

    PROCEDURE say(p_severity IN VARCHAR2, p_code IN VARCHAR2, p_message IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('  ' || RPAD(p_code, GREATEST(22, LENGTH(p_code))) || ' ' || p_message);
        IF epfpg.epf_log.current_run IS NOT NULL THEN
            epfpg.epf_log.event(p_severity, p_code, p_message);
        END IF;
    END say;

    -- SYS on a single-instance, non-CDB database.
    PROCEDURE check_instance IS
        l_cdb     VARCHAR2(3);
        l_threads NUMBER;
    BEGIN
        IF SYS_CONTEXT('USERENV', 'SESSION_USER') <> 'SYS' THEN
            RAISE_APPLICATION_ERROR(-20150, 'Run as SYS AS SYSDBA.');
        END IF;
        SELECT cdb INTO l_cdb FROM v$database;
        IF l_cdb = 'YES' THEN
            RAISE_APPLICATION_ERROR(-20150, 'Multitenant database: online redo logs and instance parameters belong '
                                            || 'to the CDB and are tuned by the DBA in CDB$ROOT.');
        END IF;
        SELECT COUNT(DISTINCT thread#) INTO l_threads FROM v$log;
        IF l_threads > 1 THEN
            RAISE_APPLICATION_ERROR(-20150, 'Several redo threads (RAC): tune each instance manually.');
        END IF;
    END check_instance;

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

    PROCEDURE enlarge_redo(p_size_mb IN NUMBER DEFAULT 1024, p_groups IN NUMBER DEFAULT 4,
                           p_run_id IN NUMBER DEFAULT NULL) IS
        l_bytes      NUMBER;
        l_size_mb    NUMBER;
        l_need       NUMBER;
        l_min        NUMBER;
        l_thread     NUMBER;
        l_gbytes     NUMBER;
        l_list       VARCHAR2(4000);
        l_known      NUMBER;
        l_run        NUMBER := NVL(p_run_id, epfpg.epf_log.current_run);
        l_log_mode   VARCHAR2(12);
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
        check_instance;
        IF p_size_mb IS NULL OR p_size_mb <> TRUNC(p_size_mb) OR p_size_mb NOT BETWEEN 64 AND 16384 THEN
            RAISE_APPLICATION_ERROR(-20150, 'Log size must be a whole number of MB between 64 and 16384, got: '
                                            || p_size_mb);
        END IF;
        IF p_groups IS NULL OR p_groups <> TRUNC(p_groups) OR p_groups NOT BETWEEN 2 AND 16 THEN
            RAISE_APPLICATION_ERROR(-20150, 'Group count must be a whole number between 2 and 16, got: ' || p_groups);
        END IF;
        l_bytes := p_size_mb * 1048576;
        SELECT log_mode INTO l_log_mode FROM v$database;
        -- With a run: nothing changes when one batch of it (its REDO_LOGS
        -- requirement) fits in the smallest online log; groups larger than
        -- p_size_mb when one batch needs more.
        IF p_run_id IS NOT NULL THEN
            SELECT MAX(needed_bytes) INTO l_need
              FROM epfpg.epf_requirement
             WHERE run_id = p_run_id AND req_code = 'REDO_LOGS';
            SELECT MIN(bytes) INTO l_min FROM v$log;
            IF l_need IS NOT NULL AND l_need <= l_min THEN
                say('OK', 'REDO_UNCHANGED', 'One batch writes about ' || ROUND(l_need / 1048576) || ' MB of redo and fits '
                                            || 'in the smallest online log (' || ROUND(l_min / 1048576) || ' MB): left as '
                                            || 'they are.');
                RETURN;
            END IF;
            IF l_need > l_bytes THEN
                l_bytes := CEIL(l_need / 268435456) * 268435456;
            END IF;
        END IF;
        l_size_mb := l_bytes / 1048576;

        show_groups('before');
        SELECT COUNT(CASE WHEN bytes >= l_bytes THEN 1 END), COUNT(CASE WHEN bytes < l_bytes THEN 1 END), MAX(group#)
          INTO l_big, l_small, l_next
          FROM v$log;
        IF l_big >= p_groups AND l_small = 0 THEN
            say('OK', 'REDO_UNCHANGED', 'All ' || l_big || ' groups already have at least ' || l_size_mb || ' MB.');
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
        say('INFO', 'REDO_PLAN', 'adding ' || GREATEST(p_groups - l_big, 0) || ' groups of ' || l_size_mb || ' MB ('
                                 || GREATEST(p_groups - l_big, 0) * l_ref.COUNT * l_size_mb
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
                                  || ' SIZE ' || l_size_mb || 'M';
                l_added.EXTEND;
                l_added(l_added.COUNT) := l_next;
                -- Recorded for redo_restore, which drops it again.
                SELECT MAX(thread#) INTO l_thread FROM v$log WHERE group# = l_next;
                SELECT LISTAGG(member, ',') WITHIN GROUP (ORDER BY member) INTO l_list
                  FROM v$logfile
                 WHERE group# = l_next;
                INSERT INTO epfpg.epf_instance_change (item, target, log_group, log_thread, log_members, original_value,
                                                       applied_at, applied_run_id)
                VALUES ('REDO_ADDED', 'group ' || l_next, l_next, l_thread, l_list, l_bytes,
                        CAST(SYSTIMESTAMP AS TIMESTAMP), l_run);
                COMMIT;
                say('INFO', 'REDO_GROUP_ADDED', 'group ' || l_next || ', ' || l_size_mb || ' MB: '
                                                || NVL(l_members, 'Oracle-managed file'));
            EXCEPTION
                WHEN OTHERS THEN
                    l_error := SQLERRM;
                    FOR k IN 1 .. l_added.COUNT LOOP
                        EXECUTE IMMEDIATE 'ALTER DATABASE DROP LOGFILE GROUP ' || l_added(k);
                        UPDATE epfpg.epf_instance_change
                           SET restored_at = CAST(SYSTIMESTAMP AS TIMESTAMP)
                         WHERE item = 'REDO_ADDED' AND log_group = l_added(k) AND restored_at IS NULL;
                        COMMIT;
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
                -- Recorded first (number, thread, members, size) for redo_restore.
                SELECT COUNT(*) INTO l_known
                  FROM epfpg.epf_instance_change
                 WHERE item = 'REDO_GROUP' AND log_group = l_candidates(k) AND restored_at IS NULL;
                IF l_known = 0 THEN
                    SELECT MAX(thread#), MAX(bytes) INTO l_thread, l_gbytes FROM v$log WHERE group# = l_candidates(k);
                    l_list := NULL;
                    FOR f IN 1 .. l_files.COUNT LOOP
                        l_list := l_list || CASE WHEN f > 1 THEN ',' END || l_files(f);
                    END LOOP;
                    INSERT INTO epfpg.epf_instance_change (item, target, log_group, log_thread, log_members,
                                                           original_value, applied_at, applied_run_id)
                    VALUES ('REDO_GROUP', 'group ' || l_candidates(k), l_candidates(k), l_thread, l_list, l_gbytes,
                            CAST(SYSTIMESTAMP AS TIMESTAMP), l_run);
                    COMMIT;
                END IF;
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
    END enlarge_redo;

    PROCEDURE redo_restore IS
        l_log_mode VARCHAR2(12);
        l_omf      VARCHAR2(4000);
        l_count    NUMBER;
        l_exists   NUMBER;
        l_rest     VARCHAR2(4000);
        l_member   VARCHAR2(1000);
        l_list     VARCHAR2(4000);
        l_pos      PLS_INTEGER;
        l_left     NUMBER;
        l_files    SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        l_removed  BOOLEAN := FALSE;
    BEGIN
        check_instance;
        SELECT COUNT(*) INTO l_count
          FROM epfpg.epf_instance_change
         WHERE restored_at IS NULL AND item IN ('REDO_GROUP', 'REDO_ADDED');
        IF l_count = 0 THEN
            say('INFO', 'REDO_NOTHING_TO_RESTORE', 'No online redo log group to put back');
            RETURN;
        END IF;
        SELECT log_mode INTO l_log_mode FROM v$database;
        SELECT MAX(value)
          INTO l_omf
          FROM v$parameter
         WHERE name IN ('db_create_online_log_dest_1', 'db_create_file_dest')
           AND value IS NOT NULL;
        show_groups('before');

        -- 1. The original groups again: their numbers, threads and sizes, and
        -- their members under the same names on a file system; Oracle names
        -- an Oracle-managed member again, in its disk group on ASM.
        FOR c IN (SELECT change_id, log_group, log_thread, log_members, original_value
                    FROM epfpg.epf_instance_change
                   WHERE restored_at IS NULL AND item = 'REDO_GROUP'
                   ORDER BY log_group) LOOP
            SELECT COUNT(*) INTO l_exists FROM v$log WHERE group# = c.log_group;
            IF l_exists = 0 THEN
                l_list := NULL;
                l_rest := c.log_members || ',';
                LOOP
                    l_pos := INSTR(l_rest, ',');
                    EXIT WHEN NVL(l_pos, 0) = 0;
                    l_member := SUBSTR(l_rest, 1, l_pos - 1);
                    l_rest := SUBSTR(l_rest, l_pos + 1);
                    IF SUBSTR(l_member, 1, 1) = '+' THEN
                        l_member := SUBSTR(l_member, 1, INSTR(l_member || '/', '/') - 1);
                    ELSIF l_omf IS NOT NULL AND INSTR(l_member, 'o1_mf_') > 0 THEN
                        l_member := NULL;
                    END IF;
                    IF l_member IS NOT NULL AND INSTR(NVL(l_list, ' '), '''' || l_member || '''') = 0 THEN
                        l_list := l_list || CASE WHEN l_list IS NOT NULL THEN ', ' END || ''''
                                  || REPLACE(l_member, '''', '''''') || '''';
                    END IF;
                END LOOP;
                EXECUTE IMMEDIATE 'ALTER DATABASE ADD LOGFILE THREAD ' || NVL(c.log_thread, 1) || ' GROUP ' || c.log_group
                                  || CASE WHEN l_list IS NOT NULL THEN ' (' || l_list || ')' END
                                  || ' SIZE ' || ROUND(c.original_value / 1024) || 'K'
                                  || CASE WHEN l_list IS NOT NULL AND INSTR(l_list, '''+') = 0 THEN ' REUSE' END;
                say('OK', 'REDO_GROUP_ADDED', 'group ' || c.log_group || ', ' || ROUND(c.original_value / 1048576)
                                              || ' MB, as before the purge: ' || NVL(l_list, 'Oracle-managed file'));
            END IF;
            UPDATE epfpg.epf_instance_change
               SET restored_at = CAST(SYSTIMESTAMP AS TIMESTAMP)
             WHERE change_id = c.change_id;
            COMMIT;
        END LOOP;

        -- 2. The groups added for the purge, dropped once Oracle no longer
        -- needs them (INACTIVE, and archived in ARCHIVELOG mode).
        FOR r IN 1 .. c_rounds LOOP
            l_left := 0;
            FOR c IN (SELECT ch.change_id, ch.log_group, ch.log_members, l.status, l.archived
                        FROM epfpg.epf_instance_change ch
                        LEFT JOIN v$log l ON l.group# = ch.log_group
                       WHERE ch.restored_at IS NULL AND ch.item = 'REDO_ADDED'
                       ORDER BY ch.log_group) LOOP
                IF c.status IS NULL
                   OR (c.status IN ('INACTIVE', 'UNUSED') AND (l_log_mode = 'NOARCHIVELOG' OR c.archived = 'YES')) THEN
                    BEGIN
                        IF c.status IS NOT NULL THEN
                            EXECUTE IMMEDIATE 'ALTER DATABASE DROP LOGFILE GROUP ' || c.log_group;
                            l_rest := c.log_members || ',';
                            LOOP
                                l_pos := INSTR(l_rest, ',');
                                EXIT WHEN NVL(l_pos, 0) = 0;
                                IF l_pos > 1 THEN
                                    l_files.EXTEND;
                                    l_files(l_files.COUNT) := SUBSTR(l_rest, 1, l_pos - 1);
                                END IF;
                                l_rest := SUBSTR(l_rest, l_pos + 1);
                            END LOOP;
                            say('INFO', 'REDO_GROUP_DROPPED', 'group ' || c.log_group || ' (added for the purge)');
                        END IF;
                        UPDATE epfpg.epf_instance_change
                           SET restored_at = CAST(SYSTIMESTAMP AS TIMESTAMP)
                         WHERE change_id = c.change_id;
                        COMMIT;
                    EXCEPTION
                        WHEN OTHERS THEN
                            -- ORA-01623 current, ORA-01624 needed for crash recovery,
                            -- ORA-00350 not archived yet: retried after the next switch.
                            IF SQLCODE NOT IN (-1623, -1624, -350) THEN
                                RAISE;
                            END IF;
                            l_left := l_left + 1;
                    END;
                ELSE
                    l_left := l_left + 1;
                END IF;
            END LOOP;
            EXIT WHEN l_left = 0;
            EXECUTE IMMEDIATE CASE WHEN l_log_mode = 'ARCHIVELOG' THEN 'ALTER SYSTEM ARCHIVE LOG CURRENT'
                                   ELSE 'ALTER SYSTEM SWITCH LOGFILE' END;
            EXECUTE IMMEDIATE 'ALTER SYSTEM CHECKPOINT';
        END LOOP;
        FOR c IN (SELECT ch.log_group, l.status
                    FROM epfpg.epf_instance_change ch
                    JOIN v$log l ON l.group# = ch.log_group
                   WHERE ch.restored_at IS NULL AND ch.item = 'REDO_ADDED'
                   ORDER BY ch.log_group) LOOP
            say('WARN', 'REDO_GROUP_KEPT', 'group ' || c.log_group || ' (' || c.status || ') is still in use; '
                                           || 'run src/sql/run/redo_logs.sql RESTORE again to drop it');
        END LOOP;

        -- Files of the dropped groups (Oracle removes Oracle-managed files itself).
        FOR k IN 1 .. l_files.COUNT LOOP
            IF SUBSTR(l_files(k), 1, 1) = '+' THEN
                say('INFO', 'REDO_FILE_KEPT', l_files(k) || ' is an ASM file; remove it with ASMCMD if it remains');
            ELSIF NOT (l_omf IS NOT NULL AND INSTR(l_files(k), 'o1_mf_') > 0) THEN
                remove_file(l_files(k));
                l_removed := TRUE;
            END IF;
        END LOOP;
        IF l_removed THEN
            BEGIN
                EXECUTE IMMEDIATE 'DROP DIRECTORY ' || c_directory;
            EXCEPTION
                WHEN OTHERS THEN
                    IF SQLCODE <> -4043 THEN
                        RAISE;
                    END IF;
            END;
        END IF;

        show_groups('after');
        SELECT COUNT(*) INTO l_count
          FROM epfpg.epf_instance_change
         WHERE restored_at IS NULL AND item IN ('REDO_GROUP', 'REDO_ADDED');
        IF l_count = 0 THEN
            say('OK', 'REDO_RESTORED', 'The online redo logs are as they were before the purge');
        END IF;
    END redo_restore;

    -- ------------------------------------------------------------------
    -- Undo
    -- ------------------------------------------------------------------

    FUNCTION undo_tablespace RETURN VARCHAR2 IS
        l_value VARCHAR2(128);
    BEGIN
        SELECT UPPER(value) INTO l_value FROM v$parameter WHERE name = 'undo_tablespace';
        RETURN l_value;
    END undo_tablespace;

    PROCEDURE undo_status IS
        l_ts        VARCHAR2(128) := undo_tablespace;
        l_retention VARCHAR2(40);
        l_guarantee VARCHAR2(11);
    BEGIN
        SELECT value INTO l_retention FROM v$parameter WHERE name = 'undo_retention';
        SELECT MAX(retention) INTO l_guarantee FROM dba_tablespaces WHERE tablespace_name = l_ts;
        DBMS_OUTPUT.PUT_LINE('  undo tablespace        ' || l_ts || ' (' || l_guarantee || '), undo_retention '
                             || l_retention || ' s');
        FOR f IN (SELECT file_id, file_name, ROUND(bytes / 1048576) AS mb, autoextensible,
                         ROUND(maxbytes / 1048576) AS max_mb
                    FROM dba_data_files
                   WHERE tablespace_name = l_ts
                   ORDER BY file_id) LOOP
            DBMS_OUTPUT.PUT_LINE('  undo datafile          ' || f.file_id || ' ' || f.file_name || ': ' || f.mb
                                 || ' MB, autoextend ' || f.autoextensible
                                 || CASE WHEN f.autoextensible = 'YES' THEN ' up to ' || f.max_mb || ' MB' END);
        END LOOP;
        FOR c IN (SELECT change_id, item, target, original_value, original_maxbytes, applied_value, applied_at
                    FROM epfpg.epf_instance_change
                   WHERE restored_at IS NULL AND item LIKE 'UNDO%'
                   ORDER BY change_id) LOOP
            DBMS_OUTPUT.PUT_LINE('  active change          ' || c.item || ' ' || c.target || ': '
                                 || CASE c.item WHEN 'UNDO_RETENTION'
                                        THEN c.original_value || ' s -> ' || c.applied_value || ' s'
                                        ELSE 'max ' || ROUND(c.original_maxbytes / 1048576) || ' MB -> '
                                             || ROUND(c.applied_value / 1048576) || ' MB' END
                                 || ' since ' || TO_CHAR(c.applied_at, 'YYYY-MM-DD HH24:MI:SS'));
        END LOOP;
    END undo_status;

    FUNCTION undo_cap(p_batch_undo IN NUMBER) RETURN NUMBER IS
        l_ts   VARCHAR2(128) := undo_tablespace;
        l_size NUMBER;
    BEGIN
        SELECT NVL(SUM(bytes), 0) INTO l_size FROM dba_data_files WHERE tablespace_name = l_ts;
        RETURN GREATEST(l_size, epfpg.epf_util.setting_num('undo_cap_mb') * 1048576, 4 * NVL(p_batch_undo, 0));
    END undo_cap;

    -- Undo of one batch of run p_run_id: its batch size times the largest undo
    -- per root estimated by the preflight run p_preflight_run_id (UNDO_ESTIMATE
    -- events). NULL without a run.
    FUNCTION batch_undo(p_run_id IN NUMBER, p_preflight_run_id IN NUMBER) RETURN NUMBER IS
        l_batch    NUMBER;
        l_per_root NUMBER;
    BEGIN
        IF p_run_id IS NULL THEN
            RETURN NULL;
        END IF;
        SELECT MAX(batch_size) INTO l_batch FROM epfpg.epf_run WHERE run_id = p_run_id;
        SELECT MAX(bytes)
          INTO l_per_root
          FROM epfpg.epf_event
         WHERE run_id = NVL(p_preflight_run_id, p_run_id) AND event_code = 'UNDO_ESTIMATE' AND bytes > 0;
        RETURN l_batch * l_per_root;
    END batch_undo;

    -- Limits the growth of the autoextensible undo datafiles so the undo
    -- tablespace stays within p_cap bytes (never below the current size of a
    -- file: nothing is shrunk). The room left under the cap is shared evenly
    -- between the files. Each change is recorded before it is made.
    PROCEDURE limit_undo_growth(p_ts IN VARCHAR2, p_cap IN NUMBER, p_run_id IN NUMBER) IS
        l_total NUMBER;
        l_files NUMBER;
        l_room  NUMBER;
        l_max   NUMBER;
    BEGIN
        SELECT NVL(SUM(bytes), 0), COUNT(CASE WHEN autoextensible = 'YES' THEN 1 END)
          INTO l_total, l_files
          FROM dba_data_files
         WHERE tablespace_name = p_ts;
        IF l_files = 0 THEN
            say('INFO', 'UNDO_GROWTH_NONE', p_ts || ' has no autoextensible datafile: it cannot grow');
            RETURN;
        END IF;
        l_room := GREATEST(p_cap - l_total, 0);
        FOR f IN (SELECT d.file_id, d.file_name, d.bytes, d.maxbytes, d.increment_by * t.block_size AS incr_bytes
                    FROM dba_data_files d
                    JOIN dba_tablespaces t ON t.tablespace_name = d.tablespace_name
                   WHERE d.tablespace_name = p_ts AND d.autoextensible = 'YES'
                   ORDER BY d.file_id) LOOP
            l_max := CEIL((f.bytes + l_room / l_files) / 1048576) * 1048576;
            IF l_max < f.maxbytes THEN
                INSERT INTO epfpg.epf_instance_change (item, target, file_id, original_autoextend, original_maxbytes,
                                                       original_increment, applied_value, applied_at, applied_run_id)
                VALUES ('UNDO_DATAFILE', f.file_name, f.file_id, 'YES', f.maxbytes, f.incr_bytes, l_max,
                        CAST(SYSTIMESTAMP AS TIMESTAMP), p_run_id);
                COMMIT;
                EXECUTE IMMEDIATE 'ALTER DATABASE DATAFILE ' || f.file_id || ' AUTOEXTEND ON NEXT '
                                  || f.incr_bytes / 1024 || 'K MAXSIZE ' || l_max / 1024 || 'K';
                say('OK', 'UNDO_GROWTH_LIMITED', f.file_name || ': may grow to ' || ROUND(l_max / 1048576)
                                                 || ' MB (was ' || ROUND(f.maxbytes / 1048576) || ' MB)');
            ELSE
                say('INFO', 'UNDO_GROWTH_KEPT', f.file_name || ': growth limit ' || ROUND(f.maxbytes / 1048576)
                                                || ' MB is already within the cap');
            END IF;
        END LOOP;
    END limit_undo_growth;

    PROCEDURE size_record(p_run_id IN NUMBER, p_undo IN BOOLEAN) IS
        l_ts VARCHAR2(128) := undo_tablespace;
    BEGIN
        IF p_undo THEN
            INSERT INTO epfpg.epf_instance_change (item, target, file_id, original_value, applied_at, applied_run_id)
            SELECT 'SIZE_UNDO', d.file_name, d.file_id, d.bytes, CAST(SYSTIMESTAMP AS TIMESTAMP), p_run_id
              FROM dba_data_files d
             WHERE d.tablespace_name = l_ts
               AND NOT EXISTS (SELECT 1
                                 FROM epfpg.epf_instance_change c
                                WHERE c.item = 'SIZE_UNDO' AND c.file_id = d.file_id AND c.restored_at IS NULL);
        END IF;
        INSERT INTO epfpg.epf_instance_change (item, target, original_value, applied_at, applied_run_id)
        SELECT 'SIZE_TEMP', t.tablespace_name, SUM(t.bytes), CAST(SYSTIMESTAMP AS TIMESTAMP), p_run_id
          FROM dba_temp_files t
         WHERE NOT EXISTS (SELECT 1
                             FROM epfpg.epf_instance_change c
                            WHERE c.item = 'SIZE_TEMP' AND c.target = t.tablespace_name AND c.restored_at IS NULL)
         GROUP BY t.tablespace_name;
        COMMIT;
    END size_record;

    PROCEDURE size_giveback IS
        l_now    NUMBER;
        l_bs     NUMBER;
        l_hwm    NUMBER;
        l_target NUMBER;
        l_after  NUMBER;
    BEGIN
        FOR c IN (SELECT change_id, item, target, file_id, original_value
                    FROM epfpg.epf_instance_change
                   WHERE restored_at IS NULL AND item IN ('SIZE_UNDO', 'SIZE_TEMP')
                   ORDER BY change_id) LOOP
            l_after := NULL;
            BEGIN
                IF c.item = 'SIZE_UNDO' THEN
                    SELECT MAX(d.bytes), MAX(t.block_size)
                      INTO l_now, l_bs
                      FROM dba_data_files d
                      JOIN dba_tablespaces t ON t.tablespace_name = d.tablespace_name
                     WHERE d.file_id = c.file_id AND d.file_name = c.target;
                    l_after := l_now;
                    IF l_now > c.original_value THEN
                        -- Not below the highest extent Oracle still holds there.
                        SELECT NVL(MAX(block_id + blocks), 0) * l_bs
                          INTO l_hwm
                          FROM dba_undo_extents
                         WHERE file_id = c.file_id;
                        l_target := GREATEST(c.original_value, CEIL(l_hwm / 1048576) * 1048576);
                        IF l_target < l_now THEN
                            EXECUTE IMMEDIATE 'ALTER DATABASE DATAFILE ' || c.file_id || ' RESIZE '
                                              || ROUND(l_target / 1024) || 'K';
                            l_after := l_target;
                        END IF;
                        say(CASE WHEN l_after > c.original_value THEN 'INFO' ELSE 'OK' END, 'UNDO_RESIZED',
                            c.target || ': ' || epfpg.epf_util.fmt_bytes(l_now) || ' -> '
                            || epfpg.epf_util.fmt_bytes(l_after)
                            || CASE WHEN l_after > c.original_value
                                    THEN ' (' || epfpg.epf_util.fmt_bytes(c.original_value) || ' before; Oracle still '
                                         || 'holds undo above that, given back by a later undo restore)' END);
                    END IF;
                ELSE
                    SELECT SUM(bytes) INTO l_now FROM dba_temp_files WHERE tablespace_name = c.target;
                    l_after := l_now;
                    IF l_now > c.original_value THEN
                        EXECUTE IMMEDIATE 'ALTER TABLESPACE "' || c.target || '" SHRINK SPACE KEEP '
                                          || CEIL(c.original_value / 1024) || 'K';
                        SELECT SUM(bytes) INTO l_after FROM dba_temp_files WHERE tablespace_name = c.target;
                        say(CASE WHEN l_after > c.original_value THEN 'INFO' ELSE 'OK' END, 'TEMP_RESIZED',
                            c.target || ': ' || epfpg.epf_util.fmt_bytes(l_now) || ' -> '
                            || epfpg.epf_util.fmt_bytes(l_after)
                            || CASE WHEN l_after > c.original_value
                                    THEN ' (' || epfpg.epf_util.fmt_bytes(c.original_value) || ' before; the rest is in use)'
                               END);
                    END IF;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    say('INFO', CASE c.item WHEN 'SIZE_UNDO' THEN 'UNDO_SIZE_KEPT' ELSE 'TEMP_SIZE_KEPT' END,
                        c.target || ' not resized: ' || SQLERRM);
            END;
            -- Closed once back at the size before, within 64 MB (a shrink stops
            -- at an extent), or gone; otherwise kept for the next call.
            IF l_after IS NULL OR l_after <= c.original_value + 67108864 THEN
                UPDATE epfpg.epf_instance_change
                   SET restored_at = CAST(SYSTIMESTAMP AS TIMESTAMP)
                 WHERE change_id = c.change_id;
                COMMIT;
            END IF;
        END LOOP;
    END size_giveback;

    PROCEDURE undo_apply(p_run_id IN NUMBER DEFAULT NULL, p_preflight_run_id IN NUMBER DEFAULT NULL) IS
        l_retention NUMBER := epfpg.epf_util.setting_num('undo_retention_s');
        l_ts        VARCHAR2(128);
        l_guarantee VARCHAR2(11);
        l_current   NUMBER;
        l_active    NUMBER;
        l_run       NUMBER := NVL(p_run_id, epfpg.epf_log.current_run);
        l_batch     NUMBER;
        l_cap       NUMBER;
    BEGIN
        check_instance;
        SELECT COUNT(*) INTO l_active
          FROM epfpg.epf_instance_change
         WHERE restored_at IS NULL AND item LIKE 'UNDO%';
        IF l_active > 0 THEN
            say('INFO', 'UNDO_ALREADY_APPLIED', l_active || ' undo changes are active; restore them first to apply again');
            undo_status;
            RETURN;
        END IF;

        l_ts := undo_tablespace;
        SELECT retention INTO l_guarantee FROM dba_tablespaces WHERE tablespace_name = l_ts;
        IF l_guarantee = 'GUARANTEE' THEN
            RAISE_APPLICATION_ERROR(-20152, 'Undo tablespace ' || l_ts || ' has RETENTION GUARANTEE: lowering the '
                                            || 'retention would make transactions fail (ORA-30036).');
        END IF;
        undo_status;
        -- The sizes the purge may grow, given back by undo_restore.
        size_record(l_run, TRUE);

        SELECT TO_NUMBER(value) INTO l_current FROM v$parameter WHERE name = 'undo_retention';
        IF l_retention < l_current THEN
            INSERT INTO epfpg.epf_instance_change (item, target, original_value, applied_value, applied_at,
                                                   applied_run_id)
            VALUES ('UNDO_RETENTION', 'undo_retention', l_current, l_retention, CAST(SYSTIMESTAMP AS TIMESTAMP), l_run);
            COMMIT;
            EXECUTE IMMEDIATE 'ALTER SYSTEM SET undo_retention = ' || l_retention || ' SCOPE = MEMORY';
            say('OK', 'UNDO_RETENTION_SET', 'undo_retention ' || l_current || ' s -> ' || l_retention || ' s');
        ELSE
            say('INFO', 'UNDO_RETENTION_KEPT', 'undo_retention is already ' || l_current || ' s');
        END IF;

        l_batch := batch_undo(p_run_id, p_preflight_run_id);
        l_cap := undo_cap(l_batch);
        say('INFO', 'UNDO_CAP', l_ts || ' limited to ' || ROUND(l_cap / 1048576) || ' MB: the largest of its size, '
                                || 'undo_cap_mb (' || epfpg.epf_util.setting('undo_cap_mb') || ' MB)'
                                || CASE WHEN l_batch IS NOT NULL THEN
                                        ' and 4 x the undo of one batch (' || ROUND(l_batch / 1048576) || ' MB)'
                                   END);
        limit_undo_growth(l_ts, l_cap, l_run);
        say('WARN', 'UNDO_APPLIED', 'Undo tuning is active until undo_restore: long queries of other sessions may fail '
                                    || 'with ORA-01555 meanwhile');
    END undo_apply;

    PROCEDURE undo_restore IS
        l_count  NUMBER := 0;
        l_exists NUMBER;
    BEGIN
        check_instance;
        FOR c IN (SELECT change_id, item, target, file_id, original_value, original_maxbytes, original_increment
                    FROM epfpg.epf_instance_change
                   WHERE restored_at IS NULL AND item LIKE 'UNDO%'
                   ORDER BY change_id DESC) LOOP
            IF c.item = 'UNDO_RETENTION' THEN
                EXECUTE IMMEDIATE 'ALTER SYSTEM SET undo_retention = ' || c.original_value || ' SCOPE = MEMORY';
                say('OK', 'UNDO_RETENTION_RESTORED', 'undo_retention ' || c.original_value || ' s');
            ELSE
                SELECT COUNT(*) INTO l_exists FROM dba_data_files WHERE file_id = c.file_id AND file_name = c.target;
                IF l_exists > 0 THEN
                    EXECUTE IMMEDIATE 'ALTER DATABASE DATAFILE ' || c.file_id || ' AUTOEXTEND ON NEXT '
                                      || c.original_increment / 1024 || 'K MAXSIZE ' || c.original_maxbytes / 1024 || 'K';
                    say('OK', 'UNDO_GROWTH_RESTORED', c.target || ': may grow to '
                                                      || ROUND(c.original_maxbytes / 1048576) || ' MB');
                ELSE
                    say('WARN', 'UNDO_FILE_GONE', c.target || ' (file ' || c.file_id || ') no longer exists; nothing '
                                                  || 'to restore');
                END IF;
            END IF;
            UPDATE epfpg.epf_instance_change
               SET restored_at = CAST(SYSTIMESTAMP AS TIMESTAMP)
             WHERE change_id = c.change_id;
            COMMIT;
            l_count := l_count + 1;
        END LOOP;
        IF l_count = 0 THEN
            say('INFO', 'UNDO_NOTHING_TO_RESTORE', 'No active undo change');
        END IF;
        -- What the undo datafiles and the temporary tablespaces grew.
        size_giveback;
        undo_status;
    END undo_restore;

END epf_tuning;
/

CREATE OR REPLACE PACKAGE BODY epf_reclaim AS

    c_phase  CONSTANT VARCHAR2(10) := 'RECLAIM';
    c_change CONSTANT VARCHAR2(30) := 'RECLAIM_DATAFILE';
    c_mb     CONSTANT NUMBER       := 1048576;
    -- A move of at least this many bytes is reported OK, a smaller one INFO.
    c_big    CONSTANT NUMBER       := 67108864;
    -- The largest system-allocated extent. A segment created with an INITIAL
    -- of n of these is created as n extents of this size, and such an extent
    -- takes only a free stretch of its size: Oracle fills partly used
    -- stretches first with smaller extents, wherever they are, and takes a
    -- wholly free stretch, the lowest, only for an extent that needs one.
    c_chunk  CONSTANT NUMBER       := 67108864;
    -- A table at least this large moves with extents of c_chunk from its
    -- first move (it wastes at most a tenth of its size); a smaller one only
    -- after its copy came back to the top, and only when it is large enough
    -- for them (chunked).
    c_large  CONSTANT NUMBER       := 671088640;

    TYPE t_flags IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;
    TYPE t_counts IS TABLE OF PLS_INTEGER INDEX BY PLS_INTEGER;

    g_run      epfpg.epf_run%ROWTYPE;
    g_mode     VARCHAR2(10);
    g_item     NUMBER := 0;
    g_warnings PLS_INTEGER := 0;
    g_errors   PLS_INTEGER := 0;
    g_stopped  BOOLEAN := FALSE;
    g_changed  BOOLEAN := FALSE;
    g_growth   NUMBER := 0;
    g_margin   NUMBER := 0;
    g_moves    NUMBER := 3;
    g_retries  NUMBER := 3;
    g_pause    NUMBER := 0;
    -- Moves of each unit (by item) after which its copy held the top of its
    -- datafile again; a unit moves c_move_cap times at most in a run.
    g_at_top   t_counts;
    c_move_cap CONSTANT PLS_INTEGER := 10;
    -- Per owner, read once per run (internal_reason): Q when it has queue
    -- tables, D when it has domain indexes, '-' otherwise, in that order.
    TYPE t_flag_text IS TABLE OF VARCHAR2(2) INDEX BY VARCHAR2(128);
    g_features t_flag_text;
    -- The segments the statement being built asks INITIAL 64 KB for, as
    -- "what|segment" (initial_clause; read once it ran by initial_kept).
    g_reset    SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();

    -- Fingerprints of the objects a compaction may affect, read once the
    -- accounts are locked and before any object changes (baseline), and again
    -- before the accounts are unlocked (verify), with the same expressions:
    -- the indexes of the run, the constraints of the tables in scope and the
    -- foreign keys referencing the tables that move, the tables that move and
    -- their LOB columns. Attributes as key=value pairs separated by ';'
    -- (EPF_OBJECT_BASELINE).
    CURSOR c_fingerprint(p_run IN NUMBER) IS
        SELECT 'INDEX' AS object_type, i.owner, i.index_name AS name, i.table_owner, i.table_name,
               i.tablespace_name, i.status, NULL AS validated, TRIM(i.degree) AS degree, i.logging,
               'status=' || i.status || ';tablespace=' || i.tablespace_name || ';degree=' || TRIM(i.degree)
               || ';logging=' || i.logging || ';type=' || i.index_type || ';uniqueness=' || i.uniqueness
               || ';visibility=' || i.visibility || ';compression=' || i.compression || ';pct_free=' || i.pct_free
                   AS fp
          FROM dba_indexes i
         WHERE (i.owner, i.index_name) IN (SELECT o.owner, o.object_name
                                             FROM epfpg.epf_reclaim_object o
                                            WHERE o.run_id = p_run AND o.unit_type = 'INDEX')
        UNION ALL
        SELECT 'CONSTRAINT', c.owner, c.constraint_name, c.owner, c.table_name, NULL, c.status, c.validated, NULL,
               NULL,
               'status=' || c.status || ';validated=' || c.validated || ';type=' || c.constraint_type
               || ';deferrable=' || c.deferrable || ';deferred=' || c.deferred || ';rely=' || c.rely
          FROM dba_constraints c
         WHERE (c.owner, c.table_name) IN (SELECT o.table_owner, o.table_name
                                             FROM epfpg.epf_reclaim_object o
                                            WHERE o.run_id = p_run AND o.unit_type IN ('TABLE', 'IOT', 'INDEX')
                                              AND o.table_name IS NOT NULL)
            OR (c.constraint_type = 'R'
                AND (c.r_owner, c.r_constraint_name) IN (SELECT p.owner, p.constraint_name
                                                           FROM dba_constraints p
                                                           JOIN epfpg.epf_reclaim_object o
                                                             ON o.owner = p.owner AND o.object_name = p.table_name
                                                          WHERE o.run_id = p_run AND o.unit_type IN ('TABLE', 'IOT')
                                                            AND p.constraint_type IN ('P', 'U')))
        UNION ALL
        SELECT 'TABLE', t.owner, t.table_name, t.owner, t.table_name, t.tablespace_name, NULL, NULL,
               TRIM(t.degree), t.logging,
               'tablespace=' || t.tablespace_name || ';logging=' || t.logging || ';degree=' || TRIM(t.degree)
               || ';pct_free=' || t.pct_free || ';ini_trans=' || t.ini_trans || ';compression=' || t.compression
               || ';compress_for=' || t.compress_for || ';iot_type=' || t.iot_type
          FROM dba_tables t
         WHERE (t.owner, t.table_name) IN (SELECT o.owner, o.object_name
                                             FROM epfpg.epf_reclaim_object o
                                            WHERE o.run_id = p_run AND o.unit_type IN ('TABLE', 'IOT'))
        UNION ALL
        SELECT 'LOB', l.owner, l.column_name, l.owner, l.table_name, l.tablespace_name, NULL, NULL, NULL, l.logging,
               'tablespace=' || l.tablespace_name || ';logging=' || l.logging || ';securefile=' || l.securefile
               || ';chunk=' || l.chunk || ';pctversion=' || l.pctversion || ';retention=' || l.retention
               || ';cache=' || l.cache || ';encrypt=' || l.encrypt || ';compression=' || l.compression
               || ';deduplication=' || l.deduplication || ';in_row=' || l.in_row || ';segment=' || l.segment_name
          FROM dba_lobs l
         WHERE (l.owner, l.table_name) IN (SELECT o.owner, o.object_name
                                             FROM epfpg.epf_reclaim_object o
                                            WHERE o.run_id = p_run AND o.unit_type IN ('TABLE', 'IOT'));

    -- ------------------------------------------------------------------
    -- Helpers
    -- ------------------------------------------------------------------

    FUNCTION q(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_ASSERT.ENQUOTE_NAME(p_name, FALSE);
    END q;

    FUNCTION qn(p_owner IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN q(p_owner) || '.' || q(p_name);
    END qn;

    FUNCTION b(p_bytes IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN NVL(epfpg.epf_util.fmt_bytes(p_bytes), '-');
    END b;

    -- Writes one event of the run; counts warnings and errors.
    PROCEDURE say(p_severity IN VARCHAR2, p_code IN VARCHAR2, p_message IN VARCHAR2,
                  p_owner IN VARCHAR2 DEFAULT NULL, p_object IN VARCHAR2 DEFAULT NULL,
                  p_rows IN NUMBER DEFAULT NULL, p_bytes IN NUMBER DEFAULT NULL, p_ora IN NUMBER DEFAULT NULL) IS
    BEGIN
        IF p_severity = epfpg.epf_log.c_warn THEN
            g_warnings := g_warnings + 1;
        ELSIF p_severity = epfpg.epf_log.c_error THEN
            g_errors := g_errors + 1;
        END IF;
        epfpg.epf_log.event(p_severity, p_code, p_message, p_object_owner => p_owner, p_object_name => p_object,
                            p_rows => p_rows, p_bytes => p_bytes, p_ora_code => p_ora);
    END say;

    -- Ends the current step FAILED with the error and where it was raised.
    PROCEDURE fail_step(p_code IN NUMBER, p_message IN VARCHAR2, p_backtrace IN VARCHAR2) IS
    BEGIN
        ROLLBACK;
        say(epfpg.epf_log.c_error, 'STEP_FAILED',
            NVL(epfpg.epf_log.current_step, c_phase) || ': ' || p_message || ' ' || p_backtrace, p_ora => ABS(p_code));
        IF epfpg.epf_log.current_step IS NOT NULL THEN
            epfpg.epf_log.step_end('FAILED', SUBSTR(p_message, 1, 400));
        END IF;
    END fail_step;

    -- The tablespace has no free space for the statement.
    FUNCTION is_space_error(p_code IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN p_code IN (-1652, -1653, -1654, -1658, -1659, -1683, -1688, -1691, -1692);
    END is_space_error;

    -- The owner of the segment has no space quota left for it in the
    -- tablespace (ORA-01536), or none there (ORA-01950).
    FUNCTION is_quota_error(p_code IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN p_code IN (-1536, -1950);
    END is_quota_error;

    -- The operator confirmed blocking requirement p_code (EPF_RUN.confirmed_reqs).
    FUNCTION confirmed(p_code IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN INSTR(',' || g_run.confirmed_reqs || ',', ',' || p_code || ',') > 0;
    END confirmed;

    -- Runs one DDL statement. ORA-00054 (resource busy once ddl_lock_timeout
    -- has passed) is retried ddl_retries times, after 30, 60, 120 ... seconds;
    -- the last error is raised.
    PROCEDURE ddl(p_sql IN VARCHAR2) IS
        l_attempt PLS_INTEGER := 0;
        l_wait    NUMBER;
    BEGIN
        LOOP
            BEGIN
                EXECUTE IMMEDIATE p_sql;
                RETURN;
            EXCEPTION
                WHEN OTHERS THEN
                    IF SQLCODE <> -54 OR l_attempt >= g_retries THEN
                        RAISE;
                    END IF;
            END;
            l_attempt := l_attempt + 1;
            l_wait := 30 * POWER(2, l_attempt - 1);
            say(epfpg.epf_log.c_info, 'DDL_RETRY', 'Resource busy (ORA-00054): retry ' || l_attempt || ' of ' || g_retries
                                                   || ' in ' || l_wait || ' s: ' || SUBSTR(p_sql, 1, 300));
            DBMS_LOCK.SLEEP(l_wait);
        END LOOP;
    END ddl;

    FUNCTION row_count(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN NUMBER IS
        l_count NUMBER;
    BEGIN
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || qn(p_owner, p_table) INTO l_count;
        RETURN l_count;
    END row_count;

    -- ------------------------------------------------------------------
    -- Datafiles
    -- ------------------------------------------------------------------

    -- Allocated size of tablespace p_ts: the sum of its datafiles.
    FUNCTION ts_bytes(p_ts IN VARCHAR2) RETURN NUMBER IS
        l_bytes NUMBER;
    BEGIN
        SELECT NVL(SUM(bytes), 0) INTO l_bytes FROM dba_data_files WHERE tablespace_name = p_ts;
        RETURN l_bytes;
    END ts_bytes;

    -- Free space of tablespace p_ts.
    FUNCTION free_bytes(p_ts IN VARCHAR2) RETURN NUMBER IS
        l_bytes NUMBER;
    BEGIN
        SELECT NVL(SUM(bytes), 0) INTO l_bytes FROM dba_free_space WHERE tablespace_name = p_ts;
        RETURN l_bytes;
    END free_bytes;

    -- Size of the last extent of a segment of p_bytes, which a segment that
    -- moves may need besides its size: the uniform size p_uniform, or with
    -- AUTOALLOCATE (p_alloc SYSTEM) 64 KB below 1 MB, 1 MB below 64 MB, 8 MB
    -- below 1 GB and 64 MB beyond.
    FUNCTION extent_for(p_bytes IN NUMBER, p_alloc IN VARCHAR2, p_uniform IN NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN CASE WHEN p_alloc = 'UNIFORM' THEN NVL(p_uniform, c_mb)
                    WHEN p_bytes < c_mb THEN 65536
                    WHEN p_bytes < 64 * c_mb THEN c_mb
                    WHEN p_bytes < 1024 * c_mb THEN 8 * c_mb
                    ELSE 64 * c_mb END;
    END extent_for;

    -- Records the largest size tablespace p_ts reached during the run.
    PROCEDURE track_peak(p_ts IN VARCHAR2) IS
        l_now NUMBER := ts_bytes(p_ts);
    BEGIN
        UPDATE epfpg.epf_reclaim_ts
           SET peak_bytes = GREATEST(NVL(peak_bytes, 0), l_now)
         WHERE run_id = g_run.run_id AND tablespace_name = p_ts;
        COMMIT;
    END track_peak;

    -- Resizes every datafile of p_ts down to the end of its highest extent
    -- (p_margin 0: no free space is left above it, where Oracle would place
    -- the first extents of the next copy), or to that plus p_margin bytes
    -- rounded up to a MB; never below 10 MB, and only when that is smaller
    -- than the file. A file that cannot shrink that far (ORA-03297, ORA-03214)
    -- keeps its size. p_report: an event per file. Returns the bytes given
    -- back.
    FUNCTION trim_ts(p_ts IN VARCHAR2, p_margin IN NUMBER, p_report IN BOOLEAN) RETURN NUMBER IS
        l_hwm    NUMBER;
        l_target NUMBER;
        l_freed  NUMBER := 0;
    BEGIN
        FOR f IN (SELECT d.file_id, d.file_name, d.bytes, t.block_size
                    FROM dba_data_files d
                    JOIN dba_tablespaces t ON t.tablespace_name = d.tablespace_name
                   WHERE d.tablespace_name = p_ts
                   ORDER BY d.file_id) LOOP
            -- Blocks up to the end of the highest extent (block_id + blocks
            -- is the block after it).
            SELECT NVL(MAX(block_id + blocks), 0) INTO l_hwm FROM dba_extents WHERE file_id = f.file_id;
            l_target := GREATEST(CASE WHEN NVL(p_margin, 0) > 0
                                      THEN CEIL((l_hwm * f.block_size + p_margin) / c_mb) * c_mb
                                      ELSE l_hwm * f.block_size END, 10 * c_mb);
            IF l_target < f.bytes THEN
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER DATABASE DATAFILE ' || f.file_id || ' RESIZE ' || l_target;
                    l_freed := l_freed + f.bytes - l_target;
                    IF p_report THEN
                        say(epfpg.epf_log.c_ok, 'FILE_RESIZED', f.file_name || ': ' || b(f.bytes) || ' -> ' || b(l_target),
                            p_bytes => l_target);
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        IF SQLCODE NOT IN (-3297, -3214) THEN
                            RAISE;
                        END IF;
                        IF p_report THEN
                            say(epfpg.epf_log.c_info, 'FILE_KEPT', f.file_name || ' keeps ' || b(f.bytes) || ': ' || SQLERRM);
                        END IF;
                END;
            ELSIF p_report THEN
                say(epfpg.epf_log.c_info, 'FILE_KEPT', f.file_name || ' keeps ' || b(f.bytes)
                                                       || ': its highest block is within the margin of its end');
            END IF;
        END LOOP;
        RETURN l_freed;
    END trim_ts;

    -- Stops the autoextensible datafiles of p_ts from growing while the run
    -- compacts: records the setting (EPF_INSTANCE_CHANGE, RECLAIM_DATAFILE;
    -- not again while an unrestored record exists), then AUTOEXTEND OFF.
    -- p_count returns the files.
    PROCEDURE freeze_files(p_ts IN VARCHAR2, p_count OUT PLS_INTEGER) IS
        l_pending NUMBER;
    BEGIN
        p_count := 0;
        FOR f IN (SELECT d.file_id, d.file_name, d.maxbytes, d.increment_by * t.block_size AS incr_bytes
                    FROM dba_data_files d
                    JOIN dba_tablespaces t ON t.tablespace_name = d.tablespace_name
                   WHERE d.tablespace_name = p_ts AND d.autoextensible = 'YES'
                   ORDER BY d.file_id) LOOP
            SELECT COUNT(*)
              INTO l_pending
              FROM epfpg.epf_instance_change
             WHERE item = c_change AND file_id = f.file_id AND target = f.file_name AND restored_at IS NULL;
            IF l_pending = 0 THEN
                INSERT INTO epfpg.epf_instance_change (item, target, file_id, original_autoextend, original_maxbytes,
                                                       original_increment, applied_value, applied_at, applied_run_id)
                VALUES (c_change, f.file_name, f.file_id, 'YES', f.maxbytes, f.incr_bytes, 0, epfpg.epf_util.now_ts,
                        g_run.run_id);
                COMMIT;
            END IF;
            g_changed := TRUE;
            EXECUTE IMMEDIATE 'ALTER DATABASE DATAFILE ' || f.file_id || ' AUTOEXTEND OFF';
            p_count := p_count + 1;
            say(epfpg.epf_log.c_info, 'FILE_GROWTH_OFF', f.file_name || ': autoextend off while the run compacts and '
                                                         || 'rebuilds (it can grow up to ' || b(f.maxbytes) || ')');
        END LOOP;
    END freeze_files;

    -- Restores every recorded datafile growth setting not yet restored: this
    -- run's and any an earlier reclaim left. A setting that cannot be
    -- restored stays recorded and is reported with its statement.
    PROCEDURE restore_files(p_count OUT PLS_INTEGER) IS
        l_exists NUMBER;
        l_sql    VARCHAR2(400);
    BEGIN
        p_count := 0;
        FOR c IN (SELECT change_id, target, file_id, original_maxbytes, original_increment
                    FROM epfpg.epf_instance_change
                   WHERE item = c_change AND restored_at IS NULL
                   ORDER BY change_id) LOOP
            SELECT COUNT(*) INTO l_exists FROM dba_data_files WHERE file_id = c.file_id AND file_name = c.target;
            l_sql := 'ALTER DATABASE DATAFILE ' || c.file_id || ' AUTOEXTEND ON NEXT '
                     || GREATEST(TRUNC(c.original_increment / 1024), 1) || 'K MAXSIZE '
                     || TRUNC(c.original_maxbytes / 1024) || 'K';
            BEGIN
                IF l_exists > 0 THEN
                    EXECUTE IMMEDIATE l_sql;
                    say(epfpg.epf_log.c_ok, 'FILE_GROWTH_RESTORED', c.target || ': autoextend on again, up to '
                                                                    || b(c.original_maxbytes));
                ELSE
                    say(epfpg.epf_log.c_warn, 'FILE_GONE', c.target || ' (file ' || c.file_id
                                                           || ') no longer exists: nothing to restore');
                END IF;
                UPDATE epfpg.epf_instance_change SET restored_at = epfpg.epf_util.now_ts WHERE change_id = c.change_id;
                COMMIT;
                p_count := p_count + 1;
            EXCEPTION
                WHEN OTHERS THEN
                    say(epfpg.epf_log.c_error, 'FILE_GROWTH_NOT_RESTORED', c.target || ': ' || SQLERRM
                                                                           || '; the DBA restores it with: ' || l_sql,
                        p_ora => ABS(SQLCODE));
            END;
        END LOOP;
    END restore_files;

    -- Grows datafile p_file_id of p_ts by about p_bytes within its room: its
    -- size at the start of the run plus reclaim_growth_mb (p_growth instead
    -- when given), and no further than its growth limit when it was
    -- autoextensible. p_for: what for, in the event (FILE_GROWN). Returns the
    -- bytes added; 0 when there is no room or the file could not grow.
    FUNCTION grow_file(p_ts IN VARCHAR2, p_file_id IN NUMBER, p_bytes IN NUMBER,
                       p_for IN VARCHAR2 DEFAULT 'a segment that does not fit in its free space',
                       p_growth IN NUMBER DEFAULT NULL) RETURN NUMBER IS
        l_now    NUMBER;
        l_start  NUMBER;
        l_limit  NUMBER;
        l_target NUMBER;
    BEGIN
        SELECT bytes INTO l_now FROM dba_data_files WHERE file_id = p_file_id;
        SELECT MAX(bytes)
          INTO l_start
          FROM epfpg.epf_file_snap
         WHERE run_id = g_run.run_id AND phase = 'BASELINE' AND file_id = p_file_id;
        l_limit := NVL(l_start, l_now) + NVL(p_growth, g_growth);
        FOR c IN (SELECT original_maxbytes
                    FROM epfpg.epf_instance_change
                   WHERE item = c_change AND file_id = p_file_id AND restored_at IS NULL) LOOP
            l_limit := LEAST(l_limit, GREATEST(c.original_maxbytes, NVL(l_start, l_now)));
        END LOOP;
        l_target := LEAST(l_limit, CEIL((l_now + p_bytes) / c_mb) * c_mb);
        IF l_target <= l_now THEN
            RETURN 0;
        END IF;
        BEGIN
            EXECUTE IMMEDIATE 'ALTER DATABASE DATAFILE ' || p_file_id || ' RESIZE ' || l_target;
        EXCEPTION
            WHEN OTHERS THEN
                say(epfpg.epf_log.c_warn, 'FILE_NOT_GROWN', 'File ' || p_file_id || ' could not grow from ' || b(l_now)
                                                            || ' to ' || b(l_target) || ': ' || SQLERRM);
                RETURN 0;
        END;
        track_peak(p_ts);
        say(epfpg.epf_log.c_info, 'FILE_GROWN', 'File ' || p_file_id || ' of ' || p_ts || ': ' || b(l_now) || ' -> '
                                                || b(l_target) || ' for ' || p_for || ' (never above ' || b(l_limit) || ')',
            p_bytes => l_target);
        RETURN l_target - l_now;
    END grow_file;

    -- Grows the datafiles of p_ts that cannot grow by themselves by about
    -- p_bytes in all, each within its room (grow_file, p_for, p_growth).
    -- Returns the bytes added.
    FUNCTION grow_ts(p_ts IN VARCHAR2, p_bytes IN NUMBER,
                     p_for IN VARCHAR2 DEFAULT 'a segment that does not fit in its free space',
                     p_growth IN NUMBER DEFAULT NULL) RETURN NUMBER IS
        l_added NUMBER := 0;
    BEGIN
        FOR f IN (SELECT file_id FROM dba_data_files
                   WHERE tablespace_name = p_ts AND autoextensible = 'NO'
                   ORDER BY file_id) LOOP
            EXIT WHEN l_added >= p_bytes;
            l_added := l_added + grow_file(p_ts, f.file_id, p_bytes - l_added, p_for, p_growth);
        END LOOP;
        RETURN l_added;
    END grow_ts;

    -- Datafiles of the run's tablespaces at p_phase (EPF_FILE_SNAP): size,
    -- highest allocated block, free space, growth settings.
    PROCEDURE snap_files(p_phase IN VARCHAR2) IS
    BEGIN
        DELETE FROM epfpg.epf_file_snap WHERE run_id = g_run.run_id AND phase = p_phase;
        INSERT INTO epfpg.epf_file_snap (run_id, phase, tablespace_name, file_id, file_name, bytes, hwm_bytes,
                                         free_bytes, autoextensible, increment_by, maxbytes)
        SELECT g_run.run_id, p_phase, d.tablespace_name, d.file_id, d.file_name, d.bytes,
               (SELECT (MAX(x.block_id + x.blocks) - 1) * t.block_size FROM dba_extents x WHERE x.file_id = d.file_id),
               (SELECT SUM(fs.bytes) FROM dba_free_space fs WHERE fs.file_id = d.file_id),
               d.autoextensible, d.increment_by * t.block_size, d.maxbytes
          FROM dba_data_files d
          JOIN dba_tablespaces t ON t.tablespace_name = d.tablespace_name
         WHERE d.tablespace_name IN (SELECT r.tablespace_name FROM epfpg.epf_reclaim_ts r WHERE r.run_id = g_run.run_id);
        COMMIT;
    END snap_files;

    -- ------------------------------------------------------------------
    -- Items
    -- ------------------------------------------------------------------

    FUNCTION new_item(p_type IN VARCHAR2, p_owner IN VARCHAR2, p_name IN VARCHAR2, p_sub IN VARCHAR2,
                      p_ts IN VARCHAR2, p_table_owner IN VARCHAR2, p_table IN VARCHAR2, p_status IN VARCHAR2,
                      p_detail IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        g_item := g_item + 1;
        INSERT INTO epfpg.epf_reclaim_object (run_id, item_id, owner, object_name, sub_name, unit_type, source_ts,
                                              target_ts, table_owner, table_name, bytes, est_bytes, move_status,
                                              attempts, detail)
        VALUES (g_run.run_id, g_item, p_owner, p_name, p_sub, p_type, p_ts, p_ts, p_table_owner, p_table, 0, 0,
                p_status, 0, SUBSTR(p_detail, 1, 4000));
        RETURN g_item;
    END new_item;

    -- Bytes a segment is expected to need after a move or rebuild: its latest
    -- space measurement (EPF_SPACE_USAGE, written by purges) plus a margin;
    -- for a table without one, its optimizer statistics; otherwise its size.
    -- Never more than its size.
    FUNCTION estimate(p_owner IN VARCHAR2, p_segment IN VARCHAR2, p_type IN VARCHAR2, p_bytes IN NUMBER)
        RETURN NUMBER IS
        l_used NUMBER;
        l_est  NUMBER;
    BEGIN
        SELECT MAX(used_bytes) KEEP (DENSE_RANK LAST ORDER BY measured_at)
          INTO l_used
          FROM epfpg.epf_space_usage
         WHERE owner = p_owner AND segment_name = p_segment AND partition_name IS NULL AND used_bytes IS NOT NULL;
        IF l_used IS NOT NULL THEN
            l_est := l_used * CASE WHEN p_type = 'TABLE' THEN 1.15 ELSE 1.1 END;
        ELSIF p_type = 'TABLE' THEN
            SELECT MAX(num_rows * avg_row_len * 100 / GREATEST(100 - NVL(pct_free, 10), 50) * 1.15)
              INTO l_est
              FROM dba_tables
             WHERE owner = p_owner AND table_name = p_segment AND num_rows IS NOT NULL AND avg_row_len IS NOT NULL;
        END IF;
        RETURN CEIL(LEAST(p_bytes, NVL(l_est, p_bytes)));
    END estimate;

    -- Bytes a segment of type p_type (TABLE, INDEX, LOBSEGMENT) whose
    -- estimate is p_est holds once it moves or is rebuilt, to decide its
    -- INITIAL (initial_clause): p_est, or for an index its leaf blocks by its
    -- optimizer statistics plus a tenth (branch blocks) when that is less. A
    -- smaller INITIAL never keeps a segment from growing; the space a move or
    -- rebuild needs is still planned with p_est.
    FUNCTION initial_need(p_owner IN VARCHAR2, p_name IN VARCHAR2, p_type IN VARCHAR2, p_est IN NUMBER)
        RETURN NUMBER IS
        l_stat NUMBER;
    BEGIN
        IF p_type = 'INDEX' THEN
            SELECT MAX(i.leaf_blocks * t.block_size * 1.1)
              INTO l_stat
              FROM dba_indexes i
              JOIN dba_tablespaces t ON t.tablespace_name = i.tablespace_name
             WHERE i.owner = p_owner AND i.index_name = p_name AND i.leaf_blocks IS NOT NULL;
        END IF;
        RETURN CEIL(LEAST(NVL(p_est, 0), NVL(l_stat, NVL(p_est, 0))));
    END initial_need;

    -- The INITIAL a segment of p_est bytes gets to move with extents of
    -- c_chunk: p_est rounded up to whole extents, one at least.
    FUNCTION large_initial(p_est IN NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN GREATEST(CEIL(NVL(p_est, 0) / c_chunk), 1) * c_chunk;
    END large_initial;

    -- An INITIAL larger than a segment needing p_need bytes needs: above
    -- p_need and 1 MB, unless it is p_need rounded up to whole extents of
    -- c_chunk wasting at most a quarter (set by a move with large extents,
    -- large_initial).
    FUNCTION oversized(p_initial IN NUMBER, p_need IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN NVL(p_initial, 0) > GREATEST(NVL(p_need, 0), c_mb)
               AND NOT (MOD(p_initial, c_chunk) = 0 AND p_initial < NVL(p_need, 0) + c_chunk
                        AND p_initial <= NVL(p_need, 0) * 1.25);
    END oversized;

    -- A segment of p_est bytes can move with extents of c_chunk: its INITIAL
    -- for that (large_initial) is not oversized, at most a quarter above its
    -- size, so the segment has at least about 51 MB.
    FUNCTION chunked(p_est IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN NVL(p_est, 0) > 0 AND NOT oversized(large_initial(p_est), p_est);
    END chunked;

    -- The tablespace of table p_owner.p_table: of its index segment for an
    -- index-organized table.
    FUNCTION home_ts(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN VARCHAR2 IS
        l_iot VARCHAR2(12);
        l_ts  VARCHAR2(128);
    BEGIN
        SELECT MAX(iot_type), MAX(tablespace_name)
          INTO l_iot, l_ts
          FROM dba_tables
         WHERE owner = p_owner AND table_name = p_table;
        IF l_iot = 'IOT' THEN
            SELECT MAX(tablespace_name)
              INTO l_ts
              FROM dba_indexes
             WHERE table_owner = p_owner AND table_name = p_table AND index_type = 'IOT - TOP';
        END IF;
        RETURN l_ts;
    END home_ts;

    -- The item of a table: created as a unit (TABLE, or IOT for an
    -- index-organized table) when missing. Its source_ts is its own
    -- tablespace when the run compacts it, otherwise p_ts (where one of its
    -- LOB segments was found).
    FUNCTION table_item(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_ts IN VARCHAR2) RETURN NUMBER IS
        l_id     NUMBER;
        l_iot    VARCHAR2(12);
        l_ts     VARCHAR2(128) := home_ts(p_owner, p_table);
        l_target NUMBER;
    BEGIN
        SELECT MAX(item_id)
          INTO l_id
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT', 'PIN')
           AND table_owner = p_owner AND table_name = p_table;
        IF l_id IS NULL THEN
            SELECT MAX(iot_type) INTO l_iot FROM dba_tables WHERE owner = p_owner AND table_name = p_table;
            SELECT COUNT(*) INTO l_target
              FROM epfpg.epf_reclaim_ts
             WHERE run_id = g_run.run_id AND tablespace_name = l_ts;
            l_id := new_item(CASE WHEN l_iot = 'IOT' THEN 'IOT' ELSE 'TABLE' END, p_owner, p_table, NULL,
                             CASE WHEN l_target > 0 THEN l_ts ELSE p_ts END, p_owner, p_table, 'PENDING', NULL);
        END IF;
        RETURN l_id;
    END table_item;

    -- Why table p_owner.p_table is maintained by an Oracle feature, which
    -- alone may move it, NULL when it is not: a queue table and the tables
    -- Oracle keeps for it (AQ$_<queue table>_*), the tables of an Oracle Text
    -- index (DR$<index>$*, DR#<index>*) and of a spatial index (MDRT_*$,
    -- MDXT_*$).
    FUNCTION internal_reason(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN VARCHAR2 IS
        l_name  VARCHAR2(128);
        l_count NUMBER;
        l_flags VARCHAR2(2);
    BEGIN
        IF p_owner IS NULL OR p_table IS NULL THEN
            RETURN NULL;
        END IF;
        IF p_table LIKE 'MDRT\_%$' ESCAPE '\' OR p_table LIKE 'MDXT\_%$' ESCAPE '\' THEN
            RETURN 'table of a spatial index (moved only with the index)';
        END IF;
        IF NOT g_features.EXISTS(p_owner) THEN
            SELECT COUNT(*) INTO l_count FROM dba_queue_tables WHERE owner = p_owner;
            l_flags := CASE WHEN l_count > 0 THEN 'Q' ELSE '-' END;
            SELECT COUNT(*) INTO l_count FROM dba_indexes WHERE owner = p_owner AND index_type = 'DOMAIN';
            g_features(p_owner) := l_flags || CASE WHEN l_count > 0 THEN 'D' ELSE '-' END;
        END IF;
        l_flags := g_features(p_owner);
        IF SUBSTR(l_flags, 1, 1) = 'Q' THEN
            SELECT MAX(queue_table) INTO l_name FROM dba_queue_tables WHERE owner = p_owner AND queue_table = p_table;
            IF l_name IS NOT NULL THEN
                RETURN 'queue table (moved only with the queue tools)';
            END IF;
            SELECT MAX(queue_table)
              INTO l_name
              FROM dba_queue_tables
             WHERE owner = p_owner AND p_table LIKE 'AQ$\_' || REPLACE(queue_table, '_', '\_') || '\_%' ESCAPE '\';
            IF l_name IS NOT NULL THEN
                RETURN 'table of queue table ' || l_name || ' (moved only with the queue tools)';
            END IF;
        END IF;
        IF SUBSTR(l_flags, 2, 1) = 'D' THEN
            SELECT MAX(index_name)
              INTO l_name
              FROM dba_indexes
             WHERE owner = p_owner AND index_type = 'DOMAIN'
               AND (p_table LIKE 'DR$' || REPLACE(index_name, '_', '\_') || '$%' ESCAPE '\'
                    OR p_table LIKE 'DR#' || REPLACE(index_name, '_', '\_') || '%' ESCAPE '\');
            IF l_name IS NOT NULL THEN
                RETURN 'table of Oracle Text index ' || l_name || ' (moved only with the index)';
            END IF;
        END IF;
        RETURN NULL;
    END internal_reason;

    -- The item of index p_owner.p_index, created when missing: PENDING
    -- (released, then rebuilt) when it is usable; RELEASED when an earlier
    -- compaction released it and it is still unusable (this run rebuilds it;
    -- an assessment only reports it); KEPT when it is unusable for another
    -- reason, or belongs to a table an Oracle feature maintains
    -- (internal_reason): left as found. NULL for an index the reclaim does not
    -- handle (IOT top, LOB, domain, cluster, partitioned, temporary).
    FUNCTION index_item(p_owner IN VARCHAR2, p_index IN VARCHAR2) RETURN NUMBER IS
        l_id     NUMBER;
        l_type   VARCHAR2(27);
        l_towner VARCHAR2(128);
        l_table  VARCHAR2(128);
        l_ts     VARCHAR2(128);
        l_status VARCHAR2(8);
        l_part   VARCHAR2(3);
        l_temp   VARCHAR2(1);
        l_func   VARCHAR2(8);
        l_prev   NUMBER;
        l_orig   VARCHAR2(20);
        l_state  VARCHAR2(20);
        l_detail VARCHAR2(400);
        l_bytes  NUMBER;
        l_est    NUMBER;
        l_prev_bytes NUMBER;
        l_internal   VARCHAR2(400);
    BEGIN
        SELECT MAX(item_id)
          INTO l_id
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id AND unit_type = 'INDEX' AND owner = p_owner AND object_name = p_index;
        IF l_id IS NOT NULL THEN
            RETURN l_id;
        END IF;
        SELECT MAX(index_type), MAX(table_owner), MAX(table_name), MAX(tablespace_name), MAX(status),
               MAX(partitioned), MAX(temporary), MAX(funcidx_status)
          INTO l_type, l_towner, l_table, l_ts, l_status, l_part, l_temp, l_func
          FROM dba_indexes
         WHERE owner = p_owner AND index_name = p_index;
        IF l_type IS NULL OR l_type IN ('IOT - TOP', 'LOB', 'DOMAIN', 'CLUSTER') OR l_part = 'YES' OR l_temp = 'Y' THEN
            RETURN NULL;
        END IF;
        SELECT MAX(o.run_id), MAX(o.orig_status) KEEP (DENSE_RANK LAST ORDER BY o.run_id),
               MAX(o.bytes) KEEP (DENSE_RANK LAST ORDER BY o.run_id)
          INTO l_prev, l_orig, l_prev_bytes
          FROM epfpg.epf_reclaim_object o
         WHERE o.unit_type = 'INDEX' AND o.owner = p_owner AND o.object_name = p_index
           AND o.run_id <> g_run.run_id AND o.move_status IN ('RELEASED', 'FAILED')
           AND o.run_id IN (SELECT r.run_id FROM epfpg.epf_run r WHERE r.reclaim_mode IN ('COMPACT', 'RESTORE'));
        l_internal := internal_reason(l_towner, l_table);
        IF l_status = 'UNUSABLE' AND l_prev IS NOT NULL THEN
            l_state := 'RELEASED';
            l_detail := 'released by ' || epfpg.epf_util.run_label(l_prev) || ' and still unusable';
            IF g_mode <> 'ASSESS' THEN
                UPDATE epfpg.epf_reclaim_object
                   SET move_status = 'ADOPTED',
                       detail = SUBSTR(NVL2(detail, detail || '; ', NULL) || 'rebuilt by '
                                       || epfpg.epf_util.run_label(g_run.run_id), 1, 4000)
                 WHERE unit_type = 'INDEX' AND owner = p_owner AND object_name = p_index
                   AND run_id <> g_run.run_id AND move_status IN ('RELEASED', 'FAILED');
            END IF;
        ELSIF l_internal IS NOT NULL THEN
            l_state := 'KEPT';
            l_orig := l_status;
            l_detail := 'on a ' || l_internal;
        ELSIF l_status = 'VALID' AND NVL(l_func, 'ENABLED') <> 'DISABLED' THEN
            l_state := 'PENDING';
            l_orig := 'VALID';
        ELSE
            l_state := 'KEPT';
            l_orig := l_status;
            l_detail := 'status ' || l_status || CASE WHEN l_func = 'DISABLED' THEN ', function-based index disabled' END
                        || ' before the reclaim: left as found';
        END IF;
        SELECT NVL(SUM(bytes), 0)
          INTO l_bytes
          FROM dba_segments
         WHERE owner = p_owner AND segment_name = p_index AND segment_type = 'INDEX';
        -- A released index has no segment: its size when it was released.
        IF l_state = 'RELEASED' THEN
            l_bytes := NVL(l_prev_bytes, 0);
        END IF;
        l_est := estimate(p_owner, p_index, 'INDEX', l_bytes);
        l_id := new_item('INDEX', p_owner, p_index, NULL, l_ts, l_towner, l_table, l_state, l_detail);
        UPDATE epfpg.epf_reclaim_object
           SET orig_status = l_orig, bytes = l_bytes, est_bytes = l_est
         WHERE run_id = g_run.run_id AND item_id = l_id;
        RETURN l_id;
    END index_item;

    -- Why table p_owner.p_table cannot move, NULL when it can. A table an
    -- Oracle feature maintains is named as such first (a queue table also
    -- has object-type columns).
    FUNCTION unit_blocker(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN VARCHAR2 IS
        l_count  NUMBER;
        l_reason VARCHAR2(400);
    BEGIN
        l_reason := internal_reason(p_owner, p_table);
        IF l_reason IS NOT NULL THEN
            RETURN l_reason;
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_tab_columns
         WHERE owner = p_owner AND table_name = p_table AND data_type IN ('LONG', 'LONG RAW');
        IF l_count > 0 THEN
            RETURN 'LONG column (a table with a LONG column cannot move; its conversion is not part of this version)';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_tab_columns
         WHERE owner = p_owner AND table_name = p_table AND data_type_owner IS NOT NULL;
        IF l_count > 0 THEN
            RETURN 'object-type column (not moved by this version)';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_object_tables WHERE owner = p_owner AND table_name = p_table;
        IF l_count > 0 THEN
            RETURN 'object table (not moved by this version)';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_tables
         WHERE owner = p_owner AND table_name = p_table
           AND (partitioned = 'YES' OR cluster_name IS NOT NULL OR dropped = 'YES' OR temporary = 'Y');
        IF l_count > 0 THEN
            RETURN 'partitioned, clustered, dropped or temporary table (not moved by this version)';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_tables
         WHERE owner = p_owner AND iot_name = p_table AND iot_type = 'IOT_MAPPING';
        IF l_count > 0 THEN
            RETURN 'index-organized table with a mapping table (not moved by this version)';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_indexes
         WHERE table_owner = p_owner AND table_name = p_table AND (index_type = 'DOMAIN' OR partitioned = 'YES');
        IF l_count > 0 THEN
            RETURN 'domain or partitioned index (not rebuilt by this version)';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_indexes
         WHERE table_owner = p_owner AND table_name = p_table AND funcidx_status = 'DISABLED';
        IF l_count > 0 THEN
            RETURN 'disabled function-based index (it could not be rebuilt after the move)';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_mviews WHERE owner = p_owner AND container_name = p_table;
        IF l_count > 0 THEN
            RETURN 'materialized view (not moved by this version)';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_mview_logs
         WHERE log_owner = p_owner AND master = p_table AND rowids = 'YES';
        IF l_count > 0 THEN
            RETURN 'materialized view log with rowids: a move changes the rowids it records';
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_flashback_archive_tables
         WHERE owner_name = p_owner AND table_name = p_table;
        IF l_count > 0 THEN
            RETURN 'tracked by a flashback archive (a move is not allowed)';
        END IF;
        RETURN NULL;
    END unit_blocker;

    -- The segments of a table that moves, as TYPE|NAME: the table (or the
    -- IOT's index segment), the IOT overflow, its LOB segments and LOB indexes.
    FUNCTION unit_segments(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN SYS.ODCIVARCHAR2LIST IS
        l_names SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST('TABLE|' || p_table);
    BEGIN
        FOR s IN (SELECT 'INDEX|' || index_name AS seg
                    FROM dba_indexes
                   WHERE owner = p_owner AND table_owner = p_owner AND table_name = p_table AND index_type = 'IOT - TOP'
                  UNION ALL
                  SELECT 'TABLE|' || table_name
                    FROM dba_tables
                   WHERE owner = p_owner AND iot_name = p_table AND iot_type = 'IOT_OVERFLOW'
                  UNION ALL
                  SELECT 'LOBSEGMENT|' || segment_name FROM dba_lobs WHERE owner = p_owner AND table_name = p_table
                  UNION ALL
                  SELECT 'LOBINDEX|' || index_name FROM dba_lobs WHERE owner = p_owner AND table_name = p_table) LOOP
            l_names.EXTEND;
            l_names(l_names.COUNT) := s.seg;
        END LOOP;
        RETURN l_names;
    END unit_segments;

    -- Replaces the inventory rows of unit p_item (its segments in the run's
    -- tablespaces) from DBA_EXTENTS. p_bytes returns its allocated bytes there.
    PROCEDURE refresh_item(p_item IN NUMBER, p_owner IN VARCHAR2, p_table IN VARCHAR2, p_bytes OUT NUMBER) IS
        l_names SYS.ODCIVARCHAR2LIST := unit_segments(p_owner, p_table);
    BEGIN
        DELETE FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND item_id = p_item;
        INSERT INTO epfpg.epf_ts_inventory (run_id, tablespace_name, kind, owner, object_name, sub_name, segment_type,
                                            bytes, file_id, top_block, handler, item_id, est_bytes)
        SELECT g_run.run_id, e.tablespace_name, 'SEGMENT', e.owner, e.segment_name, e.partition_name, e.segment_type,
               SUM(e.bytes), e.file_id, MAX(e.block_id + e.blocks - 1), 'MOVE', p_item, SUM(e.bytes)
          FROM dba_extents e
         WHERE e.owner = p_owner
           AND e.segment_type || '|' || e.segment_name IN (SELECT column_value FROM TABLE(l_names))
           AND e.tablespace_name IN (SELECT r.tablespace_name FROM epfpg.epf_reclaim_ts r WHERE r.run_id = g_run.run_id)
         GROUP BY e.tablespace_name, e.owner, e.segment_name, e.partition_name, e.segment_type, e.file_id;
        SELECT NVL(SUM(bytes), 0) INTO p_bytes FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND item_id = p_item;
        COMMIT;
    END refresh_item;

    -- Free space unit p_item needs in p_ts to move: the estimate of each of
    -- its segments there plus the extent it may need besides (extent_for).
    FUNCTION need(p_item IN NUMBER, p_ts IN VARCHAR2) RETURN NUMBER IS
        l_alloc   VARCHAR2(9);
        l_uniform NUMBER;
        l_need    NUMBER := 0;
    BEGIN
        SELECT allocation_type, initial_extent INTO l_alloc, l_uniform FROM dba_tablespaces WHERE tablespace_name = p_ts;
        FOR s IN (SELECT NVL(SUM(est_bytes), 0) AS est
                    FROM epfpg.epf_ts_inventory
                   WHERE run_id = g_run.run_id AND item_id = p_item AND tablespace_name = p_ts
                   GROUP BY owner, object_name, sub_name, segment_type) LOOP
            l_need := l_need + s.est + extent_for(s.est, l_alloc, l_uniform);
        END LOOP;
        RETURN l_need;
    END need;

    -- ------------------------------------------------------------------
    -- Assessment
    -- ------------------------------------------------------------------

    -- The run's tablespaces (EPF_RECLAIM_TS): p_list, or every candidate:
    -- online permanent tablespaces holding segments of the app_schemas,
    -- except SYSTEM, SYSAUX and the tool's tablespace. ORA-20161 for a
    -- requested tablespace that cannot be reclaimed.
    PROCEDURE resolve_targets(p_list IN VARCHAR2) IS
        l_tool     VARCHAR2(128);
        l_schemas  SYS.ODCIVARCHAR2LIST := epfpg.epf_util.split_list(epfpg.epf_util.setting('app_schemas'));
        l_names    SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        l_contents VARCHAR2(21);
        l_status   VARCHAR2(9);
        l_reason   VARCHAR2(200);
    BEGIN
        SELECT MAX(default_tablespace) INTO l_tool FROM dba_users WHERE username = 'EPFPG';
        IF TRIM(p_list) IS NULL THEN
            SELECT t.tablespace_name
              BULK COLLECT INTO l_names
              FROM dba_tablespaces t
             WHERE t.contents = 'PERMANENT' AND t.status = 'ONLINE'
               AND t.tablespace_name NOT IN ('SYSTEM', 'SYSAUX', NVL(l_tool, '-'))
               AND EXISTS (SELECT 1 FROM dba_segments s
                            WHERE s.tablespace_name = t.tablespace_name
                              AND s.owner IN (SELECT column_value FROM TABLE(l_schemas)))
             ORDER BY t.tablespace_name;
        ELSE
            l_names := epfpg.epf_util.split_list(p_list);
            FOR i IN 1 .. l_names.COUNT LOOP
                SELECT MAX(contents), MAX(status)
                  INTO l_contents, l_status
                  FROM dba_tablespaces
                 WHERE tablespace_name = l_names(i);
                l_reason := CASE WHEN l_contents IS NULL THEN 'it does not exist'
                                 WHEN l_names(i) IN ('SYSTEM', 'SYSAUX') THEN 'it holds the data dictionary'
                                 WHEN l_names(i) = l_tool THEN 'it holds the tool''s own tables'
                                 WHEN l_contents <> 'PERMANENT' THEN 'it is a ' || LOWER(l_contents) || ' tablespace'
                                 WHEN l_status <> 'ONLINE' THEN 'it is ' || LOWER(l_status) END;
                IF l_reason IS NOT NULL THEN
                    RAISE_APPLICATION_ERROR(-20161, 'Tablespace ' || l_names(i) || ' cannot be reclaimed: ' || l_reason
                                                    || '.');
                END IF;
            END LOOP;
        END IF;
        DELETE FROM epfpg.epf_reclaim_ts WHERE run_id = g_run.run_id;
        FOR i IN 1 .. l_names.COUNT LOOP
            INSERT INTO epfpg.epf_reclaim_ts (run_id, tablespace_name, bigfile, block_size, file_count, status,
                                              start_bytes, growth_bytes)
            SELECT g_run.run_id, t.tablespace_name, t.bigfile, t.block_size,
                   (SELECT COUNT(*) FROM dba_data_files d WHERE d.tablespace_name = t.tablespace_name), 'ASSESSED',
                   (SELECT NVL(SUM(d.bytes), 0) FROM dba_data_files d WHERE d.tablespace_name = t.tablespace_name),
                   g_growth
              FROM dba_tablespaces t
             WHERE t.tablespace_name = l_names(i);
        END LOOP;
        COMMIT;
    END resolve_targets;

    -- Reads the segments of p_ts from DBA_EXTENTS into EPF_TS_INVENTORY: one
    -- row per segment and datafile with its highest block; recycle-bin
    -- segments marked.
    PROCEDURE scan_ts(p_ts IN VARCHAR2) IS
    BEGIN
        DELETE FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND tablespace_name = p_ts;
        INSERT INTO epfpg.epf_ts_inventory (run_id, tablespace_name, kind, owner, object_name, sub_name, segment_type,
                                            bytes, file_id, top_block)
        SELECT g_run.run_id, p_ts, 'SEGMENT', e.owner, e.segment_name, e.partition_name, e.segment_type,
               SUM(e.bytes), e.file_id, MAX(e.block_id + e.blocks - 1)
          FROM dba_extents e
         WHERE e.tablespace_name = p_ts
         GROUP BY e.owner, e.segment_name, e.partition_name, e.segment_type, e.file_id;
        UPDATE epfpg.epf_ts_inventory i
           SET kind = 'RECYCLEBIN'
         WHERE i.run_id = g_run.run_id AND i.tablespace_name = p_ts
           AND EXISTS (SELECT 1 FROM dba_recyclebin r WHERE r.owner = i.owner AND r.object_name = i.object_name);
        COMMIT;
    END scan_ts;

    -- Classifies every segment of p_ts: MOVE with the unit of its table,
    -- RELEASE with the item of its index, or PIN with the reason; records
    -- the bytes it is expected to need after a move or rebuild (an IOT
    -- overflow segment at least its INITIAL: a move keeps it, whatever its
    -- STORAGE clause says).
    PROCEDURE classify_ts(p_ts IN VARCHAR2) IS
        l_handler VARCHAR2(10);
        l_item    NUMBER;
        l_reason  VARCHAR2(400);
        l_maint   VARCHAR2(1);
        l_table   VARCHAR2(128);
        l_towner  VARCHAR2(128);
        l_tables  NUMBER;
        l_iot     VARCHAR2(12);
        l_iotname VARCHAR2(128);
        l_itype   VARCHAR2(27);
        l_istatus VARCHAR2(20);
        l_idetail VARCHAR2(4000);
        l_est     NUMBER;
        l_ovfinit NUMBER;
    BEGIN
        FOR s IN (SELECT owner, object_name, sub_name, segment_type, MAX(kind) AS kind, SUM(bytes) AS seg_bytes
                    FROM epfpg.epf_ts_inventory
                   WHERE run_id = g_run.run_id AND tablespace_name = p_ts
                   GROUP BY owner, object_name, sub_name, segment_type
                   ORDER BY owner, object_name, sub_name) LOOP
            l_handler := 'PIN';
            l_item := NULL;
            l_reason := NULL;
            l_table := NULL;
            l_towner := s.owner;
            l_ovfinit := NULL;
            SELECT MAX(oracle_maintained) INTO l_maint FROM dba_users WHERE username = s.owner;
            IF s.kind = 'RECYCLEBIN' THEN
                l_reason := 'in the recycle bin (PURGE TABLESPACE ' || p_ts || ' removes it)';
            ELSIF s.owner IN ('SYS', 'SYSTEM') OR NVL(l_maint, 'N') = 'Y' THEN
                l_reason := 'owned by the Oracle-maintained account ' || s.owner;
            ELSIF s.segment_type = 'TABLE' THEN
                SELECT COUNT(*), MAX(iot_type), MAX(iot_name)
                  INTO l_tables, l_iot, l_iotname
                  FROM dba_tables
                 WHERE owner = s.owner AND table_name = s.object_name;
                IF l_tables = 0 THEN
                    l_reason := 'table not found in DBA_TABLES';
                ELSE
                    l_table := CASE WHEN l_iot IN ('IOT_OVERFLOW', 'IOT_MAPPING') THEN l_iotname ELSE s.object_name END;
                    IF l_iot = 'IOT_OVERFLOW' THEN
                        SELECT MAX(initial_extent) INTO l_ovfinit
                          FROM dba_segments
                         WHERE owner = s.owner AND segment_name = s.object_name AND segment_type = 'TABLE';
                    END IF;
                END IF;
            ELSIF s.segment_type = 'LOBSEGMENT' THEN
                SELECT MAX(table_name) INTO l_table FROM dba_lobs WHERE owner = s.owner AND segment_name = s.object_name;
                IF l_table IS NULL THEN
                    l_reason := 'LOB segment without its table in DBA_LOBS';
                END IF;
            ELSIF s.segment_type = 'LOBINDEX' THEN
                SELECT MAX(table_name) INTO l_table FROM dba_lobs WHERE owner = s.owner AND index_name = s.object_name;
                IF l_table IS NULL THEN
                    l_reason := 'LOB index without its table in DBA_LOBS';
                END IF;
            ELSIF s.segment_type = 'INDEX' THEN
                SELECT MAX(index_type), MAX(table_owner), MAX(table_name)
                  INTO l_itype, l_towner, l_table
                  FROM dba_indexes
                 WHERE owner = s.owner AND index_name = s.object_name;
                IF NVL(l_itype, '-') <> 'IOT - TOP' THEN
                    l_table := NULL;
                    l_item := index_item(s.owner, s.object_name);
                    SELECT MAX(move_status), MAX(detail)
                      INTO l_istatus, l_idetail
                      FROM epfpg.epf_reclaim_object
                     WHERE run_id = g_run.run_id AND item_id = l_item;
                    IF l_item IS NULL THEN
                        l_reason := 'index that is not rebuilt (' || NVL(l_itype, 'not found') || ')';
                    ELSIF l_istatus = 'KEPT' THEN
                        l_reason := 'index left as found: ' || l_idetail;
                    ELSE
                        l_handler := 'RELEASE';
                    END IF;
                END IF;
            ELSE
                l_reason := CASE WHEN s.segment_type LIKE '%PARTITION' THEN 'partitioned (not moved by this version)'
                                 WHEN s.segment_type = 'NESTED TABLE' THEN 'nested table (not moved by this version)'
                                 WHEN s.segment_type = 'CLUSTER' THEN 'cluster (not moved by this version)'
                                 WHEN s.segment_type = 'TEMPORARY' THEN 'temporary segment (Oracle removes it)'
                                 ELSE 'segment type ' || s.segment_type || ' is not moved' END;
            END IF;
            IF l_table IS NOT NULL THEN
                l_item := table_item(l_towner, l_table, p_ts);
                l_handler := 'MOVE';
            END IF;
            IF l_handler = 'PIN' THEN
                l_item := new_item('PIN', s.owner, s.object_name, s.sub_name, p_ts, NULL, NULL, 'PINNED',
                                   s.segment_type || ': ' || l_reason);
                l_est := s.seg_bytes;
            ELSE
                l_est := LEAST(GREATEST(estimate(s.owner, s.object_name, s.segment_type, s.seg_bytes),
                                        NVL(l_ovfinit, 0)), s.seg_bytes);
            END IF;
            UPDATE epfpg.epf_ts_inventory
               SET handler = l_handler, item_id = l_item, blocker_reason = SUBSTR(l_reason, 1, 400),
                   est_bytes = ROUND(bytes * l_est / GREATEST(s.seg_bytes, 1))
             WHERE run_id = g_run.run_id AND tablespace_name = p_ts AND owner = s.owner
               AND object_name = s.object_name AND NVL(sub_name, '-') = NVL(s.sub_name, '-')
               AND segment_type = s.segment_type;
        END LOOP;
        COMMIT;
    END classify_ts;

    -- A table that cannot move stays with all its segments: its unit becomes
    -- a PIN with the reason.
    PROCEDURE pin_units IS
        l_reason VARCHAR2(400);
    BEGIN
        FOR u IN (SELECT item_id, owner, object_name
                    FROM epfpg.epf_reclaim_object
                   WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT')
                   ORDER BY item_id) LOOP
            l_reason := unit_blocker(u.owner, u.object_name);
            IF l_reason IS NOT NULL THEN
                UPDATE epfpg.epf_reclaim_object
                   SET unit_type = 'PIN', move_status = 'PINNED', detail = SUBSTR(l_reason, 1, 4000)
                 WHERE run_id = g_run.run_id AND item_id = u.item_id;
                UPDATE epfpg.epf_ts_inventory
                   SET handler = 'PIN', blocker_reason = SUBSTR(l_reason, 1, 400), est_bytes = bytes
                 WHERE run_id = g_run.run_id AND item_id = u.item_id;
            END IF;
        END LOOP;
        COMMIT;
    END pin_units;

    -- Every index of a table that moves becomes unusable when the table
    -- moves: items for those stored outside the run's tablespaces too.
    PROCEDURE add_table_indexes IS
        l_item NUMBER;
    BEGIN
        FOR i IN (SELECT x.owner, x.index_name
                    FROM dba_indexes x
                    JOIN epfpg.epf_reclaim_object o
                      ON o.owner = x.table_owner AND o.object_name = x.table_name
                   WHERE o.run_id = g_run.run_id AND o.unit_type IN ('TABLE', 'IOT')
                     AND x.index_type NOT IN ('IOT - TOP', 'LOB')
                   ORDER BY x.owner, x.index_name) LOOP
            l_item := index_item(i.owner, i.index_name);
        END LOOP;
        COMMIT;
    END add_table_indexes;

    -- Indexes an earlier compaction released and left unusable, wherever
    -- they are: this run rebuilds them.
    PROCEDURE add_pending_indexes IS
        l_item NUMBER;
    BEGIN
        FOR p IN (SELECT DISTINCT o.owner, o.object_name
                    FROM epfpg.epf_reclaim_object o
                   WHERE o.unit_type = 'INDEX' AND o.run_id <> g_run.run_id AND o.move_status IN ('RELEASED', 'FAILED')
                     AND o.run_id IN (SELECT r.run_id FROM epfpg.epf_run r WHERE r.reclaim_mode IN ('COMPACT', 'RESTORE'))
                     AND EXISTS (SELECT 1 FROM dba_indexes i
                                  WHERE i.owner = o.owner AND i.index_name = o.object_name AND i.status = 'UNUSABLE')
                   ORDER BY o.owner, o.object_name) LOOP
            l_item := index_item(p.owner, p.object_name);
        END LOOP;
        COMMIT;
    END add_pending_indexes;

    -- Sizes and counts of p_ts (EPF_RECLAIM_TS) and of its units.
    PROCEDURE summarize_ts(p_ts IN VARCHAR2) IS
        l_bs    NUMBER;
        l_seg   NUMBER;
        l_hwm   NUMBER;
        l_units NUMBER;
        l_ub    NUMBER;
        l_ue    NUMBER;
        l_idx   NUMBER;
        l_ib    NUMBER;
        l_ie    NUMBER;
        l_pins  NUMBER;
        l_pb    NUMBER;
        l_ptop  NUMBER;
    BEGIN
        SELECT block_size INTO l_bs FROM dba_tablespaces WHERE tablespace_name = p_ts;
        SELECT NVL(SUM(bytes), 0) INTO l_seg
          FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND tablespace_name = p_ts;
        SELECT NVL(SUM(file_top), 0)
          INTO l_hwm
          FROM (SELECT (MAX(top_block) + 1) * l_bs AS file_top
                  FROM epfpg.epf_ts_inventory
                 WHERE run_id = g_run.run_id AND tablespace_name = p_ts
                 GROUP BY file_id);
        SELECT COUNT(DISTINCT item_id), NVL(SUM(bytes), 0), NVL(SUM(est_bytes), 0)
          INTO l_units, l_ub, l_ue
          FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND tablespace_name = p_ts AND handler = 'MOVE';
        -- Indexes released here, and those an earlier compaction left
        -- released (no segment) that this run rebuilds here.
        SELECT COUNT(DISTINCT item_id), NVL(SUM(bytes), 0), NVL(SUM(est_bytes), 0)
          INTO l_idx, l_ib, l_ie
          FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND tablespace_name = p_ts AND handler = 'RELEASE';
        FOR a IN (SELECT COUNT(*) AS cnt, NVL(SUM(bytes), 0) AS bytes, NVL(SUM(est_bytes), 0) AS est
                    FROM epfpg.epf_reclaim_object
                   WHERE run_id = g_run.run_id AND unit_type = 'INDEX' AND move_status = 'RELEASED'
                     AND source_ts = p_ts) LOOP
            l_idx := l_idx + a.cnt;
            l_ib := l_ib + a.bytes;
            l_ie := l_ie + a.est;
        END LOOP;
        SELECT COUNT(DISTINCT item_id), NVL(SUM(bytes), 0), NVL(MAX((top_block + 1) * l_bs), 0)
          INTO l_pins, l_pb, l_ptop
          FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND tablespace_name = p_ts AND handler = 'PIN';
        UPDATE epfpg.epf_reclaim_ts
           SET segment_bytes = l_seg, start_hwm_bytes = l_hwm,
               unit_count = l_units, unit_bytes = l_ub, unit_est_bytes = l_ue,
               index_count = l_idx, index_bytes = l_ib, index_est_bytes = l_ie,
               pin_count = l_pins, pin_bytes = l_pb, pin_top_bytes = l_ptop
         WHERE run_id = g_run.run_id AND tablespace_name = p_ts;
        -- Bytes and estimate of each item, over the run's tablespaces.
        UPDATE epfpg.epf_reclaim_object o
           SET (bytes, est_bytes) = (SELECT NVL(SUM(i.bytes), 0), NVL(SUM(i.est_bytes), 0)
                                       FROM epfpg.epf_ts_inventory i
                                      WHERE i.run_id = o.run_id AND i.item_id = o.item_id)
         WHERE o.run_id = g_run.run_id AND o.unit_type IN ('TABLE', 'IOT', 'PIN');
        COMMIT;
    END summarize_ts;

    -- Forecast of the compaction of p_ts (est_final_bytes, detail), as the
    -- compaction proceeds: the tables move from the highest block down, each
    -- needing its estimate (need) in the free space below the current highest
    -- block, released index space included. When the next one does not fit,
    -- the tables with the most free space inside them move first (room
    -- makers, as in compact_ts), then the room the file has given back since
    -- the start is used; a table that still does not fit stops the file
    -- there. The released indexes are rebuilt into the free space left
    -- below, and beyond. Positions are bytes with the datafiles of the
    -- tablespace taken end to end (exact for a single datafile, an estimate
    -- otherwise).
    PROCEDURE forecast_ts(p_ts IN VARCHAR2) IS
        TYPE t_num IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
        TYPE t_flag IS TABLE OF BOOLEAN INDEX BY PLS_INTEGER;
        l_top     t_num;
        l_alloc   t_num;
        l_est     t_num;
        l_need    t_num;
        l_ids     t_num;
        l_moved   t_flag;
        l_n       PLS_INTEGER := 0;
        l_bs      NUMBER;
        l_start   NUMBER;
        l_files   NUMBER;
        l_hwm     NUMBER;
        l_rest    NUMBER := 0;
        l_placed  NUMBER := 0;
        l_pins    NUMBER;
        l_pintop  NUMBER;
        l_idx     NUMBER;
        l_free    NUMBER;
        l_room    NUMBER;
        l_final   NUMBER;
        l_best    PLS_INTEGER;
        l_gain    NUMBER;
        l_next    NUMBER;
        l_makers  PLS_INTEGER := 0;
        l_stuck   VARCHAR2(1000);
        l_owner   VARCHAR2(128);
        l_name    VARCHAR2(128);

        PROCEDURE place(p_k IN PLS_INTEGER) IS
        BEGIN
            l_moved(p_k) := TRUE;
            l_rest := l_rest - l_alloc(p_k);
            l_placed := l_placed + l_est(p_k);
        END place;
    BEGIN
        SELECT t.block_size, r.start_bytes, r.file_count, NVL(r.pin_bytes, 0), NVL(r.index_est_bytes, 0)
          INTO l_bs, l_start, l_files, l_pins, l_idx
          FROM epfpg.epf_reclaim_ts r
          JOIN dba_tablespaces t ON t.tablespace_name = r.tablespace_name
         WHERE r.run_id = g_run.run_id AND r.tablespace_name = p_ts;
        SELECT NVL(MAX(CASE WHEN i.handler IN ('MOVE', 'PIN') THEN f.file_offset + (i.top_block + 1) * l_bs END), 0),
               NVL(MAX(CASE WHEN i.handler = 'PIN' THEN f.file_offset + (i.top_block + 1) * l_bs END), 0)
          INTO l_hwm, l_pintop
          FROM epfpg.epf_ts_inventory i
          JOIN (SELECT file_id,
                       NVL(SUM(bytes) OVER (ORDER BY file_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)
                           AS file_offset
                  FROM dba_data_files
                 WHERE tablespace_name = p_ts) f
            ON f.file_id = i.file_id
         WHERE i.run_id = g_run.run_id AND i.tablespace_name = p_ts;
        FOR u IN (SELECT i.item_id, MAX(f.file_offset + (i.top_block + 1) * l_bs) AS top_bytes,
                         SUM(i.bytes) AS alloc_bytes, SUM(i.est_bytes) AS est_bytes
                    FROM epfpg.epf_ts_inventory i
                    JOIN (SELECT file_id,
                                 NVL(SUM(bytes) OVER (ORDER BY file_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
                                     0) AS file_offset
                            FROM dba_data_files
                           WHERE tablespace_name = p_ts) f
                      ON f.file_id = i.file_id
                   WHERE i.run_id = g_run.run_id AND i.tablespace_name = p_ts AND i.handler = 'MOVE'
                   GROUP BY i.item_id
                   ORDER BY 2 DESC, 1) LOOP
            l_n := l_n + 1;
            l_ids(l_n) := u.item_id;
            l_top(l_n) := u.top_bytes;
            l_alloc(l_n) := u.alloc_bytes;
            l_est(l_n) := u.est_bytes;
            l_need(l_n) := need(u.item_id, p_ts);
            l_moved(l_n) := FALSE;
            l_rest := l_rest + u.alloc_bytes;
        END LOOP;
        FOR k IN 1 .. l_n LOOP
            CONTINUE WHEN l_moved(k);
            EXIT WHEN l_top(k) <= l_pintop;
            l_free := GREATEST(l_hwm - (l_rest + l_placed + l_pins), 0);
            -- Room makers: the unit not moved yet that frees the most and fits.
            WHILE l_need(k) > l_free LOOP
                l_best := 0;
                l_gain := 0;
                FOR j IN 1 .. l_n LOOP
                    IF j <> k AND NOT l_moved(j) AND l_need(j) <= l_free
                       AND l_alloc(j) - l_est(j) >= GREATEST(c_mb, 0.1 * l_alloc(j))
                       AND l_alloc(j) - l_est(j) > l_gain THEN
                        l_best := j;
                        l_gain := l_alloc(j) - l_est(j);
                    END IF;
                END LOOP;
                EXIT WHEN l_best = 0;
                place(l_best);
                l_makers := l_makers + 1;
                l_free := GREATEST(l_hwm - (l_rest + l_placed + l_pins), 0);
            END LOOP;
            l_room := GREATEST(l_start + g_growth * l_files - l_hwm, 0);
            IF l_need(k) > l_free + l_room THEN
                SELECT owner, object_name INTO l_owner, l_name
                  FROM epfpg.epf_reclaim_object
                 WHERE run_id = g_run.run_id AND item_id = l_ids(k);
                l_stuck := l_owner || '.' || l_name || ' (about ' || b(l_est(k)) || ' after the move) may not fit in the '
                           || b(l_free + l_room) || ' of free space below the top when its turn comes';
                EXIT;
            END IF;
            place(k);
            l_next := 0;
            FOR j IN k + 1 .. l_n LOOP
                IF NOT l_moved(j) THEN
                    l_next := l_top(j);
                    EXIT;
                END IF;
            END LOOP;
            l_hwm := GREATEST(l_next, l_pintop, l_rest + l_placed + l_pins);
        END LOOP;
        l_free := GREATEST(l_hwm - (l_rest + l_placed + l_pins), 0);
        l_final := LEAST(l_start, l_hwm + GREATEST(l_idx - l_free, 0) + g_margin * l_files);
        UPDATE epfpg.epf_reclaim_ts
           SET est_final_bytes = l_final,
               detail = SUBSTR(l_stuck || CASE WHEN l_makers > 0
                                               THEN CASE WHEN l_stuck IS NOT NULL THEN '; ' END || l_makers
                                                    || ' tables with free space inside them move first to make room'
                                          END, 1, 4000)
         WHERE run_id = g_run.run_id AND tablespace_name = p_ts;
        COMMIT;
    END forecast_ts;

    -- Events of the assessment of p_ts: the summary and the highest pins.
    PROCEDURE report_ts(p_ts IN VARCHAR2) IS
        r       epfpg.epf_reclaim_ts%ROWTYPE;
        l_bs    NUMBER;
        l_shown PLS_INTEGER := 0;
    BEGIN
        SELECT * INTO r FROM epfpg.epf_reclaim_ts WHERE run_id = g_run.run_id AND tablespace_name = p_ts;
        SELECT block_size INTO l_bs FROM dba_tablespaces WHERE tablespace_name = p_ts;
        say(epfpg.epf_log.c_info, 'TS_ASSESSED',
            p_ts || ': ' || b(r.start_bytes) || ' in ' || r.file_count || ' datafile(s), highest block at '
            || b(r.start_hwm_bytes) || ', segments ' || b(r.segment_bytes) || '; ' || r.unit_count || ' tables move ('
            || b(r.unit_bytes) || ', about ' || b(r.unit_est_bytes) || ' after), ' || r.index_count
            || ' indexes released and rebuilt (' || b(r.index_bytes) || '), ' || r.pin_count || ' segments stay ('
            || b(r.pin_bytes) || '); forecast ' || b(r.est_final_bytes)
            || CASE WHEN r.detail IS NOT NULL THEN '; ' || r.detail END,
            p_bytes => r.est_final_bytes);
        FOR p IN (SELECT owner, object_name, sub_name, segment_type, file_id, MAX(top_block) AS top_block,
                         SUM(bytes) AS seg_bytes, MAX(blocker_reason) AS reason
                    FROM epfpg.epf_ts_inventory
                   WHERE run_id = g_run.run_id AND tablespace_name = p_ts AND handler = 'PIN'
                   GROUP BY owner, object_name, sub_name, segment_type, file_id
                   ORDER BY top_block DESC, owner, object_name) LOOP
            l_shown := l_shown + 1;
            EXIT WHEN l_shown > 20;
            say(epfpg.epf_log.c_info, 'PIN',
                p.owner || '.' || p.object_name || CASE WHEN p.sub_name IS NOT NULL THEN ' (' || p.sub_name || ')' END
                || ' ' || p.segment_type || ', ' || b(p.seg_bytes) || ', up to ' || b((p.top_block + 1) * l_bs)
                || ' in file ' || p.file_id || ': ' || p.reason,
                p_owner => p.owner, p_object => p.object_name);
        END LOOP;
    END report_ts;

    -- The segments that move or are rebuilt with an INITIAL larger than they
    -- need (oversized, as initial_clause decides): an event for each of the
    -- 50 largest (INITIAL_SEGMENT), then one with their count and the five
    -- largest (INITIAL_OVERSIZED); their move or rebuild sets INITIAL 64 KB.
    -- Typically the size of the segment when it was exported. An IOT
    -- overflow segment is left out: a move keeps its INITIAL.
    PROCEDURE report_initial IS
        l_count PLS_INTEGER := 0;
        l_total NUMBER := 0;
        l_need  NUMBER;
        l_list  VARCHAR2(2000);
    BEGIN
        FOR s IN (SELECT i.owner, i.object_name, i.segment_type, MAX(g.initial_extent) AS initial_bytes,
                         SUM(i.est_bytes) AS est
                    FROM (SELECT /*+ NO_MERGE */ d.owner, d.segment_name, d.segment_type, d.tablespace_name,
                                 d.initial_extent
                            FROM dba_segments d
                           WHERE d.tablespace_name IN (SELECT r.tablespace_name FROM epfpg.epf_reclaim_ts r
                                                        WHERE r.run_id = g_run.run_id)
                             AND d.initial_extent > c_mb AND d.partition_name IS NULL
                             AND d.segment_type IN ('TABLE', 'INDEX', 'LOBSEGMENT')) g
                    JOIN epfpg.epf_ts_inventory i
                      ON i.owner = g.owner AND i.object_name = g.segment_name AND i.segment_type = g.segment_type
                     AND i.tablespace_name = g.tablespace_name
                   WHERE i.run_id = g_run.run_id AND i.handler IN ('MOVE', 'RELEASE') AND i.sub_name IS NULL
                     AND NOT EXISTS (SELECT 1 FROM dba_tables t
                                      WHERE t.owner = i.owner AND t.table_name = i.object_name
                                        AND t.iot_type = 'IOT_OVERFLOW')
                   GROUP BY i.owner, i.object_name, i.segment_type
                   ORDER BY 4 DESC, 1, 2) LOOP
            l_need := initial_need(s.owner, s.object_name, s.segment_type, s.est);
            IF oversized(s.initial_bytes, l_need) THEN
                l_count := l_count + 1;
                l_total := l_total + s.initial_bytes;
                IF l_count <= 50 THEN
                    say(epfpg.epf_log.c_info, 'INITIAL_SEGMENT',
                        s.owner || '.' || s.object_name || ' (' || LOWER(s.segment_type) || '): INITIAL '
                        || b(s.initial_bytes) || ', about ' || b(l_need) || ' needed',
                        p_owner => s.owner, p_object => s.object_name, p_bytes => s.initial_bytes);
                END IF;
                IF l_count <= 5 THEN
                    l_list := l_list || CASE WHEN l_count > 1 THEN ', ' END || s.owner || '.' || s.object_name || ' ('
                              || LOWER(s.segment_type) || ') INITIAL ' || b(s.initial_bytes) || ', about ' || b(l_need)
                              || ' needed';
                END IF;
            END IF;
        END LOOP;
        IF l_count > 0 THEN
            say(epfpg.epf_log.c_info, 'INITIAL_OVERSIZED',
                l_count || ' segments that move or are rebuilt have an INITIAL larger than they need (' || b(l_total)
                || ' in all): ' || l_list || CASE WHEN l_count > 5 THEN ' and ' || (l_count - 5) || ' more' END
                || '; their move or rebuild sets INITIAL 64 KB');
        END IF;
    END report_initial;

    -- Sessions of account p_user, listed as events.
    PROCEDURE list_sessions(p_user IN VARCHAR2) IS
    BEGIN
        FOR s IN (SELECT s.sid, s.serial#, s.osuser, s.machine, s.program, s.status,
                         TO_CHAR(s.logon_time, 'YYYY-MM-DD HH24:MI') AS logon,
                         (SELECT COUNT(*) FROM v$transaction t WHERE t.ses_addr = s.saddr) AS tx
                    FROM v$session s
                   WHERE s.username = p_user AND s.type = 'USER'
                   ORDER BY s.logon_time) LOOP
            say(epfpg.epf_log.c_info, 'SESSION_FOUND',
                p_user || ' session ' || s.sid || ',' || s.serial# || ' ' || s.status || ', ' || s.osuser || '@'
                || s.machine || ' ' || s.program || ', since ' || s.logon
                || CASE WHEN s.tx > 0 THEN ', open transaction' END);
        END LOOP;
    END list_sessions;

    -- Accounts the compaction locks (D15), recorded as planned rows of
    -- EPF_ACCOUNT_ACTION (locked_at NULL) with the reasons. The tables in
    -- scope are those that move and those whose indexes are released (DML
    -- on them fails or leaves an index behind while they are unusable).
    -- Accounts: their owners; accounts with INSERT, UPDATE or DELETE on them,
    -- directly or through roles; owners of tables with a foreign key to them
    -- (checking the key reads the parent's index); accounts with a session
    -- holding a lock on them. Never SYS, SYSTEM, the tool's account, the
    -- current account or an Oracle-maintained account. Their sessions are
    -- listed.
    PROCEDURE plan_accounts IS
        TYPE t_reason IS TABLE OF VARCHAR2(400) INDEX BY VARCHAR2(128);
        l_reason t_reason;
        l_user   VARCHAR2(128);
        l_status VARCHAR2(32);
        l_maint  VARCHAR2(1);
        l_public NUMBER;
        l_names  VARCHAR2(4000);
        l_shown  PLS_INTEGER;

        PROCEDURE add_reason(p_user IN VARCHAR2, p_why IN VARCHAR2) IS
        BEGIN
            IF NOT l_reason.EXISTS(p_user) THEN
                l_reason(p_user) := p_why;
            ELSIF INSTR(l_reason(p_user), p_why) = 0 THEN
                l_reason(p_user) := l_reason(p_user) || ', ' || p_why;
            END IF;
        END add_reason;
    BEGIN
        FOR r IN (SELECT DISTINCT table_owner AS username
                    FROM epfpg.epf_reclaim_object
                   WHERE run_id = g_run.run_id
                     AND (unit_type IN ('TABLE', 'IOT') OR (unit_type = 'INDEX' AND move_status IN ('PENDING', 'RELEASED')))) LOOP
            add_reason(r.username, 'owner');
        END LOOP;
        FOR r IN (SELECT DISTINCT p.grantee
                    FROM dba_tab_privs p
                    JOIN epfpg.epf_reclaim_object o ON o.table_owner = p.owner AND o.table_name = p.table_name
                   WHERE o.run_id = g_run.run_id
                     AND (o.unit_type IN ('TABLE', 'IOT') OR (o.unit_type = 'INDEX' AND o.move_status IN ('PENDING', 'RELEASED')))
                     AND p.privilege IN ('INSERT', 'UPDATE', 'DELETE')
                     AND p.grantee IN (SELECT u.username FROM dba_users u)) LOOP
            add_reason(r.grantee, 'DML grant');
        END LOOP;
        FOR r IN (SELECT DISTINCT rp.grantee
                    FROM dba_role_privs rp
                   WHERE rp.grantee IN (SELECT u.username FROM dba_users u)
                   START WITH rp.granted_role IN (SELECT p.grantee
                                                    FROM dba_tab_privs p
                                                    JOIN epfpg.epf_reclaim_object o
                                                      ON o.table_owner = p.owner AND o.table_name = p.table_name
                                                   WHERE o.run_id = g_run.run_id
                                                     AND (o.unit_type IN ('TABLE', 'IOT')
                                                          OR (o.unit_type = 'INDEX'
                                                              AND o.move_status IN ('PENDING', 'RELEASED')))
                                                     AND p.privilege IN ('INSERT', 'UPDATE', 'DELETE')
                                                     AND p.grantee IN (SELECT x.role FROM dba_roles x))
                 CONNECT BY NOCYCLE PRIOR rp.grantee = rp.granted_role) LOOP
            add_reason(r.grantee, 'DML grant through a role');
        END LOOP;
        FOR r IN (SELECT DISTINCT c.owner
                    FROM dba_constraints c
                    JOIN dba_constraints p ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
                    JOIN epfpg.epf_reclaim_object o ON o.table_owner = p.owner AND o.table_name = p.table_name
                   WHERE c.constraint_type = 'R' AND o.run_id = g_run.run_id
                     AND (o.unit_type IN ('TABLE', 'IOT') OR (o.unit_type = 'INDEX' AND o.move_status IN ('PENDING', 'RELEASED')))) LOOP
            add_reason(r.owner, 'foreign key to a table in scope');
        END LOOP;
        FOR r IN (SELECT DISTINCT s.username
                    FROM v$locked_object lo
                    JOIN dba_objects ob ON ob.object_id = lo.object_id
                    JOIN epfpg.epf_reclaim_object o ON o.table_owner = ob.owner AND o.table_name = ob.object_name
                    JOIN v$session s ON s.sid = lo.session_id
                   WHERE o.run_id = g_run.run_id AND s.username IS NOT NULL
                     AND (o.unit_type IN ('TABLE', 'IOT') OR (o.unit_type = 'INDEX' AND o.move_status IN ('PENDING', 'RELEASED')))) LOOP
            add_reason(r.username, 'session with a lock');
        END LOOP;
        SELECT COUNT(*)
          INTO l_public
          FROM dba_tab_privs p
         WHERE p.grantee = 'PUBLIC' AND p.privilege IN ('INSERT', 'UPDATE', 'DELETE')
           AND (p.owner, p.table_name) IN (SELECT o.table_owner, o.table_name
                                             FROM epfpg.epf_reclaim_object o
                                            WHERE o.run_id = g_run.run_id
                                              AND (o.unit_type IN ('TABLE', 'IOT')
                                                   OR (o.unit_type = 'INDEX' AND o.move_status IN ('PENDING', 'RELEASED'))));
        IF l_public > 0 THEN
            l_names := NULL;
            l_shown := 0;
            FOR t IN (SELECT p.owner || '.' || p.table_name AS name, COUNT(*) AS grants
                        FROM dba_tab_privs p
                       WHERE p.grantee = 'PUBLIC' AND p.privilege IN ('INSERT', 'UPDATE', 'DELETE')
                         AND (p.owner, p.table_name) IN (SELECT o.table_owner, o.table_name
                                                           FROM epfpg.epf_reclaim_object o
                                                          WHERE o.run_id = g_run.run_id
                                                            AND (o.unit_type IN ('TABLE', 'IOT')
                                                                 OR (o.unit_type = 'INDEX'
                                                                     AND o.move_status IN ('PENDING', 'RELEASED'))))
                       GROUP BY p.owner, p.table_name
                       ORDER BY 1) LOOP
                l_shown := l_shown + 1;
                IF l_shown <= 10 THEN
                    l_names := l_names || CASE WHEN l_shown > 1 THEN ', ' END || t.name;
                END IF;
            END LOOP;
            say(epfpg.epf_log.c_warn, 'PUBLIC_DML', l_public || ' INSERT, UPDATE or DELETE grants to PUBLIC on ' || l_shown
                                                    || ' tables in scope (' || l_names
                                                    || CASE WHEN l_shown > 10 THEN ' and ' || (l_shown - 10) || ' more' END
                                                    || '): every account can write them; only the accounts listed are '
                                                    || 'locked');
        END IF;

        DELETE FROM epfpg.epf_account_action WHERE run_id = g_run.run_id AND locked_at IS NULL;
        l_user := l_reason.FIRST;
        WHILE l_user IS NOT NULL LOOP
            SELECT MAX(account_status), MAX(oracle_maintained)
              INTO l_status, l_maint
              FROM dba_users
             WHERE username = l_user;
            IF l_status IS NOT NULL AND NVL(l_maint, 'N') = 'N'
               AND l_user NOT IN ('SYS', 'SYSTEM', 'EPFPG', SYS_CONTEXT('USERENV', 'SESSION_USER')) THEN
                INSERT INTO epfpg.epf_account_action (run_id, username, original_status, sessions_disconnected, detail)
                VALUES (g_run.run_id, l_user, l_status, 0, SUBSTR(l_reason(l_user), 1, 4000));
                say(epfpg.epf_log.c_info, 'ACCOUNT_IN_SCOPE', l_user || ' (' || l_status || '): ' || l_reason(l_user));
                list_sessions(l_user);
            END IF;
            l_user := l_reason.NEXT(l_user);
        END LOOP;
        COMMIT;
    END plan_accounts;

    PROCEDURE add_req(p_code IN VARCHAR2, p_seq IN NUMBER, p_status IN VARCHAR2, p_blocking IN VARCHAR2,
                      p_title IN VARCHAR2, p_why IN VARCHAR2, p_measured IN VARCHAR2,
                      p_needed IN NUMBER, p_room IN NUMBER, p_met_by IN VARCHAR2) IS
    BEGIN
        INSERT INTO epfpg.epf_requirement (run_id, req_code, seq, status, blocking, title, why, measured,
                                           needed_bytes, room_bytes, met_by)
        VALUES (g_run.run_id, p_code, p_seq, p_status, p_blocking, p_title, SUBSTR(p_why, 1, 1000),
                SUBSTR(p_measured, 1, 2000), p_needed, p_room, p_met_by);
    END add_req;

    PROCEDURE add_opt(p_code IN VARCHAR2, p_option IN VARCHAR2, p_seq IN NUMBER, p_met IN BOOLEAN,
                      p_title IN VARCHAR2, p_detail IN VARCHAR2) IS
        l_met VARCHAR2(1) := CASE WHEN p_met THEN 'Y' ELSE 'N' END;
    BEGIN
        INSERT INTO epfpg.epf_req_option (run_id, req_code, option_code, seq, met, title, detail)
        VALUES (g_run.run_id, p_code, p_option, p_seq, l_met, p_title, SUBSTR(p_detail, 1, 2000));
    END add_opt;

    -- Requirements of the compaction (EPF_REQUIREMENT, EPF_REQ_OPTION):
    --   RECYCLEBIN  no recycle-bin object in the run's tablespaces (blocking:
    --               while the datafiles cannot grow, Oracle purges them to
    --               make room)
    --   ARCHIVE     in ARCHIVELOG mode, room in the archive destinations for
    --               the redo of the moves and rebuilds (blocking)
    --   TEMP        room in the temporary tablespace for the largest index
    --               rebuild (blocking)
    --   BACKUP      a recent RMAN database backup (advice)
    --   QUOTA       every owner of a table that moves or an index that is
    --               rebuilt can be given space where they are (blocking, not
    --               confirmable: an index that cannot be rebuilt stays
    --               unusable)
    -- A blocking requirement the operator confirms counts as met (CONFIRMED).
    PROCEDURE check_requirements IS
        l_count   NUMBER;
        l_bytes   NUMBER;
        l_met     BOOLEAN;
        l_log     VARCHAR2(12);
        l_redo    NUMBER;
        l_need    NUMBER;
        l_room    NUMBER;
        l_where   VARCHAR2(2000);
        l_temp    VARCHAR2(128);
        l_free    NUMBER;
        l_grow    NUMBER;
        l_largest NUMBER;
        l_name    VARCHAR2(300);
        l_last    DATE;
        l_hours   NUMBER := NVL(epfpg.epf_util.setting_num('backup_max_age_h'), 24);
        l_margin  NUMBER := NVL(epfpg.epf_util.setting_num('archive_margin_pct'), 20);
        l_pairs   PLS_INTEGER := 0;
        l_limited PLS_INTEGER := 0;
        l_short   PLS_INTEGER := 0;
        l_shown   PLS_INTEGER := 0;
        l_text    VARCHAR2(2000);
        l_qmax    NUMBER;
        l_qused   NUMBER;
        l_qrows   NUMBER;
        l_unlim   NUMBER;
        l_issue   VARCHAR2(1000);
    BEGIN
        DELETE FROM epfpg.epf_req_option WHERE run_id = g_run.run_id;
        DELETE FROM epfpg.epf_requirement WHERE run_id = g_run.run_id;

        -- Read from DBA_RECYCLEBIN: DBA_EXTENTS does not list the segments of
        -- recycle-bin objects (DBA_FREE_SPACE counts them as free).
        SELECT COUNT(*), NVL(SUM(r.space * t.block_size), 0)
          INTO l_count, l_bytes
          FROM dba_recyclebin r
          JOIN dba_tablespaces t ON t.tablespace_name = r.ts_name
         WHERE r.ts_name IN (SELECT x.tablespace_name FROM epfpg.epf_reclaim_ts x WHERE x.run_id = g_run.run_id);
        l_met := l_count = 0 OR confirmed('RECYCLEBIN');
        add_req('RECYCLEBIN', 1, CASE WHEN l_met THEN 'MET' ELSE 'NOT_MET' END, 'Y',
                'No recycle-bin object in the tablespaces',
                'While the datafiles cannot grow, Oracle makes room for the moves by purging recycle-bin objects of '
                || 'the tablespace; they could then no longer be restored with FLASHBACK TABLE ... TO BEFORE DROP.',
                CASE WHEN l_count = 0 THEN 'none'
                     ELSE l_count || ' recycle-bin objects, ' || b(l_bytes) END,
                NULL, NULL, CASE WHEN l_count = 0 THEN 'NONE' WHEN l_met THEN 'CONFIRMED' END);
        add_opt('RECYCLEBIN', 'PURGE', 1, l_count = 0, 'The DBA purges them first',
                'PURGE TABLESPACE <name>, or PURGE TABLE for each object');
        add_opt('RECYCLEBIN', 'CONFIRMED', 2, l_count > 0 AND confirmed('RECYCLEBIN'), 'Confirm they may be purged',
                '--confirm RECYCLEBIN: the compaction purges them (PURGE TABLESPACE) before the datafiles stop growing');

        SELECT log_mode INTO l_log FROM v$database;
        SELECT NVL(SUM(est_bytes), 0)
          INTO l_redo
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id
           AND (unit_type IN ('TABLE', 'IOT') OR (unit_type = 'INDEX' AND move_status IN ('PENDING', 'RELEASED')));
        IF l_log = 'NOARCHIVELOG' THEN
            add_req('ARCHIVE', 2, 'NOT_APPLICABLE', 'Y', 'Archived logs fit',
                    'Every block a move or a rebuild writes goes to the redo log.',
                    'NOARCHIVELOG: no archived logs are written', NULL, NULL, 'NOARCHIVELOG');
        ELSE
            l_need := CEIL(l_redo * (1 + l_margin / 100));
            epfpg.epf_purge.archive_room(l_room, l_where);
            l_met := (l_room IS NOT NULL AND l_room >= l_need) OR confirmed('ARCHIVE');
            add_req('ARCHIVE', 2, CASE WHEN l_met THEN 'MET' ELSE 'NOT_MET' END, 'Y', 'Archived logs fit',
                    'Every block a move or a rebuild writes goes to the redo log; archived logs stay until they are '
                    || 'backed up, and a full archive destination stops the database (ORA-00257).',
                    'needs ' || b(l_need) || ' (redo estimate ' || b(l_redo) || ' + ' || l_margin || '%); ' || l_where,
                    l_need, l_room,
                    CASE WHEN l_room >= l_need THEN 'ROOM' WHEN l_met THEN 'CONFIRMED' END);
            add_opt('ARCHIVE', 'ROOM', 1, l_room >= l_need, 'Room in the archive destination',
                    'free space for ' || b(l_need) || ' of archived logs (back them up and delete them first)');
            add_opt('ARCHIVE', 'CONFIRMED', 2, (l_room IS NULL OR l_room < l_need) AND confirmed('ARCHIVE'),
                    'The DBA confirms the room', '--confirm ARCHIVE');
        END IF;

        SELECT MAX(est_bytes) KEEP (DENSE_RANK LAST ORDER BY est_bytes NULLS FIRST),
               MAX(owner || '.' || object_name) KEEP (DENSE_RANK LAST ORDER BY est_bytes NULLS FIRST)
          INTO l_largest, l_name
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id AND unit_type = 'INDEX' AND move_status IN ('PENDING', 'RELEASED');
        IF l_largest IS NULL THEN
            add_req('TEMP', 3, 'NOT_APPLICABLE', 'Y', 'Room in TEMP for the index rebuilds',
                    'An index rebuild sorts its keys in the temporary tablespace.', 'no index to rebuild',
                    NULL, NULL, NULL);
        ELSE
            SELECT MAX(temporary_tablespace) INTO l_temp FROM dba_users WHERE username = SYS_CONTEXT('USERENV', 'SESSION_USER');
            SELECT NVL(SUM(free_space), 0) INTO l_free FROM dba_temp_free_space WHERE tablespace_name = l_temp;
            SELECT NVL(SUM(CASE WHEN autoextensible = 'YES' THEN GREATEST(maxbytes - bytes, 0) ELSE 0 END), 0)
              INTO l_grow
              FROM dba_temp_files
             WHERE tablespace_name = l_temp;
            l_need := CEIL(l_largest * 1.5);
            l_room := l_free + l_grow;
            l_met := l_room >= l_need OR confirmed('TEMP');
            add_req('TEMP', 3, CASE WHEN l_met THEN 'MET' ELSE 'NOT_MET' END, 'Y', 'Room in TEMP for the index rebuilds',
                    'An index rebuild sorts its keys in the temporary tablespace; without room it fails and the index '
                    || 'stays unusable until a later run rebuilds it.',
                    'largest rebuild ' || l_name || ' (' || b(l_largest) || '): needs about ' || b(l_need) || '; '
                    || l_temp || ' has ' || b(l_free) || ' free and can grow by ' || b(l_grow),
                    l_need, l_room, CASE WHEN l_room >= l_need THEN 'ROOM' WHEN l_met THEN 'CONFIRMED' END);
            add_opt('TEMP', 'ROOM', 1, l_room >= l_need, 'Room in the temporary tablespace',
                    'add a tempfile or let one grow');
            add_opt('TEMP', 'CONFIRMED', 2, l_room < l_need AND confirmed('TEMP'), 'The DBA confirms the room',
                    '--confirm TEMP');
        END IF;

        SELECT MAX(end_time)
          INTO l_last
          FROM v$rman_backup_job_details
         WHERE status IN ('COMPLETED', 'COMPLETED WITH WARNINGS') AND input_type IN ('DB FULL', 'DB INCR');
        l_met := l_last IS NOT NULL AND l_last >= SYSDATE - l_hours / 24;
        add_req('BACKUP', 4, CASE WHEN l_met THEN 'MET' ELSE 'NOT_MET' END, 'N', 'Recent backup',
                'The reclaim changes no data, but it rewrites most of the tablespace; a backup from before is the way '
                || 'back from a media failure meanwhile.'
                || CASE WHEN l_log = 'NOARCHIVELOG' THEN ' In NOARCHIVELOG mode only a backup restores the database.' END,
                CASE WHEN l_last IS NULL THEN 'no RMAN database backup recorded'
                     ELSE 'latest RMAN database backup ' || TO_CHAR(l_last, 'YYYY-MM-DD HH24:MI') END,
                NULL, NULL, CASE WHEN l_met THEN 'RMAN' END);
        add_opt('BACKUP', 'RMAN', 1, l_met, 'A recent database backup',
                'an RMAN backup within ' || l_hours || ' hours, or a backup made another way');

        -- A move or a rebuild writes the segment again in the space quota of
        -- its owner, also when SYS runs it. Per owner and tablespace: the
        -- largest move (its estimate there) and the index space released
        -- before the moves. An owner without a quota there, or above it, can
        -- be given no space; one with a limited quota keeps the tables larger
        -- than its room where they are.
        FOR x IN (SELECT owner, ts, MAX(move_need) AS move_need, SUM(freed) AS freed
                    FROM (SELECT i.owner, i.tablespace_name AS ts, SUM(i.est_bytes) AS move_need, 0 AS freed
                            FROM epfpg.epf_ts_inventory i
                           WHERE i.run_id = g_run.run_id AND i.handler = 'MOVE'
                           GROUP BY i.owner, i.tablespace_name, i.item_id
                          UNION ALL
                          SELECT o.owner, o.source_ts, 0, NVL(o.bytes, 0)
                            FROM epfpg.epf_reclaim_object o
                           WHERE o.run_id = g_run.run_id AND o.unit_type = 'INDEX'
                             AND o.move_status IN ('PENDING', 'RELEASED') AND o.source_ts IS NOT NULL)
                   GROUP BY owner, ts
                   ORDER BY owner, ts) LOOP
            l_pairs := l_pairs + 1;
            l_issue := NULL;
            SELECT COUNT(*) INTO l_unlim
              FROM dba_sys_privs
             WHERE grantee = x.owner AND privilege = 'UNLIMITED TABLESPACE';
            IF l_unlim = 0 THEN
                SELECT MAX(max_bytes), MAX(bytes), COUNT(*)
                  INTO l_qmax, l_qused, l_qrows
                  FROM dba_ts_quotas
                 WHERE username = x.owner AND tablespace_name = x.ts;
                IF l_qrows = 0 THEN
                    l_short := l_short + 1;
                    l_issue := x.owner || ' has no quota on ' || x.ts;
                ELSIF l_qmax = -1 THEN
                    NULL;
                ELSIF l_qused > l_qmax THEN
                    l_short := l_short + 1;
                    l_issue := x.owner || ' uses ' || b(l_qused) || ' of ' || x.ts || ', above its quota of ' || b(l_qmax);
                ELSE
                    l_limited := l_limited + 1;
                    l_issue := x.owner || ' on ' || x.ts || ': quota ' || b(l_qmax) || ', ' || b(l_qused) || ' used'
                               || CASE WHEN x.move_need > l_qmax - l_qused + x.freed
                                       THEN ' (a table needing more than ' || b(l_qmax - l_qused + x.freed)
                                            || ' stays where it is)' END;
                END IF;
            END IF;
            IF l_issue IS NOT NULL THEN
                l_shown := l_shown + 1;
                IF l_shown <= 5 THEN
                    l_text := l_text || CASE WHEN l_shown > 1 THEN '; ' END || l_issue;
                END IF;
            END IF;
        END LOOP;
        IF l_shown > 5 THEN
            l_text := l_text || '; and ' || (l_shown - 5) || ' more';
        END IF;
        IF l_pairs = 0 THEN
            add_req('QUOTA', 5, 'NOT_APPLICABLE', 'Y', 'Space quotas of the owners',
                    'A table that moves and an index that is rebuilt are written in the space quota of their owner.',
                    'no table moves and no index is rebuilt', NULL, NULL, NULL);
        ELSE
            add_req('QUOTA', 5, CASE WHEN l_short = 0 THEN 'MET' ELSE 'NOT_MET' END, 'Y', 'Space quotas of the owners',
                    'A table that moves and an index that is rebuilt are written again in the space quota of their '
                    || 'owner, also when SYS runs the reclaim; an owner without a quota there, or above it, is refused '
                    || 'the space (ORA-01950, ORA-01536), and an index that cannot be rebuilt stays unusable.',
                    CASE WHEN l_shown = 0 THEN 'every owner may use unlimited space in its tablespaces' ELSE l_text END,
                    NULL, NULL,
                    CASE WHEN l_short > 0 THEN NULL WHEN l_limited > 0 THEN 'ROOM' ELSE 'UNLIMITED' END);
            add_opt('QUOTA', 'RAISE', 1, l_short = 0, 'Each owner has a quota above what it uses',
                    'ALTER USER <owner> QUOTA UNLIMITED ON <tablespace>, or a quota above its use');
        END IF;
        COMMIT;
    END check_requirements;

    -- Assessment: the tablespaces and every segment in them, what moves and
    -- what stays, the indexes released and rebuilt, the forecast, the
    -- accounts and the requirements. Read-only for the database.
    PROCEDURE assess(p_list IN VARCHAR2, p_message OUT VARCHAR2) IS
        l_targets    PLS_INTEGER := 0;
        l_units      NUMBER;
        l_indexes    NUMBER;
        l_pins       NUMBER;
        l_securefile VARCHAR2(30);
        l_basic      NUMBER;
        l_home       VARCHAR2(128);
        l_in         NUMBER;
        l_bytes      NUMBER;
        l_segs       SYS.ODCIVARCHAR2LIST;
    BEGIN
        resolve_targets(p_list);
        FOR t IN (SELECT tablespace_name FROM epfpg.epf_reclaim_ts WHERE run_id = g_run.run_id
                   ORDER BY start_bytes DESC, tablespace_name) LOOP
            IF g_mode = 'COMPACT' THEN
                epfpg.epf_log.step_plan('COMPACT', t.tablespace_name);
            END IF;
            scan_ts(t.tablespace_name);
            classify_ts(t.tablespace_name);
            l_targets := l_targets + 1;
        END LOOP;
        IF l_targets = 0 THEN
            say(epfpg.epf_log.c_info, 'NO_TARGET', 'No tablespace to reclaim: none holds segments of the application '
                                                   || 'schemas (setting app_schemas: '
                                                   || epfpg.epf_util.setting('app_schemas') || ')');
        END IF;
        pin_units;
        -- A table outside the run whose LOB segments move: the move rebuilds
        -- the table in its own tablespace too, which the run does not limit.
        FOR u IN (SELECT owner, object_name
                    FROM epfpg.epf_reclaim_object
                   WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT')
                   ORDER BY item_id) LOOP
            l_home := home_ts(u.owner, u.object_name);
            SELECT COUNT(*) INTO l_in
              FROM epfpg.epf_reclaim_ts
             WHERE run_id = g_run.run_id AND tablespace_name = l_home;
            IF l_in = 0 THEN
                l_segs := unit_segments(u.owner, u.object_name);
                SELECT NVL(SUM(s.bytes), 0)
                  INTO l_bytes
                  FROM dba_segments s
                 WHERE s.owner = u.owner AND s.tablespace_name = l_home
                   AND s.segment_type || '|' || s.segment_name IN (SELECT column_value FROM TABLE(l_segs));
                say(epfpg.epf_log.c_warn, 'TABLE_OUTSIDE_SCOPE',
                    u.owner || '.' || u.object_name || ' is stored in ' || NVL(l_home, '-') || ', which this run does '
                    || 'not reclaim: moving its LOB segments rebuilds the table there too (' || b(l_bytes) || '), and '
                    || NVL(l_home, 'that tablespace') || ' may grow; reclaim both tablespaces in one run to avoid this',
                    p_owner => u.owner, p_object => u.object_name);
            END IF;
        END LOOP;
        add_table_indexes;
        add_pending_indexes;
        FOR t IN (SELECT tablespace_name FROM epfpg.epf_reclaim_ts WHERE run_id = g_run.run_id ORDER BY tablespace_name) LOOP
            summarize_ts(t.tablespace_name);
            forecast_ts(t.tablespace_name);
            report_ts(t.tablespace_name);
        END LOOP;
        report_initial;
        plan_accounts;
        check_requirements;
        -- With db_securefile FORCE or ALWAYS Oracle may store a BASICFILE LOB
        -- as a SECUREFILE when it moves (reported by the attribute check).
        SELECT MAX(UPPER(value)) INTO l_securefile FROM v$parameter WHERE name = 'db_securefile';
        IF l_securefile IN ('FORCE', 'ALWAYS') THEN
            SELECT COUNT(*)
              INTO l_basic
              FROM dba_lobs l
              JOIN epfpg.epf_reclaim_object o ON o.owner = l.owner AND o.object_name = l.table_name
             WHERE o.run_id = g_run.run_id AND o.unit_type IN ('TABLE', 'IOT') AND l.securefile = 'NO';
            IF l_basic > 0 THEN
                say(epfpg.epf_log.c_warn, 'LOB_TYPE_MAY_CHANGE',
                    'db_securefile is ' || l_securefile || ': ' || l_basic || ' BASICFILE LOB columns of tables that '
                    || 'move may become SECUREFILE');
            END IF;
        END IF;
        SELECT COUNT(CASE WHEN unit_type IN ('TABLE', 'IOT') THEN 1 END),
               COUNT(CASE WHEN unit_type = 'INDEX' AND move_status IN ('PENDING', 'RELEASED') THEN 1 END),
               COUNT(CASE WHEN unit_type = 'PIN' THEN 1 END)
          INTO l_units, l_indexes, l_pins
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id;
        p_message := l_targets || ' tablespaces, ' || l_units || ' tables to move, ' || l_indexes || ' indexes to rebuild, '
                     || l_pins || ' segments or tables that stay';
    END assess;

    -- ------------------------------------------------------------------
    -- Compaction
    -- ------------------------------------------------------------------

    -- Fingerprint once the accounts are locked, before any object changes
    -- (EPF_OBJECT_BASELINE): c_fingerprint, row counts of the tables that
    -- move when reclaim_row_counts is Y, the invalid objects; and the
    -- datafiles (EPF_FILE_SNAP, BASELINE).
    PROCEDURE baseline(p_message OUT VARCHAR2) IS
        l_counts BOOLEAN := UPPER(NVL(epfpg.epf_util.setting('reclaim_row_counts'), 'Y')) = 'Y';
        l_count  NUMBER;
        l_tables PLS_INTEGER := 0;
    BEGIN
        DELETE FROM epfpg.epf_object_baseline WHERE run_id = g_run.run_id;
        FOR f IN c_fingerprint(g_run.run_id) LOOP
            INSERT INTO epfpg.epf_object_baseline (run_id, object_type, owner, name, table_owner, table_name,
                                                   tablespace_name, status, validated, degree, logging, detail)
            VALUES (g_run.run_id, f.object_type, f.owner, f.name, f.table_owner, f.table_name, f.tablespace_name,
                    f.status, f.validated, f.degree, f.logging, SUBSTR(f.fp, 1, 4000));
        END LOOP;
        INSERT INTO epfpg.epf_object_baseline (run_id, object_type, owner, name, detail)
        SELECT g_run.run_id, 'INVALID', d.owner, d.object_name, d.object_type
          FROM dba_objects d
         WHERE d.status = 'INVALID'
           AND d.owner IN (SELECT u.username FROM dba_users u WHERE u.oracle_maintained = 'N');
        COMMIT;
        FOR t IN (SELECT owner, name
                    FROM epfpg.epf_object_baseline
                   WHERE run_id = g_run.run_id AND object_type = 'TABLE'
                   ORDER BY owner, name) LOOP
            IF l_counts THEN
                l_count := row_count(t.owner, t.name);
                UPDATE epfpg.epf_object_baseline
                   SET row_count = l_count
                 WHERE run_id = g_run.run_id AND object_type = 'TABLE' AND owner = t.owner AND name = t.name;
                COMMIT;
            END IF;
            l_tables := l_tables + 1;
        END LOOP;
        snap_files('BASELINE');
        p_message := l_tables || ' tables' || CASE WHEN l_counts THEN ' counted' END;
    END baseline;

    -- Disconnects the sessions of the accounts in scope: POST_TRANSACTION
    -- (an open transaction ends first), then IMMEDIATE for the sessions still
    -- there after disconnect_timeout_s. p_count returns the sessions.
    PROCEDURE disconnect_sessions(p_count OUT PLS_INTEGER) IS
        TYPE t_counts IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(128);
        l_counts   t_counts;
        l_timeout  NUMBER := NVL(epfpg.epf_util.setting_num('disconnect_timeout_s'), 300);
        l_sid      NUMBER := TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'));
        l_deadline TIMESTAMP WITH TIME ZONE;
        l_left     NUMBER;
        l_user     VARCHAR2(128);
    BEGIN
        p_count := 0;
        FOR s IN (SELECT s.sid, s.serial#, s.username, s.osuser, s.machine, s.program
                    FROM v$session s
                   WHERE s.type = 'USER' AND s.sid <> l_sid
                     AND s.username IN (SELECT a.username FROM epfpg.epf_account_action a WHERE a.run_id = g_run.run_id)
                   ORDER BY s.username, s.sid) LOOP
            BEGIN
                EXECUTE IMMEDIATE 'ALTER SYSTEM DISCONNECT SESSION ''' || s.sid || ',' || s.serial# || ''' POST_TRANSACTION';
            EXCEPTION
                WHEN OTHERS THEN
                    -- ORA-00030 the session ended meanwhile, ORA-00031 marked for kill.
                    IF SQLCODE NOT IN (-30, -31) THEN
                        RAISE;
                    END IF;
            END;
            l_counts(s.username) := CASE WHEN l_counts.EXISTS(s.username) THEN l_counts(s.username) ELSE 0 END + 1;
            p_count := p_count + 1;
            say(epfpg.epf_log.c_info, 'SESSION_DISCONNECT',
                s.username || ' session ' || s.sid || ',' || s.serial# || ' (' || s.osuser || '@' || s.machine || ' '
                || s.program || '): disconnected once its transaction ends');
        END LOOP;
        IF p_count > 0 THEN
            l_deadline := SYSTIMESTAMP + NUMTODSINTERVAL(l_timeout, 'SECOND');
            LOOP
                SELECT COUNT(*)
                  INTO l_left
                  FROM v$session s
                 WHERE s.type = 'USER' AND s.sid <> l_sid AND s.status <> 'KILLED'
                   AND s.username IN (SELECT a.username FROM epfpg.epf_account_action a WHERE a.run_id = g_run.run_id);
                EXIT WHEN l_left = 0 OR SYSTIMESTAMP >= l_deadline;
                DBMS_LOCK.SLEEP(5);
            END LOOP;
            FOR s IN (SELECT s.sid, s.serial#, s.username
                        FROM v$session s
                       WHERE s.type = 'USER' AND s.sid <> l_sid AND s.status <> 'KILLED'
                         AND s.username IN (SELECT a.username FROM epfpg.epf_account_action a
                                             WHERE a.run_id = g_run.run_id)) LOOP
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER SYSTEM DISCONNECT SESSION ''' || s.sid || ',' || s.serial# || ''' IMMEDIATE';
                    say(epfpg.epf_log.c_warn, 'SESSION_DISCONNECT_IMMEDIATE',
                        s.username || ' session ' || s.sid || ',' || s.serial# || ' was still connected after '
                        || l_timeout || ' s: disconnected immediately (an open transaction is rolled back)');
                EXCEPTION
                    WHEN OTHERS THEN
                        IF SQLCODE NOT IN (-30, -31) THEN
                            RAISE;
                        END IF;
                END;
            END LOOP;
        END IF;
        l_user := l_counts.FIRST;
        WHILE l_user IS NOT NULL LOOP
            UPDATE epfpg.epf_account_action
               SET sessions_disconnected = sessions_disconnected + l_counts(l_user)
             WHERE run_id = g_run.run_id AND username = l_user;
            l_user := l_counts.NEXT(l_user);
        END LOOP;
        COMMIT;
    END disconnect_sessions;

    -- Locks the accounts in scope (EPF_ACCOUNT_ACTION of the run): the
    -- status is read again and the lock recorded (locked_at) before it is
    -- made; an account already locked stays as it is. Then disconnects the
    -- sessions of every account in scope.
    PROCEDURE lock_accounts(p_message OUT VARCHAR2) IS
        l_status   VARCHAR2(32);
        l_locked   PLS_INTEGER := 0;
        l_sessions PLS_INTEGER;
    BEGIN
        FOR a IN (SELECT username FROM epfpg.epf_account_action WHERE run_id = g_run.run_id ORDER BY username) LOOP
            SELECT MAX(account_status) INTO l_status FROM dba_users WHERE username = a.username;
            IF l_status IS NULL THEN
                say(epfpg.epf_log.c_info, 'ACCOUNT_GONE', a.username || ' no longer exists');
            ELSIF INSTR(l_status, 'LOCKED') = 0 THEN
                UPDATE epfpg.epf_account_action
                   SET original_status = l_status, locked_at = epfpg.epf_util.now_ts
                 WHERE run_id = g_run.run_id AND username = a.username;
                COMMIT;
                g_changed := TRUE;
                EXECUTE IMMEDIATE 'ALTER USER ' || q(a.username) || ' ACCOUNT LOCK';
                l_locked := l_locked + 1;
                say(epfpg.epf_log.c_ok, 'ACCOUNT_LOCKED', a.username || ' locked (was ' || l_status || ')');
            ELSE
                UPDATE epfpg.epf_account_action
                   SET original_status = l_status
                 WHERE run_id = g_run.run_id AND username = a.username;
                COMMIT;
                say(epfpg.epf_log.c_info, 'ACCOUNT_ALREADY_LOCKED', a.username || ' is ' || l_status
                                                                    || ' already; it stays as it is');
            END IF;
        END LOOP;
        disconnect_sessions(l_sessions);
        p_message := l_locked || ' accounts locked, ' || l_sessions || ' sessions disconnected';
    END lock_accounts;

    -- Releases the PENDING indexes: recorded RELEASED, then ALTER INDEX ...
    -- UNUSABLE (its segment is dropped); an index that is no longer usable is
    -- left as found (KEPT). Their inventory rows go: their space is free.
    PROCEDURE release_indexes(p_message OUT VARCHAR2) IS
        l_status   VARCHAR2(8);
        l_released PLS_INTEGER := 0;
        l_bytes    NUMBER := 0;
    BEGIN
        FOR i IN (SELECT item_id, owner, object_name, bytes
                    FROM epfpg.epf_reclaim_object
                   WHERE run_id = g_run.run_id AND unit_type = 'INDEX' AND move_status = 'PENDING'
                   ORDER BY item_id) LOOP
            SELECT MAX(status) INTO l_status FROM dba_indexes WHERE owner = i.owner AND index_name = i.object_name;
            IF l_status = 'VALID' THEN
                UPDATE epfpg.epf_reclaim_object
                   SET move_status = 'RELEASED', started_at = epfpg.epf_util.now_ts
                 WHERE run_id = g_run.run_id AND item_id = i.item_id;
                COMMIT;
                g_changed := TRUE;
                ddl('ALTER INDEX ' || qn(i.owner, i.object_name) || ' UNUSABLE');
                l_released := l_released + 1;
                l_bytes := l_bytes + i.bytes;
            ELSE
                UPDATE epfpg.epf_reclaim_object
                   SET move_status = 'KEPT', detail = 'status ' || NVL(l_status, 'not found') || ' when released: left as found'
                 WHERE run_id = g_run.run_id AND item_id = i.item_id;
                COMMIT;
            END IF;
            DELETE FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND item_id = i.item_id;
            COMMIT;
        END LOOP;
        say(epfpg.epf_log.c_ok, 'INDEXES_RELEASED', l_released || ' indexes released: ' || b(l_bytes)
                                                    || ' of index segments become free space', p_rows => l_released,
            p_bytes => l_bytes);
        p_message := l_released || ' indexes released, ' || b(l_bytes);
    END release_indexes;

    -- Bytes segment p_owner.p_name of type p_type is expected to need once it
    -- moves or is rebuilt (its estimate in the run's inventory); 0 when it is
    -- not there.
    FUNCTION seg_est(p_owner IN VARCHAR2, p_name IN VARCHAR2, p_type IN VARCHAR2) RETURN NUMBER IS
        l_est NUMBER;
    BEGIN
        SELECT NVL(SUM(est_bytes), 0)
          INTO l_est
          FROM epfpg.epf_ts_inventory
         WHERE run_id = g_run.run_id AND owner = p_owner AND object_name = p_name AND segment_type = p_type;
        RETURN l_est;
    END seg_est;

    -- A segment that moves or is rebuilt is created again with its INITIAL
    -- storage, all allocated at once. An INITIAL larger than the segment needs
    -- (oversized against p_est, its initial_need; typically the size of the
    -- segment when it was exported) is set to 64 KB instead: returns the
    -- STORAGE clause, adds p_what with the former INITIAL to p_note, and
    -- segment p_segment to g_reset. Otherwise NULL.
    FUNCTION initial_clause(p_initial IN NUMBER, p_est IN NUMBER, p_what IN VARCHAR2, p_segment IN VARCHAR2,
                            p_note IN OUT NOCOPY VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF oversized(p_initial, p_est) THEN
            p_note := SUBSTR(p_note || CASE WHEN p_note IS NOT NULL THEN ', ' END || p_what || ' ' || b(p_initial), 1, 1000);
            g_reset.EXTEND;
            g_reset(g_reset.COUNT) := p_what || '|' || p_segment;
            RETURN ' STORAGE (INITIAL 65536)';
        END IF;
        RETURN NULL;
    END initial_clause;

    -- Once the statement ran: the segments of p_owner it asked INITIAL 64 KB
    -- for (g_reset) whose INITIAL Oracle kept above 1 MB, as "what size", NULL
    -- when none. Such a segment holds at least that INITIAL.
    FUNCTION initial_kept(p_owner IN VARCHAR2) RETURN VARCHAR2 IS
        l_initial NUMBER;
        l_list    VARCHAR2(1000);
    BEGIN
        FOR i IN 1 .. g_reset.COUNT LOOP
            SELECT MAX(initial_extent)
              INTO l_initial
              FROM dba_segments
             WHERE owner = p_owner AND segment_name = SUBSTR(g_reset(i), INSTR(g_reset(i), '|') + 1);
            IF l_initial > c_mb THEN
                l_list := SUBSTR(l_list || CASE WHEN l_list IS NOT NULL THEN ', ' END
                                 || SUBSTR(g_reset(i), 1, INSTR(g_reset(i), '|') - 1) || ' ' || b(l_initial), 1, 1000);
            END IF;
        END LOOP;
        RETURN l_list;
    END initial_kept;

    -- The statement that moves a table within its tablespaces: the table (an
    -- IOT with its overflow), and every LOB segment kept in one of the run's
    -- tablespaces with its type (SECUREFILE or BASICFILE) stated. A segment
    -- whose INITIAL is larger than it needs gets INITIAL 64 KB
    -- (initial_clause); p_note lists them with their former INITIAL. An IOT
    -- overflow segment keeps its INITIAL: a MOVE ignores a STORAGE clause for
    -- it (lab probe, R6). p_large_ts: in that tablespace, the table or IOT
    -- index and each LOB segment move with extents of c_chunk (INITIAL
    -- large_initial) when chunked; p_large lists them with that INITIAL.
    FUNCTION move_sql(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_type IN VARCHAR2, p_large_ts IN VARCHAR2,
                      p_note OUT VARCHAR2, p_large OUT VARCHAR2) RETURN VARCHAR2 IS
        l_ts      VARCHAR2(128);
        l_ovf     VARCHAR2(128);
        l_top     VARCHAR2(128);
        l_initial NUMBER;
        l_est     NUMBER;
        l_sql     VARCHAR2(32767);

        -- The STORAGE clause of one segment: INITIAL in whole extents of
        -- c_chunk when p_big (added to p_large), otherwise initial_clause.
        FUNCTION clause(p_initial IN NUMBER, p_need IN NUMBER, p_bytes IN NUMBER, p_what IN VARCHAR2,
                        p_segment IN VARCHAR2, p_big IN BOOLEAN) RETURN VARCHAR2 IS
        BEGIN
            IF p_big THEN
                p_large := SUBSTR(p_large || CASE WHEN p_large IS NOT NULL THEN ', ' END || p_what || ' '
                                  || b(large_initial(p_bytes)), 1, 1000);
                RETURN ' STORAGE (INITIAL ' || TO_CHAR(large_initial(p_bytes)) || ')';
            END IF;
            RETURN initial_clause(p_initial, p_need, p_what, p_segment, p_note);
        END clause;
    BEGIN
        p_note := NULL;
        p_large := NULL;
        g_reset := SYS.ODCIVARCHAR2LIST();
        IF p_type = 'IOT' THEN
            SELECT MAX(tablespace_name), MAX(index_name), MAX(initial_extent)
              INTO l_ts, l_top, l_initial
              FROM dba_indexes
             WHERE table_owner = p_owner AND table_name = p_table AND index_type = 'IOT - TOP';
            SELECT MAX(tablespace_name)
              INTO l_ovf
              FROM dba_tables
             WHERE owner = p_owner AND iot_name = p_table AND iot_type = 'IOT_OVERFLOW';
        ELSE
            SELECT MAX(tablespace_name), MAX(initial_extent)
              INTO l_ts, l_initial
              FROM dba_tables
             WHERE owner = p_owner AND table_name = p_table;
        END IF;
        IF l_ts IS NULL THEN
            RAISE_APPLICATION_ERROR(-20161, 'No tablespace found for ' || p_owner || '.' || p_table);
        END IF;
        l_sql := 'ALTER TABLE ' || qn(p_owner, p_table) || ' MOVE TABLESPACE ' || q(l_ts);
        IF p_type = 'IOT' THEN
            l_est := seg_est(p_owner, l_top, 'INDEX');
            l_sql := l_sql || clause(l_initial, initial_need(p_owner, l_top, 'INDEX', l_est), l_est, 'index', l_top,
                                     l_ts = p_large_ts AND chunked(l_est));
        ELSE
            l_est := seg_est(p_owner, p_table, 'TABLE');
            l_sql := l_sql || clause(l_initial, l_est, l_est, 'table', p_table, l_ts = p_large_ts AND chunked(l_est));
        END IF;
        IF l_ovf IS NOT NULL THEN
            l_sql := l_sql || ' OVERFLOW TABLESPACE ' || q(l_ovf);
        END IF;
        FOR l IN (SELECT lb.column_name, lb.tablespace_name, lb.securefile, lb.segment_name,
                         (SELECT MAX(s.initial_extent) FROM dba_segments s
                           WHERE s.owner = lb.owner AND s.segment_name = lb.segment_name) AS initial_extent
                    FROM dba_lobs lb
                   WHERE lb.owner = p_owner AND lb.table_name = p_table AND lb.partitioned = 'NO'
                     AND lb.tablespace_name IN (SELECT r.tablespace_name FROM epfpg.epf_reclaim_ts r
                                                WHERE r.run_id = g_run.run_id)
                   ORDER BY lb.column_name) LOOP
            l_est := seg_est(p_owner, l.segment_name, 'LOBSEGMENT');
            l_sql := l_sql || ' LOB (' || q(l.column_name) || ') STORE AS '
                     || CASE l.securefile WHEN 'YES' THEN 'SECUREFILE' ELSE 'BASICFILE' END
                     || ' (TABLESPACE ' || q(l.tablespace_name)
                     || clause(l.initial_extent, l_est, l_est, 'LOB ' || l.column_name, l.segment_name,
                               l.tablespace_name = p_large_ts AND chunked(l_est)) || ')';
        END LOOP;
        RETURN l_sql;
    END move_sql;

    -- Datafile p_file cannot shrink further (FILE_DONE): its highest block
    -- belongs to p_owner.p_name, which stays there for p_why. Recorded with
    -- its tablespace (stop_detail) for the report.
    PROCEDURE file_done(p_file IN NUMBER, p_owner IN VARCHAR2, p_name IN VARCHAR2, p_why IN VARCHAR2) IS
        l_file VARCHAR2(513);
        l_ts   VARCHAR2(128);
        l_bs   NUMBER;
        l_top  NUMBER;
        l_text VARCHAR2(2000);
    BEGIN
        SELECT d.file_name, d.tablespace_name, t.block_size
          INTO l_file, l_ts, l_bs
          FROM dba_data_files d
          JOIN dba_tablespaces t ON t.tablespace_name = d.tablespace_name
         WHERE d.file_id = p_file;
        SELECT MAX(top_block) INTO l_top FROM epfpg.epf_ts_inventory WHERE run_id = g_run.run_id AND file_id = p_file;
        l_text := SUBSTR(l_file || ' stops at ' || b((NVL(l_top, 0) + 1) * l_bs) || ': its highest block belongs to '
                         || p_owner || '.' || p_name || ' (' || p_why || ')', 1, 1000);
        say(epfpg.epf_log.c_info, 'FILE_DONE', l_text);
        UPDATE epfpg.epf_reclaim_ts
           SET stop_detail = SUBSTR(stop_detail || CASE WHEN stop_detail IS NOT NULL THEN '; ' END || l_text, 1, 2000)
         WHERE run_id = g_run.run_id AND tablespace_name = l_ts;
        COMMIT;
    END file_done;

    -- The unit holding the highest block of a datafile of p_ts that is still
    -- compacting (p_item NULL when none is left). A datafile whose highest
    -- block belongs to a segment that cannot move (a pin, or an index that
    -- was not released), or to a table that did not fit, failed, could not
    -- move lower after it moved, whose copy held the top again after
    -- reclaim_unit_moves of its moves, or that moved c_move_cap times, is
    -- done: it cannot shrink further. A segment that stays but is gone
    -- meanwhile (a recycle-bin object Oracle purged, a temporary segment)
    -- leaves the inventory.
    PROCEDURE pick(p_ts IN VARCHAR2, p_done IN OUT NOCOPY t_flags, p_item OUT NUMBER, p_file OUT NUMBER) IS
        l_best     NUMBER := -1;
        l_top_item NUMBER;
        l_top      NUMBER;
        l_owner_i  VARCHAR2(128);
        l_name_i   VARCHAR2(128);
        l_live     NUMBER;
        l_type     VARCHAR2(30);
        l_status   VARCHAR2(20);
        l_attempts NUMBER;
        l_last_ora NUMBER;
        l_returns  NUMBER;
        l_owner    VARCHAR2(128);
        l_name     VARCHAR2(128);
        l_detail   VARCHAR2(4000);
    BEGIN
        p_item := NULL;
        p_file := NULL;
        FOR f IN (SELECT file_id FROM dba_data_files WHERE tablespace_name = p_ts ORDER BY file_id) LOOP
            WHILE NOT p_done.EXISTS(f.file_id) LOOP
                SELECT MAX(item_id) KEEP (DENSE_RANK LAST ORDER BY top_block),
                       MAX(top_block),
                       MAX(owner) KEEP (DENSE_RANK LAST ORDER BY top_block),
                       MAX(object_name) KEEP (DENSE_RANK LAST ORDER BY top_block)
                  INTO l_top_item, l_top, l_owner_i, l_name_i
                  FROM epfpg.epf_ts_inventory
                 WHERE run_id = g_run.run_id AND file_id = f.file_id;
                IF l_top_item IS NULL THEN
                    p_done(f.file_id) := TRUE;
                    EXIT;
                END IF;
                SELECT unit_type, move_status, attempts, last_ora, owner, object_name, detail
                  INTO l_type, l_status, l_attempts, l_last_ora, l_owner, l_name, l_detail
                  FROM epfpg.epf_reclaim_object
                 WHERE run_id = g_run.run_id AND item_id = l_top_item;
                IF l_type NOT IN ('TABLE', 'IOT') THEN
                    SELECT COUNT(*)
                      INTO l_live
                      FROM dba_extents
                     WHERE file_id = f.file_id AND owner = l_owner_i AND segment_name = l_name_i
                       AND block_id + blocks - 1 >= l_top;
                    IF l_live = 0 THEN
                        DELETE FROM epfpg.epf_ts_inventory
                         WHERE run_id = g_run.run_id AND file_id = f.file_id AND owner = l_owner_i
                           AND object_name = l_name_i;
                        COMMIT;
                        CONTINUE;
                    END IF;
                END IF;
                l_returns := CASE WHEN g_at_top.EXISTS(l_top_item) THEN g_at_top(l_top_item) ELSE 0 END;
                IF l_type NOT IN ('TABLE', 'IOT') OR l_status IN ('NO_ROOM', 'FAILED') OR l_returns >= g_moves
                   OR l_attempts >= c_move_cap OR (l_status = 'MOVED' AND l_last_ora IS NOT NULL) THEN
                    p_done(f.file_id) := TRUE;
                    file_done(f.file_id, l_owner, l_name,
                              CASE WHEN l_type = 'PIN' THEN l_detail
                                   WHEN l_type = 'INDEX' THEN 'index left as found'
                                   WHEN l_status IN ('NO_ROOM', 'FAILED') THEN LOWER(REPLACE(l_status, '_', ' '))
                                   WHEN l_status = 'MOVED' AND l_last_ora IS NOT NULL
                                   THEN 'moved; it could not move lower (ORA-' || LPAD(l_last_ora, 5, '0') || ')'
                                   WHEN l_returns >= g_moves
                                   THEN 'moved ' || l_attempts || ' times; its copy held the top again after ' || l_returns
                                        || ' of them'
                                   ELSE 'moved ' || l_attempts || ' times, the most in one run' END);
                ELSIF l_top > l_best THEN
                    l_best := l_top;
                    p_item := l_top_item;
                    p_file := f.file_id;
                END IF;
                EXIT;
            END LOOP;
        END LOOP;
    END pick;

    -- The unit of p_ts to move first to make room, other than p_top, that
    -- fits in p_free: a table not moved yet with at least 1 MB and 10 % of
    -- its space free inside it (a purged table). With p_want, the smallest
    -- whose move frees at least that much (the least to write again), else
    -- the one that frees the most; without, the one that frees the most.
    -- NULL when none.
    FUNCTION room_maker(p_ts IN VARCHAR2, p_free IN NUMBER, p_top IN NUMBER, p_want IN NUMBER DEFAULT NULL)
        RETURN NUMBER IS
    BEGIN
        FOR u IN (SELECT i.item_id, SUM(i.bytes) - SUM(i.est_bytes) AS gain
                    FROM epfpg.epf_ts_inventory i
                    JOIN epfpg.epf_reclaim_object o ON o.run_id = i.run_id AND o.item_id = i.item_id
                   WHERE i.run_id = g_run.run_id AND i.tablespace_name = p_ts AND i.handler = 'MOVE'
                     AND o.unit_type IN ('TABLE', 'IOT') AND o.move_status IN ('PENDING', 'STAYED')
                     AND o.attempts < g_moves AND o.item_id <> p_top
                   GROUP BY i.item_id
                  HAVING SUM(i.bytes) - SUM(i.est_bytes) >= GREATEST(c_mb, 0.1 * SUM(i.bytes))
                   ORDER BY CASE WHEN SUM(i.bytes) - SUM(i.est_bytes) >= NVL(p_want, 1E38) THEN 0 ELSE 1 END,
                            CASE WHEN SUM(i.bytes) - SUM(i.est_bytes) >= NVL(p_want, 1E38) THEN SUM(i.bytes) END,
                            2 DESC, 1) LOOP
            IF need(u.item_id, p_ts) <= p_free THEN
                RETURN u.item_id;
            END IF;
        END LOOP;
        RETURN NULL;
    END room_maker;

    -- Tests only (setting reclaim_test_pause_s, consumed by the compaction
    -- that reads it): after each table that moved, the compaction waits that
    -- many seconds, or until a stop is requested, so that a test can stop the
    -- run or end its session at a known point.
    PROCEDURE test_pause IS
    BEGIN
        IF g_pause = 0 THEN
            RETURN;
        END IF;
        say(epfpg.epf_log.c_info, 'TEST_PAUSE', 'Pause of up to ' || g_pause || ' s after the move (setting '
                                                || 'reclaim_test_pause_s, tests only)');
        FOR i IN 1 .. g_pause LOOP
            EXIT WHEN epfpg.epf_control.stop_requested(g_run.run_id);
            DBMS_LOCK.SLEEP(1);
        END LOOP;
    END test_pause;

    -- The other tablespaces of the run where unit p_item has segments (a LOB
    -- or an IOT overflow stored apart from its table), which its move writes
    -- again too. p_grow TRUE: each one whose free space is short of what the
    -- move writes there (need) first grows within its room (grow_ts); FALSE:
    -- each is resized down to its highest block (trim_ts). Returns the bytes
    -- added or given back.
    FUNCTION other_ts(p_item IN NUMBER, p_ts IN VARCHAR2, p_grow IN BOOLEAN) RETURN NUMBER IS
        l_bytes NUMBER := 0;
        l_need  NUMBER;
        l_free  NUMBER;
    BEGIN
        FOR t IN (SELECT DISTINCT tablespace_name
                    FROM epfpg.epf_ts_inventory
                   WHERE run_id = g_run.run_id AND item_id = p_item AND tablespace_name <> p_ts
                   ORDER BY tablespace_name) LOOP
            IF p_grow THEN
                l_need := need(p_item, t.tablespace_name);
                l_free := free_bytes(t.tablespace_name);
                IF l_need > l_free THEN
                    l_bytes := l_bytes + grow_ts(t.tablespace_name, l_need - l_free);
                END IF;
            ELSE
                l_bytes := l_bytes + trim_ts(t.tablespace_name, 0, FALSE);
            END IF;
        END LOOP;
        RETURN l_bytes;
    END other_ts;

    -- The free space of p_ts as text (MOVE_PLACEMENT): in all, in stretches of
    -- 8 MB or more and in whole stretches of c_chunk, and where the lowest of
    -- each starts in its datafile. NULL when it cannot be read: it only
    -- describes the move.
    FUNCTION free_layout(p_ts IN VARCHAR2) RETURN VARCHAR2 IS
        l_bs    NUMBER;
        l_all   NUMBER;
        l_big   NUMBER;
        l_low   NUMBER;
        l_chunk NUMBER;
        l_clow  NUMBER;
    BEGIN
        SELECT block_size INTO l_bs FROM dba_tablespaces WHERE tablespace_name = p_ts;
        SELECT NVL(SUM(bytes), 0), NVL(SUM(CASE WHEN bytes >= 8 * c_mb THEN bytes END), 0),
               MIN(CASE WHEN bytes >= 8 * c_mb THEN block_id END), NVL(SUM(FLOOR(bytes / c_chunk) * c_chunk), 0),
               MIN(CASE WHEN bytes >= c_chunk THEN block_id END)
          INTO l_all, l_big, l_low, l_chunk, l_clow
          FROM dba_free_space
         WHERE tablespace_name = p_ts;
        RETURN b(l_all) || ' free, ' || b(l_big) || ' of it in stretches of 8 MB or more'
               || CASE WHEN l_low IS NOT NULL THEN ' (the lowest at ' || b(l_low * l_bs) || ')' END
               || ', ' || b(l_chunk) || ' in whole 64 MB stretches'
               || CASE WHEN l_clow IS NOT NULL THEN ' (the lowest at ' || b(l_clow * l_bs) || ')' END;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END free_layout;

    -- The free space of p_ts that extents of c_chunk can take: each free
    -- stretch counted in whole extents of c_chunk.
    FUNCTION fresh_bytes(p_ts IN VARCHAR2) RETURN NUMBER IS
        l_bytes NUMBER;
    BEGIN
        SELECT NVL(SUM(FLOOR(bytes / c_chunk) * c_chunk), 0)
          INTO l_bytes
          FROM dba_free_space
         WHERE tablespace_name = p_ts;
        RETURN l_bytes;
    END fresh_bytes;

    -- How unit p_item moves in p_ts with extents of c_chunk, as move_sql
    -- writes it: p_bytes, the estimate of its segments there that do (its
    -- table or IOT index segment and its LOB segments, each when chunked; 0
    -- when none does); p_chunks, their INITIAL (large_initial), which only
    -- whole free stretches of c_chunk take; p_need, the free space the move
    -- needs in all, its other segments at their estimate plus 1 MB.
    PROCEDURE large_plan(p_item IN NUMBER, p_ts IN VARCHAR2, p_bytes OUT NUMBER, p_chunks OUT NUMBER,
                         p_need OUT NUMBER) IS
    BEGIN
        p_bytes := 0;
        p_chunks := 0;
        p_need := 0;
        FOR s IN (SELECT NVL(SUM(i.est_bytes), 0) AS est,
                         MAX(CASE WHEN i.segment_type IN ('INDEX', 'LOBSEGMENT')
                                       OR (i.segment_type = 'TABLE' AND i.object_name = o.object_name)
                                  THEN 'Y' ELSE 'N' END) AS main
                    FROM epfpg.epf_ts_inventory i
                    JOIN epfpg.epf_reclaim_object o ON o.run_id = i.run_id AND o.item_id = i.item_id
                   WHERE i.run_id = g_run.run_id AND i.item_id = p_item AND i.tablespace_name = p_ts
                   GROUP BY i.owner, i.object_name, i.sub_name, i.segment_type) LOOP
            IF s.main = 'Y' AND chunked(s.est) THEN
                p_bytes := p_bytes + s.est;
                p_chunks := p_chunks + large_initial(s.est);
            ELSE
                p_need := p_need + s.est + c_mb;
            END IF;
        END LOOP;
        p_need := p_need + p_chunks;
    END large_plan;

    -- Where the segments of table p_owner.p_table lie in p_ts, as text
    -- (MOVE_PLACEMENT): their size, extents and extent sizes, and their
    -- lowest and highest position in their datafile. NULL when it cannot be
    -- read: it only describes the move.
    FUNCTION unit_layout(p_ts IN VARCHAR2, p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN VARCHAR2 IS
        l_names SYS.ODCIVARCHAR2LIST;
        l_bs    NUMBER;
        l_count NUMBER;
        l_bytes NUMBER;
        l_minext NUMBER;
        l_maxext NUMBER;
        l_low   NUMBER;
        l_high  NUMBER;
    BEGIN
        l_names := unit_segments(p_owner, p_table);
        SELECT block_size INTO l_bs FROM dba_tablespaces WHERE tablespace_name = p_ts;
        SELECT COUNT(*), NVL(SUM(e.bytes), 0), MIN(e.bytes), MAX(e.bytes), MIN(e.block_id), MAX(e.block_id + e.blocks)
          INTO l_count, l_bytes, l_minext, l_maxext, l_low, l_high
          FROM dba_extents e
         WHERE e.owner = p_owner AND e.tablespace_name = p_ts
           AND e.segment_type || '|' || e.segment_name IN (SELECT column_value FROM TABLE(l_names));
        RETURN b(l_bytes) || ' in ' || l_count || ' extents of ' || b(l_minext) || ' to ' || b(l_maxext) || ', from '
               || b(l_low * l_bs) || ' to ' || b(l_high * l_bs);
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END unit_layout;

    -- Moves unit p_item within its tablespaces. p_file: the datafile of p_ts
    -- whose highest block the unit holds; a move that does not fit is tried
    -- once more after that file grew by all its room (grow_file), and a unit
    -- that still does not fit or exceeds its owner's quota (NO_ROOM), is in
    -- use (ORA-00054) or fails otherwise (FAILED, an error) stays where it
    -- was. The other tablespaces of the run where it has segments grow within
    -- their room first when they are short (other_ts), also for a unit that
    -- moved already: its segments there do not land in p_ts (a LOB tablespace
    -- compacted after the tablespace of its tables, which its compaction left
    -- full). A unit that moved already (at the top again) is not tried after
    -- its datafile grew, and when it cannot move lower it keeps its move
    -- (MOVED, with the error in last_ora: its datafile is then done). p_file NULL: a move that makes room for the
    -- unit at the top; when it does not fit, the unit keeps its status and is
    -- no longer a room maker. p_large: its segments in p_ts move with extents
    -- of c_chunk (move_sql); when that statement fails, a unit that moved
    -- already keeps its move, and one that did not moves as usual. After a
    -- move its positions are read again and the datafiles resized down.
    PROCEDURE move_unit(p_ts IN VARCHAR2, p_item IN NUMBER, p_file IN NUMBER, p_large IN BOOLEAN DEFAULT FALSE) IS
        l_owner   VARCHAR2(128);
        l_table   VARCHAR2(128);
        l_type    VARCHAR2(30);
        l_prior   VARCHAR2(20);
        l_est     NUMBER;
        l_bytes   NUMBER;
        l_sql     VARCHAR2(32767);
        l_before  NUMBER;
        l_after   NUMBER;
        l_new     NUMBER;
        l_top     NUMBER;
        l_code    NUMBER := 0;
        l_msg     VARCHAR2(4000);
        l_status  VARCHAR2(20);
        l_done    BOOLEAN := FALSE;
        l_started TIMESTAMP := epfpg.epf_util.now_ts;
        l_freed   NUMBER;
        l_grown   NUMBER := 0;
        l_other   NUMBER := 0;
        l_note    VARCHAR2(1000);
        l_kept    VARCHAR2(1000);
        l_tops    NUMBER;
        l_again   BOOLEAN := FALSE;
        l_from    VARCHAR2(400);
        l_space   VARCHAR2(400);
        l_large   BOOLEAN := NVL(p_large, FALSE);
        l_big     VARCHAR2(1000);
        l_tries   PLS_INTEGER := 0;
        l_detail  VARCHAR2(4000);
    BEGIN
        SELECT owner, object_name, unit_type, move_status
          INTO l_owner, l_table, l_type, l_prior
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id AND item_id = p_item;
        SELECT NVL(SUM(est_bytes), 0), NVL(SUM(bytes), 0)
          INTO l_est, l_bytes
          FROM epfpg.epf_ts_inventory
         WHERE run_id = g_run.run_id AND item_id = p_item AND tablespace_name = p_ts;
        l_sql := move_sql(l_owner, l_table, l_type, CASE WHEN l_large THEN p_ts END, l_note, l_big);
        l_before := ts_bytes(p_ts);
        UPDATE epfpg.epf_reclaim_object
           SET attempts = attempts + 1, started_at = NVL(started_at, l_started)
         WHERE run_id = g_run.run_id AND item_id = p_item;
        COMMIT;
        l_other := other_ts(p_item, p_ts, TRUE);
        l_from := unit_layout(p_ts, l_owner, l_table);
        l_space := free_layout(p_ts);
        LOOP
            l_tries := l_tries + 1;
            BEGIN
                ddl(l_sql);
                l_done := TRUE;
            EXCEPTION
                WHEN OTHERS THEN
                    l_code := SQLCODE;
                    l_msg := SQLERRM;
            END;
            EXIT WHEN l_done OR l_tries >= 3;
            IF l_large THEN
                -- It did not move with extents of c_chunk: a unit that moved
                -- already keeps its move; one that did not moves as usual.
                EXIT WHEN NVL(l_prior, '-') = 'MOVED';
                l_large := FALSE;
                l_sql := move_sql(l_owner, l_table, l_type, NULL, l_note, l_big);
            ELSE
                EXIT WHEN NOT is_space_error(l_code) OR p_file IS NULL OR NVL(l_prior, '-') = 'MOVED' OR l_grown > 0;
                l_grown := grow_file(p_ts, p_file, 1125899906842624);
                EXIT WHEN l_grown = 0;
            END IF;
        END LOOP;
        IF l_done THEN
            refresh_item(p_item, l_owner, l_table, l_new);
            SELECT MAX(top_block)
              INTO l_top
              FROM epfpg.epf_ts_inventory
             WHERE run_id = g_run.run_id AND item_id = p_item AND file_id = p_file;
            l_freed := trim_ts(p_ts, 0, FALSE) + other_ts(p_item, p_ts, FALSE);
            l_after := ts_bytes(p_ts);
            l_kept := CASE WHEN l_note IS NOT NULL THEN initial_kept(l_owner) END;
            -- A unit at the top whose copy holds the top of a datafile of p_ts
            -- again, this one or another (counted for pick).
            IF p_file IS NOT NULL THEN
                SELECT COUNT(*)
                  INTO l_tops
                  FROM (SELECT MAX(item_id) KEEP (DENSE_RANK LAST ORDER BY top_block) AS holder
                          FROM epfpg.epf_ts_inventory
                         WHERE run_id = g_run.run_id AND tablespace_name = p_ts
                         GROUP BY file_id)
                 WHERE holder = p_item;
                IF l_tops > 0 THEN
                    l_again := TRUE;
                    g_at_top(p_item) := CASE WHEN g_at_top.EXISTS(p_item) THEN g_at_top(p_item) ELSE 0 END + 1;
                END IF;
            END IF;
            l_detail := CASE WHEN l_large AND l_big IS NOT NULL THEN 'moved with 64 MB extents (INITIAL ' || l_big || ')' END;
            IF l_note IS NOT NULL THEN
                l_detail := SUBSTR(l_detail || CASE WHEN l_detail IS NOT NULL THEN '; ' END
                                   || 'INITIAL set to 64 KB (it was: ' || l_note || ')'
                                   || CASE WHEN l_kept IS NOT NULL THEN '; Oracle kept the INITIAL of ' || l_kept END, 1, 4000);
            END IF;
            UPDATE epfpg.epf_reclaim_object
               SET move_status = 'MOVED', after_bytes = l_new, after_top_block = l_top, last_ora = NULL,
                   ended_at = epfpg.epf_util.now_ts, detail = NVL(l_detail, detail)
             WHERE run_id = g_run.run_id AND item_id = p_item;
            COMMIT;
            IF l_note IS NOT NULL THEN
                say(epfpg.epf_log.c_info, 'INITIAL_RESET',
                    l_owner || '.' || l_table || ': INITIAL larger than needed (' || l_note || '); the move set it to 64 KB',
                    p_owner => l_owner, p_object => l_table);
            END IF;
            IF l_kept IS NOT NULL THEN
                say(epfpg.epf_log.c_info, 'INITIAL_KEPT',
                    l_owner || '.' || l_table || ': the move asked for INITIAL 64 KB, but Oracle kept the INITIAL of '
                    || l_kept || '; such a segment holds at least its INITIAL',
                    p_owner => l_owner, p_object => l_table);
            END IF;
            say(CASE WHEN l_bytes >= c_big THEN epfpg.epf_log.c_ok ELSE epfpg.epf_log.c_info END, 'UNIT_MOVED',
                l_owner || '.' || l_table || ': ' || b(l_bytes) || ' -> ' || b(l_new) || '; ' || p_ts || ' '
                || b(l_before) || ' -> ' || b(l_after)
                || CASE WHEN p_file IS NULL THEN ' (it made room for the table at the top)' END
                || CASE WHEN l_prior = 'MOVED' THEN ' (moved again)' END
                || CASE WHEN l_large AND l_big IS NOT NULL THEN ' (with 64 MB extents: ' || l_big || ')' END
                || CASE WHEN l_again THEN ' (its copy holds the top again)' END
                || CASE WHEN l_grown + l_other > 0 THEN ' (datafiles first grew by ' || b(l_grown + l_other)
                                                        || ' to fit it)' END
                || ' (' || epfpg.epf_util.fmt_duration(epfpg.epf_util.elapsed_s(l_started)) || ')',
                p_owner => l_owner, p_object => l_table, p_bytes => l_new);
            -- Where the copy went, against the free space it had (console.log).
            say(epfpg.epf_log.c_info, 'MOVE_PLACEMENT',
                SUBSTR(l_owner || '.' || l_table || ' in ' || p_ts || ': was ' || NVL(l_from, '-') || '; now '
                       || NVL(unit_layout(p_ts, l_owner, l_table), '-') || '; before the move ' || NVL(l_space, '-'),
                       1, 2000),
                p_owner => l_owner, p_object => l_table);
            test_pause;
            RETURN;
        END IF;
        l_freed := trim_ts(p_ts, 0, FALSE) + other_ts(p_item, p_ts, FALSE);
        IF l_prior = 'MOVED' THEN
            -- Moved already: it stays where its last move put it.
            UPDATE epfpg.epf_reclaim_object
               SET last_ora = ABS(l_code), ended_at = epfpg.epf_util.now_ts,
                   detail = SUBSTR('moved; it could not move lower: ' || l_msg || ' [' || l_sql || ']', 1, 4000)
             WHERE run_id = g_run.run_id AND item_id = p_item;
            COMMIT;
            say(CASE WHEN is_space_error(l_code) OR is_quota_error(l_code) THEN epfpg.epf_log.c_info
                     ELSE epfpg.epf_log.c_warn END,
                'MOVE_AGAIN_NOT_DONE',
                l_owner || '.' || l_table || ' moved already and holds the top of ' || p_ts || ' again; it could not '
                || 'move lower and stays where its move put it: ' || l_msg,
                p_owner => l_owner, p_object => l_table, p_ora => ABS(l_code));
            RETURN;
        END IF;
        IF p_file IS NULL AND (is_space_error(l_code) OR is_quota_error(l_code)) THEN
            -- A room maker that does not fit is no longer one (its estimate
            -- becomes its size); it moves when it is at the top.
            UPDATE epfpg.epf_ts_inventory
               SET est_bytes = bytes
             WHERE run_id = g_run.run_id AND item_id = p_item;
            COMMIT;
            say(epfpg.epf_log.c_info, 'ROOM_MOVE_NO_ROOM',
                l_owner || '.' || l_table || ' (about ' || b(l_est) || ' after the move) did not fit in the free space of '
                || p_ts || ' to make room: ' || l_msg, p_owner => l_owner, p_object => l_table, p_ora => ABS(l_code));
            RETURN;
        END IF;
        l_status := CASE WHEN is_space_error(l_code) OR is_quota_error(l_code) THEN 'NO_ROOM' ELSE 'FAILED' END;
        UPDATE epfpg.epf_reclaim_object
           SET move_status = l_status, last_ora = ABS(l_code), ended_at = epfpg.epf_util.now_ts,
               detail = SUBSTR(l_msg || ' [' || l_sql || ']', 1, 4000)
         WHERE run_id = g_run.run_id AND item_id = p_item;
        COMMIT;
        IF is_quota_error(l_code) THEN
            say(epfpg.epf_log.c_warn, 'MOVE_NO_QUOTA',
                l_owner || '.' || l_table || ' (about ' || b(l_est) || ' after the move) does not fit in the space quota '
                || 'of ' || l_owner || ' (the DBA can raise it: ALTER USER ... QUOTA); it stays where it was: ' || l_msg,
                p_owner => l_owner, p_object => l_table, p_ora => ABS(l_code));
        ELSIF l_status = 'NO_ROOM' THEN
            say(epfpg.epf_log.c_warn, 'MOVE_NO_ROOM',
                l_owner || '.' || l_table || ' (about ' || b(l_est) || ' after the move) does not fit in the free '
                || 'space of ' || p_ts || ' below its highest block'
                || CASE WHEN g_growth = 0 THEN ' (setting reclaim_growth_mb lets the datafiles grow above their '
                                               || 'start size for it)' END
                || '; it stays where it was: ' || l_msg,
                p_owner => l_owner, p_object => l_table, p_ora => ABS(l_code));
        ELSIF l_code = -54 THEN
            say(epfpg.epf_log.c_warn, 'MOVE_BUSY',
                l_owner || '.' || l_table || ' is in use by another session (ORA-00054 after ' || g_retries
                || ' retries); it stays where it was',
                p_owner => l_owner, p_object => l_table, p_ora => 54);
        ELSE
            say(epfpg.epf_log.c_error, 'MOVE_FAILED',
                l_owner || '.' || l_table || ' could not move; it stays where it was: ' || l_msg || ' [' || l_sql
                || ']', p_owner => l_owner, p_object => l_table, p_ora => ABS(l_code));
        END IF;
    END move_unit;

    -- Purges the recycle-bin objects of p_ts when the DBA confirmed it
    -- (--confirm RECYCLEBIN, requirement RECYCLEBIN): while the datafiles
    -- cannot grow Oracle would purge them anyway to make room, and a segment
    -- of theirs, which DBA_EXTENTS does not list, could keep a datafile from
    -- shrinking. Returns the objects purged.
    FUNCTION purge_recyclebin(p_ts IN VARCHAR2) RETURN PLS_INTEGER IS
        l_count NUMBER;
        l_bytes NUMBER;
    BEGIN
        IF NOT confirmed('RECYCLEBIN') THEN
            RETURN 0;
        END IF;
        SELECT COUNT(*), NVL(SUM(r.space * t.block_size), 0)
          INTO l_count, l_bytes
          FROM dba_recyclebin r
          JOIN dba_tablespaces t ON t.tablespace_name = r.ts_name
         WHERE r.ts_name = p_ts;
        IF l_count = 0 THEN
            RETURN 0;
        END IF;
        EXECUTE IMMEDIATE 'PURGE TABLESPACE ' || q(p_ts);
        say(epfpg.epf_log.c_ok, 'RECYCLEBIN_PURGED',
            p_ts || ': ' || l_count || ' recycle-bin objects purged (' || b(l_bytes) || '), as the DBA confirmed '
            || '(--confirm RECYCLEBIN)', p_rows => l_count, p_bytes => l_bytes);
        RETURN l_count;
    END purge_recyclebin;

    -- Stops the datafiles of every tablespace of the run from growing and
    -- resizes them to their highest block (step FREEZE_FILES), after the
    -- recycle-bin objects the DBA confirmed are purged: a table that moves
    -- writes its LOB segments into their tablespace, which may be another
    -- tablespace of the run.
    PROCEDURE freeze_all(p_message OUT VARCHAR2) IS
        l_files PLS_INTEGER := 0;
        l_count PLS_INTEGER;
        l_freed NUMBER := 0;
        l_bin   PLS_INTEGER := 0;
    BEGIN
        FOR t IN (SELECT tablespace_name FROM epfpg.epf_reclaim_ts WHERE run_id = g_run.run_id
                   ORDER BY start_bytes DESC, tablespace_name) LOOP
            l_bin := l_bin + purge_recyclebin(t.tablespace_name);
            freeze_files(t.tablespace_name, l_count);
            l_files := l_files + l_count;
            l_freed := l_freed + trim_ts(t.tablespace_name, 0, FALSE);
            track_peak(t.tablespace_name);
        END LOOP;
        p_message := CASE WHEN l_bin > 0 THEN l_bin || ' recycle-bin objects purged, ' END
                     || l_files || ' datafiles stopped growing, ' || b(l_freed) || ' above the highest blocks given back';
    END freeze_all;

    -- A stop was requested: the compaction of p_ts ends here (reported once).
    FUNCTION stop_now(p_ts IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        IF NOT g_stopped AND epfpg.epf_control.stop_requested(g_run.run_id) THEN
            g_stopped := TRUE;
            say(epfpg.epf_log.c_warn, 'STOP_HONORED', 'Stop requested: the compaction of ' || p_ts
                                                      || ' ends here; indexes, datafiles and accounts are restored');
        END IF;
        RETURN g_stopped;
    END stop_now;

    -- Compacts tablespace p_ts (step COMPACT, scope p_ts): the unit holding
    -- the highest block of a datafile moves down, until every datafile stops
    -- or a stop is requested. When it does not fit in the free space, the
    -- tables with the most free space inside them move first (room_maker),
    -- then its datafile grows within its room. Oracle places the extents of a
    -- copy (64 KB, 1 MB, 8 MB) first in partly used stretches, wherever they
    -- are, and those near the top are the ones the table itself and the
    -- released indexes leave: its copy comes back to the top (R6, R7). With
    -- system-allocated extents, a table that came back, and one of at least
    -- c_large, therefore moves with extents of c_chunk, which take only
    -- wholly free stretches of that size, the lowest first: its segments
    -- large enough for them do (chunked; large_plan, fresh_bytes). For one
    -- that came back, the tables with free space inside them move first until
    -- there are enough such stretches (their segments leave them), three in a
    -- row that add none ending it; when there are not, it stays where its
    -- move put it: its datafile is done. Room made for a given amount takes
    -- the smallest table that frees enough (room_maker, p_want). A table
    -- that came back with no segment large enough, or with uniform extents
    -- (no size to choose), first has room made for it, as much as it needs,
    -- then moves again when it fits in the free space as it is. A stop
    -- request is honored before every move. Units not reached are STAYED
    -- (below a segment that stays), or SKIPPED after a stop request.
    PROCEDURE compact_ts(p_ts IN VARCHAR2) IS
        l_done   t_flags;
        l_item   NUMBER;
        l_file   NUMBER;
        l_maker  NUMBER;
        l_need   NUMBER;
        l_free   NUMBER;
        l_main   NUMBER;
        l_chunks NUMBER := 0;
        l_lneed  NUMBER := 0;
        l_fresh  NUMBER := 0;
        l_fit    BOOLEAN;
        l_large  BOOLEAN;
        l_target NUMBER;
        l_stale  PLS_INTEGER;
        l_last   NUMBER;
        l_system BOOLEAN;
        l_alloc  VARCHAR2(9);
        l_units  NUMBER;
        l_bytes  NUMBER;
        l_moved  NUMBER;
        l_mbytes NUMBER;
        l_start  NUMBER := ts_bytes(p_ts);
        l_freed  NUMBER;
        l_status VARCHAR2(20);
        l_was    VARCHAR2(20);
        l_why    VARCHAR2(400);
        l_owner  VARCHAR2(128);
        l_name   VARCHAR2(128);
    BEGIN
        SELECT COUNT(*), NVL(SUM(bytes), 0)
          INTO l_units, l_bytes
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT') AND source_ts = p_ts;
        epfpg.epf_log.step_start('COMPACT', p_ts, l_units, l_bytes);
        SELECT allocation_type INTO l_alloc FROM dba_tablespaces WHERE tablespace_name = p_ts;
        l_system := l_alloc = 'SYSTEM';
        UPDATE epfpg.epf_reclaim_ts SET stop_detail = NULL WHERE run_id = g_run.run_id AND tablespace_name = p_ts;
        COMMIT;
        l_freed := trim_ts(p_ts, 0, FALSE);
        LOOP
            EXIT WHEN stop_now(p_ts);
            pick(p_ts, l_done, l_item, l_file);
            EXIT WHEN l_item IS NULL;
            SELECT owner, object_name, move_status
              INTO l_owner, l_name, l_was
              FROM epfpg.epf_reclaim_object
             WHERE run_id = g_run.run_id AND item_id = l_item;
            l_need := need(l_item, p_ts);
            l_free := free_bytes(p_ts);
            -- With extents of c_chunk (system-allocated extents only, and only
            -- its segments large enough for them, large_plan): a unit whose
            -- copy came back to the top, or one with at least c_large of such
            -- segments.
            large_plan(l_item, p_ts, l_main, l_chunks, l_lneed);
            l_fit := l_system AND l_main > 0;
            l_large := l_fit AND (NVL(l_was, '-') = 'MOVED' OR l_main >= c_large);
            IF l_large THEN
                l_fresh := fresh_bytes(p_ts);
                IF l_was = 'MOVED' THEN
                    -- Three moves in a row that add no whole stretch end it.
                    l_stale := 0;
                    LOOP
                        EXIT WHEN l_fresh >= l_chunks OR l_stale >= 3 OR stop_now(p_ts);
                        l_maker := room_maker(p_ts, l_free, l_item);
                        EXIT WHEN l_maker IS NULL;
                        say(epfpg.epf_log.c_info, 'MAKING_ROOM',
                            l_owner || '.' || l_name || ' came back to the top after its move; to move lower with 64 MB '
                            || 'extents it needs about ' || b(l_chunks) || ' in whole 64 MB stretches, and ' || p_ts
                            || ' has ' || b(l_fresh) || ': a table with free space inside it moves first');
                        l_last := l_fresh;
                        move_unit(p_ts, l_maker, NULL);
                        l_free := free_bytes(p_ts);
                        l_fresh := fresh_bytes(p_ts);
                        l_stale := CASE WHEN l_fresh > l_last THEN 0 ELSE l_stale + 1 END;
                    END LOOP;
                    EXIT WHEN g_stopped;
                END IF;
                l_large := l_fresh >= l_chunks AND l_free >= l_lneed;
            ELSIF l_was = 'MOVED' THEN
                -- Uniform extents, or no segment large enough for extents of
                -- c_chunk: room as much as it needs once more.
                l_target := l_free + l_need;
                LOOP
                    EXIT WHEN l_free >= l_target OR stop_now(p_ts);
                    l_maker := room_maker(p_ts, l_free, l_item, l_target - l_free);
                    EXIT WHEN l_maker IS NULL;
                    say(epfpg.epf_log.c_info, 'MAKING_ROOM',
                        l_owner || '.' || l_name || ' (about ' || b(l_need) || ') came back to the top after its move, '
                        || 'with ' || b(l_free) || ' free below: a table with free space inside it moves first');
                    move_unit(p_ts, l_maker, NULL);
                    l_free := free_bytes(p_ts);
                END LOOP;
                EXIT WHEN g_stopped;
            END IF;
            -- A stop requested meanwhile (while tables moved to make room)
            -- ends the compaction before this move.
            EXIT WHEN stop_now(p_ts);
            -- A unit that came back moves again with extents of c_chunk when it
            -- can (l_fit), and as usual otherwise, when it fits.
            IF l_was = 'MOVED' AND NOT l_large AND (l_fit OR l_need > l_free) THEN
                l_why := CASE WHEN l_fit AND l_fresh < l_chunks
                              THEN 'about ' || b(l_chunks) || ' in whole 64 MB stretches needed to move it lower with '
                                   || '64 MB extents, ' || b(l_fresh) || ' there'
                              WHEN l_fit
                              THEN 'about ' || b(l_lneed) || ' needed to move it lower with 64 MB extents, ' || b(l_free)
                                   || ' free'
                              ELSE 'about ' || b(l_need) || ' needed to move it lower, ' || b(l_free) || ' free' END;
                UPDATE epfpg.epf_reclaim_object
                   SET detail = 'holds the top again after its move: ' || l_why
                 WHERE run_id = g_run.run_id AND item_id = l_item;
                COMMIT;
                l_done(l_file) := TRUE;
                file_done(l_file, l_owner, l_name, 'moved; ' || l_why);
                CONTINUE;
            END IF;
            IF NOT l_large AND NVL(l_was, '-') <> 'MOVED' AND l_need > l_free THEN
                LOOP
                    EXIT WHEN l_need <= l_free OR stop_now(p_ts);
                    l_maker := room_maker(p_ts, l_free, l_item, l_need - l_free);
                    EXIT WHEN l_maker IS NULL;
                    say(epfpg.epf_log.c_info, 'MAKING_ROOM',
                        l_owner || '.' || l_name || ' needs about ' || b(l_need) || ' and ' || p_ts || ' has ' || b(l_free)
                        || ' free: a table with free space inside it moves first');
                    move_unit(p_ts, l_maker, NULL);
                    l_free := free_bytes(p_ts);
                END LOOP;
                EXIT WHEN g_stopped;
                IF l_need > l_free THEN
                    l_free := l_free + grow_file(p_ts, l_file, l_need - l_free);
                END IF;
                EXIT WHEN stop_now(p_ts);
            END IF;
            move_unit(p_ts, l_item, l_file, l_large);
            SELECT COUNT(*), NVL(SUM(bytes), 0)
              INTO l_moved, l_mbytes
              FROM epfpg.epf_reclaim_object
             WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT') AND source_ts = p_ts AND move_status = 'MOVED';
            epfpg.epf_log.step_progress(l_moved, l_mbytes);
        END LOOP;
        l_status := CASE WHEN g_stopped THEN 'SKIPPED' ELSE 'STAYED' END;
        l_why := CASE WHEN g_stopped THEN 'not moved: stop requested'
                      ELSE 'not moved: below where its datafile stopped (FILE_DONE)' END;
        UPDATE epfpg.epf_reclaim_object
           SET move_status = l_status, detail = l_why
         WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT') AND source_ts = p_ts AND move_status = 'PENDING';
        COMMIT;
        l_freed := trim_ts(p_ts, 0, FALSE);
        SELECT COUNT(*) INTO l_moved
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT') AND source_ts = p_ts AND move_status = 'MOVED';
        say(epfpg.epf_log.c_ok, 'COMPACT_DONE', p_ts || ': ' || l_moved || ' of ' || l_units || ' tables moved; datafiles '
                                                || b(l_start) || ' -> ' || b(ts_bytes(p_ts))
                                                || ' before the indexes are rebuilt');
        epfpg.epf_log.step_end('DONE', l_moved || ' of ' || l_units || ' tables moved');
    END compact_ts;

    -- ------------------------------------------------------------------
    -- Restore path
    -- ------------------------------------------------------------------

    -- Rebuilds released index p_item in its tablespace. p_frozen: the
    -- datafiles of the run cannot grow by themselves yet; when the free space
    -- of a tablespace of the run is short, its datafiles first grow within
    -- their room (grow_ts), and a rebuild that still does not fit returns
    -- NO_ROOM, to be tried again once the growth settings are restored.
    -- Returns REBUILT, VALID (usable already: only marked), GONE, NO_ROOM or
    -- FAILED (the index stays unusable; an error).
    FUNCTION rebuild_index(p_item IN NUMBER, p_frozen IN BOOLEAN) RETURN VARCHAR2 IS
        l_owner   VARCHAR2(128);
        l_name    VARCHAR2(128);
        l_source  VARCHAR2(128);
        l_est     NUMBER;
        l_status  VARCHAR2(8);
        l_ts      VARCHAR2(128);
        l_in_run  NUMBER;
        l_alloc   VARCHAR2(9);
        l_uniform NUMBER;
        l_need    NUMBER;
        l_free    NUMBER;
        l_added   NUMBER := 0;
        l_bytes   NUMBER;
        l_code    NUMBER := 0;
        l_msg     VARCHAR2(4000);
        l_initial NUMBER;
        l_note    VARCHAR2(1000);
        l_kept    VARCHAR2(1000);
        l_clause  VARCHAR2(100);
    BEGIN
        SELECT owner, object_name, source_ts, NVL(est_bytes, 0)
          INTO l_owner, l_name, l_source, l_est
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id AND item_id = p_item;
        SELECT MAX(status), MAX(tablespace_name), MAX(initial_extent)
          INTO l_status, l_ts, l_initial
          FROM dba_indexes
         WHERE owner = l_owner AND index_name = l_name;
        IF l_status IS NULL THEN
            UPDATE epfpg.epf_reclaim_object
               SET move_status = 'FAILED', detail = 'the index no longer exists', ended_at = epfpg.epf_util.now_ts
             WHERE run_id = g_run.run_id AND item_id = p_item;
            COMMIT;
            say(epfpg.epf_log.c_warn, 'INDEX_GONE', l_owner || '.' || l_name || ' no longer exists',
                p_owner => l_owner, p_object => l_name);
            RETURN 'GONE';
        ELSIF l_status = 'VALID' THEN
            UPDATE epfpg.epf_reclaim_object
               SET move_status = 'REBUILT', ended_at = epfpg.epf_util.now_ts,
                   detail = SUBSTR(NVL2(detail, detail || '; ', NULL) || 'usable already', 1, 4000)
             WHERE run_id = g_run.run_id AND item_id = p_item;
            COMMIT;
            RETURN 'VALID';
        END IF;
        l_ts := NVL(l_ts, l_source);
        IF p_frozen THEN
            SELECT COUNT(*) INTO l_in_run
              FROM epfpg.epf_reclaim_ts
             WHERE run_id = g_run.run_id AND tablespace_name = l_ts;
            SELECT allocation_type, initial_extent INTO l_alloc, l_uniform
              FROM dba_tablespaces
             WHERE tablespace_name = l_ts;
            l_need := l_est + extent_for(l_est, l_alloc, l_uniform);
            l_free := free_bytes(l_ts);
            IF l_in_run > 0 AND l_need > l_free THEN
                l_added := grow_ts(l_ts, l_need - l_free);
            END IF;
        END IF;
        BEGIN
            g_reset := SYS.ODCIVARCHAR2LIST();
            l_clause := initial_clause(l_initial, initial_need(l_owner, l_name, 'INDEX', l_est), 'INITIAL', l_name, l_note);
            ddl('ALTER INDEX ' || qn(l_owner, l_name) || ' REBUILD TABLESPACE ' || q(l_ts) || l_clause);
        EXCEPTION
            WHEN OTHERS THEN
                l_code := SQLCODE;
                l_msg := SQLERRM;
        END;
        IF l_code = 0 THEN
            SELECT NVL(SUM(bytes), 0)
              INTO l_bytes
              FROM dba_segments
             WHERE owner = l_owner AND segment_name = l_name AND segment_type = 'INDEX';
            l_kept := CASE WHEN l_note IS NOT NULL THEN initial_kept(l_owner) END;
            UPDATE epfpg.epf_reclaim_object
               SET move_status = 'REBUILT', after_bytes = l_bytes, last_ora = NULL, ended_at = epfpg.epf_util.now_ts,
                   detail = CASE WHEN l_note IS NOT NULL
                                 THEN SUBSTR(NVL2(detail, detail || '; ', NULL) || l_note || ' set to 64 KB'
                                             || CASE WHEN l_kept IS NOT NULL THEN '; Oracle kept ' || l_kept END, 1, 4000)
                                 ELSE detail END
             WHERE run_id = g_run.run_id AND item_id = p_item;
            COMMIT;
            track_peak(l_ts);
            say(epfpg.epf_log.c_info, 'INDEX_REBUILT', l_owner || '.' || l_name || ': ' || b(l_bytes) || ' in ' || l_ts
                                                       || CASE WHEN l_added > 0 THEN ' (it first grew by ' || b(l_added)
                                                                                     || ' to fit it)' END
                                                       || CASE WHEN l_note IS NOT NULL THEN ' (' || l_note
                                                                                       || ' set to 64 KB)' END,
                p_owner => l_owner, p_object => l_name, p_bytes => l_bytes);
            IF l_kept IS NOT NULL THEN
                say(epfpg.epf_log.c_info, 'INITIAL_KEPT',
                    l_owner || '.' || l_name || ': the rebuild asked for INITIAL 64 KB, but Oracle kept ' || l_kept,
                    p_owner => l_owner, p_object => l_name);
            END IF;
            RETURN 'REBUILT';
        ELSIF p_frozen AND is_space_error(l_code) THEN
            say(epfpg.epf_log.c_info, 'INDEX_NO_ROOM',
                l_owner || '.' || l_name || ' (about ' || b(l_est) || ') does not fit within the room of ' || l_ts
                || ': rebuilt once the growth settings of the datafiles are restored (' || l_msg || ')',
                p_owner => l_owner, p_object => l_name, p_ora => ABS(l_code));
            RETURN 'NO_ROOM';
        END IF;
        UPDATE epfpg.epf_reclaim_object
           SET move_status = 'FAILED', last_ora = ABS(l_code), detail = SUBSTR(l_msg, 1, 4000),
               ended_at = epfpg.epf_util.now_ts
         WHERE run_id = g_run.run_id AND item_id = p_item;
        COMMIT;
        say(epfpg.epf_log.c_error, 'INDEX_REBUILD_FAILED',
            l_owner || '.' || l_name || ' stays unusable: ' || l_msg || '; reclaim --restore rebuilds it',
            p_owner => l_owner, p_object => l_name, p_ora => ABS(l_code));
        RETURN 'FAILED';
    END rebuild_index;

    -- Before the rebuilds: each tablespace of the run whose free space is
    -- short of what its rebuilds need (their estimates, each with the extent
    -- it may need besides, plus the largest once more: the free space is
    -- scattered, and a rebuild needs extents of its size) grows once, within
    -- its room. A rebuild that still does not fit grows it again
    -- (rebuild_index).
    PROCEDURE grow_for_rebuilds IS
        l_need  NUMBER;
        l_large NUMBER;
        l_count PLS_INTEGER;
        l_free  NUMBER;
        l_added NUMBER;
    BEGIN
        FOR t IN (SELECT r.tablespace_name, d.allocation_type, d.initial_extent
                    FROM epfpg.epf_reclaim_ts r
                    JOIN dba_tablespaces d ON d.tablespace_name = r.tablespace_name
                   WHERE r.run_id = g_run.run_id
                   ORDER BY r.tablespace_name) LOOP
            l_need := 0;
            l_large := 0;
            l_count := 0;
            FOR i IN (SELECT NVL(est_bytes, 0) AS est
                        FROM epfpg.epf_reclaim_object
                       WHERE run_id = g_run.run_id AND unit_type = 'INDEX' AND move_status IN ('RELEASED', 'FAILED')
                         AND source_ts = t.tablespace_name) LOOP
                l_need := l_need + i.est + extent_for(i.est, t.allocation_type, t.initial_extent);
                l_large := GREATEST(l_large, i.est);
                l_count := l_count + 1;
            END LOOP;
            l_free := free_bytes(t.tablespace_name);
            IF l_count > 0 AND l_need + l_large > l_free THEN
                l_added := grow_ts(t.tablespace_name, l_need + l_large - l_free,
                                   'the ' || l_count || ' index rebuilds in it (about ' || b(l_need) || ')');
            END IF;
        END LOOP;
    END grow_for_rebuilds;

    -- Rebuilds the indexes the run released or adopted (RELEASED, FAILED),
    -- the largest first, while the datafiles of the run cannot grow by
    -- themselves (within their room: grow_for_rebuilds, then rebuild_index).
    -- The indexes that do not fit are rebuilt after the growth settings are
    -- restored (restore_files), with resumable space allocation
    -- (resumable_timeout_s): a rebuild then waits for space instead of
    -- failing.
    PROCEDURE rebuild_indexes(p_rebuilt OUT PLS_INTEGER, p_failed OUT PLS_INTEGER) IS
        TYPE t_ids IS TABLE OF NUMBER;
        l_ids     t_ids;
        l_later   t_ids := t_ids();
        l_result  VARCHAR2(10);
        l_files   PLS_INTEGER;
        l_timeout NUMBER := NVL(epfpg.epf_util.setting_num('resumable_timeout_s'), 0);
    BEGIN
        p_rebuilt := 0;
        p_failed := 0;
        SELECT item_id
          BULK COLLECT INTO l_ids
          FROM epfpg.epf_reclaim_object
         WHERE run_id = g_run.run_id AND unit_type = 'INDEX' AND move_status IN ('RELEASED', 'FAILED')
         ORDER BY est_bytes DESC, item_id;
        grow_for_rebuilds;
        FOR k IN 1 .. l_ids.COUNT LOOP
            l_result := rebuild_index(l_ids(k), TRUE);
            IF l_result = 'NO_ROOM' THEN
                l_later.EXTEND;
                l_later(l_later.COUNT) := l_ids(k);
            ELSIF l_result = 'REBUILT' THEN
                p_rebuilt := p_rebuilt + 1;
            ELSIF l_result = 'FAILED' THEN
                p_failed := p_failed + 1;
            END IF;
        END LOOP;
        IF l_later.COUNT > 0 THEN
            say(epfpg.epf_log.c_warn, 'INDEXES_NEED_GROWTH',
                l_later.COUNT || ' indexes do not fit within the room of their datafiles: the growth settings are '
                || 'restored first, and the datafiles may grow above their size at the start of the run');
            restore_files(l_files);
            IF l_timeout > 0 THEN
                EXECUTE IMMEDIATE 'ALTER SESSION ENABLE RESUMABLE TIMEOUT ' || TRUNC(l_timeout) || ' NAME ''EPF '
                                  || epfpg.epf_util.run_label(g_run.run_id) || ' index rebuild''';
            END IF;
            FOR k IN 1 .. l_later.COUNT LOOP
                l_result := rebuild_index(l_later(k), FALSE);
                IF l_result = 'REBUILT' THEN
                    p_rebuilt := p_rebuilt + 1;
                ELSIF l_result = 'FAILED' THEN
                    p_failed := p_failed + 1;
                END IF;
            END LOOP;
            IF l_timeout > 0 THEN
                EXECUTE IMMEDIATE 'ALTER SESSION DISABLE RESUMABLE';
            END IF;
        END IF;
    END rebuild_indexes;

    -- Final resize of the run's tablespaces (highest block plus
    -- reclaim_margin_mb, when that is smaller). The compaction leaves no free
    -- space above the highest extents, so a tablespace whose datafiles cannot
    -- grow by themselves (none autoextensible) gets reclaim_margin_mb of free
    -- space back, its datafiles growing up to their size at the start of the
    -- run at most (R6); when that is not enough, a warning (FILE_NO_GROWTH):
    -- the application needs room to grow.
    PROCEDURE resize_all(p_message OUT VARCHAR2) IS
        l_freed NUMBER := 0;
        l_kept  NUMBER := 0;
        l_auto  NUMBER;
        l_free  NUMBER;
    BEGIN
        FOR t IN (SELECT tablespace_name FROM epfpg.epf_reclaim_ts WHERE run_id = g_run.run_id ORDER BY tablespace_name) LOOP
            l_freed := l_freed + trim_ts(t.tablespace_name, g_margin, TRUE);
            SELECT COUNT(CASE WHEN autoextensible = 'YES' THEN 1 END)
              INTO l_auto
              FROM dba_data_files
             WHERE tablespace_name = t.tablespace_name;
            IF l_auto = 0 THEN
                l_free := free_bytes(t.tablespace_name);
                IF l_free < g_margin THEN
                    l_kept := l_kept + grow_ts(t.tablespace_name, g_margin - l_free,
                                               'free space for the application (setting reclaim_margin_mb; no datafile '
                                               || 'of ' || t.tablespace_name || ' grows by itself)', 0);
                    l_free := free_bytes(t.tablespace_name);
                END IF;
                IF l_free < g_margin THEN
                    say(epfpg.epf_log.c_warn, 'FILE_NO_GROWTH',
                        t.tablespace_name || ': no datafile grows by itself, and ' || b(l_free) || ' is free after '
                        || 'the reclaim, less than setting reclaim_margin_mb (' || b(g_margin) || ') even at the size '
                        || 'the datafiles had at the start: the application needs room to grow (add a datafile, resize '
                        || 'one or turn autoextend on)');
                END IF;
            END IF;
        END LOOP;
        p_message := b(GREATEST(l_freed - l_kept, 0)) || ' given back'
                     || CASE WHEN l_kept > 0 THEN ' (' || b(l_kept) || ' kept free in tablespaces that cannot grow by '
                                                  || 'themselves)' END;
    END resize_all;

    -- Recompiles, per owner, the objects invalid now that were valid in the
    -- baseline (DBMS_UTILITY.COMPILE_SCHEMA, invalid objects only).
    PROCEDURE recompile(p_message OUT VARCHAR2) IS
        l_owners PLS_INTEGER := 0;
    BEGIN
        FOR o IN (SELECT DISTINCT d.owner
                    FROM dba_objects d
                   WHERE d.status = 'INVALID' AND d.owner <> 'EPFPG'
                     AND d.owner IN (SELECT u.username FROM dba_users u WHERE u.oracle_maintained = 'N')
                     AND NOT EXISTS (SELECT 1 FROM epfpg.epf_object_baseline x
                                      WHERE x.run_id = g_run.run_id AND x.object_type = 'INVALID'
                                        AND x.owner = d.owner AND x.name = d.object_name AND x.detail = d.object_type)
                   ORDER BY d.owner) LOOP
            BEGIN
                DBMS_UTILITY.COMPILE_SCHEMA(schema => o.owner, compile_all => FALSE);
                l_owners := l_owners + 1;
                say(epfpg.epf_log.c_info, 'RECOMPILED', 'Objects of ' || o.owner
                                                        || ' invalid since the baseline recompiled');
            EXCEPTION
                WHEN OTHERS THEN
                    say(epfpg.epf_log.c_warn, 'RECOMPILE_FAILED', 'Objects of ' || o.owner || ': ' || SQLERRM,
                        p_ora => ABS(SQLCODE));
            END;
        END LOOP;
        p_message := l_owners || ' schemas recompiled';
    END recompile;

    -- The state after the reclaim, before the accounts are unlocked
    -- (EPF_OBJECT_BASELINE, compared by the report): c_fingerprint again
    -- (detail_after; NULL for an object that no longer exists), the objects
    -- invalid now that were not before (NEW_INVALID), and the row counts of
    -- the tables counted at the baseline.
    PROCEDURE verify(p_message OUT VARCHAR2) IS
        l_count   NUMBER;
        l_tables  PLS_INTEGER := 0;
        l_objects PLS_INTEGER := 0;
        l_invalid PLS_INTEGER;
    BEGIN
        UPDATE epfpg.epf_object_baseline
           SET detail_after = NULL
         WHERE run_id = g_run.run_id AND object_type IN ('INDEX', 'CONSTRAINT', 'TABLE', 'LOB');
        FOR f IN c_fingerprint(g_run.run_id) LOOP
            UPDATE epfpg.epf_object_baseline
               SET detail_after = SUBSTR(f.fp, 1, 4000)
             WHERE run_id = g_run.run_id AND object_type = f.object_type AND owner = f.owner AND name = f.name
               AND NVL(table_name, '-') = NVL(f.table_name, '-');
            l_objects := l_objects + SQL%ROWCOUNT;
        END LOOP;
        DELETE FROM epfpg.epf_object_baseline WHERE run_id = g_run.run_id AND object_type = 'NEW_INVALID';
        INSERT INTO epfpg.epf_object_baseline (run_id, object_type, owner, name, detail)
        SELECT g_run.run_id, 'NEW_INVALID', d.owner, d.object_name, d.object_type
          FROM dba_objects d
         WHERE d.status = 'INVALID' AND d.owner <> 'EPFPG'
           AND d.owner IN (SELECT u.username FROM dba_users u WHERE u.oracle_maintained = 'N')
           AND NOT EXISTS (SELECT 1 FROM epfpg.epf_object_baseline x
                            WHERE x.run_id = g_run.run_id AND x.object_type = 'INVALID'
                              AND x.owner = d.owner AND x.name = d.object_name AND x.detail = d.object_type);
        l_invalid := SQL%ROWCOUNT;
        COMMIT;
        FOR t IN (SELECT owner, name
                    FROM epfpg.epf_object_baseline
                   WHERE run_id = g_run.run_id AND object_type = 'TABLE' AND row_count IS NOT NULL
                   ORDER BY owner, name) LOOP
            BEGIN
                l_count := row_count(t.owner, t.name);
            EXCEPTION
                WHEN OTHERS THEN
                    l_count := NULL;
                    say(epfpg.epf_log.c_warn, 'COUNT_FAILED', t.owner || '.' || t.name || ' could not be counted: '
                                                              || SQLERRM, p_owner => t.owner, p_object => t.name,
                        p_ora => ABS(SQLCODE));
            END;
            UPDATE epfpg.epf_object_baseline
               SET row_count_after = l_count
             WHERE run_id = g_run.run_id AND object_type = 'TABLE' AND owner = t.owner AND name = t.name;
            COMMIT;
            l_tables := l_tables + 1;
        END LOOP;
        p_message := l_objects || ' objects compared, ' || l_tables || ' tables counted, ' || l_invalid
                     || ' new invalid objects';
    END verify;

    -- Unlocks the accounts locked by this run (p_all 'Y': by any reclaim)
    -- and not unlocked yet, unless their status before the lock was locked.
    PROCEDURE unlock_accounts(p_all IN VARCHAR2, p_count OUT PLS_INTEGER) IS
        l_status VARCHAR2(32);
    BEGIN
        p_count := 0;
        FOR a IN (SELECT run_id, username, original_status
                    FROM epfpg.epf_account_action
                   WHERE locked_at IS NOT NULL AND unlocked_at IS NULL
                     AND (p_all = 'Y' OR run_id = g_run.run_id)
                   ORDER BY run_id, username) LOOP
            SELECT MAX(account_status) INTO l_status FROM dba_users WHERE username = a.username;
            IF l_status IS NOT NULL AND INSTR(a.original_status, 'LOCKED') = 0 AND INSTR(l_status, 'LOCKED') > 0 THEN
                EXECUTE IMMEDIATE 'ALTER USER ' || q(a.username) || ' ACCOUNT UNLOCK';
                say(epfpg.epf_log.c_ok, 'ACCOUNT_UNLOCKED', a.username || ' unlocked (it was ' || a.original_status
                                                            || CASE WHEN a.run_id <> g_run.run_id
                                                                    THEN ', locked by ' || epfpg.epf_util.run_label(a.run_id)
                                                               END || ')');
            END IF;
            UPDATE epfpg.epf_account_action
               SET unlocked_at = epfpg.epf_util.now_ts
             WHERE run_id = a.run_id AND username = a.username;
            COMMIT;
            p_count := p_count + 1;
        END LOOP;
    END unlock_accounts;

    -- End values of the run's tablespaces (EPF_RECLAIM_TS) and the result
    -- events; datafiles at POST_RECLAIM.
    PROCEDURE finish_ts IS
        l_end    NUMBER;
        l_hwm    NUMBER;
        l_seg    NUMBER;
        l_moved  NUMBER;
        l_bad    NUMBER;
        l_units  NUMBER;
        l_status VARCHAR2(20);
    BEGIN
        snap_files('POST_RECLAIM');
        FOR t IN (SELECT tablespace_name, start_bytes, status
                    FROM epfpg.epf_reclaim_ts
                   WHERE run_id = g_run.run_id
                   ORDER BY tablespace_name) LOOP
            SELECT NVL(SUM(bytes), 0), NVL(SUM(hwm_bytes), 0)
              INTO l_end, l_hwm
              FROM epfpg.epf_file_snap
             WHERE run_id = g_run.run_id AND phase = 'POST_RECLAIM' AND tablespace_name = t.tablespace_name;
            SELECT NVL(SUM(bytes), 0) INTO l_seg FROM dba_segments WHERE tablespace_name = t.tablespace_name;
            SELECT COUNT(CASE WHEN move_status = 'MOVED' THEN 1 END),
                   COUNT(CASE WHEN move_status IN ('NO_ROOM', 'FAILED', 'SKIPPED') THEN 1 END), COUNT(*)
              INTO l_moved, l_bad, l_units
              FROM epfpg.epf_reclaim_object
             WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT') AND source_ts = t.tablespace_name;
            l_status := CASE WHEN t.status = 'FAILED' THEN 'FAILED'
                             WHEN l_bad > 0 THEN 'PARTIAL'
                             WHEN l_moved = 0 AND l_end >= t.start_bytes THEN 'UNCHANGED'
                             ELSE 'COMPACTED' END;
            UPDATE epfpg.epf_reclaim_ts
               SET end_bytes = l_end, end_hwm_bytes = l_hwm, end_segment_bytes = l_seg, moved_count = l_moved,
                   status = l_status, peak_bytes = GREATEST(NVL(peak_bytes, 0), start_bytes, l_end)
             WHERE run_id = g_run.run_id AND tablespace_name = t.tablespace_name;
            COMMIT;
            say(epfpg.epf_log.c_ok, 'RECLAIM_RESULT',
                t.tablespace_name || ' ' || l_status || ': datafiles ' || b(t.start_bytes) || ' -> ' || b(l_end) || ' ('
                || b(GREATEST(t.start_bytes - l_end, 0)) || ' given back), segments ' || b(l_seg) || ', ' || l_moved
                || ' of ' || l_units || ' tables moved',
                p_bytes => t.start_bytes - l_end);
        END LOOP;
    END finish_ts;

    -- The restore path, run whenever the run changed something and also for
    -- mode RESTORE: tables not reached are SKIPPED; index rebuilds (with
    -- p_adopt, every index a compaction left released) while the datafiles
    -- still cannot grow by themselves; datafile growth settings; final
    -- resize; recompilation and the state after (verify), when the run has a
    -- baseline; accounts (p_all 'Y': every account a reclaim left locked);
    -- end values. Every step runs even when an earlier one fails.
    PROCEDURE restore_path(p_adopt IN BOOLEAN, p_all IN VARCHAR2, p_ok IN OUT BOOLEAN) IS
        l_count    PLS_INTEGER;
        l_failed   PLS_INTEGER;
        l_message  VARCHAR2(400);
        l_baseline NUMBER;
        l_why      VARCHAR2(100) := CASE WHEN g_stopped THEN 'not moved: stop requested'
                                       WHEN g_mode = 'RESTORE' THEN 'not moved: the compaction was interrupted'
                                       ELSE 'not moved: the compaction ended after an error' END;
    BEGIN
        UPDATE epfpg.epf_reclaim_object
           SET move_status = 'SKIPPED', detail = l_why
         WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT') AND move_status = 'PENDING';
        COMMIT;
        BEGIN
            epfpg.epf_log.step_start('REBUILD_INDEXES');
            IF p_adopt THEN
                add_pending_indexes;
            END IF;
            rebuild_indexes(l_count, l_failed);
            epfpg.epf_log.step_end(CASE WHEN l_failed > 0 THEN 'FAILED' ELSE 'DONE' END,
                                   l_count || ' indexes rebuilt' || CASE WHEN l_failed > 0 THEN ', ' || l_failed
                                                                                               || ' failed' END);
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                p_ok := FALSE;
        END;
        BEGIN
            epfpg.epf_log.step_start('RESTORE_FILES');
            restore_files(l_count);
            epfpg.epf_log.step_end('DONE', l_count || ' datafile settings restored');
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                p_ok := FALSE;
        END;
        BEGIN
            epfpg.epf_log.step_start('RESIZE');
            resize_all(l_message);
            epfpg.epf_log.step_end('DONE', l_message);
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                p_ok := FALSE;
        END;
        SELECT COUNT(*) INTO l_baseline FROM epfpg.epf_object_baseline WHERE run_id = g_run.run_id AND ROWNUM = 1;
        IF l_baseline > 0 THEN
            BEGIN
                epfpg.epf_log.step_start('RECOMPILE');
                recompile(l_message);
                epfpg.epf_log.step_end('DONE', l_message);
            EXCEPTION
                WHEN OTHERS THEN
                    fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                    p_ok := FALSE;
            END;
            BEGIN
                epfpg.epf_log.step_start('VERIFY');
                verify(l_message);
                epfpg.epf_log.step_end('DONE', l_message);
            EXCEPTION
                WHEN OTHERS THEN
                    fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                    p_ok := FALSE;
            END;
        END IF;
        BEGIN
            epfpg.epf_log.step_start('UNLOCK_ACCOUNTS');
            unlock_accounts(p_all, l_count);
            epfpg.epf_log.step_end('DONE', l_count || ' accounts restored');
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                p_ok := FALSE;
        END;
        BEGIN
            finish_ts;
        EXCEPTION
            WHEN OTHERS THEN
                say(epfpg.epf_log.c_error, 'RESULT_FAILED', 'End values not recorded: ' || SQLERRM,
                    p_ora => ABS(SQLCODE));
                p_ok := FALSE;
        END;
    END restore_path;

    -- Waits while another session still runs a reclaim on the database (SYS,
    -- module EPF, a run's client identifier, ACTIVE). Only a worker whose
    -- client is gone can be one: its call goes on until it ends, and a
    -- restore or a new compaction beside it would undo or redo its work.
    -- Reported when found and every 10 minutes; a stop request ends the wait
    -- with ORA-20162, before any change.
    PROCEDURE wait_for_workers IS
        l_own    NUMBER := TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'));
        l_found  BOOLEAN;
        l_what   VARCHAR2(400);
        l_waited NUMBER := 0;
    BEGIN
        LOOP
            l_found := FALSE;
            FOR s IN (SELECT sid, serial#, client_identifier, action
                        FROM v$session
                       WHERE sid <> l_own AND username = 'SYS' AND module = 'EPF'
                         AND client_identifier LIKE 'EPF:%' AND status = 'ACTIVE'
                       ORDER BY logon_time) LOOP
                l_found := TRUE;
                l_what := 'session ' || s.sid || ',' || s.serial# || ' (' || s.client_identifier || ', ' || s.action || ')';
                EXIT;
            END LOOP;
            EXIT WHEN NOT l_found;
            IF l_waited = 0 THEN
                say(epfpg.epf_log.c_warn, 'WORKER_RUNNING',
                    'Another reclaim still runs on the database, ' || l_what || ': its client is gone, but its call goes '
                    || 'on. This ' || CASE g_mode WHEN 'COMPACT' THEN 'compaction' ELSE 'restore' END
                    || ' waits for it to end; a stop request ends the wait.');
            ELSIF MOD(l_waited, 600) = 0 THEN
                say(epfpg.epf_log.c_info, 'WORKER_RUNNING', 'Still running after ' || (l_waited / 60) || ' min: ' || l_what);
            END IF;
            IF epfpg.epf_control.stop_requested(g_run.run_id) THEN
                RAISE_APPLICATION_ERROR(-20162, 'Stop requested while another reclaim still runs (' || l_what
                                                || '); nothing was changed. Once it has ended: epf_purge.bat reclaim '
                                                || '--restore.');
            END IF;
            DBMS_LOCK.SLEEP(10);
            l_waited := l_waited + 10;
        END LOOP;
        IF l_waited > 0 THEN
            say(epfpg.epf_log.c_info, 'WORKER_ENDED', 'The other reclaim ended after about ' || CEIL(l_waited / 60)
                                                      || ' min of waiting');
        END IF;
    END wait_for_workers;

    -- Restores what earlier reclaims left pending before a new compaction:
    -- locked accounts, datafile growth settings, indexes rebuilt outside the
    -- tool since (marked). Indexes still released are adopted by the
    -- assessment.
    PROCEDURE prepare(p_message OUT VARCHAR2) IS
        l_accounts PLS_INTEGER;
        l_files    PLS_INTEGER;
    BEGIN
        unlock_accounts('Y', l_accounts);
        restore_files(l_files);
        UPDATE epfpg.epf_reclaim_object o
           SET move_status = 'REBUILT', ended_at = epfpg.epf_util.now_ts,
               detail = SUBSTR(NVL2(detail, detail || '; ', NULL) || 'usable again, rebuilt outside the tool', 1, 4000)
         WHERE o.unit_type = 'INDEX' AND o.move_status IN ('RELEASED', 'FAILED') AND o.run_id <> g_run.run_id
           AND EXISTS (SELECT 1 FROM dba_indexes i
                        WHERE i.owner = o.owner AND i.index_name = o.object_name AND i.status = 'VALID');
        COMMIT;
        p_message := l_accounts || ' accounts and ' || l_files || ' datafile settings left by earlier reclaims restored';
    END prepare;

    -- Tablespaces of a RESTORE run: those holding indexes a compaction left
    -- released and those whose datafile settings are not restored.
    PROCEDURE restore_targets IS
    BEGIN
        INSERT INTO epfpg.epf_reclaim_ts (run_id, tablespace_name, bigfile, block_size, file_count, status,
                                          start_bytes, growth_bytes)
        SELECT g_run.run_id, t.tablespace_name, t.bigfile, t.block_size,
               (SELECT COUNT(*) FROM dba_data_files d WHERE d.tablespace_name = t.tablespace_name), 'ASSESSED',
               (SELECT NVL(SUM(d.bytes), 0) FROM dba_data_files d WHERE d.tablespace_name = t.tablespace_name), 0
          FROM dba_tablespaces t
         WHERE t.tablespace_name IN (SELECT o.source_ts
                                       FROM epfpg.epf_reclaim_object o
                                      WHERE o.unit_type = 'INDEX' AND o.move_status IN ('RELEASED', 'FAILED')
                                        AND o.run_id IN (SELECT r.run_id FROM epfpg.epf_run r
                                                          WHERE r.reclaim_mode IN ('COMPACT', 'RESTORE'))
                                     UNION
                                     SELECT d.tablespace_name
                                       FROM dba_data_files d
                                       JOIN epfpg.epf_instance_change c ON c.file_id = d.file_id
                                      WHERE c.item = c_change AND c.restored_at IS NULL)
           AND NOT EXISTS (SELECT 1 FROM epfpg.epf_reclaim_ts r
                            WHERE r.run_id = g_run.run_id AND r.tablespace_name = t.tablespace_name);
        COMMIT;
    END restore_targets;

    -- The account locks, the baseline (taken once the accounts are locked
    -- and their sessions gone, so that no write changes the row counts
    -- afterwards), the index release, the datafiles stopped and the
    -- compaction of each tablespace (the largest first). A failure ends the
    -- compaction; the caller then runs the restore path.
    PROCEDURE compact_all(p_ok IN OUT BOOLEAN) IS
        l_message VARCHAR2(400);
    BEGIN
        BEGIN
            epfpg.epf_log.step_start('LOCK_ACCOUNTS');
            lock_accounts(l_message);
            epfpg.epf_log.step_end('DONE', l_message);
            epfpg.epf_log.step_start('BASELINE');
            baseline(l_message);
            epfpg.epf_log.step_end('DONE', l_message);
            epfpg.epf_log.step_start('RELEASE_INDEXES');
            release_indexes(l_message);
            epfpg.epf_log.step_end('DONE', l_message);
            epfpg.epf_log.step_start('FREEZE_FILES');
            freeze_all(l_message);
            epfpg.epf_log.step_end('DONE', l_message);
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                p_ok := FALSE;
                RETURN;
        END;
        FOR t IN (SELECT tablespace_name FROM epfpg.epf_reclaim_ts WHERE run_id = g_run.run_id
                   ORDER BY start_bytes DESC, tablespace_name) LOOP
            EXIT WHEN g_stopped;
            BEGIN
                compact_ts(t.tablespace_name);
            EXCEPTION
                WHEN OTHERS THEN
                    fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                    UPDATE epfpg.epf_reclaim_ts
                       SET status = 'FAILED'
                     WHERE run_id = g_run.run_id AND tablespace_name = t.tablespace_name;
                    COMMIT;
                    p_ok := FALSE;
                    EXIT;
            END;
        END LOOP;
    END compact_all;

    -- Checks the session and loads the run.
    PROCEDURE init(p_run_id IN NUMBER, p_mode IN VARCHAR2, p_tablespaces IN VARCHAR2) IS
        l_empty epfpg.epf_run%ROWTYPE;
        l_rac   VARCHAR2(3);
    BEGIN
        g_run := l_empty;
        IF SYS_CONTEXT('USERENV', 'SESSION_USER') <> 'SYS' THEN
            RAISE_APPLICATION_ERROR(-20160, 'Run the reclaim as SYS AS SYSDBA.');
        END IF;
        IF SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT' THEN
            RAISE_APPLICATION_ERROR(-20160, 'Connected to CDB$ROOT: connect to the PDB service.');
        END IF;
        SELECT parallel INTO l_rac FROM v$instance;
        IF l_rac = 'YES' THEN
            RAISE_APPLICATION_ERROR(-20160, 'Real Application Clusters: the reclaim runs on single-instance databases.');
        END IF;
        BEGIN
            SELECT * INTO g_run FROM epfpg.epf_run WHERE run_id = p_run_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20160, 'Run not found: ' || epfpg.epf_util.run_label(p_run_id));
        END;
        IF g_run.action <> 'RECLAIM' THEN
            RAISE_APPLICATION_ERROR(-20160, 'Run ' || epfpg.epf_util.run_label(p_run_id) || ' is a ' || g_run.action
                                            || ' run; expected RECLAIM.');
        END IF;
        IF NVL(epfpg.epf_log.current_run, -1) <> p_run_id THEN
            RAISE_APPLICATION_ERROR(-20160, 'This session is not bound to run ' || epfpg.epf_util.run_label(p_run_id)
                                            || ' (epf_control.enter).');
        END IF;
        g_mode := UPPER(TRIM(p_mode));
        IF g_mode IS NULL OR g_mode NOT IN ('ASSESS', 'COMPACT', 'RESTORE') THEN
            RAISE_APPLICATION_ERROR(-20161, 'Mode must be ASSESS, COMPACT or RESTORE, got: ' || p_mode);
        END IF;
        IF (g_run.dry_run = 'Y' AND g_mode <> 'ASSESS') OR (g_run.dry_run = 'N' AND g_mode = 'ASSESS') THEN
            RAISE_APPLICATION_ERROR(-20161, 'A dry run assesses (mode ASSESS) and an assessment is a dry run; run '
                                            || epfpg.epf_util.run_label(p_run_id) || ' has dry_run ' || g_run.dry_run);
        END IF;
        g_warnings := 0;
        g_errors := 0;
        g_stopped := FALSE;
        g_changed := FALSE;
        g_growth := GREATEST(NVL(epfpg.epf_util.setting_num('reclaim_growth_mb'), 0), 0) * c_mb;
        g_margin := GREATEST(NVL(epfpg.epf_util.setting_num('reclaim_margin_mb'), 64), 0) * c_mb;
        g_moves := GREATEST(NVL(epfpg.epf_util.setting_num('reclaim_unit_moves'), 3), 1);
        g_at_top.DELETE;
        g_features.DELETE;
        g_retries := GREATEST(NVL(epfpg.epf_util.setting_num('ddl_retries'), 3), 0);
        -- The test pause applies to one compaction: reading it sets it back to 0.
        g_pause := 0;
        IF g_mode = 'COMPACT' THEN
            g_pause := LEAST(GREATEST(TRUNC(NVL(epfpg.epf_util.setting_num('reclaim_test_pause_s'), 0)), 0), 600);
            IF g_pause > 0 THEN
                UPDATE epfpg.epf_setting SET value = '0' WHERE name = 'reclaim_test_pause_s';
                COMMIT;
            END IF;
        END IF;
        SELECT NVL(MAX(item_id), 0) INTO g_item FROM epfpg.epf_reclaim_object WHERE run_id = p_run_id;
        UPDATE epfpg.epf_run
           SET reclaim_mode = NVL(reclaim_mode, g_mode),
               reclaim_scope = NVL(reclaim_scope, SUBSTR(UPPER(REPLACE(p_tablespaces, ' ')), 1, 4000))
         WHERE run_id = p_run_id;
        COMMIT;
        SELECT * INTO g_run FROM epfpg.epf_run WHERE run_id = p_run_id;
        epfpg.epf_log.set_phase(c_phase);
        EXECUTE IMMEDIATE 'ALTER SESSION SET ddl_lock_timeout = '
                          || TO_CHAR(TRUNC(NVL(epfpg.epf_util.setting_num('ddl_lock_timeout_s'), 30)));
    END init;

    PROCEDURE plan_steps IS
    BEGIN
        IF g_mode = 'COMPACT' THEN
            epfpg.epf_log.step_plan('PREPARE');
        END IF;
        epfpg.epf_log.step_plan('ASSESS');
        IF g_mode = 'COMPACT' THEN
            FOR s IN (SELECT column_value AS step_code
                        FROM TABLE(SYS.ODCIVARCHAR2LIST('LOCK_ACCOUNTS', 'BASELINE', 'RELEASE_INDEXES',
                                                        'FREEZE_FILES'))) LOOP
                epfpg.epf_log.step_plan(s.step_code);
            END LOOP;
        END IF;
    END plan_steps;

    PROCEDURE plan_restore_steps IS
    BEGIN
        FOR s IN (SELECT column_value AS step_code
                    FROM TABLE(SYS.ODCIVARCHAR2LIST('REBUILD_INDEXES', 'RESTORE_FILES', 'RESIZE', 'RECOMPILE',
                                                    'VERIFY', 'UNLOCK_ACCOUNTS'))) LOOP
            epfpg.epf_log.step_plan(s.step_code);
        END LOOP;
    END plan_restore_steps;

    PROCEDURE run(p_run_id IN NUMBER, p_mode IN VARCHAR2, p_tablespaces IN VARCHAR2, p_status OUT VARCHAR2) IS
        l_ok      BOOLEAN := TRUE;
        l_message VARCHAR2(400);
        l_unmet   VARCHAR2(400);
        l_work    NUMBER;
        l_code    NUMBER;
        l_msg     VARCHAR2(4000);
        l_trace   VARCHAR2(4000);
    BEGIN
        init(p_run_id, p_mode, p_tablespaces);
        IF g_mode IN ('COMPACT', 'RESTORE') THEN
            wait_for_workers;
        END IF;
        IF g_mode = 'RESTORE' THEN
            -- Steps left running by a worker session that ended without them.
            UPDATE epfpg.epf_step
               SET status = 'FAILED', ended_at = epfpg.epf_util.now_ts,
                   message = NVL(message, 'the worker session ended during the step')
             WHERE run_id = g_run.run_id AND status = 'RUNNING';
            COMMIT;
            plan_restore_steps;
            restore_targets;
            restore_path(TRUE, 'Y', l_ok);
        ELSE
            plan_steps;
            IF g_mode = 'COMPACT' THEN
                BEGIN
                    epfpg.epf_log.step_start('PREPARE');
                    prepare(l_message);
                    epfpg.epf_log.step_end('DONE', l_message);
                EXCEPTION
                    WHEN OTHERS THEN
                        fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                        l_ok := FALSE;
                END;
            END IF;
            IF l_ok THEN
                BEGIN
                    epfpg.epf_log.step_start('ASSESS');
                    assess(p_tablespaces, l_message);
                    epfpg.epf_log.step_end('DONE', l_message);
                    IF g_mode = 'COMPACT' THEN
                        plan_restore_steps;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                        l_ok := FALSE;
                END;
            END IF;
            IF l_ok AND g_mode = 'COMPACT' THEN
                SELECT LISTAGG(req_code, ', ') WITHIN GROUP (ORDER BY seq)
                  INTO l_unmet
                  FROM epfpg.epf_requirement
                 WHERE run_id = g_run.run_id AND blocking = 'Y' AND status = 'NOT_MET';
                IF l_unmet IS NOT NULL THEN
                    say(epfpg.epf_log.c_error, 'REQUIREMENTS_NOT_MET',
                        'The compaction did not start: blocking requirements not met: ' || l_unmet
                        || ' (REQUIREMENTS in the report: ways to meet them); nothing was changed');
                    l_ok := FALSE;
                ELSIF epfpg.epf_control.stop_requested(g_run.run_id) THEN
                    g_stopped := TRUE;
                    say(epfpg.epf_log.c_warn, 'STOP_HONORED', 'Stop requested before the compaction: nothing was changed');
                ELSE
                    SELECT COUNT(*)
                      INTO l_work
                      FROM epfpg.epf_reclaim_object
                     WHERE run_id = g_run.run_id
                       AND (unit_type IN ('TABLE', 'IOT') OR (unit_type = 'INDEX' AND move_status IN ('PENDING', 'RELEASED')));
                    IF l_work > 0 THEN
                        compact_all(l_ok);
                    ELSE
                        snap_files('BASELINE');
                    END IF;
                    IF NOT g_stopped OR g_changed THEN
                        restore_path(FALSE, 'N', l_ok);
                    END IF;
                END IF;
            END IF;
        END IF;
        epfpg.epf_log.step_skip_pending(CASE WHEN g_stopped THEN 'stop requested'
                                             WHEN NOT l_ok THEN 'an earlier step failed or the requirements are not met'
                                             ELSE 'nothing to do' END);
        p_status := CASE WHEN NOT l_ok OR g_errors > 0 THEN 'FAILED'
                         WHEN g_stopped THEN 'STOPPED'
                         WHEN g_warnings > 0 THEN 'WARNING'
                         ELSE 'SUCCESS' END;
    EXCEPTION
        WHEN OTHERS THEN
            l_code := SQLCODE;
            l_msg := SQLERRM;
            l_trace := DBMS_UTILITY.FORMAT_ERROR_BACKTRACE;
            IF g_run.run_id IS NULL OR epfpg.epf_log.current_run IS NULL THEN
                RAISE;
            END IF;
            fail_step(l_code, l_msg, l_trace);
            IF g_changed THEN
                restore_path(FALSE, 'N', l_ok);
            END IF;
            p_status := 'FAILED';
    END run;

END epf_reclaim;
/

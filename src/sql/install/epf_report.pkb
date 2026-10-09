CREATE OR REPLACE PACKAGE BODY epf_report AS

    c_width CONSTANT PLS_INTEGER := 132;

    g_run epf_run%ROWTYPE;

    -- ------------------------------------------------------------------
    -- Formatting
    -- ------------------------------------------------------------------

    PROCEDURE put(p_line IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p_line);
    END put;

    FUNCTION n(p_value IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN NVL(epf_util.fmt_int(p_value), '-');
    END n;

    FUNCTION b(p_value IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN NVL(epf_util.fmt_bytes(p_value), '-');
    END b;

    -- Column helpers: left- or right-aligned in p_width characters. A value
    -- that does not fit is never cut; it widens its column by what it needs
    -- plus one space, so neighbouring values stay separated.
    FUNCTION l(p_text IN VARCHAR2, p_width IN PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN RPAD(NVL(p_text, ' '), GREATEST(p_width, NVL(LENGTH(p_text), 0) + 1));
    END l;

    FUNCTION r(p_text IN VARCHAR2, p_width IN PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN LPAD(NVL(p_text, ' '), GREATEST(p_width, NVL(LENGTH(p_text), 0) + 1));
    END r;

    PROCEDURE title(p_text IN VARCHAR2) IS
    BEGIN
        put;
        put(' ' || p_text);
        put(' ' || RPAD('-', c_width - 1, '-'));
    END title;

    -- The module deletes its rows (modes FULL and LOGS, and the LOGS module
    -- in CLOB_N_LOGS); otherwise it clears LOB values.
    FUNCTION module_deletes(p_module IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN g_run.purge_mode IN ('FULL', 'LOGS') OR (g_run.purge_mode = 'CLOB_N_LOGS' AND p_module = 'LOGS');
    END module_deletes;

    FUNCTION in_depth(p_module IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        RETURN g_run.depth = 'ALL' OR INSTR(',' || g_run.depth || ',', ',' || p_module || ',') > 0;
    END in_depth;

    -- ------------------------------------------------------------------
    -- Checks
    -- ------------------------------------------------------------------

    PROCEDURE add_check(p_id IN VARCHAR2, p_status IN VARCHAR2, p_title IN VARCHAR2,
                        p_value IN VARCHAR2, p_detail IN VARCHAR2 DEFAULT NULL) IS
        l_run NUMBER := g_run.run_id;
    BEGIN
        INSERT INTO epf_check (run_id, check_id, status, title, value, detail)
        VALUES (l_run, p_id, p_status, p_title, SUBSTR(p_value, 1, 200), SUBSTR(p_detail, 1, 4000));
    END add_check;

    FUNCTION add_detail(p_list IN VARCHAR2, p_item IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF LENGTH(p_list) > 3800 THEN
            RETURN p_list;
        END IF;
        RETURN SUBSTR(p_list || CASE WHEN p_list IS NOT NULL THEN '; ' END || p_item, 1, 3900);
    END add_detail;

    -- P5: errors and warnings of the run (every action).
    PROCEDURE check_errors(p_status IN VARCHAR2) IS
        l_run      NUMBER := g_run.run_id;
        l_errors   NUMBER;
        l_warnings NUMBER;
        l_detail   VARCHAR2(4000);
    BEGIN
        SELECT COUNT(CASE WHEN severity = 'ERROR' THEN 1 END), COUNT(CASE WHEN severity = 'WARN' THEN 1 END)
          INTO l_errors, l_warnings
          FROM epf_event
         WHERE run_id = l_run AND event_code <> 'RUN_END';
        FOR t IN (SELECT event_code, severity, COUNT(*) AS cnt
                    FROM epf_event
                   WHERE run_id = l_run AND event_code <> 'RUN_END' AND severity IN ('ERROR', 'WARN')
                   GROUP BY event_code, severity
                   ORDER BY severity, event_code) LOOP
            l_detail := add_detail(l_detail, t.event_code || ' x' || t.cnt);
        END LOOP;
        add_check('P5', CASE WHEN l_errors > 0 OR p_status = 'FAILED' THEN 'FAIL'
                             WHEN l_warnings > 0 THEN 'WARN' ELSE 'PASS' END,
                  'Errors during the run',
                  l_errors || ' errors, ' || l_warnings || ' warnings'
                  || CASE WHEN p_status = 'FAILED' THEN ', run FAILED' END, l_detail);
    END check_errors;

    -- Value of key p_key in fingerprint p_fp (key=value pairs separated by
    -- ';', EPF_OBJECT_BASELINE).
    FUNCTION fp_value(p_fp IN VARCHAR2, p_key IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REGEXP_SUBSTR(';' || p_fp, ';' || p_key || '=([^;]*)', 1, 1, NULL, 1);
    END fp_value;

    -- The attributes of fingerprint p_after that differ from p_before, as
    -- "key before->after" separated by commas; NULL when none differ. p_keys:
    -- only these keys; p_skip: every key but these (lists separated by
    -- commas).
    FUNCTION attr_diff(p_before IN VARCHAR2, p_after IN VARCHAR2, p_keys IN VARCHAR2 DEFAULT NULL,
                       p_skip IN VARCHAR2 DEFAULT NULL) RETURN VARCHAR2 IS
        l_diff VARCHAR2(4000);
        l_pair VARCHAR2(4000);
        l_key  VARCHAR2(100);
        l_old  VARCHAR2(4000);
        l_new  VARCHAR2(4000);
        l_i    PLS_INTEGER := 1;
    BEGIN
        LOOP
            l_pair := REGEXP_SUBSTR(p_before, '[^;]+', 1, l_i);
            EXIT WHEN l_pair IS NULL;
            l_key := SUBSTR(l_pair, 1, INSTR(l_pair, '=') - 1);
            IF (p_keys IS NULL OR INSTR(',' || p_keys || ',', ',' || l_key || ',') > 0)
               AND (p_skip IS NULL OR INSTR(',' || p_skip || ',', ',' || l_key || ',') = 0) THEN
                l_old := SUBSTR(l_pair, INSTR(l_pair, '=') + 1);
                l_new := fp_value(p_after, l_key);
                IF NVL(l_old, '-') <> NVL(l_new, '-') THEN
                    l_diff := SUBSTR(l_diff || CASE WHEN l_diff IS NOT NULL THEN ', ' END || l_key || ' '
                                     || NVL(l_old, '-') || '->' || NVL(l_new, '-'), 1, 3900);
                END IF;
            END IF;
            l_i := l_i + 1;
        END LOOP;
        RETURN l_diff;
    END attr_diff;

    FUNCTION r_title(p_id IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE p_id
                   WHEN 'R1' THEN 'Indexes usable and identical'
                   WHEN 'R2' THEN 'Constraints identical'
                   WHEN 'R3' THEN 'No new invalid objects'
                   WHEN 'R4' THEN 'Row counts identical'
                   WHEN 'R5' THEN 'Table and LOB attributes kept'
                   WHEN 'R6' THEN 'Datafiles within their start size'
                   WHEN 'R7' THEN 'Efficiency'
                   WHEN 'R8' THEN 'Tables moved'
                   WHEN 'R9' THEN 'Accounts restored'
               END;
    END r_title;

    -- Checks R1-R9 of a reclaim run (see the specification).
    PROCEDURE check_reclaim IS
        l_run      NUMBER := g_run.run_id;
        l_restore  BOOLEAN := NVL(g_run.reclaim_mode, '-') = 'RESTORE';
        -- A restore run checks what every reclaim left pending.
        l_all      VARCHAR2(1) := CASE WHEN g_run.reclaim_mode = 'RESTORE' THEN 'Y' ELSE 'N' END;
        l_base     NUMBER;
        l_verified NUMBER;
        l_started  NUMBER;
        l_total    NUMBER;
        l_ok       NUMBER;
        l_bad      NUMBER;
        l_soft     NUMBER;
        l_gone     NUMBER;
        l_count    NUMBER;
        l_value    VARCHAR2(200);
        l_detail   VARCHAR2(4000);
        l_diff     VARCHAR2(4000);
        l_hard     VARCHAR2(4000);
        l_light    VARCHAR2(4000);
        l_before   VARCHAR2(30);
        l_after    VARCHAR2(30);
        l_margin   NUMBER := NVL(epf_util.setting_num('reclaim_margin_mb'), 64) * 1048576;

        -- R2-R5 cannot be evaluated: SKIP or WARN with the reason; TRUE when
        -- the check is done.
        FUNCTION not_compared(p_id IN VARCHAR2) RETURN BOOLEAN IS
        BEGIN
            IF l_restore THEN
                add_check(p_id, 'SKIP', r_title(p_id), 'restore only');
            ELSIF l_base = 0 THEN
                add_check(p_id, 'SKIP', r_title(p_id), 'nothing moved');
            ELSIF l_verified = 0 THEN
                add_check(p_id, 'WARN', r_title(p_id), 'not verified: the run ended before step VERIFY');
            ELSE
                RETURN FALSE;
            END IF;
            RETURN TRUE;
        END not_compared;
    BEGIN
        IF g_run.dry_run = 'Y' THEN
            FOR k IN 1 .. 9 LOOP
                add_check('R' || k, 'SKIP', r_title('R' || k), 'assessment');
            END LOOP;
            RETURN;
        END IF;
        SELECT COUNT(CASE WHEN step_code = 'BASELINE' AND status = 'DONE' THEN 1 END),
               COUNT(CASE WHEN step_code = 'VERIFY' AND status = 'DONE' THEN 1 END),
               COUNT(CASE WHEN step_code IN ('LOCK_ACCOUNTS', 'RELEASE_INDEXES', 'FREEZE_FILES', 'COMPACT')
                           AND started_at IS NOT NULL THEN 1 END)
          INTO l_base, l_verified, l_started
          FROM epf_step
         WHERE run_id = l_run AND phase = 'RECLAIM';

        -- R1 indexes: with the fingerprint, every attribute but the status
        -- identical and the status VALID (an index unusable before and left
        -- as found keeps its status); otherwise the indexes of the run usable
        -- now.
        SELECT COUNT(*) INTO l_total
          FROM epf_reclaim_object
         WHERE run_id = l_run AND unit_type = 'INDEX' AND move_status IN ('RELEASED', 'REBUILT', 'FAILED');
        IF l_total = 0 THEN
            add_check('R1', 'SKIP', r_title('R1'), 'no index released');
        ELSE
            l_total := 0;
            l_ok := 0;
            l_bad := 0;
            l_gone := 0;
            l_detail := NULL;
            IF l_verified > 0 THEN
                FOR i IN (SELECT x.owner, x.name, x.detail, x.detail_after, o.move_status
                            FROM epf_object_baseline x
                            LEFT JOIN epf_reclaim_object o
                              ON o.run_id = x.run_id AND o.unit_type = 'INDEX' AND o.owner = x.owner
                             AND o.object_name = x.name
                           WHERE x.run_id = l_run AND x.object_type = 'INDEX'
                           ORDER BY x.owner, x.name) LOOP
                    l_total := l_total + 1;
                    l_before := fp_value(i.detail, 'status');
                    l_after := fp_value(i.detail_after, 'status');
                    l_diff := attr_diff(i.detail, i.detail_after, p_skip => 'status');
                    IF i.detail_after IS NULL THEN
                        l_gone := l_gone + 1;
                        l_detail := add_detail(l_detail, i.owner || '.' || i.name || ' no longer exists');
                    ELSIF NVL(i.move_status, '-') = 'FAILED' OR l_diff IS NOT NULL
                          OR (l_after <> 'VALID' AND NOT (NVL(i.move_status, '-') = 'KEPT' AND l_after = l_before)) THEN
                        l_bad := l_bad + 1;
                        l_detail := add_detail(l_detail, i.owner || '.' || i.name || ' '
                                                         || NVL(l_diff, 'status ' || l_before || '->' || l_after));
                    ELSE
                        l_ok := l_ok + 1;
                    END IF;
                END LOOP;
            ELSE
                FOR i IN (SELECT o.owner, o.object_name, o.move_status, x.status AS live
                            FROM epf_reclaim_object o
                            LEFT JOIN dba_indexes x ON x.owner = o.owner AND x.index_name = o.object_name
                           WHERE o.run_id = l_run AND o.unit_type = 'INDEX'
                             AND o.move_status IN ('RELEASED', 'REBUILT', 'FAILED')
                           ORDER BY o.owner, o.object_name) LOOP
                    l_total := l_total + 1;
                    IF i.live IS NULL THEN
                        l_gone := l_gone + 1;
                        l_detail := add_detail(l_detail, i.owner || '.' || i.object_name || ' no longer exists');
                    ELSIF i.live <> 'VALID' THEN
                        l_bad := l_bad + 1;
                        l_detail := add_detail(l_detail, i.owner || '.' || i.object_name || ' ' || i.live);
                    ELSE
                        l_ok := l_ok + 1;
                    END IF;
                END LOOP;
            END IF;
            add_check('R1', CASE WHEN l_bad > 0 THEN 'FAIL' WHEN l_gone > 0 THEN 'WARN' ELSE 'PASS' END, r_title('R1'),
                      l_ok || '/' || l_total || CASE WHEN l_verified > 0 THEN ' usable and identical' ELSE ' usable' END
                      || CASE WHEN l_gone > 0 THEN ', ' || l_gone || ' no longer exist' END, l_detail);
        END IF;

        -- R2 constraints: status, validated, type and deferral identical.
        IF NOT not_compared('R2') THEN
            l_total := 0;
            l_bad := 0;
            l_detail := NULL;
            FOR c IN (SELECT owner, name, table_name, detail, detail_after
                        FROM epf_object_baseline
                       WHERE run_id = l_run AND object_type = 'CONSTRAINT'
                       ORDER BY owner, table_name, name) LOOP
                l_total := l_total + 1;
                l_diff := CASE WHEN c.detail_after IS NULL THEN 'no longer exists'
                               ELSE attr_diff(c.detail, c.detail_after) END;
                IF l_diff IS NOT NULL THEN
                    l_bad := l_bad + 1;
                    l_detail := add_detail(l_detail, c.owner || '.' || c.name || ' on ' || c.table_name || ' ' || l_diff);
                END IF;
            END LOOP;
            add_check('R2', CASE WHEN l_bad > 0 THEN 'FAIL' ELSE 'PASS' END, r_title('R2'),
                      (l_total - l_bad) || '/' || l_total || ' identical', l_detail);
        END IF;

        -- R3 objects invalid after the recompilation that were valid before.
        IF NOT not_compared('R3') THEN
            l_detail := NULL;
            l_count := 0;
            FOR o IN (SELECT owner, name, detail
                        FROM epf_object_baseline
                       WHERE run_id = l_run AND object_type = 'NEW_INVALID'
                       ORDER BY owner, name) LOOP
                l_count := l_count + 1;
                l_detail := add_detail(l_detail, o.detail || ' ' || o.owner || '.' || o.name);
            END LOOP;
            add_check('R3', CASE WHEN l_count > 0 THEN 'FAIL' ELSE 'PASS' END, r_title('R3'),
                      CASE WHEN l_count = 0 THEN 'none new' ELSE l_count || ' new invalid objects' END, l_detail);
        END IF;

        -- R4 row counts of the tables that move, before and after.
        IF NOT not_compared('R4') THEN
            SELECT COUNT(row_count),
                   COUNT(CASE WHEN row_count = row_count_after THEN 1 END),
                   COUNT(CASE WHEN row_count IS NOT NULL AND row_count_after IS NULL THEN 1 END)
              INTO l_total, l_ok, l_gone
              FROM epf_object_baseline
             WHERE run_id = l_run AND object_type = 'TABLE';
            IF l_total = 0 THEN
                add_check('R4', 'SKIP', r_title('R4'), 'not counted (setting reclaim_row_counts)');
            ELSE
                l_detail := NULL;
                FOR t IN (SELECT owner, name, row_count, row_count_after
                            FROM epf_object_baseline
                           WHERE run_id = l_run AND object_type = 'TABLE' AND row_count IS NOT NULL
                             AND (row_count_after IS NULL OR row_count_after <> row_count)
                           ORDER BY owner, name) LOOP
                    l_detail := add_detail(l_detail, t.owner || '.' || t.name || ' ' || n(t.row_count) || ' -> '
                                                     || NVL(n(t.row_count_after), 'not counted'));
                END LOOP;
                add_check('R4', CASE WHEN l_ok + l_gone < l_total THEN 'FAIL' WHEN l_gone > 0 THEN 'WARN'
                                     ELSE 'PASS' END, r_title('R4'),
                          l_ok || '/' || l_total || ' tables identical'
                          || CASE WHEN l_gone > 0 THEN ', ' || l_gone || ' not counted after' END, l_detail);
            END IF;
        END IF;

        -- R5 table and LOB attributes: a LOB stored as SECUREFILE instead of
        -- BASICFILE (db_securefile), a new retention (undo_retention) or a new
        -- segment name warn; any other difference fails.
        IF NOT not_compared('R5') THEN
            l_total := 0;
            l_bad := 0;
            l_soft := 0;
            l_detail := NULL;
            FOR t IN (SELECT object_type, owner, name, table_name, detail, detail_after
                        FROM epf_object_baseline
                       WHERE run_id = l_run AND object_type IN ('TABLE', 'LOB')
                       ORDER BY owner, table_name, object_type DESC, name) LOOP
                l_total := l_total + 1;
                IF t.detail_after IS NULL THEN
                    l_hard := 'no longer exists';
                    l_light := NULL;
                ELSIF t.object_type = 'LOB' THEN
                    l_hard := attr_diff(t.detail, t.detail_after, p_skip => 'securefile,retention,segment');
                    l_light := attr_diff(t.detail, t.detail_after, p_keys => 'securefile,retention,segment');
                ELSE
                    l_hard := attr_diff(t.detail, t.detail_after);
                    l_light := NULL;
                END IF;
                IF l_hard IS NOT NULL THEN
                    l_bad := l_bad + 1;
                ELSIF l_light IS NOT NULL THEN
                    l_soft := l_soft + 1;
                END IF;
                IF l_hard IS NOT NULL OR l_light IS NOT NULL THEN
                    l_detail := add_detail(l_detail, t.owner || '.' || t.table_name
                                                     || CASE WHEN t.object_type = 'LOB' THEN ' LOB ' || t.name END || ' '
                                                     || l_hard || CASE WHEN l_hard IS NOT NULL AND l_light IS NOT NULL
                                                                       THEN ', ' END || l_light);
                END IF;
            END LOOP;
            add_check('R5', CASE WHEN l_bad > 0 THEN 'FAIL' WHEN l_soft > 0 THEN 'WARN' ELSE 'PASS' END, r_title('R5'),
                      (l_total - l_bad - l_soft) || '/' || l_total || ' tables and LOB columns identical', l_detail);
        END IF;

        -- R6 datafiles: every growth setting the run changed restored and
        -- equal to the baseline, its scratch tablespace dropped; each
        -- tablespace at most its start size at the end, and at most its start
        -- size plus reclaim_growth_mb per datafile at its peak (above it only
        -- for an index or a parked table that did not fit, a warning).
        l_detail := NULL;
        l_bad := 0;
        l_soft := 0;
        SELECT COUNT(*) INTO l_count
          FROM epf_instance_change
         WHERE item = 'RECLAIM_DATAFILE' AND restored_at IS NULL
           AND (applied_run_id = l_run OR l_all = 'Y');
        IF l_count > 0 THEN
            l_bad := l_bad + l_count;
            l_detail := add_detail(l_detail, l_count || ' datafile growth settings not restored (epf_purge.bat reclaim '
                                             || '--restore)');
        END IF;
        FOR c IN (SELECT target
                    FROM epf_instance_change
                   WHERE item = 'RECLAIM_SCRATCH' AND restored_at IS NULL
                     AND (applied_run_id = l_run OR l_all = 'Y')
                   ORDER BY change_id) LOOP
            l_bad := l_bad + 1;
            l_detail := add_detail(l_detail, 'scratch tablespace ' || c.target || ' not dropped (epf_purge.bat reclaim '
                                             || '--restore)');
        END LOOP;
        IF l_restore THEN
            add_check('R6', CASE WHEN l_bad > 0 THEN 'FAIL' ELSE 'PASS' END, r_title('R6'),
                      CASE WHEN l_bad > 0 THEN l_bad || ' growth settings not restored'
                           ELSE 'growth settings restored' END, l_detail);
        ELSE
            SELECT COUNT(*) INTO l_total FROM epf_file_snap WHERE run_id = l_run AND phase = 'BASELINE';
            SELECT COUNT(*) INTO l_count FROM epf_file_snap WHERE run_id = l_run AND phase = 'POST_RECLAIM';
            IF l_total = 0 AND l_bad = 0 THEN
                add_check('R6', 'SKIP', r_title('R6'), 'nothing changed');
            ELSIF l_count = 0 THEN
                add_check('R6', CASE WHEN l_bad > 0 THEN 'FAIL' ELSE 'WARN' END, r_title('R6'),
                          'not measured: the run ended before its end values', l_detail);
            ELSE
                FOR f IN (SELECT s.file_name, s.autoextensible, s.increment_by, s.maxbytes,
                                 e.autoextensible AS auto_end, e.increment_by AS incr_end, e.maxbytes AS max_end
                            FROM epf_file_snap s
                            LEFT JOIN epf_file_snap e
                              ON e.run_id = s.run_id AND e.phase = 'POST_RECLAIM' AND e.file_id = s.file_id
                           WHERE s.run_id = l_run AND s.phase = 'BASELINE'
                           ORDER BY s.file_id) LOOP
                    IF f.auto_end IS NULL THEN
                        l_soft := l_soft + 1;
                        l_detail := add_detail(l_detail, f.file_name || ' no longer exists');
                    ELSIF f.autoextensible <> f.auto_end
                          OR (f.autoextensible = 'YES' AND (f.increment_by <> f.incr_end OR f.maxbytes <> f.max_end)) THEN
                        l_bad := l_bad + 1;
                        l_detail := add_detail(l_detail, f.file_name || ' autoextend ' || f.autoextensible
                                                         || CASE WHEN f.autoextensible = 'YES' THEN ' next ' || b(f.increment_by)
                                                                                                    || ' max ' || b(f.maxbytes) END
                                                         || ' -> ' || f.auto_end
                                                         || CASE WHEN f.auto_end = 'YES' THEN ' next ' || b(f.incr_end)
                                                                                              || ' max ' || b(f.max_end) END);
                    END IF;
                END LOOP;
                SELECT COUNT(*) INTO l_count
                  FROM epf_event
                 WHERE run_id = l_run AND event_code IN ('INDEXES_NEED_GROWTH', 'RETURN_GREW');
                l_value := NULL;
                FOR t IN (SELECT tablespace_name, start_bytes, end_bytes, peak_bytes,
                                 start_bytes + NVL(growth_bytes, 0) * NVL(file_count, 1) AS limit_bytes
                            FROM epf_reclaim_ts
                           WHERE run_id = l_run
                           ORDER BY tablespace_name) LOOP
                    IF t.peak_bytes > t.limit_bytes THEN
                        IF l_count > 0 THEN
                            l_soft := l_soft + 1;
                        ELSE
                            l_bad := l_bad + 1;
                        END IF;
                        l_detail := add_detail(l_detail, t.tablespace_name || ' reached ' || b(t.peak_bytes) || ', above '
                                                         || b(t.limit_bytes)
                                                         || CASE WHEN l_count > 0
                                                                 THEN ' (an index or a parked table did not fit within it)'
                                                            END);
                    END IF;
                    IF t.end_bytes > t.start_bytes THEN
                        l_soft := l_soft + 1;
                        l_detail := add_detail(l_detail, t.tablespace_name || ' ends at ' || b(t.end_bytes)
                                                         || ', above its start size ' || b(t.start_bytes));
                    END IF;
                    IF l_value IS NULL OR LENGTH(l_value) < 150 THEN
                        l_value := l_value || CASE WHEN l_value IS NOT NULL THEN ', ' END || t.tablespace_name || ' '
                                   || b(t.start_bytes) || ' -> ' || NVL(b(t.end_bytes), '-');
                    END IF;
                END LOOP;
                add_check('R6', CASE WHEN l_bad > 0 THEN 'FAIL' WHEN l_soft > 0 THEN 'WARN' ELSE 'PASS' END,
                          r_title('R6'), l_value, l_detail);
            END IF;
        END IF;

        -- R7 efficiency: each tablespace ends within max(1 %, 256 MB) of its
        -- segments plus the margin of its datafiles; otherwise a warning that
        -- names what stopped it.
        IF l_restore THEN
            add_check('R7', 'SKIP', r_title('R7'), 'restore only');
        ELSE
            l_total := 0;
            l_soft := 0;
            l_detail := NULL;
            l_value := NULL;
            FOR t IN (SELECT r.tablespace_name, r.end_bytes, r.end_segment_bytes, r.file_count, r.status, r.stop_detail,
                             (SELECT MAX(i.owner || '.' || i.object_name || ' (' || i.blocker_reason || ')')
                                     KEEP (DENSE_RANK LAST ORDER BY i.top_block)
                                FROM epf_ts_inventory i
                               WHERE i.run_id = r.run_id AND i.tablespace_name = r.tablespace_name
                                 AND i.handler = 'PIN') AS top_pin
                        FROM epf_reclaim_ts r
                       WHERE r.run_id = l_run AND r.end_bytes IS NOT NULL
                       ORDER BY r.tablespace_name) LOOP
                l_total := l_total + 1;
                IF t.end_bytes - t.end_segment_bytes - l_margin * NVL(t.file_count, 1)
                   > GREATEST(t.end_segment_bytes * 0.01, 268435456) THEN
                    l_soft := l_soft + 1;
                    l_detail := add_detail(l_detail, t.tablespace_name || ' ' || b(t.end_bytes) || ' for '
                                                     || b(t.end_segment_bytes) || ' of segments: '
                                                     || CASE WHEN t.stop_detail IS NOT NULL THEN t.stop_detail
                                                             WHEN t.status = 'PARTIAL'
                                                             THEN 'tables did not fit, failed or were not reached'
                                                             WHEN t.top_pin IS NOT NULL
                                                             THEN 'a segment that stays holds the top, ' || t.top_pin
                                                             ELSE 'free space below the highest block' END);
                END IF;
                IF l_value IS NULL OR LENGTH(l_value) < 150 THEN
                    l_value := l_value || CASE WHEN l_value IS NOT NULL THEN ', ' END || t.tablespace_name || ' '
                               || b(t.end_bytes) || ' vs ' || b(t.end_segment_bytes) || ' of segments';
                END IF;
            END LOOP;
            IF l_total = 0 THEN
                add_check('R7', 'SKIP', r_title('R7'), 'not measured');
            ELSE
                add_check('R7', CASE WHEN l_soft > 0 THEN 'WARN' ELSE 'PASS' END, r_title('R7'), l_value, l_detail);
            END IF;
        END IF;

        -- R8 tables: a move that failed fails, and so does a table still
        -- parked; tables that did not fit, were busy or were not reached warn.
        SELECT COUNT(*),
               COUNT(CASE WHEN move_status = 'MOVED' THEN 1 END),
               COUNT(CASE WHEN (move_status = 'FAILED' AND NVL(last_ora, 0) <> 54) OR move_status = 'PARKED' THEN 1 END),
               COUNT(CASE WHEN move_status IN ('NO_ROOM', 'SKIPPED') OR (move_status = 'FAILED' AND last_ora = 54)
                          THEN 1 END)
          INTO l_total, l_ok, l_bad, l_soft
          FROM epf_reclaim_object
         WHERE run_id = l_run AND unit_type IN ('TABLE', 'IOT');
        IF l_total = 0 THEN
            add_check('R8', 'SKIP', r_title('R8'), CASE WHEN l_restore THEN 'restore only' ELSE 'no table to move' END);
        ELSIF l_started = 0 THEN
            add_check('R8', 'SKIP', r_title('R8'), 'nothing moved');
        ELSE
            l_detail := NULL;
            FOR t IN (SELECT owner, object_name, move_status, last_ora, detail
                        FROM epf_reclaim_object
                       WHERE run_id = l_run AND unit_type IN ('TABLE', 'IOT')
                         AND move_status IN ('NO_ROOM', 'FAILED', 'SKIPPED', 'PARKED')
                       ORDER BY CASE move_status WHEN 'PARKED' THEN 0 WHEN 'FAILED' THEN 1 WHEN 'NO_ROOM' THEN 2 ELSE 3 END,
                                bytes DESC) LOOP
                l_detail := add_detail(l_detail, t.owner || '.' || t.object_name || ' '
                                                 || CASE WHEN t.move_status = 'FAILED' AND t.last_ora = 54 THEN 'busy'
                                                         WHEN t.move_status = 'PARKED' THEN 'still parked'
                                                         ELSE LOWER(REPLACE(t.move_status, '_', ' ')) END
                                                 || CASE WHEN t.last_ora IS NOT NULL THEN ' (ORA-' || LPAD(t.last_ora, 5, '0')
                                                                                         || ')' END);
            END LOOP;
            add_check('R8', CASE WHEN l_bad > 0 THEN 'FAIL' WHEN l_soft > 0 THEN 'WARN' ELSE 'PASS' END, r_title('R8'),
                      l_ok || ' of ' || l_total || ' moved'
                      || CASE WHEN l_total - l_ok - l_bad - l_soft > 0
                              THEN ', ' || (l_total - l_ok - l_bad - l_soft) || ' below where the datafile stopped' END
                      || CASE WHEN l_soft > 0 THEN ', ' || l_soft || ' not moved' END
                      || CASE WHEN l_bad > 0 THEN ', ' || l_bad || ' failed or still parked' END, l_detail);
        END IF;

        -- R9 accounts: every account the run locked (a restore: any reclaim)
        -- unlocked again; accounts locked before stay locked.
        SELECT COUNT(CASE WHEN locked_at IS NOT NULL THEN 1 END),
               COUNT(CASE WHEN locked_at IS NOT NULL AND unlocked_at IS NULL THEN 1 END),
               COUNT(*)
          INTO l_total, l_bad, l_count
          FROM epf_account_action
         WHERE run_id = l_run;
        IF l_restore THEN
            SELECT COUNT(*) INTO l_bad FROM epf_account_action WHERE locked_at IS NOT NULL AND unlocked_at IS NULL;
            SELECT COUNT(*) INTO l_total FROM epf_event WHERE run_id = l_run AND event_code = 'ACCOUNT_UNLOCKED';
        END IF;
        l_detail := NULL;
        FOR a IN (SELECT run_id, username, original_status
                    FROM epf_account_action
                   WHERE locked_at IS NOT NULL AND unlocked_at IS NULL AND (run_id = l_run OR l_all = 'Y')
                   ORDER BY run_id, username) LOOP
            l_detail := add_detail(l_detail, a.username || ' still locked by ' || epf_util.run_label(a.run_id)
                                             || ' (originally ' || a.original_status || ')');
        END LOOP;
        IF l_count = 0 AND NOT l_restore THEN
            add_check('R9', 'SKIP', r_title('R9'), 'no account in scope');
        ELSE
            add_check('R9', CASE WHEN l_bad > 0 THEN 'FAIL' ELSE 'PASS' END, r_title('R9'),
                      CASE WHEN l_restore THEN l_total || ' unlocked, ' || l_bad || ' still locked'
                           ELSE l_total || ' locked, ' || (l_total - l_bad) || ' restored' END, l_detail);
        END IF;
    END check_reclaim;

    PROCEDURE evaluate(p_run_id IN NUMBER, p_verdict OUT VARCHAR2, p_exit_code OUT NUMBER,
                       p_status IN VARCHAR2 DEFAULT NULL) IS
        l_run       NUMBER := p_run_id;
        l_status    epf_run.status%TYPE;
        l_no_purge  BOOLEAN;
        l_stopped   BOOLEAN;
        l_failed    BOOLEAN;
        l_after     NUMBER;
        l_count     NUMBER;
        l_total     NUMBER;
        l_equal     NUMBER;
        l_more      NUMBER;
        l_fewer     NUMBER;
        l_value     NUMBER;
        l_links     NUMBER;
        l_by_fk     NUMBER;
        l_new       NUMBER;
        l_old       NUMBER;
        l_phases    NUMBER;
        l_estimated NUMBER;
        l_lob_est   NUMBER;
        l_before    NUMBER;
        l_now       NUMBER;
        l_done      NUMBER;
        l_skipped   NUMBER;
        l_freed     NUMBER;
        l_detail    VARCHAR2(4000);
        l_fail      NUMBER;
        l_warn      NUMBER;
    BEGIN
        SELECT * INTO g_run FROM epf_run WHERE run_id = p_run_id;
        l_status := NVL(UPPER(p_status), g_run.status);
        DELETE FROM epf_check WHERE run_id = l_run;

        IF g_run.action = 'RECLAIM' THEN
            check_errors(l_status);
            check_reclaim;
            COMMIT;
            SELECT COUNT(CASE WHEN status = 'FAIL' THEN 1 END), COUNT(CASE WHEN status = 'WARN' THEN 1 END)
              INTO l_fail, l_warn
              FROM epf_check
             WHERE run_id = l_run;
            p_verdict   := CASE WHEN l_fail > 0 THEN 'FAIL' WHEN l_warn > 0 THEN 'PASS WITH WARNINGS' ELSE 'PASS' END;
            p_exit_code := CASE WHEN l_fail > 0 THEN 1 WHEN l_warn > 0 THEN 2 ELSE 0 END;
            RETURN;
        END IF;

        SELECT COUNT(*) INTO l_after FROM epf_table_stat WHERE run_id = l_run AND phase = 'AFTER';
        l_no_purge := g_run.action <> 'PURGE' OR g_run.dry_run = 'Y' OR l_after = 0;
        SELECT COUNT(*) INTO l_count FROM epf_event WHERE run_id = l_run AND event_code = 'STOP_HONORED';
        l_stopped := l_count > 0 OR l_status = 'STOPPED';
        SELECT COUNT(*) INTO l_count FROM epf_step WHERE run_id = l_run AND phase = 'PURGE' AND status = 'FAILED';
        l_failed := l_count > 0 OR l_status = 'FAILED';

        -- P1 residual
        IF l_no_purge THEN
            add_check('P1', 'SKIP', 'Residual eligible rows', CASE WHEN g_run.dry_run = 'Y' THEN 'dry run' ELSE 'no purge' END);
        ELSE
            l_value := 0;
            l_total := 0;
            l_detail := NULL;
            FOR t IN (SELECT e.owner, e.table_name,
                             CASE WHEN a.action = 'CLEAR' THEN NVL(a.nonempty_lob_rows, 0)
                                  ELSE NVL(a.eligible_rows, 0) END AS residual
                        FROM epf_table_stat a
                        JOIN epf_table e ON e.table_id = a.table_id
                       WHERE a.run_id = l_run AND a.phase = 'AFTER'
                       ORDER BY e.table_id) LOOP
                l_total := l_total + 1;
                l_value := l_value + t.residual;
                IF t.residual > 0 THEN
                    l_detail := add_detail(l_detail, t.owner || '.' || t.table_name || ' ' || n(t.residual));
                END IF;
            END LOOP;
            add_check('P1', CASE WHEN l_value = 0 THEN 'PASS' WHEN l_stopped OR l_failed THEN 'WARN' ELSE 'FAIL' END,
                      'Residual eligible rows', n(l_value) || ' in ' || l_total || ' tables', l_detail);
        END IF;

        -- P2 accounting
        IF l_no_purge THEN
            add_check('P2', 'SKIP', 'Processed = eligible at start', 'no purge');
        ELSE
            l_total := 0;
            l_equal := 0;
            l_more  := 0;
            l_fewer := 0;
            l_detail := NULL;
            FOR t IN (SELECT e.owner, e.table_name, NVL(a.processed_rows, 0) AS processed,
                             NVL(CASE WHEN a.action = 'CLEAR' THEN bf.nonempty_lob_rows ELSE bf.eligible_rows END, 0)
                                 AS expected
                        FROM epf_table_stat a
                        JOIN epf_table_stat bf
                          ON bf.run_id = a.run_id AND bf.table_id = a.table_id AND bf.phase = 'BEFORE'
                        JOIN epf_table e ON e.table_id = a.table_id
                       WHERE a.run_id = l_run AND a.phase = 'AFTER'
                       ORDER BY e.table_id) LOOP
                l_total := l_total + 1;
                IF t.processed = t.expected THEN
                    l_equal := l_equal + 1;
                ELSE
                    IF t.processed > t.expected THEN
                        l_more := l_more + 1;
                    ELSE
                        l_fewer := l_fewer + 1;
                    END IF;
                    l_detail := add_detail(l_detail, t.owner || '.' || t.table_name || ' processed ' || n(t.processed)
                                                     || ', eligible ' || n(t.expected));
                END IF;
            END LOOP;
            add_check('P2', CASE WHEN l_fewer > 0 AND NOT (l_stopped OR l_failed) THEN 'FAIL'
                                 WHEN l_fewer > 0 OR l_more > 0 THEN 'WARN'
                                 ELSE 'PASS' END,
                      'Processed = eligible at start', l_equal || '/' || l_total || ' tables', l_detail);
        END IF;

        -- P3 retention safety
        IF l_no_purge THEN
            add_check('P3', 'SKIP', 'Retention safety', 'no purge');
        ELSE
            l_fewer := 0;
            l_detail := NULL;
            FOR t IN (SELECT e.owner, e.table_name, NVL(bf.retained_rows, 0) AS kept_before,
                             NVL(a.total_rows, 0) - NVL(a.eligible_rows, 0) AS kept_after
                        FROM epf_table_stat a
                        JOIN epf_table_stat bf
                          ON bf.run_id = a.run_id AND bf.table_id = a.table_id AND bf.phase = 'BEFORE'
                        JOIN epf_table e ON e.table_id = a.table_id
                       WHERE a.run_id = l_run AND a.phase = 'AFTER'
                       ORDER BY e.table_id) LOOP
                IF t.kept_after < t.kept_before THEN
                    l_fewer := l_fewer + 1;
                    l_detail := add_detail(l_detail, t.owner || '.' || t.table_name || ' kept ' || n(t.kept_before)
                                                     || ' -> ' || n(t.kept_after));
                END IF;
            END LOOP;
            add_check('P3', CASE WHEN l_fewer > 0 THEN 'FAIL' ELSE 'PASS' END, 'Retention safety',
                      CASE WHEN l_fewer > 0 THEN l_fewer || ' tables lost kept rows' ELSE 'kept rows unchanged' END,
                      l_detail);
        END IF;

        -- P4 orphans
        IF l_no_purge THEN
            add_check('P4', 'SKIP', 'Orphans on registry links', 'no purge');
        ELSE
            l_links := 0;
            l_by_fk := 0;
            l_new   := 0;
            l_old   := 0;
            l_detail := NULL;
            FOR t IN (SELECT a.link_id, a.protected_by, NVL(a.orphan_rows, 0) AS orphans_after,
                             NVL(bf.orphan_rows, 0) AS orphans_before, e.owner, e.table_name
                        FROM epf_link_stat a
                        LEFT JOIN epf_link_stat bf
                          ON bf.run_id = a.run_id AND bf.link_id = a.link_id AND bf.phase = 'BEFORE'
                        JOIN epf_table e ON e.table_id = a.pointing_table_id
                       WHERE a.run_id = l_run AND a.phase = 'AFTER'
                       ORDER BY a.link_id) LOOP
                l_links := l_links + 1;
                IF t.protected_by IS NOT NULL THEN
                    l_by_fk := l_by_fk + 1;
                END IF;
                IF t.orphans_after > t.orphans_before THEN
                    l_new := l_new + 1;
                ELSIF t.orphans_after > 0 THEN
                    l_old := l_old + 1;
                END IF;
                IF t.orphans_after > 0 THEN
                    l_detail := add_detail(l_detail, 'link ' || t.link_id || ' ' || t.owner || '.' || t.table_name
                                                     || ' ' || n(t.orphans_before) || ' -> ' || n(t.orphans_after));
                END IF;
            END LOOP;
            add_check('P4', CASE WHEN l_new > 0 THEN 'FAIL' WHEN l_old > 0 THEN 'WARN' ELSE 'PASS' END,
                      'Orphans on registry links',
                      l_links || ' links (' || l_by_fk || ' by FK, ' || (l_links - l_by_fk) || ' scanned)', l_detail);
        END IF;

        -- P5 errors
        check_errors(l_status);

        -- P6 temporary indexes
        IF l_no_purge THEN
            add_check('P6', 'SKIP', 'Temporary indexes dropped', 'no purge');
        ELSE
            SELECT COUNT(*) INTO l_total FROM epf_temp_index WHERE run_id = l_run;
            SELECT COUNT(*)
              INTO l_count
              FROM epf_temp_index t
             WHERE t.run_id = l_run
               AND t.dropped_at IS NULL
               AND EXISTS (SELECT 1 FROM dba_indexes i WHERE i.owner = t.owner AND i.index_name = t.index_name);
            add_check('P6', CASE WHEN l_count > 0 THEN 'FAIL' ELSE 'PASS' END, 'Temporary indexes dropped',
                      l_total || ' created, ' || l_count || ' still present');
        END IF;

        -- P7 space measured
        SELECT COUNT(DISTINCT phase),
               COUNT(CASE WHEN method IN ('ESTIMATE', 'UNSUPPORTED') THEN 1 END),
               COUNT(DISTINCT CASE WHEN method = 'BASICFILE_EST'
                                   THEN owner || '.' || segment_name || '.' || partition_name END),
               SUM(CASE WHEN phase = 'BASELINE' THEN used_bytes END),
               SUM(CASE WHEN phase = 'POST_PURGE' THEN used_bytes END)
          INTO l_phases, l_estimated, l_lob_est, l_before, l_now
          FROM epf_space_usage
         WHERE run_id = l_run AND phase IN ('BASELINE', 'POST_PURGE');
        IF g_run.action <> 'PURGE' THEN
            add_check('P7', 'SKIP', 'Space measured inside segments', 'no purge');
        ELSIF l_phases < CASE WHEN l_no_purge THEN 1 ELSE 2 END THEN
            add_check('P7', 'WARN', 'Space measured inside segments', 'not measured');
        ELSE
            add_check('P7', CASE WHEN l_estimated > 0 THEN 'WARN' ELSE 'PASS' END, 'Space measured inside segments',
                      CASE WHEN l_no_purge THEN 'used ' || b(l_before)
                           ELSE 'used ' || b(l_before) || ' -> ' || b(l_now) || ', freed ' || b(l_before - l_now) END
                      || CASE WHEN l_estimated > 0 THEN ', ' || l_estimated || ' segments estimated or unsupported' END
                      || CASE WHEN l_lob_est > 0 THEN ', ' || l_lob_est || ' BASICFILE LOB segments scaled by rows' END);
        END IF;

        -- P8 compaction
        IF g_run.with_compact = 'N' OR l_no_purge THEN
            add_check('P8', 'SKIP', 'Compaction', 'not requested');
        ELSE
            SELECT COUNT(CASE WHEN event_code = 'COMPACTED' THEN 1 END),
                   COUNT(CASE WHEN event_code IN ('COMPACT_SKIPPED', 'COMPACT_FAILED') THEN 1 END),
                   SUM(CASE WHEN event_code = 'COMPACTED' THEN bytes END)
              INTO l_done, l_skipped, l_freed
              FROM epf_event
             WHERE run_id = l_run;
            add_check('P8', CASE WHEN l_skipped > 0 THEN 'WARN' ELSE 'PASS' END, 'Compaction',
                      l_done || ' tables compacted, ' || l_skipped || ' skipped, ' || b(NVL(l_freed, 0)) || ' returned');
        END IF;
        COMMIT;

        SELECT COUNT(CASE WHEN status = 'FAIL' THEN 1 END), COUNT(CASE WHEN status = 'WARN' THEN 1 END)
          INTO l_fail, l_warn
          FROM epf_check
         WHERE run_id = l_run;
        p_verdict   := CASE WHEN l_fail > 0 THEN 'FAIL' WHEN l_warn > 0 THEN 'PASS WITH WARNINGS' ELSE 'PASS' END;
        p_exit_code := CASE WHEN l_fail > 0 THEN 1 WHEN l_warn > 0 THEN 2 ELSE 0 END;
    END evaluate;

    PROCEDURE close_run(p_run_id IN NUMBER, p_status IN VARCHAR2, p_exit_code OUT NUMBER) IS
        l_verdict VARCHAR2(30);
        l_p1      VARCHAR2(10);
    BEGIN
        evaluate(p_run_id, l_verdict, p_exit_code, p_status);
        IF UPPER(p_status) = 'STOPPED' THEN
            p_exit_code := 3;
        END IF;
        -- A plan step is complete when its purge ended without residual rows;
        -- a plan check counts when its preflight ended.
        SELECT MAX(status) INTO l_p1 FROM epf_check WHERE run_id = p_run_id AND check_id = 'P1';
        epf_control.end_plan_step(p_run_id, UPPER(p_status) IN ('SUCCESS', 'WARNING') AND l_p1 = 'PASS');
        epf_control.end_plan_check(p_run_id, p_status);
        epf_control.finish(p_run_id => p_run_id, p_status => p_status, p_verdict => l_verdict,
                           p_exit_code => p_exit_code);
    END close_run;

    -- ------------------------------------------------------------------
    -- Report sections
    -- ------------------------------------------------------------------

    PROCEDURE print_header(p_verdict IN VARCHAR2, p_exit IN NUMBER) IS
        l_label VARCHAR2(20) := epf_util.run_label(g_run.run_id);
    BEGIN
        put(RPAD('=', c_width, '='));
        put(' EPF DATA PURGE REPORT' || LPAD(l_label, c_width - 22));
        put(RPAD('=', c_width, '='));
        put(' Run         ' || l_label || '  ' || g_run.action || '  status ' || g_run.status
            || '  verdict ' || p_verdict || '  exit ' || p_exit);
        put(' Database    ' || g_run.db_name || ' (container ' || g_run.container_name || '), tool version '
            || g_run.tool_version);
        put(' Operator    ' || g_run.os_user || ' on ' || g_run.client_host);
        IF g_run.purge_mode IS NOT NULL THEN
            put(' Parameters  mode ' || g_run.purge_mode || ', depth ' || g_run.depth || ', retention '
                || g_run.retention_days || ' days (cutoff ' || TO_CHAR(g_run.cutoff_date, 'YYYY-MM-DD') || '), batch '
                || n(g_run.batch_size)
                || CASE WHEN g_run.batch_rows IS NOT NULL THEN ' (at most ' || n(g_run.batch_rows) || ' rows)' END
                || ', dry run ' || g_run.dry_run || ', compact ' || g_run.with_compact
                || ', reclaim ' || g_run.with_reclaim);
        ELSIF g_run.action = 'RECLAIM' THEN
            put(' Parameters  ' || CASE g_run.reclaim_mode WHEN 'ASSESS' THEN 'assessment (dry run)'
                                                           WHEN 'RESTORE' THEN 'restore of what reclaims left pending'
                                                           ELSE 'compaction' END
                || ', tablespaces ' || NVL(REPLACE(g_run.reclaim_scope, ',', ', '), 'every candidate')
                || CASE WHEN g_run.reclaim_scratch_bytes IS NOT NULL
                        THEN ', scratch space up to ' || b(g_run.reclaim_scratch_bytes) END
                || CASE WHEN g_run.confirmed_reqs IS NOT NULL THEN ', confirmed ' || g_run.confirmed_reqs END);
        END IF;
        put(' Time        started ' || NVL(TO_CHAR(g_run.started_at, 'YYYY-MM-DD HH24:MI:SS'), '-')
            || ', ended ' || NVL(TO_CHAR(g_run.ended_at, 'YYYY-MM-DD HH24:MI:SS'), '-')
            || ', duration ' || epf_util.fmt_duration(epf_util.elapsed_s(g_run.started_at, g_run.ended_at)));
    END print_header;

    PROCEDURE print_steps IS
    BEGIN
        title('STEPS');
        put('  ' || l('Phase', 10) || l('Step', 22) || l('Scope', 18) || l('Status', 9) || r('Duration', 9) || '  Message');
        FOR s IN (SELECT phase, step_code, scope, status, started_at, ended_at, message
                    FROM epf_step
                   WHERE run_id = g_run.run_id
                   ORDER BY step_seq) LOOP
            put('  ' || l(s.phase, 10) || l(s.step_code, 22) || l(s.scope, 18) || l(s.status, 9)
                || r(CASE WHEN s.started_at IS NOT NULL
                          THEN epf_util.fmt_duration(epf_util.elapsed_s(s.started_at, s.ended_at)) END, 9)
                || '  ' || s.message);
        END LOOP;
    END print_steps;

    PROCEDURE print_results IS
        l_module VARCHAR2(30);
    BEGIN
        title('PURGE RESULTS (clearing modules count non-empty LOB values)');
        put('  ' || l('Table', 46) || l('Action', 7) || r('Eligible', 13) || r('Processed', 13) || r('Residual', 10)
            || r('Rows before', 13) || r('Rows after', 13) || r('Kept before', 13) || r('Kept after', 13)
            || r('Held', 10) || r('Orphans', 12));
        FOR t IN (SELECT m.module_code, m.display_order, e.owner, e.table_name, bf.action,
                         CASE WHEN bf.action = 'CLEAR' THEN bf.nonempty_lob_rows ELSE bf.eligible_rows END AS eligible,
                         a.processed_rows AS processed,
                         CASE WHEN bf.action = 'CLEAR' THEN a.nonempty_lob_rows ELSE a.eligible_rows END AS residual,
                         bf.total_rows AS rows_before, a.total_rows AS rows_after,
                         bf.retained_rows AS kept_before, a.total_rows - a.eligible_rows AS kept_after,
                         bf.held_rows AS held, NVL(a.orphan_rows, bf.orphan_rows) AS orphans
                    FROM epf_table_stat bf
                    JOIN epf_table e ON e.table_id = bf.table_id
                    JOIN epf_module m ON m.module_code = e.module_code
                    LEFT JOIN epf_table_stat a
                      ON a.run_id = bf.run_id AND a.table_id = bf.table_id AND a.phase = 'AFTER'
                   WHERE bf.run_id = g_run.run_id AND bf.phase = 'BEFORE'
                   ORDER BY m.display_order, e.root_table_id, e.delete_order DESC, e.table_id) LOOP
            IF l_module IS NULL OR l_module <> t.module_code THEN
                put('  ' || t.module_code);
                l_module := t.module_code;
            END IF;
            put('   ' || l(t.owner || '.' || t.table_name, 45) || l(LOWER(t.action), 7) || r(n(t.eligible), 13)
                || r(n(t.processed), 13) || r(n(t.residual), 10) || r(n(t.rows_before), 13) || r(n(t.rows_after), 13)
                || r(n(t.kept_before), 13) || r(n(t.kept_after), 13) || r(n(t.held), 10) || r(n(t.orphans), 12));
        END LOOP;
        IF l_module IS NULL THEN
            put('  No table counts recorded for this run.');
        END IF;

        FOR hb IN (SELECT rt.owner || '.' || rt.table_name AS root_table,
                          hr.child_owner || '.' || hr.child_table AS child, hr.constraint_name,
                          hr.parent_owner || '.' || hr.parent_table AS parent, COUNT(*) AS roots
                     FROM epf_held_root hr
                     JOIN epf_table rt ON rt.table_id = hr.table_id
                    WHERE hr.run_id = g_run.run_id
                    GROUP BY rt.owner, rt.table_name, hr.child_owner, hr.child_table, hr.constraint_name,
                             hr.parent_owner, hr.parent_table
                    ORDER BY 1, 2) LOOP
            put('  Held back: ' || n(hb.roots) || ' ' || hb.root_table || ' rows, ' || hb.parent
                || ' rows of their trees referenced by kept ' || hb.child || ' rows (' || hb.constraint_name || ')');
        END LOOP;
    END print_results;

    PROCEDURE print_space IS
        l_last    VARCHAR2(20);
        l_module  VARCHAR2(30);
        l_m_alloc NUMBER;
        l_m_bef   NUMBER;
        l_m_aft   NUMBER;
        l_m_now   NUMBER;
        l_lob_est NUMBER;
        l_lob_carry NUMBER;

        -- Without a phase after the purge (dry run) there is no used after.
        PROCEDURE module_total IS
        BEGIN
            IF l_module IS NOT NULL THEN
                put('   ' || l('Total ' || l_module, 45) || r(b(l_m_alloc), 13) || r(b(l_m_bef), 13)
                    || r(CASE WHEN l_last = 'BASELINE' THEN '-' ELSE b(l_m_aft) END, 13)
                    || r(CASE WHEN l_last = 'BASELINE' THEN '-' ELSE b(l_m_bef - l_m_aft) END, 13)
                    || r(b(l_m_now), 13));
            END IF;
        END module_total;
    BEGIN
        SELECT MAX(phase) KEEP (DENSE_RANK LAST ORDER BY CASE phase WHEN 'BASELINE' THEN 1 WHEN 'POST_PURGE' THEN 2
                                                                    WHEN 'POST_COMPACT' THEN 3 ELSE 0 END)
          INTO l_last
          FROM epf_segment_snap
         WHERE run_id = g_run.run_id;
        IF l_last IS NULL THEN
            RETURN;
        END IF;

        title('SPACE INSIDE SEGMENTS (table, indexes and LOB segments of each table; allocated now: '
              || l_last || ')');
        put('  ' || l('Table', 46) || r('Allocated', 13) || r('Used before', 13) || r('Used after', 13)
            || r('Freed', 13) || r('Alloc. now', 13));
        FOR t IN (SELECT x.module_code, x.parent_owner, x.parent_table,
                         MAX(CASE WHEN x.phase = 'BASELINE' THEN x.alloc END) AS alloc_before,
                         MAX(CASE WHEN x.phase = 'BASELINE' THEN x.used END) AS used_before,
                         MAX(CASE WHEN x.phase = 'POST_PURGE' THEN x.used END) AS used_after,
                         MAX(CASE WHEN x.phase = l_last THEN x.alloc END) AS alloc_now
                    FROM (SELECT ss.module_code, ss.parent_owner, ss.parent_table, ss.phase,
                                 SUM(ss.bytes) AS alloc, SUM(su.used_bytes) AS used
                            FROM epf_segment_snap ss
                            LEFT JOIN epf_space_usage su
                              ON su.run_id = ss.run_id AND su.phase = ss.phase AND su.owner = ss.owner
                             AND su.segment_name = ss.segment_name
                             AND NVL(su.partition_name, '-') = NVL(ss.partition_name, '-')
                           WHERE ss.run_id = g_run.run_id
                           GROUP BY ss.module_code, ss.parent_owner, ss.parent_table, ss.phase) x
                    JOIN epf_module m ON m.module_code = x.module_code
                   GROUP BY x.module_code, m.display_order, x.parent_owner, x.parent_table
                   ORDER BY m.display_order,
                            NVL(MAX(CASE WHEN x.phase = 'BASELINE' THEN x.used END), 0)
                            - NVL(MAX(CASE WHEN x.phase = 'POST_PURGE' THEN x.used END), 0) DESC,
                            x.parent_owner, x.parent_table) LOOP
            CONTINUE WHEN NOT in_depth(t.module_code);
            IF l_module IS NULL OR l_module <> t.module_code THEN
                module_total;
                put('  ' || t.module_code);
                l_module  := t.module_code;
                l_m_alloc := 0;
                l_m_bef   := 0;
                l_m_aft   := 0;
                l_m_now   := 0;
            END IF;
            l_m_alloc := l_m_alloc + NVL(t.alloc_before, 0);
            l_m_bef   := l_m_bef + NVL(t.used_before, 0);
            l_m_aft   := l_m_aft + NVL(t.used_after, t.used_before);
            l_m_now   := l_m_now + NVL(t.alloc_now, 0);
            put('   ' || l(t.parent_owner || '.' || t.parent_table, 45) || r(b(t.alloc_before), 13)
                || r(b(t.used_before), 13) || r(b(t.used_after), 13)
                || r(CASE WHEN t.used_after IS NOT NULL THEN b(t.used_before - t.used_after) END, 13)
                || r(b(t.alloc_now), 13));
        END LOOP;
        module_total;
        SELECT COUNT(CASE WHEN phase = 'BASELINE' THEN 1 END), COUNT(CASE WHEN phase <> 'BASELINE' THEN 1 END)
          INTO l_lob_carry, l_lob_est
          FROM epf_space_usage
         WHERE run_id = g_run.run_id AND method = 'BASICFILE_EST';
        IF l_lob_carry > 0 THEN
            put('  Used before includes ' || l_lob_carry || ' BASICFILE LOB segments carried over from the estimate of an '
                || 'earlier purge: Oracle still reports the space that purge freed as used.');
        END IF;
        IF l_lob_est > 0 THEN
            put('  Used after includes ' || l_lob_est || ' BASICFILE LOB segments estimated from the baseline and the '
                || 'share of LOB data the purge left: Oracle reports the space of deleted or cleared LOB values as '
                || 'used until new values of the same column reuse it.');
        END IF;

        title('DATAFILES');
        put('  ' || l('File', 60) || l('Phase', 14) || r('Size', 12) || r('HWM', 12) || r('Free', 12));
        FOR f IN (SELECT file_name, phase, bytes, hwm_bytes, free_bytes
                    FROM epf_file_snap
                   WHERE run_id = g_run.run_id
                   ORDER BY file_id, CASE phase WHEN 'BASELINE' THEN 1 WHEN 'POST_PURGE' THEN 2
                                                WHEN 'POST_COMPACT' THEN 3 ELSE 4 END) LOOP
            put('  ' || l(f.file_name, 60) || l(f.phase, 14) || r(b(f.bytes), 12) || r(b(f.hwm_bytes), 12)
                || r(b(f.free_bytes), 12));
        END LOOP;

        title('REDO AND UNDO WRITTEN (what the purge kept on disk: DISK)');
        FOR t IN (SELECT e.module_code, ev.object_owner || '.' || ev.object_name AS root_table,
                         SUM(CASE WHEN ev.event_code = 'TREE_REDO' THEN ev.bytes END) AS redo,
                         SUM(CASE WHEN ev.event_code = 'TREE_UNDO' THEN ev.bytes END) AS undo,
                         MAX(ev.rows_affected) AS roots
                    FROM epf_event ev
                    JOIN epf_table e ON e.owner = ev.object_owner AND e.table_name = ev.object_name
                   WHERE ev.run_id = g_run.run_id AND ev.event_code IN ('TREE_REDO', 'TREE_UNDO')
                   GROUP BY e.module_code, ev.object_owner, ev.object_name
                   ORDER BY 1, 2) LOOP
            put('  ' || l(t.module_code, 18) || l(t.root_table, 46) || 'redo ' || r(b(t.redo), 10) || ', undo '
                || r(b(t.undo), 10) || ' for ' || n(t.roots) || ' roots ('
                || b(t.redo / NULLIF(t.roots, 0)) || ' redo per root)');
        END LOOP;
        -- Per table: the redo and undo of its statements over the rows they
        -- processed, and the redo per row estimated from optimizer statistics
        -- before the purge (deleting).
        l_module := NULL;
        FOR t IN (SELECT e.module_code, e.owner || '.' || e.table_name AS table_label, a.processed_rows AS rows_done,
                         a.redo_bytes, a.undo_bytes, bf.est_redo_row
                    FROM epf_table_stat a
                    JOIN epf_table e ON e.table_id = a.table_id
                    JOIN epf_module m ON m.module_code = e.module_code
                    LEFT JOIN epf_table_stat bf
                      ON bf.run_id = a.run_id AND bf.table_id = a.table_id AND bf.phase = 'BEFORE'
                   WHERE a.run_id = g_run.run_id AND a.phase = 'AFTER' AND a.processed_rows > 0
                     AND a.redo_bytes IS NOT NULL
                   ORDER BY m.display_order, a.redo_bytes DESC, e.table_id) LOOP
            IF l_module IS NULL THEN
                put('  ' || l('Per table', 18) || l('Table', 46) || r('Rows', 14) || r('Redo/row', 12)
                    || r('Undo/row', 12) || r('Estimate/row', 14));
            END IF;
            put('  ' || l(CASE WHEN NVL(l_module, '-') <> t.module_code THEN t.module_code END, 18)
                || l(t.table_label, 46) || r(n(t.rows_done), 14)
                || r(b(t.redo_bytes / t.rows_done), 12) || r(b(t.undo_bytes / t.rows_done), 12)
                || r(b(t.est_redo_row), 14));
            put('EPF_TABLE_REDO|' || epf_util.run_label(g_run.run_id) || '|' || t.table_label || '|' || t.rows_done
                || '|' || t.redo_bytes || '|' || t.undo_bytes || '|' || t.est_redo_row);
            l_module := t.module_code;
        END LOOP;
        -- Undo tuning as the purge found it at its start (undo tablespace size
        -- before and after: DATAFILES).
        FOR u IN (SELECT message
                    FROM epf_event
                   WHERE run_id = g_run.run_id AND event_code = 'UNDO_TUNING'
                   ORDER BY event_id
                   FETCH FIRST 1 ROWS ONLY) LOOP
            put('  ' || u.message);
        END LOOP;
    END print_space;

    PROCEDURE print_checks(p_verdict IN VARCHAR2, p_exit IN NUMBER) IS
        l_label VARCHAR2(20) := epf_util.run_label(g_run.run_id);
    BEGIN
        put;
        put(' CHECKS' || LPAD('run ' || l_label, c_width - 7));
        put(' ' || RPAD('-', c_width - 1, '-'));
        FOR c IN (SELECT check_id, status, title, value, detail
                    FROM epf_check
                   WHERE run_id = g_run.run_id
                   ORDER BY check_id) LOOP
            put(' ' || l(c.check_id, 4) || RPAD(c.title || ' ', 44, '.') || ' ' || l(c.status, 6) || c.value);
            IF c.detail IS NOT NULL AND c.status <> 'PASS' THEN
                put('      ' || c.detail);
            END IF;
        END LOOP;
        put(' ' || RPAD('-', c_width - 1, '-'));
        put(' VERDICT  ' || p_verdict || '  (exit ' || p_exit || ')');
        put;
        FOR c IN (SELECT check_id, status, value, title
                    FROM epf_check
                   WHERE run_id = g_run.run_id
                   ORDER BY check_id) LOOP
            put('EPF_CHECK|' || l_label || '|' || c.check_id || '|' || c.status || '|' || c.value || '|' || c.title);
        END LOOP;
        FOR s IN (SELECT phase, step_code, scope, status, started_at, ended_at
                    FROM epf_step
                   WHERE run_id = g_run.run_id
                   ORDER BY step_seq) LOOP
            put('EPF_STEP|' || l_label || '|' || s.phase || '|' || s.step_code || '|' || s.scope || '|' || s.status
                || '|' || CASE WHEN s.started_at IS NOT NULL
                               THEN ROUND(epf_util.elapsed_s(s.started_at, s.ended_at)) END);
        END LOOP;
        put('EPF_VERDICT|' || l_label || '|' || p_verdict || '|exit=' || p_exit);
    END print_checks;

    -- ------------------------------------------------------------------
    -- Requirements, forecast, simulation
    -- ------------------------------------------------------------------

    -- Signed error of a forecast against the actual value, in percent.
    FUNCTION pct_error(p_forecast IN NUMBER, p_actual IN NUMBER) RETURN VARCHAR2 IS
        l_pct NUMBER;
    BEGIN
        IF p_forecast IS NULL OR p_actual IS NULL OR p_actual = 0 THEN
            RETURN '-';
        END IF;
        l_pct := ROUND(100 * (p_forecast - p_actual) / p_actual, 1);
        RETURN CASE WHEN l_pct > 0 THEN '+' END || TO_CHAR(l_pct, 'FM999999990.0') || '%';
    END pct_error;

    FUNCTION dur(p_seconds IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN p_seconds IS NULL THEN '-' ELSE epf_util.fmt_duration(p_seconds) END;
    END dur;

    -- Requirements measured by the run's preflight, with the ways to meet the
    -- ones not met, and whether a purge can start (READY).
    PROCEDURE print_requirements IS
        l_run   NUMBER := g_run.run_id;
        l_label VARCHAR2(20) := epf_util.run_label(g_run.run_id);
        l_count NUMBER;
        l_met   NUMBER;
        l_block NUMBER;
        l_unmet VARCHAR2(400);
        l_slow  VARCHAR2(400);
        -- A requirement that is not blocking makes a purge slower; for a
        -- reclaim it is advice.
        l_soft  VARCHAR2(20) := CASE WHEN g_run.action = 'RECLAIM' THEN 'advice' ELSE 'slower only' END;
    BEGIN
        SELECT COUNT(*),
               COUNT(CASE WHEN status <> 'NOT_MET' THEN 1 END),
               COUNT(CASE WHEN status = 'NOT_MET' AND blocking = 'Y' THEN 1 END),
               LISTAGG(CASE WHEN status = 'NOT_MET' AND blocking = 'Y' THEN req_code END, ', ') WITHIN GROUP (ORDER BY seq),
               LISTAGG(CASE WHEN status = 'NOT_MET' AND blocking = 'N' THEN req_code END, ', ') WITHIN GROUP (ORDER BY seq)
          INTO l_count, l_met, l_block, l_unmet, l_slow
          FROM epf_requirement
         WHERE run_id = l_run;
        IF l_count = 0 THEN
            RETURN;
        END IF;
        title('REQUIREMENTS' || CASE WHEN g_run.dry_run = 'N' AND g_run.action = 'PURGE'
                                     THEN ' (checked when the purge started)'
                                     WHEN g_run.dry_run = 'N' AND g_run.action = 'RECLAIM'
                                     THEN ' (checked when the reclaim started)' END);
        FOR q IN (SELECT req_code, status, blocking, title, why, measured, met_by
                    FROM epf_requirement
                   WHERE run_id = l_run
                   ORDER BY seq) LOOP
            put('  ' || l(q.req_code, 12) || RPAD(q.title || ' ', 40, '.') || ' '
                || CASE q.status WHEN 'MET' THEN 'MET' WHEN 'NOT_MET' THEN 'NOT MET' ELSE 'NOT APPLICABLE' END
                || CASE WHEN q.status = 'NOT_MET' AND q.blocking = 'N' THEN ' (' || l_soft || ')' END);
            IF q.status = 'NOT_MET' THEN
                put('      Why: ' || q.why);
            END IF;
            put('      ' || q.measured);
            IF q.status = 'NOT_MET' THEN
                FOR o IN (SELECT met, title, detail
                            FROM epf_req_option
                           WHERE run_id = l_run AND req_code = q.req_code
                           ORDER BY seq) LOOP
                    put('      [' || CASE o.met WHEN 'Y' THEN 'x' ELSE ' ' END || '] ' || l(o.title, 52) || o.detail);
                END LOOP;
            ELSE
                FOR o IN (SELECT title FROM epf_req_option
                           WHERE run_id = l_run AND req_code = q.req_code AND met = 'Y'
                           ORDER BY seq) LOOP
                    put('      [x] ' || o.title);
                END LOOP;
            END IF;
        END LOOP;
        put(' ' || RPAD('-', c_width - 1, '-'));
        put(' RESULT  ' || CASE WHEN l_block > 0 THEN 'NOT READY: ' || l_block || ' blocking requirement'
                                                    || CASE WHEN l_block > 1 THEN 's' END || ' not met (' || l_unmet || ')'
                                ELSE 'READY: ' || l_met || ' of ' || l_count || ' met' END
            || CASE WHEN l_slow IS NOT NULL THEN '; ' || l_soft || ': ' || l_slow END);
        FOR q IN (SELECT req_code, status, blocking, met_by FROM epf_requirement WHERE run_id = l_run ORDER BY seq) LOOP
            put('EPF_REQ|' || l_label || '|' || q.req_code || '|' || q.status || '|' || q.blocking || '|' || q.met_by);
        END LOOP;
    END print_requirements;

    -- Forecast per module of the run: SIMULATION for a dry run (exact rows),
    -- ESTIMATE for a preflight (eligible roots, estimates).
    PROCEDURE print_forecast_table(p_origin IN VARCHAR2) IS
        l_run   NUMBER := g_run.run_id;
        l_count NUMBER;
        l_rows  NUMBER := 0;
        l_roots NUMBER := 0;
        l_batch NUMBER := 0;
        l_redo  NUMBER := 0;
        l_undo  NUMBER := 0;
        l_secs  NUMBER := 0;
        l_freed NUMBER := 0;
    BEGIN
        SELECT COUNT(*) INTO l_count FROM epf_forecast WHERE run_id = l_run AND origin = p_origin;
        IF l_count = 0 THEN
            RETURN;
        END IF;
        title(CASE p_origin WHEN 'DRY_RUN' THEN 'SIMULATION (dry run: nothing was changed)'
                            ELSE 'ESTIMATE (rows before the cutoff are counted exactly by a dry run)' END);
        put('  ' || l('Module', 18) || r('Rows', 14) || r('Roots', 12) || r('Batches', 9) || r('Redo written', 14)
            || r('Undo written', 14) || r('Deleting', 10) || r('Space freed', 13));
        FOR x IN (SELECT f.module_code, f.row_count, f.roots, f.batches, f.redo_bytes, f.undo_bytes,
                         f.delete_seconds, f.freed_bytes
                    FROM epf_forecast f
                    JOIN epf_module m ON m.module_code = f.module_code
                   WHERE f.run_id = l_run AND f.origin = p_origin
                   ORDER BY m.display_order) LOOP
            put('  ' || l(x.module_code, 18) || r(n(x.row_count), 14) || r(n(x.roots), 12) || r(n(x.batches), 9)
                || r(b(x.redo_bytes), 14) || r(b(x.undo_bytes), 14) || r(dur(x.delete_seconds), 10)
                || r(b(x.freed_bytes), 13));
            l_rows  := l_rows + NVL(x.row_count, 0);
            l_roots := l_roots + NVL(x.roots, 0);
            l_batch := l_batch + NVL(x.batches, 0);
            l_redo  := l_redo + NVL(x.redo_bytes, 0);
            l_undo  := l_undo + NVL(x.undo_bytes, 0);
            l_secs  := l_secs + NVL(x.delete_seconds, 0);
            l_freed := l_freed + NVL(x.freed_bytes, 0);
        END LOOP;
        IF l_count > 1 THEN
            put('  ' || l('Total', 18) || r(CASE WHEN p_origin = 'DRY_RUN' THEN n(l_rows) ELSE '-' END, 14)
                || r(n(l_roots), 12) || r(n(l_batch), 9) || r(b(l_redo), 14) || r(b(l_undo), 14) || r(dur(l_secs), 10)
                || r(CASE WHEN p_origin = 'DRY_RUN' THEN b(l_freed) ELSE '-' END, 13));
        END IF;
        -- One line per basis; the modules it applies to when they differ.
        SELECT COUNT(DISTINCT redo_basis) INTO l_count
          FROM epf_forecast
         WHERE run_id = l_run AND origin = p_origin AND redo_basis IS NOT NULL;
        FOR x IN (SELECT f.redo_basis,
                         LISTAGG(f.module_code, ', ') WITHIN GROUP (ORDER BY m.display_order) AS modules
                    FROM epf_forecast f
                    JOIN epf_module m ON m.module_code = f.module_code
                   WHERE f.run_id = l_run AND f.origin = p_origin AND f.redo_basis IS NOT NULL
                   GROUP BY f.redo_basis
                   ORDER BY MIN(m.display_order)) LOOP
            put('  Redo and undo ' || CASE WHEN x.redo_basis LIKE 'per row%' THEN x.redo_basis
                                           ELSE 'per root, ' || x.redo_basis END
                || CASE WHEN l_count > 1 THEN ' (' || x.modules || ')' END);
        END LOOP;
        SELECT COUNT(DISTINCT time_basis) INTO l_count
          FROM epf_forecast
         WHERE run_id = l_run AND origin = p_origin AND time_basis IS NOT NULL;
        FOR x IN (SELECT f.time_basis,
                         LISTAGG(f.module_code, ', ') WITHIN GROUP (ORDER BY m.display_order) AS modules
                    FROM epf_forecast f
                    JOIN epf_module m ON m.module_code = f.module_code
                   WHERE f.run_id = l_run AND f.origin = p_origin AND f.time_basis IS NOT NULL
                   GROUP BY f.time_basis
                   ORDER BY MIN(m.display_order)) LOOP
            put('  Deleting time: ' || x.time_basis || CASE WHEN l_count > 1 THEN ' (' || x.modules || ')' END);
        END LOOP;
    END print_forecast_table;

    -- Roots held back, triggers that would fire, and application sessions now
    -- (dry run).
    PROCEDURE print_simulation_notes IS
        l_run   NUMBER := g_run.run_id;
        l_held  NUMBER;
        l_trig  VARCHAR2(4000);
        l_count NUMBER := 0;
        l_apps  SYS.ODCIVARCHAR2LIST := epf_util.split_list(epf_util.setting('app_schemas'));
        l_sess  NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_held FROM epf_held_root WHERE run_id = l_run;
        put('  Held back       ' || CASE WHEN l_held = 0 THEN 'none (no kept row references a row to purge)'
                                         ELSE n(l_held) || ' roots, still referenced by rows that are kept (PURGE RESULTS)' END);
        -- Triggers the purge fires: delete triggers on the tables of a
        -- deleting module, update triggers on the tables whose LOB values a
        -- clearing module clears.
        FOR t IN (SELECT tr.owner, tr.trigger_name, tr.table_owner, tr.table_name, tr.triggering_event, e.module_code,
                         e.lob_clear
                    FROM dba_triggers tr
                    JOIN epf_table e ON e.owner = tr.table_owner AND e.table_name = tr.table_name AND e.active = 'Y'
                   WHERE tr.status = 'ENABLED'
                     AND (tr.triggering_event LIKE '%DELETE%' OR tr.triggering_event LIKE '%UPDATE%')
                   ORDER BY tr.table_owner, tr.table_name, tr.trigger_name) LOOP
            CONTINUE WHEN NOT in_depth(t.module_code);
            IF module_deletes(t.module_code) THEN
                CONTINUE WHEN t.triggering_event NOT LIKE '%DELETE%';
            ELSE
                CONTINUE WHEN t.triggering_event NOT LIKE '%UPDATE%' OR NVL(t.lob_clear, 'N') <> 'Y';
            END IF;
            l_count := l_count + 1;
            IF l_count <= 5 THEN
                l_trig := l_trig || CASE WHEN l_count > 1 THEN '; ' END || t.owner || '.' || t.trigger_name || ' on '
                          || t.table_owner || '.' || t.table_name || ' (' || LOWER(t.triggering_event) || ')';
            END IF;
        END LOOP;
        put('  Triggers        ' || CASE WHEN l_count = 0 THEN 'none that the purge fires'
                                         ELSE l_count || ' that fire for every row the purge deletes or clears: ' || l_trig
                                              || CASE WHEN l_count > 5 THEN ' and ' || (l_count - 5) || ' more' END END);
        SELECT COUNT(*) INTO l_sess
          FROM v$session
         WHERE username IN (SELECT column_value FROM TABLE(l_apps));
        put('  Activity now    ' || l_sess || ' sessions of ' || epf_util.setting('app_schemas')
            || CASE WHEN l_sess > 0 THEN ': rows they lock make batches wait' END);
    END print_simulation_notes;

    -- Rows, redo, archive space and space freed for the requested retention
    -- and longer ones (a longer retention purges less).
    PROCEDURE print_retention_options IS
        l_run    NUMBER := g_run.run_id;
        l_count  NUMBER;
        l_margin NUMBER := 1 + epf_util.setting_num('archive_margin_pct') / 100;
        l_room   NUMBER;
        l_noarch NUMBER;
        l_rows    NUMBER;
        l_freed   NUMBER;
        l_redo    NUMBER;
        l_unknown NUMBER;
        l_fits    VARCHAR2(10);
        l_days    NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_count FROM epf_retention_option WHERE run_id = l_run;
        IF l_count = 0 THEN
            RETURN;
        END IF;
        SELECT MAX(room_bytes), COUNT(CASE WHEN met_by = 'NOARCHIVELOG' THEN 1 END)
          INTO l_room, l_noarch
          FROM epf_requirement
         WHERE run_id = l_run AND req_code = 'ARCHIVE';
        title('RETENTION OPTIONS (a longer retention purges less'
              || CASE WHEN l_noarch > 0 THEN '; NOARCHIVELOG: no archive space needed'
                      WHEN l_room IS NOT NULL THEN '; free archive space ' || b(l_room) END || ')');
        put('  ' || l('Retention', 11) || l('Cutoff', 12) || r('Roots', 12) || r('Rows', 14) || r('Redo', 11)
            || r('Archive need', 14) || r('Space freed', 13) || r('Fits', 6));
        FOR o IN (SELECT ro.retention_days, MIN(ro.cutoff_date) AS cutoff_date, SUM(ro.roots) AS roots,
                         SUM(ro.roots * te.redo_root) AS redo_bytes,
                         COUNT(CASE WHEN ro.roots > 0 AND te.redo_root IS NULL THEN 1 END) AS unknown
                    FROM epf_retention_option ro
                    LEFT JOIN epf_tree_est te ON te.run_id = ro.run_id AND te.table_id = ro.table_id
                   WHERE ro.run_id = l_run
                   GROUP BY ro.retention_days
                   ORDER BY ro.retention_days DESC) LOOP
            l_days := o.retention_days;
            -- A dry run scales its own forecast per module (redo per row
            -- included); a preflight has the estimates per root only.
            SELECT SUM(x.roots * f.row_count / NULLIF(f.roots, 0)), SUM(x.roots * f.freed_bytes / NULLIF(f.roots, 0)),
                   CASE WHEN COUNT(CASE WHEN f.redo_bytes IS NULL THEN 1 END) = 0
                        THEN SUM(x.roots * f.redo_bytes / NULLIF(f.roots, 0)) END
              INTO l_rows, l_freed, l_redo
              FROM (SELECT t.module_code, SUM(ro.roots) AS roots
                      FROM epf_retention_option ro
                      JOIN epf_table t ON t.table_id = ro.table_id
                     WHERE ro.run_id = l_run AND ro.retention_days = l_days
                     GROUP BY t.module_code) x
              JOIN epf_forecast f ON f.run_id = l_run AND f.origin = 'DRY_RUN' AND f.module_code = x.module_code;
            l_unknown := o.unknown;
            IF l_redo IS NULL THEN
                l_redo := o.redo_bytes;
            ELSE
                l_unknown := 0;
            END IF;
            l_fits := CASE WHEN l_noarch > 0 THEN 'n/a'
                           WHEN l_room IS NULL OR l_unknown > 0 THEN '?'
                           WHEN NVL(l_redo, 0) * l_margin <= l_room THEN 'yes' ELSE 'no' END;
            put('  ' || l(o.retention_days, 11) || l(TO_CHAR(o.cutoff_date, 'YYYY-MM-DD'), 12) || r(n(o.roots), 12)
                || r(n(l_rows), 14)
                || r(CASE WHEN l_unknown > 0 THEN '-' ELSE b(NVL(l_redo, 0)) END, 11)
                || r(CASE WHEN l_unknown > 0 OR l_noarch > 0 THEN '-' ELSE b(NVL(l_redo, 0) * l_margin) END, 14)
                || r(b(l_freed), 13) || r(l_fits, 6)
                || CASE WHEN o.retention_days = g_run.retention_days THEN '  (requested)' END);
        END LOOP;
        FOR x IN (SELECT detail FROM epf_req_option
                   WHERE run_id = l_run AND req_code = 'ARCHIVE' AND option_code = 'SMALLER_RUNS') LOOP
            put('  Smaller runs: ' || x.detail);
        END LOOP;
    END print_retention_options;

    -- Predicted outcome of a dry run: the first blocking requirement not met
    -- decides where it would fail; otherwise it would complete.
    PROCEDURE print_expected IS
        l_run     NUMBER := g_run.run_id;
        l_label   VARCHAR2(20) := epf_util.run_label(g_run.run_id);
        l_code    VARCHAR2(20);
        l_text    VARCHAR2(4000);
        l_notes   VARCHAR2(4000);
        l_cum     NUMBER := 0;
        l_batch   NUMBER;
        l_secs    NUMBER;
        l_freed   NUMBER;
        l_redo    NUMBER;

        PROCEDURE note(p_text IN VARCHAR2) IS
        BEGIN
            l_notes := l_notes || CASE WHEN l_notes IS NOT NULL THEN '; ' END || p_text;
        END note;
    BEGIN
        FOR q IN (SELECT req_code, blocking, needed_bytes, room_bytes
                    FROM epf_requirement
                   WHERE run_id = l_run AND status = 'NOT_MET'
                   ORDER BY seq) LOOP
            CASE q.req_code
                WHEN 'ARCHIVE' THEN
                    IF l_code IS NULL AND q.room_bytes IS NULL THEN
                        l_code := 'MAY_FAIL';
                        l_text := 'archived logs need about ' || b(q.needed_bytes)
                                  || ' and the free space of the archive destination cannot be measured';
                    ELSIF l_code IS NULL THEN
                        FOR f IN (SELECT f.module_code, f.redo_bytes, f.batches
                                    FROM epf_forecast f
                                    JOIN epf_module m ON m.module_code = f.module_code
                                   WHERE f.run_id = l_run AND f.origin = 'DRY_RUN'
                                   ORDER BY m.display_order) LOOP
                            IF f.redo_bytes IS NOT NULL AND f.batches > 0 AND l_cum + f.redo_bytes > q.room_bytes THEN
                                l_batch := GREATEST(1, CEIL((q.room_bytes - l_cum) / (f.redo_bytes / f.batches)));
                                l_code  := 'FAIL';
                                l_text  := 'the archive destination would be full at about batch ' || n(l_batch)
                                           || ' of ' || n(f.batches) || ' in ' || f.module_code || ' ('
                                           || b(q.room_bytes) || ' of archived logs); from then on the whole database '
                                           || 'waits (ORA-00257)';
                                EXIT;
                            END IF;
                            l_cum := l_cum + NVL(f.redo_bytes, 0);
                        END LOOP;
                        IF l_code IS NULL THEN
                            l_code := 'MAY_FAIL';
                            l_text := 'archived logs need about ' || b(q.needed_bytes) || ' with the margin, '
                                      || b(q.room_bytes) || ' free';
                        END IF;
                    END IF;
                WHEN 'UNDO' THEN
                    IF l_code IS NULL AND q.needed_bytes > q.room_bytes THEN
                        l_code := 'FAIL';
                        l_text := 'the first batch would fail: one batch needs ' || b(q.needed_bytes)
                                  || ' of undo, the undo tablespace can hold ' || b(q.room_bytes) || ' (ORA-30036)';
                    ELSIF l_code IS NULL AND 4 * q.needed_bytes > q.room_bytes THEN
                        l_code := 'MAY_FAIL';
                        l_text := 'one batch needs ' || b(q.needed_bytes) || ' of undo; the undo tablespace can hold '
                                  || b(q.room_bytes);
                    ELSE
                        note('the undo tablespace would grow during the purge (no undo tuning)');
                    END IF;
                WHEN 'TEMP' THEN
                    IF l_code IS NULL THEN
                        l_code := 'FAIL';
                        l_text := 'recording the keys would fail: TEMP needs about ' || b(q.needed_bytes) || ', '
                                  || b(q.room_bytes) || ' free (ORA-01652); nothing would be deleted';
                    END IF;
                WHEN 'BACKUP' THEN
                    note('no backup to go back to');
                WHEN 'REDO_LOGS' THEN
                    note('slower: one batch writes more redo than an online log holds');
                WHEN 'INDEX_SPACE' THEN
                    note('slower: not every temporary index fits');
                ELSE
                    NULL;
            END CASE;
        END LOOP;
        SELECT SUM(delete_seconds), SUM(freed_bytes), SUM(redo_bytes)
          INTO l_secs, l_freed, l_redo
          FROM epf_forecast
         WHERE run_id = l_run AND origin = 'DRY_RUN';
        IF l_code IS NULL THEN
            l_code := 'COMPLETE';
            l_text := 'in about ' || dur(l_secs) || ' of deleting'
                      || CASE WHEN l_freed IS NOT NULL THEN ', about ' || b(l_freed) || ' freed inside the tables' END;
        END IF;
        put;
        put(' EXPECTED  ' || CASE l_code WHEN 'COMPLETE' THEN 'WOULD COMPLETE ' WHEN 'FAIL' THEN 'WOULD FAIL: '
                                         ELSE 'MAY FAIL: ' END || l_text);
        IF l_notes IS NOT NULL THEN
            put('           ' || l_notes);
        END IF;
        put('EPF_EXPECTED|' || l_label || '|' || l_code || '|' || ROUND(l_secs) || '|' || ROUND(l_freed) || '|'
            || ROUND(l_redo));
    END print_expected;

    -- Result of a purge against the latest forecast with the same cutoff and
    -- mode, per module: the latest dry run, otherwise the latest preflight
    -- (the purge's own), made before this purge and after the last purge of
    -- the module.
    PROCEDURE print_forecast_result IS
        l_run      NUMBER := g_run.run_id;
        l_label    VARCHAR2(20) := epf_util.run_label(g_run.run_id);
        l_cutoff   DATE := g_run.cutoff_date;
        l_mode     VARCHAR2(30) := g_run.purge_mode;
        l_created  TIMESTAMP := g_run.created_at;
        l_status   VARCHAR2(20) := g_run.status;
        l_module   VARCHAR2(30);
        l_shown    BOOLEAN := FALSE;
        l_fc_run   NUMBER;
        l_origin   VARCHAR2(10);
        l_f_rows   NUMBER;
        l_f_redo   NUMBER;
        l_f_undo   NUMBER;
        l_f_secs   NUMBER;
        l_f_freed  NUMBER;
        l_rows     NUMBER;
        l_redo     NUMBER;
        l_undo     NUMBER;
        l_secs     NUMBER;
        l_freed    NUMBER;

        PROCEDURE line(p_measure IN VARCHAR2, p_code IN VARCHAR2, p_forecast IN NUMBER, p_actual IN NUMBER,
                       p_text_f IN VARCHAR2, p_text_a IN VARCHAR2) IS
        BEGIN
            put('  ' || l(CASE WHEN p_code = 'ROWS' THEN l_module END, 18) || l(p_measure, 16)
                || r(p_text_f, 16) || r(p_text_a, 16) || r(pct_error(p_forecast, p_actual), 10));
            put('EPF_FORECAST|' || l_label || '|' || l_module || '|' || p_code || '|' || ROUND(p_forecast) || '|'
                || ROUND(p_actual) || '|' || epf_util.run_label(l_fc_run) || '|' || l_origin);
        END line;
    BEGIN
        FOR m IN (SELECT DISTINCT t.module_code, md.display_order
                    FROM epf_table_stat s
                    JOIN epf_table t ON t.table_id = s.table_id
                    JOIN epf_module md ON md.module_code = t.module_code
                   WHERE s.run_id = l_run AND s.phase = 'AFTER'
                   ORDER BY md.display_order) LOOP
            l_module := m.module_code;
            l_fc_run := NULL;
            l_origin := NULL;
            FOR f IN (SELECT f.run_id, f.origin, f.row_count, f.redo_bytes, f.undo_bytes, f.delete_seconds, f.freed_bytes
                        FROM epf_forecast f
                        JOIN epf_run fr ON fr.run_id = f.run_id
                       WHERE f.module_code = l_module
                         AND fr.cutoff_date = l_cutoff AND fr.purge_mode = l_mode
                         AND fr.created_at <= l_created
                         AND (fr.run_id = l_run OR fr.status IN ('SUCCESS', 'WARNING', 'RUNNING'))
                         AND NOT EXISTS (SELECT 1
                                           FROM epf_run p
                                           JOIN epf_table_stat ps ON ps.run_id = p.run_id AND ps.phase = 'AFTER'
                                           JOIN epf_table pt ON pt.table_id = ps.table_id
                                          WHERE p.action = 'PURGE' AND p.dry_run = 'N' AND p.run_id <> l_run
                                            AND p.created_at > fr.created_at AND p.created_at < l_created
                                            AND pt.module_code = l_module AND ps.processed_rows > 0)
                       ORDER BY CASE f.origin WHEN 'DRY_RUN' THEN 0 ELSE 1 END, f.run_id DESC
                       FETCH FIRST 1 ROWS ONLY) LOOP
                l_fc_run  := f.run_id;
                l_origin  := f.origin;
                l_f_rows  := f.row_count;
                l_f_redo  := f.redo_bytes;
                l_f_undo  := f.undo_bytes;
                l_f_secs  := f.delete_seconds;
                l_f_freed := f.freed_bytes;
            END LOOP;
            IF NOT l_shown THEN
                title('FORECAST AND RESULT (error = forecast against actual)');
                put('  ' || l('Module', 18) || l('Measure', 16) || r('Forecast', 16) || r('Actual', 16) || r('Error', 10));
                l_shown := TRUE;
            END IF;
            IF l_fc_run IS NULL THEN
                put('  ' || l(l_module, 18) || 'no forecast with the same cutoff before this purge (a dry run makes one)');
                CONTINUE;
            END IF;
            SELECT SUM(s.processed_rows)
              INTO l_rows
              FROM epf_table_stat s
              JOIN epf_table t ON t.table_id = s.table_id
             WHERE s.run_id = l_run AND s.phase = 'AFTER' AND t.module_code = l_module;
            SELECT SUM(CASE WHEN ev.event_code = 'TREE_REDO' THEN ev.bytes END),
                   SUM(CASE WHEN ev.event_code = 'TREE_UNDO' THEN ev.bytes END)
              INTO l_redo, l_undo
              FROM epf_event ev
              JOIN epf_table t ON t.owner = ev.object_owner AND t.table_name = ev.object_name
             WHERE ev.run_id = l_run AND ev.event_code IN ('TREE_REDO', 'TREE_UNDO') AND t.module_code = l_module;
            SELECT MAX(epf_util.elapsed_s(started_at, ended_at))
              INTO l_secs
              FROM epf_step
             WHERE run_id = l_run AND step_code = 'PROCESS_BATCHES' AND scope = l_module;
            SELECT SUM(CASE WHEN su.phase = 'BASELINE' THEN su.used_bytes END)
                   - SUM(CASE WHEN su.phase = 'POST_PURGE' THEN su.used_bytes END)
              INTO l_freed
              FROM epf_segment_snap ss
              JOIN epf_space_usage su
                ON su.run_id = ss.run_id AND su.phase = ss.phase AND su.owner = ss.owner
               AND su.segment_name = ss.segment_name AND NVL(su.partition_name, '-') = NVL(ss.partition_name, '-')
             WHERE ss.run_id = l_run AND ss.phase IN ('BASELINE', 'POST_PURGE') AND ss.module_code = l_module;
            put('  ' || l(l_module, 18) || 'forecast of ' || epf_util.run_label(l_fc_run)
                || CASE l_origin WHEN 'DRY_RUN' THEN ' (dry run)' ELSE ' (preflight, estimated)' END);
            line('rows', 'ROWS', l_f_rows, l_rows, n(l_f_rows), n(l_rows));
            line('redo written', 'REDO', l_f_redo, l_redo, b(l_f_redo), b(l_redo));
            line('undo written', 'UNDO', l_f_undo, l_undo, b(l_f_undo), b(l_undo));
            line('deleting time', 'SECONDS', l_f_secs, l_secs, dur(l_f_secs), dur(l_secs));
            line('space freed', 'FREED', l_f_freed, l_freed, b(l_f_freed), b(l_freed));
        END LOOP;
        IF l_shown AND l_status IN ('STOPPED', 'FAILED') THEN
            put('  The purge ended ' || l_status || ': the actual values cover only what it did.');
        END IF;
    END print_forecast_result;

    -- What a purge kept on disk while it ran (DISK_USE): the most undo it held
    -- against the undo tablespace's limit, and where its redo went.
    PROCEDURE print_disk IS
    BEGIN
        FOR d IN (SELECT message
                    FROM epf_event
                   WHERE run_id = g_run.run_id AND event_code = 'DISK_USE'
                   ORDER BY event_id DESC
                   FETCH FIRST 1 ROWS ONLY) LOOP
            put;
            put(' DISK      ' || d.message);
        END LOOP;
    END print_disk;

    -- ------------------------------------------------------------------
    -- Plans
    -- ------------------------------------------------------------------

    -- Choices of a run as one line: batch size, undo tuning, redo log
    -- sizing, backup choice, confirmations.
    FUNCTION choices_text(p_run_id IN NUMBER) RETURN VARCHAR2 IS
        l_text VARCHAR2(400);
    BEGIN
        FOR r IN (SELECT batch_size, with_undo_tuning, with_redo_logs, backup_choice, confirmed_reqs
                    FROM epf_run
                   WHERE run_id = p_run_id) LOOP
            l_text := 'batch ' || r.batch_size
                      || CASE WHEN r.with_undo_tuning = 'Y' THEN ', undo tuning' END
                      || CASE WHEN r.with_redo_logs = 'Y' THEN ', redo logs enlarged when the purge starts' END
                      || CASE r.backup_choice WHEN 'NONE' THEN ', no backup'
                                              WHEN 'CONFIRMED' THEN ', backup made another way' END
                      || CASE WHEN r.confirmed_reqs IS NOT NULL THEN ', confirmed by the DBA: ' || r.confirmed_reqs END;
        END LOOP;
        RETURN l_text;
    END choices_text;

    -- A plan with its steps: scope, who planned it and when, the limit of a
    -- run, the choices its purges follow, each step with its estimates and
    -- state, and the next step. p_note follows the title. Machine lines:
    --   EPF_PLAN|<plan>|<plan_id>|<status>|<mode>|<depth>|<cutoff>|<retention|->
    --           |<steps>|<done>|<next step|->|<next cutoff|->|<preflight run>
    --           |<checked at>|<minutes since checked>|<batch>|<undo Y|N>
    --           |<redo logs Y|N>|<backup|->|<confirmed|->|<ready Y|N|->|<created by>
    --           |<max redo bytes of the plan's preflight|->|<checked within preflight_valid_h Y|N>
    --   EPF_PLAN_STEP|<plan>|<step>|<cutoff>|<roots>|<rows>|<redo>|<status>|<fits Y|N>|<last run|->
    PROCEDURE print_plan_detail(p_plan_id IN NUMBER, p_note IN VARCHAR2 DEFAULT NULL) IS
        l_plan    epf_plan%ROWTYPE;
        l_pre     epf_run%ROWTYPE;
        l_label   VARCHAR2(20) := epf_util.plan_label(p_plan_id);
        l_total   NUMBER;
        l_done    NUMBER;
        l_next    NUMBER;
        l_next_ct DATE;
        l_noarch  NUMBER;
        l_ready   VARCHAR2(1);
        l_margin  NUMBER := 1 + epf_util.setting_num('archive_margin_pct') / 100;
        l_open    BOOLEAN;
        l_state   VARCHAR2(200);
    BEGIN
        SELECT * INTO l_plan FROM epf_plan WHERE plan_id = p_plan_id;
        FOR r IN (SELECT * FROM epf_run WHERE run_id = l_plan.preflight_run_id) LOOP
            l_pre := r;
        END LOOP;
        l_open := l_plan.status IN ('READY', 'IN_PROGRESS');
        SELECT COUNT(*), COUNT(CASE WHEN status = 'DONE' THEN 1 END), MIN(CASE WHEN status = 'PENDING' THEN step_no END)
          INTO l_total, l_done, l_next
          FROM epf_plan_step
         WHERE plan_id = p_plan_id;
        SELECT MAX(cutoff_date) INTO l_next_ct FROM epf_plan_step WHERE plan_id = p_plan_id AND step_no = l_next;
        SELECT COUNT(CASE WHEN req_code = 'ARCHIVE' AND met_by = 'NOARCHIVELOG' THEN 1 END),
               CASE WHEN COUNT(*) = 0 THEN '-'
                    WHEN COUNT(CASE WHEN status = 'NOT_MET' AND blocking = 'Y' THEN 1 END) = 0 THEN 'Y' ELSE 'N' END
          INTO l_noarch, l_ready
          FROM epf_requirement
         WHERE run_id = l_plan.preflight_run_id;

        title('PLAN ' || l_label || '  ' || l_plan.status || ': ' || l_done || ' of ' || l_total || ' steps done'
              || CASE WHEN l_open AND l_next IS NOT NULL THEN ', next: step ' || l_next || ', rows before '
                                                             || TO_CHAR(l_next_ct, 'YYYY-MM-DD') END);
        IF p_note IS NOT NULL THEN
            put('  ' || p_note);
        END IF;
        put('  Scope       mode ' || l_plan.purge_mode || ', depth ' || l_plan.depth || ', rows before '
            || TO_CHAR(l_plan.cutoff_date, 'YYYY-MM-DD')
            || CASE WHEN l_plan.retention_days IS NOT NULL THEN ' (retention ' || l_plan.retention_days
                                                                || ' days when planned)' END);
        put('  Planned     by ' || epf_util.run_label(l_plan.created_run_id) || ' on '
            || TO_CHAR(l_plan.created_at, 'YYYY-MM-DD HH24:MI') || ' (' || NVL(l_plan.created_by, '-') || ')'
            || CASE WHEN l_plan.preflight_run_id <> l_plan.created_run_id THEN
                        '; checked again by ' || epf_util.run_label(l_plan.preflight_run_id) || ' at '
                        || TO_CHAR(l_plan.checked_at, 'YYYY-MM-DD HH24:MI') END);
        put('  Runs        ' || l_plan.limit_basis);
        put('  Choices     ' || choices_text(l_plan.preflight_run_id)
            || CASE l_ready WHEN 'Y' THEN '; requirements READY'
                            WHEN 'N' THEN '; NOT READY (REQUIREMENTS of '
                                          || epf_util.run_label(l_plan.preflight_run_id) || ')' END);
        IF l_plan.status = 'CLOSED' THEN
            put('  Closed      ' || TO_CHAR(l_plan.closed_at, 'YYYY-MM-DD HH24:MI') || ' by ' || NVL(l_plan.closed_by, '-')
                || ': ' || l_plan.close_reason);
        ELSIF l_plan.status = 'DONE' THEN
            put('  Done        ' || TO_CHAR(l_plan.closed_at, 'YYYY-MM-DD HH24:MI'));
        END IF;
        put('  ' || l('Step', 6) || l('Rows before', 13) || r('Roots', 11) || r('Rows (est.)', 14)
            || r('Redo (est.)', 13) || r('Archive need', 14) || r('Deleting', 10) || '  State');
        FOR st IN (SELECT step_no, cutoff_date, roots, row_count, redo_bytes, delete_seconds, fits, status, last_run_id
                     FROM epf_plan_step
                    WHERE plan_id = p_plan_id
                    ORDER BY step_no) LOOP
            l_state := CASE WHEN st.status = 'DONE' THEN 'done by ' || epf_util.run_label(st.last_run_id)
                            WHEN l_open AND st.step_no = l_next THEN
                                 'next' || CASE WHEN st.last_run_id IS NOT NULL THEN
                                                    ', ' || epf_util.run_label(st.last_run_id) || ' ended before its end'
                                           END
                            ELSE 'pending' END
                       || CASE WHEN st.fits = 'N' THEN '; above the limit (one month)' END;
            put('  ' || l(st.step_no, 6) || l(TO_CHAR(st.cutoff_date, 'YYYY-MM-DD'), 13) || r(n(st.roots), 11)
                || r(n(st.row_count), 14) || r(b(st.redo_bytes), 13)
                || r(CASE WHEN l_noarch > 0 THEN '-' ELSE b(st.redo_bytes * l_margin) END, 14)
                || r(dur(st.delete_seconds), 10) || '  ' || l_state);
        END LOOP;
        IF l_open AND l_next IS NOT NULL THEN
            IF l_noarch = 0 AND l_total > 1 THEN
                put('  Between runs the DBA backs up and deletes the archived logs (RMAN: BACKUP ARCHIVELOG ALL DELETE INPUT).');
            END IF;
            put('  Next        epf_purge.bat purge   (step ' || l_next || ' of ' || l_total || ': rows before '
                || TO_CHAR(l_next_ct, 'YYYY-MM-DD') || '; add --dry-run to rehearse it)');
        END IF;
        put('EPF_PLAN|' || l_label || '|' || p_plan_id || '|' || l_plan.status || '|' || l_plan.purge_mode
            || '|' || l_plan.depth || '|' || TO_CHAR(l_plan.cutoff_date, 'YYYY-MM-DD')
            || '|' || NVL(TO_CHAR(l_plan.retention_days), '-') || '|' || l_total || '|' || l_done
            || '|' || NVL(TO_CHAR(l_next), '-') || '|' || NVL(TO_CHAR(l_next_ct, 'YYYY-MM-DD'), '-')
            || '|' || epf_util.run_label(l_plan.preflight_run_id)
            || '|' || NVL(TO_CHAR(l_plan.checked_at, 'YYYY-MM-DD HH24:MI'), '-')
            || '|' || ROUND(NVL(epf_util.elapsed_s(l_plan.checked_at), 0) / 60)
            || '|' || l_pre.batch_size || '|' || l_pre.with_undo_tuning || '|' || l_pre.with_redo_logs
            || '|' || NVL(l_pre.backup_choice, '-') || '|' || NVL(l_pre.confirmed_reqs, '-') || '|' || l_ready
            || '|' || NVL(l_plan.created_by, '-') || '|' || NVL(TO_CHAR(l_pre.max_redo_bytes), '-')
            || '|' || CASE WHEN l_plan.checked_at >= epf_util.now_ts
                                                     - NUMTODSINTERVAL(epf_util.setting_num('preflight_valid_h'), 'HOUR')
                           THEN 'Y' ELSE 'N' END);
        FOR st IN (SELECT step_no, cutoff_date, roots, row_count, redo_bytes, fits, status, last_run_id
                     FROM epf_plan_step
                    WHERE plan_id = p_plan_id
                    ORDER BY step_no) LOOP
            put('EPF_PLAN_STEP|' || l_label || '|' || st.step_no || '|' || TO_CHAR(st.cutoff_date, 'YYYY-MM-DD')
                || '|' || st.roots || '|' || st.row_count || '|' || st.redo_bytes || '|' || st.status || '|' || st.fits
                || '|' || NVL(epf_util.run_label(st.last_run_id), '-'));
        END LOOP;
    END print_plan_detail;

    -- The plan of the run: the plan a preflight made or checked again, the
    -- plan step a purge carried out or a dry run rehearsed. A preflight that
    -- planned nothing, a plan of another scope being in progress, names it:
    --   EPF_PLAN_KEPT|<plan>
    PROCEDURE print_run_plan IS
    BEGIN
        IF g_run.plan_id IS NULL THEN
            FOR e IN (SELECT message FROM epf_event
                       WHERE run_id = g_run.run_id AND event_code = 'PLAN_KEPT'
                       ORDER BY event_id) LOOP
                title('PLAN');
                put('  ' || e.message);
                put('EPF_PLAN_KEPT|' || REGEXP_SUBSTR(e.message, 'P-[0-9]+'));
            END LOOP;
            RETURN;
        END IF;
        print_plan_detail(g_run.plan_id,
                          CASE WHEN g_run.action = 'PURGE' AND g_run.plan_step IS NOT NULL THEN
                                   'This run: ' || CASE WHEN g_run.dry_run = 'Y'
                                                        THEN 'rehearsal of step ' || g_run.plan_step || ', nothing changed'
                                                        ELSE 'step ' || g_run.plan_step END
                          END);
    END print_run_plan;

    -- What changed since the plan's previous preflight: requirements, roots,
    -- redo estimate, choices.
    PROCEDURE print_changes IS
        l_run   NUMBER := g_run.run_id;
        l_prev  NUMBER;
        l_count NUMBER := 0;
        l_now   VARCHAR2(400);
        l_then  VARCHAR2(400);
    BEGIN
        IF g_run.plan_id IS NULL THEN
            RETURN;
        END IF;
        SELECT MAX(run_id) INTO l_prev
          FROM epf_run
         WHERE plan_id = g_run.plan_id AND action = 'PREFLIGHT' AND run_id < l_run;
        IF l_prev IS NULL THEN
            RETURN;
        END IF;
        title('CHANGES SINCE ' || epf_util.run_label(l_prev) || ' (the previous check of the plan)');
        FOR q IN (SELECT c.req_code, p.status AS status_then, c.status AS status_now
                    FROM epf_requirement c
                    JOIN epf_requirement p ON p.run_id = l_prev AND p.req_code = c.req_code
                   WHERE c.run_id = l_run AND p.status <> c.status
                   ORDER BY c.seq) LOOP
            put('  ' || l(q.req_code, 12) || REPLACE(q.status_then, '_', ' ') || ' -> ' || REPLACE(q.status_now, '_', ' '));
            l_count := l_count + 1;
        END LOOP;
        FOR t IN (SELECT (SELECT SUM(roots) FROM epf_tree_est WHERE run_id = l_prev) AS roots_then,
                         (SELECT SUM(roots) FROM epf_tree_est WHERE run_id = l_run) AS roots_now,
                         (SELECT SUM(redo_bytes) FROM epf_forecast WHERE run_id = l_prev AND origin = 'PREFLIGHT') AS redo_then,
                         (SELECT SUM(redo_bytes) FROM epf_forecast WHERE run_id = l_run AND origin = 'PREFLIGHT') AS redo_now
                    FROM dual) LOOP
            IF NVL(t.roots_then, -1) <> NVL(t.roots_now, -1) THEN
                put('  ' || l('Roots', 12) || n(t.roots_then) || ' -> ' || n(t.roots_now));
                l_count := l_count + 1;
            END IF;
            IF NVL(t.redo_then, -1) <> NVL(t.redo_now, -1) THEN
                put('  ' || l('Redo (est.)', 12) || b(t.redo_then) || ' -> ' || b(t.redo_now));
                l_count := l_count + 1;
            END IF;
        END LOOP;
        l_then := choices_text(l_prev);
        l_now  := choices_text(l_run);
        IF NVL(l_then, '-') <> NVL(l_now, '-') THEN
            put('  ' || l('Choices', 12) || l_then || ' -> ' || l_now);
            l_count := l_count + 1;
        END IF;
        IF l_count = 0 THEN
            put('  No change.');
        END IF;
    END print_changes;

    PROCEDURE print_plan(p_which IN VARCHAR2) IS
        l_plan  NUMBER;
        l_which VARCHAR2(30) := UPPER(TRIM(NVL(p_which, 'OPEN')));
    BEGIN
        IF l_which IN ('OPEN', 'CURRENT') THEN
            l_plan := epf_control.open_plan_id;
            IF l_plan IS NULL AND l_which = 'CURRENT' THEN
                SELECT MAX(plan_id) INTO l_plan FROM epf_plan;
                IF l_plan IS NOT NULL THEN
                    put('No open plan. The latest plan:');
                END IF;
            END IF;
        ELSIF l_which = 'LATEST' THEN
            SELECT MAX(plan_id) INTO l_plan FROM epf_plan;
        ELSE
            SELECT MAX(plan_id) INTO l_plan FROM epf_plan
             WHERE plan_id = TO_NUMBER(REGEXP_SUBSTR(l_which, '[0-9]+'));
        END IF;
        IF l_plan IS NULL THEN
            put(CASE l_which WHEN 'OPEN' THEN 'No open plan.' WHEN 'LATEST' THEN 'No plan recorded.'
                             WHEN 'CURRENT' THEN 'No plan recorded.'
                             ELSE 'Plan not found: ' || p_which END);
            RETURN;
        END IF;
        print_plan_detail(l_plan);
    END print_plan;

    -- ------------------------------------------------------------------
    -- Reclaim
    -- ------------------------------------------------------------------

    -- Per tablespace of a reclaim run: sizes at the start, what moves and
    -- what stays, the forecast and, after a compaction, the end values.
    PROCEDURE print_reclaim_ts IS
        l_label VARCHAR2(20) := epf_util.run_label(g_run.run_id);
        l_count PLS_INTEGER := 0;
        l_start NUMBER := 0;
        l_end   NUMBER := 0;
        l_fc    NUMBER := 0;
        l_ended BOOLEAN := FALSE;
    BEGIN
        title('TABLESPACES (sizes of their datafiles; forecast: at the end of a compaction)');
        put('  ' || l('Tablespace', 22) || r('Files', 6) || r('Start', 12) || r('Segments', 12) || r('Tables', 8)
            || r('Indexes', 9) || r('Pins', 7) || r('Forecast', 12) || r('End', 12) || r('Peak', 12)
            || r('Given back', 12) || '  Status');
        FOR t IN (SELECT tablespace_name, file_count, start_bytes, segment_bytes, unit_count, index_count, pin_count,
                         est_final_bytes, end_bytes, peak_bytes, status, detail, moved_count, stop_detail
                    FROM epf_reclaim_ts
                   WHERE run_id = g_run.run_id
                   ORDER BY start_bytes DESC, tablespace_name) LOOP
            l_count := l_count + 1;
            l_start := l_start + NVL(t.start_bytes, 0);
            l_end := l_end + NVL(t.end_bytes, t.start_bytes);
            l_fc := l_fc + NVL(t.est_final_bytes, t.start_bytes);
            l_ended := l_ended OR t.end_bytes IS NOT NULL;
            put('  ' || l(t.tablespace_name, 22) || r(n(t.file_count), 6) || r(b(t.start_bytes), 12)
                || r(b(t.segment_bytes), 12) || r(n(t.unit_count), 8) || r(n(t.index_count), 9) || r(n(t.pin_count), 7)
                || r(b(t.est_final_bytes), 12) || r(b(t.end_bytes), 12) || r(b(t.peak_bytes), 12)
                || r(CASE WHEN t.end_bytes IS NOT NULL THEN b(GREATEST(t.start_bytes - t.end_bytes, 0)) END, 12)
                || '  ' || t.status);
            IF t.detail IS NOT NULL THEN
                put('    forecast: ' || t.detail);
            END IF;
            IF t.stop_detail IS NOT NULL THEN
                put('    stopped: ' || t.stop_detail);
            END IF;
        END LOOP;
        IF l_count = 0 THEN
            put('  No tablespace to reclaim.');
            RETURN;
        END IF;
        IF l_count > 1 THEN
            put('  ' || l('Total', 22) || r(' ', 6) || r(b(l_start), 12) || r(' ', 12) || r(' ', 8) || r(' ', 9)
                || r(' ', 7) || r(b(l_fc), 12) || r(CASE WHEN l_ended THEN b(l_end) END, 12) || r(' ', 12)
                || r(CASE WHEN l_ended THEN b(GREATEST(l_start - l_end, 0)) END, 12));
        END IF;
        put('  Tables: tables that move with their LOB segments; Indexes: released and rebuilt; Pins: segments that '
            || 'stay (a datafile cannot shrink below the highest of them).');
        FOR t IN (SELECT tablespace_name, status, start_bytes, end_bytes, peak_bytes, est_final_bytes, unit_count,
                         index_count, moved_count, pin_count
                    FROM epf_reclaim_ts
                   WHERE run_id = g_run.run_id
                   ORDER BY start_bytes DESC, tablespace_name) LOOP
            put('EPF_RECLAIM_TS|' || l_label || '|' || t.tablespace_name || '|' || t.status || '|' || t.start_bytes
                || '|' || t.end_bytes || '|' || t.peak_bytes || '|' || t.est_final_bytes || '|' || t.unit_count || '|'
                || t.index_count || '|' || t.moved_count || '|' || t.pin_count);
        END LOOP;
    END print_reclaim_ts;

    -- The tables of a reclaim run per tablespace: the ones that did not move
    -- first, then the largest; at most 60 per tablespace.
    PROCEDURE print_reclaim_tables IS
        l_ts     VARCHAR2(128);
        l_assess BOOLEAN := g_run.dry_run = 'Y';
    BEGIN
        FOR u IN (SELECT source_ts, owner, object_name, unit_type, bytes, est_bytes, after_bytes, attempts, move_status,
                         detail, rn, cnt, ts_bytes
                    FROM (SELECT source_ts, owner, object_name, unit_type, bytes, est_bytes, after_bytes, attempts,
                                 move_status, detail,
                                 ROW_NUMBER() OVER (PARTITION BY source_ts
                                                    ORDER BY CASE move_status WHEN 'PARKED' THEN 0 WHEN 'FAILED' THEN 1
                                                                              WHEN 'NO_ROOM' THEN 2 WHEN 'SKIPPED' THEN 3
                                                                              ELSE 4 END,
                                                             bytes DESC, item_id) AS rn,
                                 COUNT(*) OVER (PARTITION BY source_ts) AS cnt,
                                 SUM(bytes) OVER (PARTITION BY source_ts) AS ts_bytes
                            FROM epf_reclaim_object
                           WHERE run_id = g_run.run_id AND unit_type IN ('TABLE', 'IOT'))
                   WHERE rn <= 61
                   ORDER BY source_ts, rn) LOOP
            IF l_ts IS NULL THEN
                title(CASE WHEN l_assess THEN 'TABLES TO MOVE (each within its tablespace, with its LOB segments; '
                                              || 'estimate: allocated after the move)'
                           ELSE 'TABLES (each moves within its tablespace, with its LOB segments)' END);
                put('  ' || l('Table', 48) || r('Before', 12) || r('Estimate', 12) || r('After', 12) || r('Moves', 7)
                    || '  ' || l('Status', 9) || 'Detail');
            END IF;
            IF l_ts IS NULL OR l_ts <> u.source_ts THEN
                put('  ' || u.source_ts || ': ' || n(u.cnt) || ' tables, ' || b(u.ts_bytes));
                l_ts := u.source_ts;
            END IF;
            IF u.rn <= 60 THEN
                put('   ' || l(u.owner || '.' || u.object_name || CASE WHEN u.unit_type = 'IOT' THEN ' (IOT)' END, 47)
                    || r(b(u.bytes), 12) || r(b(u.est_bytes), 12) || r(b(u.after_bytes), 12) || r(n(u.attempts), 7)
                    || '  ' || l(CASE WHEN l_assess THEN 'TO MOVE' ELSE u.move_status END, 9) || SUBSTR(u.detail, 1, 200));
            ELSE
                put('   ... ' || n(u.cnt - 60) || ' more tables');
            END IF;
        END LOOP;
    END print_reclaim_tables;

    -- The indexes of a reclaim run: counts by outcome, the ones not usable
    -- or left as found, and the largest.
    PROCEDURE print_reclaim_indexes IS
        l_assess  BOOLEAN := g_run.dry_run = 'Y';
        l_total   NUMBER;
        l_pending NUMBER;
        l_rebuilt NUMBER;
        l_failed  NUMBER;
        l_kept    NUMBER;
        l_left    NUMBER;
        l_bytes   NUMBER;
        l_after   NUMBER;
        l_shown   PLS_INTEGER := 0;
    BEGIN
        SELECT COUNT(*),
               COUNT(CASE WHEN move_status = 'PENDING' THEN 1 END),
               COUNT(CASE WHEN move_status = 'REBUILT' THEN 1 END),
               COUNT(CASE WHEN move_status = 'FAILED' THEN 1 END),
               COUNT(CASE WHEN move_status = 'KEPT' THEN 1 END),
               COUNT(CASE WHEN move_status = 'RELEASED' THEN 1 END),
               SUM(CASE WHEN move_status <> 'KEPT' THEN bytes END),
               SUM(CASE WHEN move_status = 'REBUILT' THEN after_bytes END)
          INTO l_total, l_pending, l_rebuilt, l_failed, l_kept, l_left, l_bytes, l_after
          FROM epf_reclaim_object
         WHERE run_id = g_run.run_id AND unit_type = 'INDEX';
        IF l_total = 0 THEN
            RETURN;
        END IF;
        title('INDEXES (released before the tables move, rebuilt in their tablespace after)');
        IF l_assess THEN
            put('  ' || n(l_pending + l_left) || ' indexes to release and rebuild (' || b(l_bytes) || ')'
                || CASE WHEN l_left > 0 THEN ', of which ' || n(l_left) || ' released by an earlier reclaim and still '
                                             || 'unusable' END
                || CASE WHEN l_kept > 0 THEN '; ' || n(l_kept) || ' unusable before, left as found' END);
        ELSE
            put('  ' || n(l_rebuilt) || ' rebuilt (' || b(l_bytes) || ' before, ' || b(l_after) || ' after)'
                || CASE WHEN l_failed > 0 THEN ', ' || n(l_failed) || ' failed or no longer exist' END
                || CASE WHEN l_left > 0 THEN ', ' || n(l_left) || ' still released (unusable)' END
                || CASE WHEN l_pending > 0 THEN ', ' || n(l_pending) || ' not released' END
                || CASE WHEN l_kept > 0 THEN ', ' || n(l_kept) || ' unusable before, left as found' END);
        END IF;
        FOR i IN (SELECT owner, object_name, table_owner, table_name, source_ts, move_status, detail, last_ora
                    FROM epf_reclaim_object
                   WHERE run_id = g_run.run_id AND unit_type = 'INDEX'
                     AND (move_status IN ('FAILED', 'KEPT') OR (move_status = 'RELEASED' AND g_run.dry_run = 'N')
                          OR detail IS NOT NULL)
                   ORDER BY CASE move_status WHEN 'FAILED' THEN 1 WHEN 'RELEASED' THEN 2 ELSE 3 END, owner, object_name) LOOP
            l_shown := l_shown + 1;
            EXIT WHEN l_shown > 100;
            put('   ' || l(i.owner || '.' || i.object_name, 47) || l(i.move_status, 10) || 'on ' || i.table_owner || '.'
                || i.table_name || CASE WHEN i.detail IS NOT NULL THEN ': ' || SUBSTR(i.detail, 1, 200) END);
        END LOOP;
        put('  ' || CASE WHEN l_assess THEN 'Largest' ELSE 'Largest rebuilt' END || ':');
        FOR i IN (SELECT owner, object_name, table_owner, table_name, source_ts, bytes, est_bytes, after_bytes
                    FROM epf_reclaim_object
                   WHERE run_id = g_run.run_id AND unit_type = 'INDEX' AND move_status <> 'KEPT'
                     AND (g_run.dry_run = 'Y' OR move_status = 'REBUILT')
                   ORDER BY bytes DESC, item_id
                   FETCH FIRST 10 ROWS ONLY) LOOP
            put('   ' || l(i.owner || '.' || i.object_name, 47) || r(b(i.bytes), 12)
                || r(CASE WHEN g_run.dry_run = 'Y' THEN b(i.est_bytes) ELSE b(i.after_bytes) END, 12) || '  in '
                || i.source_ts || ', on ' || i.table_owner || '.' || i.table_name);
        END LOOP;
    END print_reclaim_indexes;

    -- Segments that stay, per tablespace, the highest first (a datafile
    -- cannot shrink below them); at most 15 per tablespace.
    PROCEDURE print_reclaim_pins IS
        l_ts VARCHAR2(128);
    BEGIN
        FOR p IN (SELECT tablespace_name, owner, object_name, sub_name, segment_type, file_id, top_bytes, seg_bytes,
                         reason, rn, cnt, all_bytes
                    FROM (SELECT i.tablespace_name, i.owner, i.object_name, i.sub_name, i.segment_type, i.file_id,
                                 (MAX(i.top_block) + 1) * MAX(t.block_size) AS top_bytes, SUM(i.bytes) AS seg_bytes,
                                 MAX(i.blocker_reason) AS reason,
                                 ROW_NUMBER() OVER (PARTITION BY i.tablespace_name ORDER BY MAX(i.top_block) DESC,
                                                                                         i.owner, i.object_name) AS rn,
                                 COUNT(*) OVER (PARTITION BY i.tablespace_name) AS cnt,
                                 SUM(SUM(i.bytes)) OVER (PARTITION BY i.tablespace_name) AS all_bytes
                            FROM epf_ts_inventory i
                            JOIN epf_reclaim_ts t ON t.run_id = i.run_id AND t.tablespace_name = i.tablespace_name
                           WHERE i.run_id = g_run.run_id AND i.handler = 'PIN'
                           GROUP BY i.tablespace_name, i.owner, i.object_name, i.sub_name, i.segment_type, i.file_id)
                   WHERE rn <= 16
                   ORDER BY tablespace_name, rn) LOOP
            IF l_ts IS NULL THEN
                title('SEGMENTS THAT STAY (the highest first: a datafile cannot shrink below them)');
                put('  ' || l('Segment', 52) || l('Type', 14) || r('Size', 11) || r('Up to', 11) || l('  File', 7)
                    || '  Reason');
            END IF;
            IF l_ts IS NULL OR l_ts <> p.tablespace_name THEN
                put('  ' || p.tablespace_name || ': ' || n(p.cnt) || ' segments, ' || b(p.all_bytes));
                l_ts := p.tablespace_name;
            END IF;
            IF p.rn <= 15 THEN
                put('   ' || l(p.owner || '.' || p.object_name || CASE WHEN p.sub_name IS NOT NULL
                                                                         THEN ' (' || p.sub_name || ')' END, 51)
                    || l(p.segment_type, 14) || r(b(p.seg_bytes), 11) || r(b(p.top_bytes), 11) || l('  ' || p.file_id, 7)
                    || '  ' || p.reason);
            ELSE
                put('   ... ' || n(p.cnt - 15) || ' more segments, lower in their datafiles');
            END IF;
        END LOOP;
    END print_reclaim_pins;

    -- Accounts locked while the tables move, and the sessions found.
    PROCEDURE print_reclaim_accounts IS
        l_count PLS_INTEGER := 0;
    BEGIN
        FOR a IN (SELECT username, original_status, locked_at, unlocked_at, sessions_disconnected, detail
                    FROM epf_account_action
                   WHERE run_id = g_run.run_id
                   ORDER BY username) LOOP
            IF l_count = 0 THEN
                title(CASE WHEN g_run.dry_run = 'Y'
                           THEN 'ACCOUNTS (locked, and their sessions disconnected, while the tables move)'
                           ELSE 'ACCOUNTS (locked, and their sessions disconnected, while the tables moved)' END);
                put('  ' || l('Account', 26) || l('Status before', 18) || l('Locked', 10) || l('Unlocked', 10)
                    || r('Sessions', 9) || '  In scope as');
            END IF;
            l_count := l_count + 1;
            put('  ' || l(a.username, 26) || l(a.original_status, 18)
                || l(CASE WHEN a.locked_at IS NOT NULL THEN TO_CHAR(a.locked_at, 'HH24:MI:SS')
                          WHEN g_run.dry_run = 'N' AND INSTR(a.original_status, 'LOCKED') > 0 THEN 'already'
                          ELSE '-' END, 10)
                || l(NVL(TO_CHAR(a.unlocked_at, 'HH24:MI:SS'), '-'), 10) || r(n(a.sessions_disconnected), 9)
                || '  ' || a.detail);
        END LOOP;
        FOR e IN (SELECT message
                    FROM epf_event
                   WHERE run_id = g_run.run_id AND event_code IN ('SESSION_FOUND', 'SESSION_DISCONNECT_IMMEDIATE')
                   ORDER BY event_id) LOOP
            IF l_count = 0 THEN
                title('ACCOUNTS');
                l_count := 1;
            END IF;
            put('  ' || e.message);
        END LOOP;
    END print_reclaim_accounts;

    -- Datafiles of the run's tablespaces at the start and at the end.
    PROCEDURE print_reclaim_files IS
        l_count PLS_INTEGER := 0;
    BEGIN
        FOR f IN (SELECT NVL(s.file_name, e.file_name) AS file_name, s.bytes AS start_bytes, e.bytes AS end_bytes,
                         e.hwm_bytes AS end_hwm, e.free_bytes AS end_free,
                         s.autoextensible AS auto_start, s.maxbytes AS max_start,
                         e.autoextensible AS auto_end, e.maxbytes AS max_end
                    FROM (SELECT * FROM epf_file_snap WHERE run_id = g_run.run_id AND phase = 'BASELINE') s
                    FULL JOIN (SELECT * FROM epf_file_snap WHERE run_id = g_run.run_id AND phase = 'POST_RECLAIM') e
                      ON e.file_id = s.file_id
                   ORDER BY NVL(s.tablespace_name, e.tablespace_name), NVL(s.file_id, e.file_id)) LOOP
            IF l_count = 0 THEN
                title('DATAFILES (at the start and at the end of the run)');
                put('  ' || l('File', 58) || r('Start', 11) || r('End', 11) || r('HWM end', 11) || r('Free end', 11)
                    || '  Autoextend (up to) start -> end');
            END IF;
            l_count := l_count + 1;
            put('  ' || l(f.file_name, 58) || r(b(f.start_bytes), 11) || r(b(f.end_bytes), 11) || r(b(f.end_hwm), 11)
                || r(b(f.end_free), 11) || '  '
                || NVL(f.auto_start || CASE WHEN f.auto_start = 'YES' THEN ' (' || b(f.max_start) || ')' END, '-')
                || ' -> '
                || NVL(f.auto_end || CASE WHEN f.auto_end = 'YES' THEN ' (' || b(f.max_end) || ')' END, '-'));
        END LOOP;
    END print_reclaim_files;

    PROCEDURE print_report(p_run_id IN NUMBER) IS
        l_verdict VARCHAR2(30);
        l_exit    NUMBER;
    BEGIN
        evaluate(p_run_id, l_verdict, l_exit);
        IF g_run.status = 'STOPPED' THEN
            l_exit := 3;
        END IF;
        print_header(l_verdict, l_exit);
        print_steps;
        IF g_run.action = 'PURGE' THEN
            print_results;
            IF g_run.dry_run = 'Y' THEN
                print_forecast_table('DRY_RUN');
                print_simulation_notes;
                print_retention_options;
                print_requirements;
                print_expected;
            ELSE
                print_forecast_result;
                print_disk;
                print_requirements;
            END IF;
            print_run_plan;
            print_space;
        ELSIF g_run.action = 'PREFLIGHT' THEN
            print_forecast_table('PREFLIGHT');
            print_retention_options;
            print_requirements;
            print_changes;
            print_run_plan;
        ELSIF g_run.action = 'RECLAIM' THEN
            print_reclaim_ts;
            print_reclaim_tables;
            print_reclaim_indexes;
            print_reclaim_pins;
            print_reclaim_accounts;
            print_reclaim_files;
            print_requirements;
        END IF;
        print_checks(l_verdict, l_exit);
    END print_report;

    PROCEDURE print_advice(p_run_id IN NUMBER) IS
        l_batch    NUMBER;
        l_severity VARCHAR2(10);
        l_count    NUMBER;
        l_errors   NUMBER;
        l_warnings NUMBER;
    BEGIN
        SELECT MAX(rows_affected) KEEP (DENSE_RANK LAST ORDER BY event_id),
               MAX(severity) KEEP (DENSE_RANK LAST ORDER BY event_id)
          INTO l_batch, l_severity
          FROM epf_event
         WHERE run_id = p_run_id AND event_code = 'REDO_SUMMARY';
        put('EPF_ADVICE|BATCH_SIZE|' || l_batch);
        put('EPF_ADVICE|REDO_WARN|' || CASE WHEN l_severity = 'WARN' THEN 'Y' ELSE 'N' END);
        SELECT MAX(bytes) INTO l_count
          FROM epf_event
         WHERE run_id = p_run_id AND event_code = 'REDO_ESTIMATE' AND bytes > 0;
        put('EPF_ADVICE|REDO_PER_ROOT|' || ROUND(l_count));
        SELECT COUNT(*) INTO l_count
          FROM epf_event
         WHERE run_id = p_run_id AND event_code = 'UNDO_ESTIMATE' AND severity = 'WARN';
        put('EPF_ADVICE|UNDO_WARN|' || CASE WHEN l_count > 0 THEN 'Y' ELSE 'N' END);
        SELECT COUNT(*) INTO l_count FROM epf_instance_change WHERE restored_at IS NULL AND item LIKE 'UNDO%';
        put('EPF_ADVICE|UNDO_ACTIVE|' || CASE WHEN l_count > 0 THEN 'Y' ELSE 'N' END);
        SELECT COUNT(CASE WHEN severity = 'ERROR' THEN 1 END), COUNT(CASE WHEN severity = 'WARN' THEN 1 END)
          INTO l_errors, l_warnings
          FROM epf_event
         WHERE run_id = p_run_id AND event_code <> 'RUN_END';
        put('EPF_ADVICE|ERRORS|' || l_errors);
        put('EPF_ADVICE|WARNINGS|' || l_warnings);
        FOR e IN (SELECT object_owner || '.' || object_name AS root_table, rows_affected
                    FROM epf_event
                   WHERE run_id = p_run_id AND event_code = 'ROOTS_ELIGIBLE'
                   ORDER BY event_id) LOOP
            put('EPF_ADVICE|ROOTS|' || e.root_table || '|' || e.rows_affected);
        END LOOP;
        SELECT COUNT(*), COUNT(CASE WHEN status = 'NOT_MET' AND blocking = 'Y' THEN 1 END)
          INTO l_count, l_errors
          FROM epf_requirement
         WHERE run_id = p_run_id;
        put('EPF_ADVICE|READY|' || CASE WHEN l_count = 0 THEN '-' WHEN l_errors = 0 THEN 'Y' ELSE 'N' END);
        FOR q IN (SELECT req_code, status, blocking, met_by FROM epf_requirement WHERE run_id = p_run_id ORDER BY seq) LOOP
            put('EPF_ADVICE|REQ|' || q.req_code || '|' || q.status || '|' || q.blocking || '|' || q.met_by);
        END LOOP;
        -- Texts for the wizard's questions: title and measurement of each
        -- requirement, and the details of its ways to meet it.
        FOR q IN (SELECT req_code, title, measured FROM epf_requirement WHERE run_id = p_run_id ORDER BY seq) LOOP
            put('EPF_ADVICE|REQTEXT|' || q.req_code || '|' || REPLACE(q.title, '|', '/') || '|'
                || REPLACE(q.measured, '|', '/'));
        END LOOP;
        FOR o IN (SELECT req_code, option_code, met, detail FROM epf_req_option WHERE run_id = p_run_id
                   ORDER BY req_code, seq) LOOP
            put('EPF_ADVICE|OPT|' || o.req_code || '|' || o.option_code || '|' || o.met || '|'
                || REPLACE(o.detail, '|', '/'));
        END LOOP;
        SELECT MAX(batch_size) INTO l_count FROM epf_run WHERE run_id = p_run_id;
        put('EPF_ADVICE|RUN_BATCH|' || l_count);
        -- Largest batch (root rows) whose undo the undo tablespace holds 4
        -- times (UNDO), from the largest undo per root of the trees.
        FOR u IN (SELECT rq.room_bytes,
                         (SELECT MAX(te.undo_root) FROM epf_tree_est te
                           WHERE te.run_id = rq.run_id AND te.roots > 0) AS undo_root
                    FROM epf_requirement rq
                   WHERE rq.run_id = p_run_id AND rq.req_code = 'UNDO' AND rq.room_bytes > 0) LOOP
            IF u.undo_root > 0 THEN
                put('EPF_ADVICE|UNDO_MAX_BATCH|' || FLOOR(u.room_bytes / 4 / u.undo_root));
            END IF;
        END LOOP;
    END print_advice;

    PROCEDURE print_status IS
        l_active NUMBER := epf_control.active_run_id;
        l_run_id NUMBER := NVL(l_active, epf_control.latest_run_id);
        l_count  NUMBER := 0;
    BEGIN
        -- Other sessions of the tool schema: monitor and worker sessions, with
        -- what they wait on and who blocks them.
        FOR s IN (SELECT w.sid, w.serial#, w.status, w.event, w.seconds_in_wait, w.blocking_session, w.sql_id,
                         w.action, w.client_identifier, TO_CHAR(w.logon_time, 'HH24:MI:SS') AS logon,
                         (SELECT b.username || '@' || b.machine || ' ' || b.program
                            FROM v$session b
                           WHERE b.sid = w.blocking_session AND ROWNUM = 1) AS blocker
                    FROM v$session w
                   WHERE w.username = $$PLSQL_UNIT_OWNER
                     AND w.sid <> TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'))
                   ORDER BY w.logon_time) LOOP
            put('session ' || s.sid || ',' || s.serial# || ' ' || s.status || ' since ' || s.logon
                || CASE WHEN s.client_identifier IS NOT NULL THEN ' ' || s.client_identifier END
                || CASE WHEN s.action IS NOT NULL THEN ' ' || s.action END
                || ': ' || s.event || ' ' || s.seconds_in_wait || ' s'
                || CASE WHEN s.blocking_session IS NOT NULL THEN
                        ', blocked by session ' || s.blocking_session || ' (' || s.blocker || ')'
                   END
                || CASE WHEN s.sql_id IS NOT NULL THEN ', sql_id ' || s.sql_id END);
        END LOOP;
        IF l_run_id IS NULL THEN
            put('No run recorded.');
            RETURN;
        END IF;
        SELECT * INTO g_run FROM epf_run WHERE run_id = l_run_id;
        put(epf_util.run_label(l_run_id) || '  ' || g_run.action || '  status ' || g_run.status
            || CASE WHEN l_active IS NOT NULL THEN ' (active)' END
            || '  verdict ' || NVL(g_run.verdict, '-') || '  exit ' || NVL(TO_CHAR(g_run.exit_code), '-'));
        put('  started ' || NVL(TO_CHAR(g_run.started_at, 'YYYY-MM-DD HH24:MI:SS'), '-') || ', ended '
            || NVL(TO_CHAR(g_run.ended_at, 'YYYY-MM-DD HH24:MI:SS'), '-') || ', stop requested '
            || g_run.stop_requested);
        FOR s IN (SELECT phase, step_code, scope, status, units_done, units_total
                    FROM epf_step
                   WHERE run_id = l_run_id AND status <> 'DONE'
                   ORDER BY step_seq) LOOP
            put('  step ' || l(s.phase, 10) || l(s.step_code, 22) || l(s.scope, 18) || l(s.status, 9)
                || CASE WHEN s.units_total IS NOT NULL THEN n(s.units_done) || '/' || n(s.units_total) END);
        END LOOP;
        put('  last events:');
        FOR e IN (SELECT ts, severity, event_code, message
                    FROM (SELECT ts, severity, event_code, message, event_id
                            FROM epf_event
                           WHERE run_id = l_run_id
                           ORDER BY event_id DESC)
                   WHERE ROWNUM <= 10
                   ORDER BY event_id) LOOP
            put('    ' || TO_CHAR(e.ts, 'HH24:MI:SS') || ' ' || l(e.severity, 9) || l(e.event_code, 24) || e.message);
        END LOOP;
        FOR t IN (SELECT ti.index_name, ti.table_owner, ti.table_name, ti.run_id
                    FROM epf_temp_index ti
                   WHERE ti.dropped_at IS NULL
                     AND EXISTS (SELECT 1 FROM dba_indexes i WHERE i.owner = ti.owner AND i.index_name = ti.index_name)
                   ORDER BY ti.run_id, ti.index_name) LOOP
            l_count := l_count + 1;
            put('  temporary index still present: ' || t.index_name || ' on ' || t.table_owner || '.' || t.table_name
                || ' (' || epf_util.run_label(t.run_id) || '); dropped by the next purge');
        END LOOP;
        FOR c IN (SELECT item, target, original_value, applied_value, applied_at
                    FROM epf_instance_change
                   WHERE restored_at IS NULL AND item LIKE 'UNDO%'
                   ORDER BY change_id) LOOP
            l_count := l_count + 1;
            put('  undo tuning active: ' || c.item || ' ' || c.target || ' since '
                || TO_CHAR(c.applied_at, 'YYYY-MM-DD HH24:MI:SS') || '; restore with run/undo.sql RESTORE as SYS');
        END LOOP;
        -- What a reclaim left pending: epf_purge.bat reclaim --restore
        -- restores it (a new reclaim does too, before it starts).
        FOR c IN (SELECT target, original_maxbytes, applied_at, applied_run_id
                    FROM epf_instance_change
                   WHERE restored_at IS NULL AND item = 'RECLAIM_DATAFILE'
                   ORDER BY change_id) LOOP
            l_count := l_count + 1;
            put('  datafile growth stopped by ' || epf_util.run_label(c.applied_run_id) || ': ' || c.target
                || ' (autoextend up to ' || b(c.original_maxbytes) || ') since '
                || TO_CHAR(c.applied_at, 'YYYY-MM-DD HH24:MI:SS') || '; epf_purge.bat reclaim --restore restores it');
        END LOOP;
        FOR p IN (SELECT run_id, owner, table_name, MAX(park_ts) AS park_ts
                    FROM epf_reclaim_park
                   WHERE returned_at IS NULL
                   GROUP BY run_id, item_id, owner, table_name
                   ORDER BY run_id, owner, table_name) LOOP
            l_count := l_count + 1;
            put('  table parked by ' || epf_util.run_label(p.run_id) || ': ' || p.owner || '.' || p.table_name || ' in '
                || p.park_ts || ' (usable there); epf_purge.bat reclaim --restore moves it back');
        END LOOP;
        FOR c IN (SELECT target, applied_at, applied_run_id
                    FROM epf_instance_change
                   WHERE restored_at IS NULL AND item = 'RECLAIM_SCRATCH'
                   ORDER BY change_id) LOOP
            l_count := l_count + 1;
            put('  scratch tablespace of ' || epf_util.run_label(c.applied_run_id) || ' still there: ' || c.target
                || ' since ' || TO_CHAR(c.applied_at, 'YYYY-MM-DD HH24:MI:SS')
                || '; epf_purge.bat reclaim --restore drops it once it is empty');
        END LOOP;
        FOR i IN (SELECT o.run_id, o.owner, o.object_name, o.table_owner, o.table_name
                    FROM epf_reclaim_object o
                   WHERE o.unit_type = 'INDEX' AND o.move_status IN ('RELEASED', 'FAILED')
                     AND o.run_id IN (SELECT r.run_id FROM epf_run r WHERE r.reclaim_mode IN ('COMPACT', 'RESTORE'))
                     AND EXISTS (SELECT 1 FROM dba_indexes x
                                  WHERE x.owner = o.owner AND x.index_name = o.object_name AND x.status = 'UNUSABLE')
                   ORDER BY o.run_id, o.owner, o.object_name) LOOP
            l_count := l_count + 1;
            put('  index released by ' || epf_util.run_label(i.run_id) || ' still unusable: ' || i.owner || '.'
                || i.object_name || ' on ' || i.table_owner || '.' || i.table_name
                || '; epf_purge.bat reclaim --restore rebuilds it');
        END LOOP;
        FOR a IN (SELECT username, original_status, locked_at, run_id
                    FROM epf_account_action
                   WHERE locked_at IS NOT NULL AND unlocked_at IS NULL
                   ORDER BY run_id, username) LOOP
            l_count := l_count + 1;
            put('  account locked by ' || epf_util.run_label(a.run_id) || ': ' || a.username || ' (originally '
                || a.original_status || '); epf_purge.bat reclaim --restore unlocks it');
        END LOOP;
        IF l_count = 0 THEN
            put('  no temporary index, undo tuning, reclaim change or locked account pending');
        END IF;
        FOR p IN (SELECT plan_id, status, cutoff_date, purge_mode, depth
                    FROM epf_plan
                   WHERE status IN ('READY', 'IN_PROGRESS')) LOOP
            put('Plan ' || epf_util.plan_label(p.plan_id) || '  ' || p.status || ': mode ' || p.purge_mode || ', depth '
                || p.depth || ', rows before ' || TO_CHAR(p.cutoff_date, 'YYYY-MM-DD') || '; epf_purge.bat plan shows it');
        END LOOP;
    END print_status;

END epf_report;
/

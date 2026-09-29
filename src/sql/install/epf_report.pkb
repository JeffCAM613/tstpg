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

    FUNCTION l(p_text IN VARCHAR2, p_width IN PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN RPAD(NVL(SUBSTR(p_text, 1, p_width), ' '), p_width);
    END l;

    FUNCTION r(p_text IN VARCHAR2, p_width IN PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN LPAD(NVL(SUBSTR(p_text, 1, p_width), ' '), p_width);
    END r;

    PROCEDURE title(p_text IN VARCHAR2) IS
    BEGIN
        put;
        put(' ' || p_text);
        put(' ' || RPAD('-', c_width - 1, '-'));
    END title;

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
        RETURN p_list || CASE WHEN p_list IS NOT NULL THEN '; ' END || p_item;
    END add_detail;

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
        l_errors    NUMBER;
        l_warnings  NUMBER;
        l_phases    NUMBER;
        l_estimated NUMBER;
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
        SELECT COUNT(CASE WHEN severity = 'ERROR' THEN 1 END), COUNT(CASE WHEN severity = 'WARN' THEN 1 END)
          INTO l_errors, l_warnings
          FROM epf_event
         WHERE run_id = l_run AND event_code <> 'RUN_END';
        l_detail := NULL;
        FOR t IN (SELECT event_code, severity, COUNT(*) AS cnt
                    FROM epf_event
                   WHERE run_id = l_run AND event_code <> 'RUN_END' AND severity IN ('ERROR', 'WARN')
                   GROUP BY event_code, severity
                   ORDER BY severity, event_code) LOOP
            l_detail := add_detail(l_detail, t.event_code || ' x' || t.cnt);
        END LOOP;
        add_check('P5', CASE WHEN l_errors > 0 OR l_status = 'FAILED' THEN 'FAIL'
                             WHEN l_warnings > 0 THEN 'WARN' ELSE 'PASS' END,
                  'Errors during the run',
                  l_errors || ' errors, ' || l_warnings || ' warnings'
                  || CASE WHEN l_status = 'FAILED' THEN ', run FAILED' END, l_detail);

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
               SUM(CASE WHEN phase = 'BASELINE' THEN used_bytes END),
               SUM(CASE WHEN phase = 'POST_PURGE' THEN used_bytes END)
          INTO l_phases, l_estimated, l_before, l_now
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
                      || CASE WHEN l_estimated > 0 THEN ', ' || l_estimated || ' segments estimated or unsupported' END);
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
    BEGIN
        evaluate(p_run_id, l_verdict, p_exit_code, p_status);
        IF UPPER(p_status) = 'STOPPED' THEN
            p_exit_code := 3;
        END IF;
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
                || n(g_run.batch_size) || ', dry run ' || g_run.dry_run || ', compact ' || g_run.with_compact
                || ', reclaim ' || g_run.with_reclaim);
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
        put('  ' || l('Table', 40) || l('Action', 7) || r('Eligible', 13) || r('Processed', 13) || r('Residual', 10)
            || r('Rows before', 13) || r('Rows after', 13) || r('Kept before', 13) || r('Kept after', 13)
            || r('Held', 8) || r('Orphans', 9));
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
            put('   ' || l(t.owner || '.' || t.table_name, 39) || l(LOWER(t.action), 7) || r(n(t.eligible), 13)
                || r(n(t.processed), 13) || r(n(t.residual), 10) || r(n(t.rows_before), 13) || r(n(t.rows_after), 13)
                || r(n(t.kept_before), 13) || r(n(t.kept_after), 13) || r(n(t.held), 8) || r(n(t.orphans), 9));
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

        PROCEDURE module_total IS
        BEGIN
            IF l_module IS NOT NULL THEN
                put('   ' || l('Total ' || l_module, 39) || r(b(l_m_alloc), 13) || r(b(l_m_bef), 13)
                    || r(b(l_m_aft), 13) || r(b(l_m_bef - l_m_aft), 13) || r(b(l_m_now), 13));
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
        put('  ' || l('Table', 40) || r('Allocated', 13) || r('Used before', 13) || r('Used after', 13)
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
            put('   ' || l(t.parent_owner || '.' || t.parent_table, 39) || r(b(t.alloc_before), 13)
                || r(b(t.used_before), 13) || r(b(t.used_after), 13)
                || r(CASE WHEN t.used_after IS NOT NULL THEN b(t.used_before - t.used_after) END, 13)
                || r(b(t.alloc_now), 13));
        END LOOP;
        module_total;

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

        title('REDO AND UNDO');
        FOR t IN (SELECT e.module_code, ev.object_owner || '.' || ev.object_name AS root_table,
                         SUM(CASE WHEN ev.event_code = 'TREE_REDO' THEN ev.bytes END) AS redo,
                         SUM(CASE WHEN ev.event_code = 'TREE_UNDO' THEN ev.bytes END) AS undo,
                         MAX(ev.rows_affected) AS roots
                    FROM epf_event ev
                    JOIN epf_table e ON e.owner = ev.object_owner AND e.table_name = ev.object_name
                   WHERE ev.run_id = g_run.run_id AND ev.event_code IN ('TREE_REDO', 'TREE_UNDO')
                   GROUP BY e.module_code, ev.object_owner, ev.object_name
                   ORDER BY 1, 2) LOOP
            put('  ' || l(t.module_code, 18) || l(t.root_table, 40) || 'redo ' || r(b(t.redo), 10) || ', undo '
                || r(b(t.undo), 10) || ' for ' || n(t.roots) || ' roots ('
                || b(t.redo / NULLIF(t.roots, 0)) || ' redo per root)');
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
            print_space;
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
        SELECT COUNT(*) INTO l_count
          FROM epf_event
         WHERE run_id = p_run_id AND event_code = 'UNDO_ESTIMATE' AND severity = 'WARN';
        put('EPF_ADVICE|UNDO_WARN|' || CASE WHEN l_count > 0 THEN 'Y' ELSE 'N' END);
        SELECT COUNT(*) INTO l_count FROM epf_instance_change WHERE restored_at IS NULL;
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
    END print_advice;

    PROCEDURE print_status IS
        l_active NUMBER := epf_control.active_run_id;
        l_run_id NUMBER := NVL(l_active, epf_control.latest_run_id);
        l_count  NUMBER := 0;
    BEGIN
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
            put('    ' || TO_CHAR(e.ts, 'HH24:MI:SS') || ' ' || l(e.severity, 8) || l(e.event_code, 22) || e.message);
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
                   WHERE restored_at IS NULL
                   ORDER BY change_id) LOOP
            l_count := l_count + 1;
            put('  undo tuning active: ' || c.item || ' ' || c.target || ' since '
                || TO_CHAR(c.applied_at, 'YYYY-MM-DD HH24:MI:SS') || '; restore with run/undo.sql RESTORE as SYS');
        END LOOP;
        FOR a IN (SELECT username, original_status, locked_at, run_id
                    FROM epf_account_action
                   WHERE locked_at IS NOT NULL AND unlocked_at IS NULL
                   ORDER BY run_id, username) LOOP
            l_count := l_count + 1;
            put('  account locked by ' || epf_util.run_label(a.run_id) || ': ' || a.username || ' (originally '
                || a.original_status || ')');
        END LOOP;
        IF l_count = 0 THEN
            put('  no temporary index, undo tuning or locked account pending');
        END IF;
    END print_status;

END epf_report;
/

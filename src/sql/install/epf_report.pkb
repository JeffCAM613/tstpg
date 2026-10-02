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
               COUNT(CASE WHEN method = 'BASICFILE_EST' THEN 1 END),
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

        PROCEDURE module_total IS
        BEGIN
            IF l_module IS NOT NULL THEN
                put('   ' || l('Total ' || l_module, 45) || r(b(l_m_alloc), 13) || r(b(l_m_bef), 13)
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
        SELECT COUNT(*) INTO l_lob_est
          FROM epf_space_usage
         WHERE run_id = g_run.run_id AND method = 'BASICFILE_EST';
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
            put('  ' || l(t.module_code, 18) || l(t.root_table, 46) || 'redo ' || r(b(t.redo), 10) || ', undo '
                || r(b(t.undo), 10) || ' for ' || n(t.roots) || ' roots ('
                || b(t.redo / NULLIF(t.roots, 0)) || ' redo per root)');
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
        title('REQUIREMENTS' || CASE WHEN g_run.action = 'PURGE' AND g_run.dry_run = 'N'
                                     THEN ' (checked when the purge started)' END);
        FOR q IN (SELECT req_code, status, blocking, title, why, measured, met_by
                    FROM epf_requirement
                   WHERE run_id = l_run
                   ORDER BY seq) LOOP
            put('  ' || l(q.req_code, 12) || RPAD(q.title || ' ', 40, '.') || ' '
                || CASE q.status WHEN 'MET' THEN 'MET' WHEN 'NOT_MET' THEN 'NOT MET' ELSE 'NOT MEASURED' END
                || CASE WHEN q.status = 'NOT_MET' AND q.blocking = 'N' THEN ' (slower only)' END);
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
            || CASE WHEN l_slow IS NOT NULL THEN '; slower only: ' || l_slow END);
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
        put('  ' || l('Module', 18) || r('Rows', 14) || r('Roots', 12) || r('Batches', 9) || r('Redo', 11)
            || r('Undo', 11) || r('Deleting', 10) || r('Space freed', 13));
        FOR x IN (SELECT f.module_code, f.row_count, f.roots, f.batches, f.redo_bytes, f.undo_bytes,
                         f.delete_seconds, f.freed_bytes
                    FROM epf_forecast f
                    JOIN epf_module m ON m.module_code = f.module_code
                   WHERE f.run_id = l_run AND f.origin = p_origin
                   ORDER BY m.display_order) LOOP
            put('  ' || l(x.module_code, 18) || r(n(x.row_count), 14) || r(n(x.roots), 12) || r(n(x.batches), 9)
                || r(b(x.redo_bytes), 11) || r(b(x.undo_bytes), 11) || r(dur(x.delete_seconds), 10)
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
                || r(n(l_roots), 12) || r(n(l_batch), 9) || r(b(l_redo), 11) || r(b(l_undo), 11) || r(dur(l_secs), 10)
                || r(CASE WHEN p_origin = 'DRY_RUN' THEN b(l_freed) ELSE '-' END, 13));
        END IF;
        FOR x IN (SELECT DISTINCT redo_basis FROM epf_forecast
                   WHERE run_id = l_run AND origin = p_origin AND redo_basis IS NOT NULL) LOOP
            put('  Redo and undo per root: ' || x.redo_basis);
        END LOOP;
        FOR x IN (SELECT DISTINCT time_basis FROM epf_forecast
                   WHERE run_id = l_run AND origin = p_origin AND time_basis IS NOT NULL) LOOP
            put('  Deleting time: ' || x.time_basis);
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
        FOR t IN (SELECT tr.owner, tr.trigger_name, tr.table_owner, tr.table_name, tr.triggering_event, e.module_code
                    FROM dba_triggers tr
                    JOIN epf_table e ON e.owner = tr.table_owner AND e.table_name = tr.table_name AND e.active = 'Y'
                   WHERE tr.status = 'ENABLED'
                     AND (tr.triggering_event LIKE '%DELETE%' OR tr.triggering_event LIKE '%UPDATE%')
                   ORDER BY tr.table_owner, tr.table_name, tr.trigger_name) LOOP
            CONTINUE WHEN NOT in_depth(t.module_code);
            l_count := l_count + 1;
            IF l_count <= 5 THEN
                l_trig := l_trig || CASE WHEN l_count > 1 THEN '; ' END || t.owner || '.' || t.trigger_name || ' on '
                          || t.table_owner || '.' || t.table_name || ' (' || LOWER(t.triggering_event) || ')';
            END IF;
        END LOOP;
        put('  Triggers        ' || CASE WHEN l_count = 0 THEN 'none enabled on the tables of the run'
                                         ELSE l_count || ' enabled, they fire for every row: ' || l_trig END);
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
        l_rows   NUMBER;
        l_freed  NUMBER;
        l_fits   VARCHAR2(10);
        l_days   NUMBER;
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
            SELECT SUM(x.roots * f.row_count / NULLIF(f.roots, 0)), SUM(x.roots * f.freed_bytes / NULLIF(f.roots, 0))
              INTO l_rows, l_freed
              FROM (SELECT t.module_code, SUM(ro.roots) AS roots
                      FROM epf_retention_option ro
                      JOIN epf_table t ON t.table_id = ro.table_id
                     WHERE ro.run_id = l_run AND ro.retention_days = l_days
                     GROUP BY t.module_code) x
              JOIN epf_forecast f ON f.run_id = l_run AND f.origin = 'DRY_RUN' AND f.module_code = x.module_code;
            l_fits := CASE WHEN l_noarch > 0 THEN 'n/a'
                           WHEN l_room IS NULL OR o.unknown > 0 THEN '?'
                           WHEN NVL(o.redo_bytes, 0) * l_margin <= l_room THEN 'yes' ELSE 'no' END;
            put('  ' || l(o.retention_days, 11) || l(TO_CHAR(o.cutoff_date, 'YYYY-MM-DD'), 12) || r(n(o.roots), 12)
                || r(n(l_rows), 14)
                || r(CASE WHEN o.unknown > 0 THEN '-' ELSE b(NVL(o.redo_bytes, 0)) END, 11)
                || r(CASE WHEN o.unknown > 0 OR l_noarch > 0 THEN '-' ELSE b(NVL(o.redo_bytes, 0) * l_margin) END, 14)
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
            line('redo', 'REDO', l_f_redo, l_redo, b(l_f_redo), b(l_redo));
            line('undo', 'UNDO', l_f_undo, l_undo, b(l_f_undo), b(l_undo));
            line('deleting time', 'SECONDS', l_f_secs, l_secs, dur(l_f_secs), dur(l_secs));
            line('space freed', 'FREED', l_f_freed, l_freed, b(l_f_freed), b(l_freed));
        END LOOP;
        IF l_shown AND l_status IN ('STOPPED', 'FAILED') THEN
            put('  The purge ended ' || l_status || ': the actual values cover only what it did.');
        END IF;
    END print_forecast_result;

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
                print_requirements;
            END IF;
            print_space;
        ELSIF g_run.action = 'PREFLIGHT' THEN
            print_forecast_table('PREFLIGHT');
            print_retention_options;
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
        -- Largest batch whose undo the undo tablespace holds 4 times (UNDO).
        FOR u IN (SELECT rq.needed_bytes, rq.room_bytes, rn.batch_size
                    FROM epf_requirement rq
                    JOIN epf_run rn ON rn.run_id = rq.run_id
                   WHERE rq.run_id = p_run_id AND rq.req_code = 'UNDO' AND rq.needed_bytes > 0
                     AND rq.room_bytes > 0) LOOP
            put('EPF_ADVICE|UNDO_MAX_BATCH|' || FLOOR(u.room_bytes / 4 / (u.needed_bytes / u.batch_size)));
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

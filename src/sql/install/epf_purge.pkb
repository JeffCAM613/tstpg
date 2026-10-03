CREATE OR REPLACE PACKAGE BODY epf_purge AS

    c_delete      CONSTANT VARCHAR2(10) := 'DELETE';
    c_clear       CONSTANT VARCHAR2(10) := 'CLEAR';
    c_logs_module CONSTANT VARCHAR2(30) := 'LOGS';
    c_max_rounds  CONSTANT PLS_INTEGER  := 50;

    TYPE t_table IS RECORD (
        table_id      NUMBER,
        module_code   VARCHAR2(30),
        root_table_id NUMBER,
        owner         VARCHAR2(128),
        table_name    VARCHAR2(128),
        role          VARCHAR2(10),
        key_column    VARCHAR2(128),
        date_column   VARCHAR2(128),
        delete_order  NUMBER,
        lob_clear     VARCHAR2(1),
        present       BOOLEAN,
        is_source     BOOLEAN,
        reachable     BOOLEAN
    );
    TYPE t_tables IS TABLE OF t_table INDEX BY PLS_INTEGER;

    TYPE t_link IS RECORD (
        link_id         NUMBER,
        table_id        NUMBER,
        match_column    VARCHAR2(128),
        source_table_id NUMBER,
        source_column   VARCHAR2(128),
        direct          BOOLEAN,
        usable          BOOLEAN
    );
    TYPE t_links IS TABLE OF t_link INDEX BY PLS_INTEGER;

    TYPE t_fk IS RECORD (
        c_owner         VARCHAR2(128),
        c_table         VARCHAR2(128),
        constraint_name VARCHAR2(128),
        p_owner         VARCHAR2(128),
        p_table         VARCHAR2(128),
        p_id            NUMBER,
        c_id            NUMBER,
        join_cond       VARCHAR2(4000),
        covered         BOOLEAN
    );
    TYPE t_fks IS TABLE OF t_fk INDEX BY PLS_INTEGER;

    TYPE t_lob IS RECORD (column_name VARCHAR2(128), data_type VARCHAR2(128));
    TYPE t_lobs IS TABLE OF t_lob INDEX BY PLS_INTEGER;

    TYPE t_stmt IS RECORD (table_id NUMBER, sql_text VARCHAR2(32767));
    TYPE t_stmts IS TABLE OF t_stmt INDEX BY PLS_INTEGER;

    TYPE t_texts   IS TABLE OF VARCHAR2(32767) INDEX BY PLS_INTEGER;
    TYPE t_numbers IS TABLE OF NUMBER INDEX BY PLS_INTEGER;
    TYPE t_key_map IS TABLE OF NUMBER INDEX BY VARCHAR2(200);

    -- An index the purge of a module relies on:
    --   link  the match column of every link into its tables and the source
    --         column of a reverse link: read once per batch, indexed when the
    --         table is at least temp_index_min_mb
    --   fk    when the module deletes, the columns of every enabled FK into
    --         its tables (any schema): Oracle looks up child rows for each
    --         deleted parent row, scanning the child table when these columns
    --         are not indexed, so they are indexed whatever the size
    -- table_id is NULL for a child table outside the registry, which the tool
    -- cannot index.
    TYPE t_need IS RECORD (
        table_id   NUMBER,
        owner      VARCHAR2(128),
        table_name VARCHAR2(128),
        col_list   SYS.ODCIVARCHAR2LIST,
        fk         BOOLEAN,
        detail     VARCHAR2(400)
    );
    TYPE t_needs IS TABLE OF t_need INDEX BY PLS_INTEGER;
    TYPE t_position_map IS TABLE OF PLS_INTEGER INDEX BY VARCHAR2(4000);

    g_run      epf_run%ROWTYPE;
    g_tables   t_tables;
    g_links    t_links;
    g_modules  SYS.ODCIVARCHAR2LIST;
    g_owner    VARCHAR2(128) := $$PLSQL_UNIT_OWNER;
    g_warnings PLS_INTEGER := 0;
    -- Eligible roots per root table_id, counted by the preflight (check_roots).
    g_eligible t_numbers;
    -- Online redo logs and undo tablespace as the preflight found them
    -- (check_redo, check_undo), for the requirements (check_requirements).
    g_min_log    NUMBER;
    g_log_mode   VARCHAR2(12);
    g_undo_ts    VARCHAR2(128);
    g_undo_size  NUMBER;
    g_undo_max   NUMBER;
    g_undo_batch NUMBER := 0;
    g_undo_kept  NUMBER := 0;
    g_undo_cap   NUMBER;
    g_undo_limit BOOLEAN := FALSE;
    -- Preflight run whose root counts this preflight reuses (reusable_run).
    g_reuse_run  NUMBER;
    -- TRUE while recheck runs the redo and undo checks again (no events).
    g_silent     BOOLEAN := FALSE;

    -- ------------------------------------------------------------------
    -- Names and SQL fragments
    -- ------------------------------------------------------------------

    FUNCTION tq(p_table_id IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN epf_util.qname(g_tables(p_table_id).owner, g_tables(p_table_id).table_name);
    END tq;

    FUNCTION qc(p_column IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_ASSERT.ENQUOTE_NAME(p_column, FALSE);
    END qc;

    FUNCTION tname(p_table_id IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN g_tables(p_table_id).owner || '.' || g_tables(p_table_id).table_name;
    END tname;

    -- Filter of EPF_WORK_KEY rows of this run for one table.
    FUNCTION wk(p_alias IN VARCHAR2, p_table_id IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        RETURN p_alias || '.run_id = ' || g_run.run_id || ' AND ' || p_alias || '.table_id = ' || p_table_id;
    END wk;

    FUNCTION cutoff_literal RETURN VARCHAR2 IS
    BEGIN
        RETURN 'TO_DATE(''' || TO_CHAR(g_run.cutoff_date, 'YYYY-MM-DD HH24:MI:SS')
               || ''', ''YYYY-MM-DD HH24:MI:SS'')';
    END cutoff_literal;

    FUNCTION cutoff_text RETURN VARCHAR2 IS
    BEGIN
        RETURN TO_CHAR(g_run.cutoff_date, 'YYYY-MM-DD');
    END cutoff_text;

    -- Root snapshot by ROWID: a root without key column.
    FUNCTION by_rowid(p_table_id IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN g_tables(p_table_id).role = 'ROOT' AND g_tables(p_table_id).key_column IS NULL;
    END by_rowid;

    -- Tables whose eligible keys are stored in EPF_WORK_KEY: key roots and link sources.
    FUNCTION has_keys(p_table_id IN NUMBER) RETURN BOOLEAN IS
    BEGIN
        RETURN g_tables(p_table_id).key_column IS NOT NULL
               AND (g_tables(p_table_id).role = 'ROOT' OR g_tables(p_table_id).is_source);
    END has_keys;

    -- Usable links of a dependent table, in link_id order.
    FUNCTION links_of(p_table_id IN NUMBER) RETURN t_links IS
        l_out t_links;
        i     PLS_INTEGER := g_links.FIRST;
    BEGIN
        WHILE i IS NOT NULL LOOP
            IF g_links(i).table_id = p_table_id AND g_links(i).usable THEN
                l_out(l_out.COUNT + 1) := g_links(i);
            END IF;
            i := g_links.NEXT(i);
        END LOOP;
        RETURN l_out;
    END links_of;

    FUNCTION tree_tables(p_root_id IN NUMBER, p_descending IN BOOLEAN DEFAULT FALSE)
        RETURN SYS.ODCINUMBERLIST IS
        l_out SYS.ODCINUMBERLIST;
    BEGIN
        IF p_descending THEN
            SELECT table_id BULK COLLECT INTO l_out
              FROM epf_table
             WHERE active = 'Y' AND root_table_id = p_root_id
             ORDER BY delete_order DESC, table_id;
        ELSE
            SELECT table_id BULK COLLECT INTO l_out
              FROM epf_table
             WHERE active = 'Y' AND root_table_id = p_root_id
             ORDER BY delete_order, table_id;
        END IF;
        RETURN l_out;
    END tree_tables;

    -- Keys of a key root or link source that belong to the batch bound as :b.
    FUNCTION batch_keys(p_table_id IN NUMBER) RETURN VARCHAR2 IS
        l_root NUMBER := g_tables(p_table_id).root_table_id;
    BEGIN
        IF p_table_id = l_root THEN
            RETURN 'SELECT zb.key_num FROM epf_work_key zb WHERE ' || wk('zb', l_root) || ' AND zb.batch_no = :b';
        END IF;
        RETURN 'SELECT zd.key_num FROM epf_work_key zd WHERE ' || wk('zd', p_table_id)
               || ' AND zd.root_key IN (SELECT zb.key_num FROM epf_work_key zb WHERE '
               || wk('zb', l_root) || ' AND zb.batch_no = :b)';
    END batch_keys;

    -- Rows still pointed at by a retained source row through a reverse link
    -- are kept: ' AND NOT EXISTS (...)' per reverse link, NULL when none.
    FUNCTION keep_pred(p_table_id IN NUMBER, p_alias IN VARCHAR2) RETURN VARCHAR2 IS
        l_links t_links := links_of(p_table_id);
        l_src   NUMBER;
        l_sql   VARCHAR2(32767);
    BEGIN
        FOR i IN 1 .. l_links.COUNT LOOP
            IF NOT l_links(i).direct THEN
                l_src := l_links(i).source_table_id;
                l_sql := l_sql
                    || ' AND NOT EXISTS (SELECT 1 FROM ' || tq(l_src) || ' zr WHERE zr.'
                    || qc(l_links(i).source_column) || ' = ' || p_alias || '.' || qc(l_links(i).match_column)
                    || ' AND NOT EXISTS (SELECT 1 FROM epf_work_key zq WHERE ' || wk('zq', l_src)
                    || ' AND zq.key_num = zr.' || qc(g_tables(l_src).key_column) || '))';
            END IF;
        END LOOP;
        RETURN l_sql;
    END keep_pred;

    -- Link condition over all batches (EXISTS form).
    FUNCTION link_exists(p_link IN t_link, p_alias IN VARCHAR2) RETURN VARCHAR2 IS
        l_src NUMBER := p_link.source_table_id;
    BEGIN
        IF p_link.direct THEN
            RETURN 'EXISTS (SELECT 1 FROM epf_work_key ze WHERE ' || wk('ze', l_src)
                   || ' AND ze.key_num = ' || p_alias || '.' || qc(p_link.match_column) || ')';
        END IF;
        RETURN 'EXISTS (SELECT 1 FROM ' || tq(l_src) || ' zs JOIN epf_work_key ze ON ' || wk('ze', l_src)
               || ' AND ze.key_num = zs.' || qc(g_tables(l_src).key_column)
               || ' WHERE zs.' || qc(p_link.source_column) || ' = ' || p_alias || '.' || qc(p_link.match_column) || ')';
    END link_exists;

    -- Eligibility of a root or link source through its own snapshot keys.
    FUNCTION own_exists(p_table_id IN NUMBER, p_alias IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF by_rowid(p_table_id) THEN
            RETURN '(EXISTS (SELECT 1 FROM epf_work_key ze WHERE ' || wk('ze', p_table_id)
                   || ' AND ze.key_rowid = ' || p_alias || '.ROWID) AND ' || p_alias || '.'
                   || qc(g_tables(p_table_id).date_column) || ' < ' || cutoff_literal || ')';
        END IF;
        RETURN 'EXISTS (SELECT 1 FROM epf_work_key ze WHERE ' || wk('ze', p_table_id)
               || ' AND ze.key_num = ' || p_alias || '.' || qc(g_tables(p_table_id).key_column) || ')';
    END own_exists;

    -- Predicates with disjoint matches that together select the eligible rows
    -- of a table (one per link: rows of that link not matched by an earlier
    -- one). With p_held, they select the linked rows kept by keep_pred.
    FUNCTION eligible_branches(p_table_id IN NUMBER, p_alias IN VARCHAR2, p_held IN BOOLEAN DEFAULT FALSE)
        RETURN t_texts IS
        l_out   t_texts;
        l_links t_links;
        l_prior VARCHAR2(32767);
        l_keep  VARCHAR2(32767);
        l_tail  VARCHAR2(32767);
    BEGIN
        IF g_tables(p_table_id).role = 'ROOT' OR has_keys(p_table_id) THEN
            l_out(1) := own_exists(p_table_id, p_alias);
            RETURN l_out;
        END IF;
        l_keep  := keep_pred(p_table_id, p_alias);
        l_tail  := CASE WHEN p_held THEN ' AND NOT (1 = 1' || l_keep || ')' ELSE l_keep END;
        l_links := links_of(p_table_id);
        FOR i IN 1 .. l_links.COUNT LOOP
            l_out(i) := link_exists(l_links(i), p_alias) || l_prior || l_tail;
            l_prior  := l_prior || ' AND NOT ' || link_exists(l_links(i), p_alias);
        END LOOP;
        RETURN l_out;
    END eligible_branches;

    -- Condition true for a row that is not eligible (anti-join form).
    FUNCTION not_eligible(p_table_id IN NUMBER, p_alias IN VARCHAR2) RETURN VARCHAR2 IS
        l_links t_links;
        l_sql   VARCHAR2(32767);
        l_keep  VARCHAR2(32767);
    BEGIN
        IF g_tables(p_table_id).role = 'ROOT' OR has_keys(p_table_id) THEN
            RETURN 'NOT ' || own_exists(p_table_id, p_alias);
        END IF;
        l_links := links_of(p_table_id);
        FOR i IN 1 .. l_links.COUNT LOOP
            l_sql := l_sql || CASE WHEN i > 1 THEN ' AND ' END || 'NOT ' || link_exists(l_links(i), p_alias);
        END LOOP;
        l_keep := keep_pred(p_table_id, p_alias);
        RETURN '((' || NVL(l_sql, '1 = 1') || ')'
               || CASE WHEN l_keep IS NOT NULL THEN ' OR NOT (1 = 1' || l_keep || ')' END || ')';
    END not_eligible;

    -- Query (rid, root_key) of the eligible rows of a table and the root(s)
    -- they belong to.
    FUNCTION root_map(p_table_id IN NUMBER) RETURN VARCHAR2 IS
        l_links t_links;
        l_keep  VARCHAR2(32767);
        l_sql   VARCHAR2(32767);
        l_src   NUMBER;
    BEGIN
        IF has_keys(p_table_id) THEN
            RETURN 'SELECT rm.ROWID AS rid, zm.root_key FROM ' || tq(p_table_id) || ' rm JOIN epf_work_key zm ON '
                   || wk('zm', p_table_id) || ' AND zm.key_num = rm.' || qc(g_tables(p_table_id).key_column);
        END IF;
        l_keep  := keep_pred(p_table_id, 'rm');
        l_links := links_of(p_table_id);
        FOR i IN 1 .. l_links.COUNT LOOP
            l_src := l_links(i).source_table_id;
            l_sql := l_sql || CASE WHEN i > 1 THEN ' UNION ALL ' END
                || 'SELECT rm.ROWID AS rid, zm.root_key FROM ' || tq(p_table_id) || ' rm '
                || CASE WHEN l_links(i).direct THEN
                        'JOIN epf_work_key zm ON ' || wk('zm', l_src)
                        || ' AND zm.key_num = rm.' || qc(l_links(i).match_column)
                   ELSE
                        'JOIN ' || tq(l_src) || ' zn ON zn.' || qc(l_links(i).source_column)
                        || ' = rm.' || qc(l_links(i).match_column)
                        || ' JOIN epf_work_key zm ON ' || wk('zm', l_src)
                        || ' AND zm.key_num = zn.' || qc(g_tables(l_src).key_column)
                   END
                || ' WHERE 1 = 1' || l_keep;
        END LOOP;
        RETURN l_sql;
    END root_map;

    -- Condition selecting the rows of a table processed in the batch bound as
    -- :b; one per link for a dependent.
    FUNCTION batch_preds(p_table_id IN NUMBER) RETURN t_texts IS
        l_out   t_texts;
        l_links t_links;
        l_keep  VARCHAR2(32767);
        l_src   NUMBER;
    BEGIN
        IF by_rowid(p_table_id) THEN
            l_out(1) := 't.ROWID IN (SELECT zb.key_rowid FROM epf_work_key zb WHERE ' || wk('zb', p_table_id)
                        || ' AND zb.batch_no = :b) AND t.' || qc(g_tables(p_table_id).date_column)
                        || ' < ' || cutoff_literal;
        ELSIF g_tables(p_table_id).role = 'ROOT' THEN
            l_out(1) := 't.' || qc(g_tables(p_table_id).key_column) || ' IN (' || batch_keys(p_table_id) || ')';
        ELSE
            l_keep  := keep_pred(p_table_id, 't');
            l_links := links_of(p_table_id);
            FOR i IN 1 .. l_links.COUNT LOOP
                l_src := l_links(i).source_table_id;
                IF l_links(i).direct THEN
                    l_out(i) := 't.' || qc(l_links(i).match_column) || ' IN (' || batch_keys(l_src) || ')';
                ELSE
                    l_out(i) := 't.' || qc(l_links(i).match_column) || ' IN (SELECT zs.' || qc(l_links(i).source_column)
                                || ' FROM ' || tq(l_src) || ' zs WHERE zs.' || qc(g_tables(l_src).key_column)
                                || ' IN (' || batch_keys(l_src) || '))';
                END IF;
                l_out(i) := l_out(i) || l_keep;
            END LOOP;
        END IF;
        RETURN l_out;
    END batch_preds;

    FUNCTION lob_columns(p_table_id IN NUMBER) RETURN t_lobs IS
        l_owner VARCHAR2(128) := g_tables(p_table_id).owner;
        l_table VARCHAR2(128) := g_tables(p_table_id).table_name;
        l_out   t_lobs;
    BEGIN
        SELECT c.column_name, c.data_type
          BULK COLLECT INTO l_out
          FROM dba_tab_columns c
          JOIN dba_lobs l ON l.owner = c.owner AND l.table_name = c.table_name AND l.column_name = c.column_name
         WHERE c.owner = l_owner
           AND c.table_name = l_table
           AND c.data_type IN ('CLOB', 'NCLOB', 'BLOB')
         ORDER BY c.column_id;
        RETURN l_out;
    END lob_columns;

    -- TRUE when a usable index starts with exactly these columns (any order).
    FUNCTION index_covers(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_columns IN SYS.ODCIVARCHAR2LIST)
        RETURN BOOLEAN IS
        l_n     NUMBER := p_columns.COUNT;
        l_count NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO l_count
          FROM (SELECT c.index_owner, c.index_name
                  FROM dba_ind_columns c
                  JOIN dba_indexes i ON i.owner = c.index_owner AND i.index_name = c.index_name
                 WHERE c.table_owner = p_owner
                   AND c.table_name = p_table
                   AND c.column_position <= l_n
                   AND c.column_name IN (SELECT column_value FROM TABLE(p_columns))
                   AND i.status IN ('VALID', 'N/A')
                 GROUP BY c.index_owner, c.index_name
                HAVING COUNT(*) = l_n);
        RETURN l_count > 0;
    END index_covers;

    FUNCTION table_bytes(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN NUMBER IS
        l_bytes NUMBER;
    BEGIN
        SELECT NVL(SUM(bytes), 0)
          INTO l_bytes
          FROM dba_segments
         WHERE owner = p_owner AND segment_name = p_table AND segment_type LIKE 'TABLE%';
        RETURN l_bytes;
    END table_bytes;

    FUNCTION column_text(p_columns IN SYS.ODCIVARCHAR2LIST, p_quoted IN BOOLEAN DEFAULT FALSE) RETURN VARCHAR2 IS
        l_out VARCHAR2(4000);
    BEGIN
        FOR i IN 1 .. p_columns.COUNT LOOP
            l_out := l_out || CASE WHEN i > 1 THEN ', ' END
                     || CASE WHEN p_quoted THEN qc(p_columns(i)) ELSE p_columns(i) END;
        END LOOP;
        RETURN l_out;
    END column_text;

    -- ------------------------------------------------------------------
    -- Run, registry and scope
    -- ------------------------------------------------------------------

    PROCEDURE load_registry IS
        l_tab t_table;
        l_lnk t_link;
        l_ids SYS.ODCINUMBERLIST;
        l_any BOOLEAN;
        i     PLS_INTEGER;
    BEGIN
        g_tables.DELETE;
        g_links.DELETE;
        FOR t IN (SELECT e.table_id, e.module_code, e.root_table_id, e.owner, e.table_name, e.role,
                         e.key_column, e.date_column, e.delete_order, e.lob_clear,
                         (SELECT COUNT(*) FROM dba_tables d
                           WHERE d.owner = e.owner AND d.table_name = e.table_name) AS present
                    FROM epf_table e
                   WHERE e.active = 'Y') LOOP
            l_tab.table_id      := t.table_id;
            l_tab.module_code   := t.module_code;
            l_tab.root_table_id := t.root_table_id;
            l_tab.owner         := t.owner;
            l_tab.table_name    := t.table_name;
            l_tab.role          := t.role;
            l_tab.key_column    := t.key_column;
            l_tab.date_column   := t.date_column;
            l_tab.delete_order  := t.delete_order;
            l_tab.lob_clear     := t.lob_clear;
            l_tab.present       := t.present > 0;
            l_tab.is_source     := FALSE;
            l_tab.reachable     := FALSE;
            g_tables(t.table_id) := l_tab;
        END LOOP;

        FOR k IN (SELECT l.link_id, l.table_id, l.match_column, l.source_table_id, l.source_column,
                         CASE WHEN l.source_column = s.key_column THEN 'Y' ELSE 'N' END AS direct
                    FROM epf_link l
                    JOIN epf_table d ON d.table_id = l.table_id AND d.active = 'Y'
                    JOIN epf_table s ON s.table_id = l.source_table_id AND s.active = 'Y') LOOP
            l_lnk.link_id         := k.link_id;
            l_lnk.table_id        := k.table_id;
            l_lnk.match_column    := k.match_column;
            l_lnk.source_table_id := k.source_table_id;
            l_lnk.source_column   := k.source_column;
            l_lnk.direct          := k.direct = 'Y';
            l_lnk.usable          := FALSE;
            g_links(k.link_id) := l_lnk;
            g_tables(k.source_table_id).is_source := TRUE;
        END LOOP;

        -- A table is processed when it is present and, for a dependent, at
        -- least one of its sources is processed. Sources come first.
        SELECT table_id BULK COLLECT INTO l_ids
          FROM epf_table
         WHERE active = 'Y'
         ORDER BY root_table_id, delete_order DESC, table_id;
        FOR k IN 1 .. l_ids.COUNT LOOP
            IF g_tables(l_ids(k)).role = 'ROOT' THEN
                g_tables(l_ids(k)).reachable := g_tables(l_ids(k)).present;
            ELSE
                l_any := FALSE;
                i := g_links.FIRST;
                WHILE i IS NOT NULL LOOP
                    IF g_links(i).table_id = l_ids(k) THEN
                        g_links(i).usable := g_tables(l_ids(k)).present
                                             AND g_tables(g_links(i).source_table_id).reachable;
                        l_any := l_any OR g_links(i).usable;
                    END IF;
                    i := g_links.NEXT(i);
                END LOOP;
                g_tables(l_ids(k)).reachable := l_any;
            END IF;
        END LOOP;
    END load_registry;

    PROCEDURE init(p_run_id IN NUMBER, p_actions IN VARCHAR2) IS
    BEGIN
        BEGIN
            SELECT * INTO g_run FROM epf_run WHERE run_id = p_run_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20130, 'Run not found: ' || epf_util.run_label(p_run_id));
        END;
        IF INSTR(',' || p_actions || ',', ',' || g_run.action || ',') = 0 OR g_run.purge_mode IS NULL THEN
            RAISE_APPLICATION_ERROR(-20130, 'Run ' || epf_util.run_label(p_run_id) || ' is a ' || g_run.action
                                            || ' run; expected ' || p_actions || ' with purge parameters.');
        END IF;
        IF NVL(epf_log.current_run, -1) <> p_run_id THEN
            RAISE_APPLICATION_ERROR(-20130, 'This session is not bound to run ' || epf_util.run_label(p_run_id)
                                            || ' (epf_control.enter).');
        END IF;
        g_warnings := 0;
        g_eligible.DELETE;
        g_undo_batch := 0;
        g_undo_kept  := 0;
        g_undo_cap   := NULL;
        g_reuse_run  := NULL;
        g_silent     := FALSE;
        load_registry;
        SELECT module_code BULK COLLECT INTO g_modules
          FROM epf_module
         WHERE g_run.depth = 'ALL'
            OR INSTR(',' || g_run.depth || ',', ',' || module_code || ',') > 0
         ORDER BY display_order;
    END init;

    FUNCTION in_scope(p_module IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        FOR i IN 1 .. g_modules.COUNT LOOP
            IF g_modules(i) = p_module THEN
                RETURN TRUE;
            END IF;
        END LOOP;
        RETURN FALSE;
    END in_scope;

    FUNCTION module_action(p_module IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF g_run.purge_mode IN ('FULL', 'LOGS')
           OR (g_run.purge_mode = 'CLOB_N_LOGS' AND p_module = c_logs_module) THEN
            RETURN c_delete;
        END IF;
        RETURN c_clear;
    END module_action;

    PROCEDURE scope_event IS
        l_text VARCHAR2(4000);
        i      PLS_INTEGER;
    BEGIN
        FOR m IN 1 .. g_modules.COUNT LOOP
            l_text := l_text || CASE WHEN m > 1 THEN ', ' END || g_modules(m) || ' '
                      || CASE module_action(g_modules(m)) WHEN c_delete THEN 'delete' ELSE 'clear LOBs' END;
        END LOOP;
        epf_log.info('PURGE_SCOPE', 'mode=' || g_run.purge_mode || ' cutoff=' || cutoff_text
                                    || ' batch=' || g_run.batch_size || ' dry_run=' || g_run.dry_run
                                    || ': ' || l_text);
        i := g_tables.FIRST;
        WHILE i IS NOT NULL LOOP
            IF in_scope(g_tables(i).module_code) AND g_tables(i).present AND NOT g_tables(i).reachable THEN
                g_warnings := g_warnings + 1;
                epf_log.warn('TABLE_SKIPPED', 'No source table of this table is present; it is skipped',
                             g_tables(i).owner, g_tables(i).table_name);
            END IF;
            i := g_tables.NEXT(i);
        END LOOP;
    END scope_event;

    -- Ends the running step as FAILED after an unexpected error.
    PROCEDURE fail_step(p_code IN NUMBER, p_message IN VARCHAR2, p_backtrace IN VARCHAR2) IS
    BEGIN
        ROLLBACK;
        epf_log.event(epf_log.c_error, 'STEP_FAILED',
                      NVL(epf_log.current_step, 'PURGE') || ': ' || p_message || ' ' || p_backtrace,
                      p_ora_code => ABS(p_code));
        IF epf_log.current_step IS NOT NULL THEN
            epf_log.step_end('FAILED', p_message);
        END IF;
    END fail_step;

    -- ------------------------------------------------------------------
    -- Key snapshot, held roots, shared batches
    -- ------------------------------------------------------------------

    FUNCTION derive_keys(p_table_id IN NUMBER) RETURN NUMBER IS
        l_links t_links := links_of(p_table_id);
        l_parts VARCHAR2(32767);
    BEGIN
        FOR i IN 1 .. l_links.COUNT LOOP
            l_parts := l_parts || CASE WHEN i > 1 THEN ' UNION ALL ' END
                || 'SELECT dt.' || qc(g_tables(p_table_id).key_column) || ' AS key_num, dw.root_key FROM '
                || tq(p_table_id) || ' dt JOIN epf_work_key dw ON ' || wk('dw', l_links(i).source_table_id)
                || ' AND dw.key_num = dt.' || qc(l_links(i).match_column);
        END LOOP;
        EXECUTE IMMEDIATE
            'INSERT INTO epf_work_key (run_id, table_id, batch_no, key_num, root_key) SELECT '
            || CASE WHEN l_links.COUNT > 1 THEN 'DISTINCT ' END
            || g_run.run_id || ', ' || p_table_id || ', 0, u.key_num, u.root_key FROM (' || l_parts || ') u';
        RETURN SQL%ROWCOUNT;
    END derive_keys;

    -- Enabled FKs into the tables of a tree, with the join between child (c)
    -- and parent (p) and whether the child's own link already follows the FK.
    FUNCTION tree_fks(p_root_id IN NUMBER) RETURN t_fks IS
        l_out   t_fks;
        l_fk    t_fk;
        l_cols  PLS_INTEGER;
        l_c_col VARCHAR2(128);
        l_p_col VARCHAR2(128);
        i       PLS_INTEGER;
    BEGIN
        FOR f IN (SELECT c.owner AS c_owner, c.table_name AS c_table, c.constraint_name,
                         p.owner AS p_owner, p.table_name AS p_table, p.constraint_name AS p_cons,
                         pt.table_id AS p_id, ct.table_id AS c_id, ct.root_table_id AS c_root
                    FROM dba_constraints c
                    JOIN dba_constraints p
                      ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
                    JOIN epf_table pt
                      ON pt.owner = p.owner AND pt.table_name = p.table_name
                     AND pt.active = 'Y' AND pt.root_table_id = p_root_id
                    LEFT JOIN epf_table ct
                      ON ct.owner = c.owner AND ct.table_name = c.table_name AND ct.active = 'Y'
                   WHERE c.constraint_type = 'R'
                     AND c.status = 'ENABLED'
                   ORDER BY p.owner, p.table_name, c.owner, c.table_name, c.constraint_name) LOOP
            CONTINUE WHEN f.c_id IS NOT NULL AND f.c_root <> p_root_id;
            CONTINUE WHEN NOT g_tables(f.p_id).reachable OR by_rowid(f.p_id);
            CONTINUE WHEN f.c_id IS NOT NULL AND NOT g_tables(f.c_id).reachable;

            l_fk.c_owner         := f.c_owner;
            l_fk.c_table         := f.c_table;
            l_fk.constraint_name := f.constraint_name;
            l_fk.p_owner         := f.p_owner;
            l_fk.p_table         := f.p_table;
            l_fk.p_id            := f.p_id;
            l_fk.c_id            := f.c_id;
            l_fk.join_cond       := NULL;
            l_cols := 0;
            FOR col IN (SELECT cc.column_name AS c_col, pc.column_name AS p_col
                          FROM dba_cons_columns cc
                          JOIN dba_cons_columns pc
                            ON pc.owner = f.p_owner AND pc.constraint_name = f.p_cons
                           AND pc.position = cc.position
                         WHERE cc.owner = f.c_owner AND cc.constraint_name = f.constraint_name
                         ORDER BY cc.position) LOOP
                l_fk.join_cond := l_fk.join_cond || CASE WHEN l_cols > 0 THEN ' AND ' END
                                  || 'c.' || qc(col.c_col) || ' = p.' || qc(col.p_col);
                l_cols  := l_cols + 1;
                l_c_col := col.c_col;
                l_p_col := col.p_col;
            END LOOP;

            l_fk.covered := FALSE;
            IF f.c_id IS NOT NULL AND l_cols = 1 THEN
                i := g_links.FIRST;
                WHILE i IS NOT NULL LOOP
                    IF g_links(i).table_id = f.c_id AND g_links(i).usable AND g_links(i).direct
                       AND g_links(i).source_table_id = f.p_id
                       AND g_links(i).match_column = l_c_col AND g_links(i).source_column = l_p_col THEN
                        l_fk.covered := TRUE;
                    END IF;
                    i := g_links.NEXT(i);
                END LOOP;
            END IF;
            l_out(l_out.COUNT + 1) := l_fk;
        END LOOP;
        RETURN l_out;
    END tree_fks;

    -- Removes from the snapshot every root whose tree holds a row referenced
    -- by a row that is kept, until no such reference remains.
    PROCEDURE hold_back(p_root_id IN NUMBER, p_held OUT NUMBER) IS
        l_fks     t_fks := tree_fks(p_root_id);
        l_tree    SYS.ODCINUMBERLIST := tree_tables(p_root_id);
        l_keys    SYS.ODCINUMBERLIST;
        l_run     NUMBER := g_run.run_id;
        l_round   PLS_INTEGER := 0;
        l_found   NUMBER;
        l_c_owner VARCHAR2(128);
        l_c_table VARCHAR2(128);
        l_cons    VARCHAR2(128);
        l_p_owner VARCHAR2(128);
        l_p_table VARCHAR2(128);
    BEGIN
        p_held := 0;
        LOOP
            l_round := l_round + 1;
            l_found := 0;
            FOR f IN 1 .. l_fks.COUNT LOOP
                CONTINUE WHEN l_fks(f).covered;
                EXECUTE IMMEDIATE
                    'SELECT DISTINCT pm.root_key FROM (' || root_map(l_fks(f).p_id) || ') pm'
                    || ' JOIN ' || tq(l_fks(f).p_id) || ' p ON p.ROWID = pm.rid'
                    || ' JOIN ' || epf_util.qname(l_fks(f).c_owner, l_fks(f).c_table) || ' c ON ' || l_fks(f).join_cond
                    || CASE WHEN l_fks(f).c_id IS NOT NULL THEN ' WHERE ' || not_eligible(l_fks(f).c_id, 'c') END
                    BULK COLLECT INTO l_keys;
                IF l_keys.COUNT > 0 THEN
                    l_c_owner := l_fks(f).c_owner;
                    l_c_table := l_fks(f).c_table;
                    l_cons    := l_fks(f).constraint_name;
                    l_p_owner := l_fks(f).p_owner;
                    l_p_table := l_fks(f).p_table;
                    FORALL i IN 1 .. l_keys.COUNT
                        INSERT INTO epf_held_root (run_id, table_id, root_key, child_owner, child_table,
                                                   constraint_name, parent_owner, parent_table, iteration)
                        SELECT l_run, p_root_id, l_keys(i), l_c_owner, l_c_table, l_cons, l_p_owner, l_p_table, l_round
                          FROM dual
                         WHERE NOT EXISTS (SELECT 1 FROM epf_held_root h
                                            WHERE h.run_id = l_run AND h.table_id = p_root_id
                                              AND h.root_key = l_keys(i));
                    l_found := l_found + SQL%ROWCOUNT;
                    FORALL i IN 1 .. l_keys.COUNT
                        DELETE FROM epf_work_key
                         WHERE run_id = l_run
                           AND table_id IN (SELECT column_value FROM TABLE(l_tree))
                           AND root_key = l_keys(i);
                    COMMIT;
                END IF;
            END LOOP;
            p_held := p_held + l_found;
            EXIT WHEN l_found = 0;
            IF l_round >= c_max_rounds THEN
                RAISE_APPLICATION_ERROR(-20131, 'Held roots of ' || tname(p_root_id) || ' did not converge after '
                                                || c_max_rounds || ' rounds (' || p_held || ' held).');
            END IF;
        END LOOP;
    END hold_back;

    -- Gives roots whose trees reference each other through an FK the same
    -- group and moves them to the batch of the group's smallest key (the
    -- earliest batch of the group, since batches follow key order). Returns
    -- the number of roots in shared groups.
    FUNCTION group_roots(p_root_id IN NUMBER) RETURN NUMBER IS
        l_fks    t_fks := tree_fks(p_root_id);
        l_parent t_key_map;
        l_a      SYS.ODCINUMBERLIST;
        l_b      SYS.ODCINUMBERLIST;
        l_keys   SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        l_reps   SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        l_run    NUMBER := g_run.run_id;
        l_k      VARCHAR2(200);

        FUNCTION find_rep(p_key IN NUMBER) RETURN NUMBER IS
            l_node NUMBER := p_key;
        BEGIN
            WHILE l_parent.EXISTS(TO_CHAR(l_node)) AND l_parent(TO_CHAR(l_node)) <> l_node LOOP
                l_node := l_parent(TO_CHAR(l_node));
            END LOOP;
            RETURN l_node;
        END find_rep;

        PROCEDURE unite(p_a IN NUMBER, p_b IN NUMBER) IS
            l_ra NUMBER := find_rep(p_a);
            l_rb NUMBER := find_rep(p_b);
        BEGIN
            IF NOT l_parent.EXISTS(TO_CHAR(l_ra)) THEN
                l_parent(TO_CHAR(l_ra)) := l_ra;
            END IF;
            IF NOT l_parent.EXISTS(TO_CHAR(l_rb)) THEN
                l_parent(TO_CHAR(l_rb)) := l_rb;
            END IF;
            IF l_ra < l_rb THEN
                l_parent(TO_CHAR(l_rb)) := l_ra;
            ELSIF l_rb < l_ra THEN
                l_parent(TO_CHAR(l_ra)) := l_rb;
            END IF;
        END unite;
    BEGIN
        FOR f IN 1 .. l_fks.COUNT LOOP
            CONTINUE WHEN l_fks(f).covered OR l_fks(f).c_id IS NULL;
            EXECUTE IMMEDIATE
                'SELECT DISTINCT cm.root_key, pm.root_key FROM (' || root_map(l_fks(f).p_id) || ') pm'
                || ' JOIN ' || tq(l_fks(f).p_id) || ' p ON p.ROWID = pm.rid'
                || ' JOIN ' || tq(l_fks(f).c_id) || ' c ON ' || l_fks(f).join_cond
                || ' JOIN (' || root_map(l_fks(f).c_id) || ') cm ON cm.rid = c.ROWID'
                || ' WHERE cm.root_key <> pm.root_key'
                BULK COLLECT INTO l_a, l_b;
            FOR i IN 1 .. l_a.COUNT LOOP
                unite(l_a(i), l_b(i));
            END LOOP;
        END LOOP;

        l_k := l_parent.FIRST;
        WHILE l_k IS NOT NULL LOOP
            l_keys.EXTEND;
            l_keys(l_keys.COUNT) := TO_NUMBER(l_k);
            l_reps.EXTEND;
            l_reps(l_reps.COUNT) := find_rep(TO_NUMBER(l_k));
            l_k := l_parent.NEXT(l_k);
        END LOOP;
        FORALL i IN 1 .. l_keys.COUNT
            UPDATE epf_work_key w
               SET w.group_key = l_reps(i),
                   w.batch_no  = (SELECT r.batch_no
                                    FROM epf_work_key r
                                   WHERE r.run_id = l_run AND r.table_id = p_root_id
                                     AND r.root_key = l_reps(i))
             WHERE w.run_id = l_run AND w.table_id = p_root_id AND w.root_key = l_keys(i);
        COMMIT;
        RETURN l_keys.COUNT;
    END group_roots;

    PROCEDURE gather_work_key_stats IS
    BEGIN
        DBMS_STATS.GATHER_TABLE_STATS(
            ownname       => g_owner,
            tabname       => 'EPF_WORK_KEY',
            method_opt    => 'FOR ALL COLUMNS SIZE 1 FOR COLUMNS table_id SIZE 254',
            cascade       => TRUE,
            no_invalidate => FALSE);
    END gather_work_key_stats;

    PROCEDURE snapshot_tree(p_root_id IN NUMBER, p_action IN VARCHAR2, p_batches OUT NUMBER) IS
        l_root    t_table := g_tables(p_root_id);
        l_ids     SYS.ODCINUMBERLIST;
        l_tree    SYS.ODCINUMBERLIST;
        l_roots   NUMBER;
        l_derived NUMBER := 0;
        l_held    NUMBER := 0;
        l_grouped NUMBER := 0;
        l_run     NUMBER := g_run.run_id;
    BEGIN
        IF by_rowid(p_root_id) THEN
            EXECUTE IMMEDIATE
                'INSERT INTO epf_work_key (run_id, table_id, batch_no, key_rowid)'
                || ' SELECT ' || l_run || ', ' || p_root_id || ', CEIL(ROWNUM / ' || g_run.batch_size || '), rid'
                || ' FROM (SELECT t.ROWID AS rid FROM ' || tq(p_root_id) || ' t WHERE t.'
                || qc(l_root.date_column) || ' < ' || cutoff_literal || ' ORDER BY t.ROWID)';
            COMMIT;
        ELSE
            EXECUTE IMMEDIATE
                'INSERT INTO epf_work_key (run_id, table_id, batch_no, key_num, root_key, group_key)'
                || ' SELECT ' || l_run || ', ' || p_root_id || ', CEIL(ROW_NUMBER() OVER (ORDER BY t.'
                || qc(l_root.key_column) || ') / ' || g_run.batch_size || '), t.' || qc(l_root.key_column)
                || ', t.' || qc(l_root.key_column) || ', t.' || qc(l_root.key_column)
                || ' FROM ' || tq(p_root_id) || ' t WHERE t.' || qc(l_root.date_column) || ' < ' || cutoff_literal;
            COMMIT;
            l_ids := tree_tables(p_root_id, p_descending => TRUE);
            FOR k IN 1 .. l_ids.COUNT LOOP
                IF l_ids(k) <> p_root_id AND g_tables(l_ids(k)).reachable AND has_keys(l_ids(k)) THEN
                    l_derived := l_derived + derive_keys(l_ids(k));
                    COMMIT;
                END IF;
            END LOOP;
        END IF;
        gather_work_key_stats;

        IF p_action = c_delete AND NOT by_rowid(p_root_id) THEN
            hold_back(p_root_id, l_held);
            l_grouped := group_roots(p_root_id);
        END IF;

        l_tree := tree_tables(p_root_id);
        SELECT COUNT(CASE WHEN table_id = p_root_id THEN 1 END),
               COUNT(CASE WHEN table_id <> p_root_id THEN 1 END),
               NVL(MAX(CASE WHEN table_id = p_root_id THEN batch_no END), 0)
          INTO l_roots, l_derived, p_batches
          FROM epf_work_key
         WHERE run_id = l_run
           AND table_id IN (SELECT column_value FROM TABLE(l_tree));

        epf_log.event(epf_log.c_info, 'KEYS_SNAPSHOT',
                      tname(p_root_id) || ': ' || epf_util.fmt_int(l_roots) || ' rows before ' || cutoff_text
                      || ' in ' || epf_util.fmt_int(p_batches) || ' batches'
                      || CASE WHEN by_rowid(p_root_id) THEN ' (by ROWID)'
                              ELSE ', ' || epf_util.fmt_int(l_derived) || ' derived keys' END,
                      p_object_owner => l_root.owner, p_object_name => l_root.table_name, p_rows => l_roots);
        IF l_held > 0 THEN
            g_warnings := g_warnings + 1;
            FOR h IN (SELECT child_owner, child_table, constraint_name, parent_owner, parent_table, COUNT(*) AS roots
                        FROM epf_held_root
                       WHERE run_id = l_run AND table_id = p_root_id
                       GROUP BY child_owner, child_table, constraint_name, parent_owner, parent_table
                       ORDER BY child_owner, child_table, constraint_name) LOOP
                epf_log.event(epf_log.c_warn, 'ROOTS_HELD',
                              epf_util.fmt_int(h.roots) || ' ' || tname(p_root_id) || ' rows held back: '
                              || h.parent_owner || '.' || h.parent_table || ' rows of their trees are referenced by '
                              || h.child_owner || '.' || h.child_table || ' rows that are kept (' || h.constraint_name || ')',
                              p_object_owner => l_root.owner, p_object_name => l_root.table_name, p_rows => h.roots);
            END LOOP;
        END IF;
        IF l_grouped > 0 THEN
            epf_log.event(epf_log.c_info, 'ROOTS_GROUPED',
                          epf_util.fmt_int(l_grouped) || ' ' || tname(p_root_id)
                          || ' rows share a batch with the rows their trees reference',
                          p_object_owner => l_root.owner, p_object_name => l_root.table_name, p_rows => l_grouped);
        END IF;
    END snapshot_tree;

    -- ------------------------------------------------------------------
    -- Counts
    -- ------------------------------------------------------------------

    FUNCTION count_sum(p_table_id IN NUMBER, p_select IN VARCHAR2, p_preds IN t_texts) RETURN NUMBER IS
        l_total NUMBER := 0;
        l_value NUMBER;
    BEGIN
        FOR i IN 1 .. p_preds.COUNT LOOP
            EXECUTE IMMEDIATE 'SELECT ' || p_select || ' FROM ' || tq(p_table_id) || ' t WHERE ' || p_preds(i)
                INTO l_value;
            l_total := l_total + NVL(l_value, 0);
        END LOOP;
        RETURN l_total;
    END count_sum;

    -- Counts every table of the module into EPF_TABLE_STAT (phase BEFORE or
    -- AFTER). p_complete: the module processed every batch; residual rows are
    -- then a warning, after a stop or a failure they are expected (checks P1
    -- and P2 report them).
    PROCEDURE count_tables(p_module IN VARCHAR2, p_action IN VARCHAR2, p_phase IN VARCHAR2,
                           p_processed IN t_numbers, p_complete IN BOOLEAN DEFAULT TRUE) IS
        l_total     NUMBER;
        l_eligible  NUMBER;
        l_lob       NUMBER;
        l_held      NUMBER;
        l_processed NUMBER;
        l_lobs      t_lobs;
        l_select    VARCHAR2(32767);
        l_residual  NUMBER;
        l_run       NUMBER := g_run.run_id;
        l_tid       NUMBER;
    BEGIN
        FOR e IN (SELECT table_id
                    FROM epf_table
                   WHERE active = 'Y' AND module_code = p_module
                   ORDER BY root_table_id, delete_order DESC, table_id) LOOP
            l_tid := e.table_id;
            CONTINUE WHEN NOT g_tables(l_tid).reachable;

            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || tq(l_tid) INTO l_total;
            l_eligible := count_sum(l_tid, 'COUNT(*)', eligible_branches(l_tid, 't'));

            l_lob := NULL;
            IF p_action = c_clear AND g_tables(l_tid).lob_clear = 'Y' THEN
                l_lobs := lob_columns(l_tid);
                l_select := NULL;
                FOR c IN 1 .. l_lobs.COUNT LOOP
                    l_select := l_select || CASE WHEN c > 1 THEN ' + ' END
                                || 'COUNT(CASE WHEN DBMS_LOB.GETLENGTH(t.' || qc(l_lobs(c).column_name)
                                || ') > 0 THEN 1 END)';
                END LOOP;
                l_lob := CASE WHEN l_select IS NULL THEN 0
                              ELSE count_sum(l_tid, l_select, eligible_branches(l_tid, 't')) END;
            END IF;

            l_held := NULL;
            IF p_phase = 'BEFORE' THEN
                IF g_tables(l_tid).role = 'ROOT' THEN
                    SELECT COUNT(*) INTO l_held FROM epf_held_root WHERE run_id = l_run AND table_id = l_tid;
                ELSIF NOT has_keys(l_tid) AND keep_pred(l_tid, 't') IS NOT NULL THEN
                    l_held := count_sum(l_tid, 'COUNT(*)', eligible_branches(l_tid, 't', p_held => TRUE));
                    IF l_held > 0 THEN
                        g_warnings := g_warnings + 1;
                        epf_log.event(epf_log.c_warn, 'ROWS_HELD',
                                      epf_util.fmt_int(l_held) || ' rows kept: still referenced by rows that are kept',
                                      p_object_owner => g_tables(l_tid).owner,
                                      p_object_name => g_tables(l_tid).table_name, p_rows => l_held);
                    END IF;
                END IF;
            END IF;

            l_processed := NULL;
            IF p_phase = 'AFTER' THEN
                l_processed := CASE WHEN p_processed.EXISTS(l_tid) THEN p_processed(l_tid) ELSE 0 END;
            END IF;

            INSERT INTO epf_table_stat (run_id, table_id, phase, total_rows, eligible_rows, retained_rows,
                                        nonempty_lob_rows, processed_rows, held_rows, action)
            VALUES (l_run, l_tid, p_phase, l_total, l_eligible, l_total - l_eligible,
                    l_lob, l_processed, l_held, p_action);
            COMMIT;

            IF p_phase = 'BEFORE' THEN
                epf_log.event(epf_log.c_info, 'TABLE_ELIGIBLE',
                              'total ' || epf_util.fmt_int(l_total) || ', eligible ' || epf_util.fmt_int(l_eligible)
                              || ', retained ' || epf_util.fmt_int(l_total - l_eligible)
                              || CASE WHEN l_lob IS NOT NULL THEN ', non-empty LOB values ' || epf_util.fmt_int(l_lob) END
                              || CASE WHEN l_held > 0 THEN ', held ' || epf_util.fmt_int(l_held) END,
                              p_object_owner => g_tables(l_tid).owner, p_object_name => g_tables(l_tid).table_name,
                              p_rows => NVL(l_lob, l_eligible));
            ELSE
                l_residual := CASE WHEN p_action = c_delete THEN l_eligible ELSE l_lob END;
                epf_log.event(CASE WHEN NVL(l_residual, 0) = 0 THEN epf_log.c_ok
                                   WHEN p_complete THEN epf_log.c_warn
                                   ELSE epf_log.c_info END,
                              'TABLE_RESULT',
                              CASE WHEN p_action = c_delete
                                   THEN 'deleted ' || epf_util.fmt_int(l_processed) || ', residual eligible '
                                        || epf_util.fmt_int(l_eligible) || ', rows now ' || epf_util.fmt_int(l_total)
                                   ELSE 'LOB values cleared ' || epf_util.fmt_int(l_processed)
                                        || ', non-empty remaining ' || epf_util.fmt_int(NVL(l_lob, 0))
                              END,
                              p_object_owner => g_tables(l_tid).owner, p_object_name => g_tables(l_tid).table_name,
                              p_rows => l_processed);
            END IF;
        END LOOP;
    END count_tables;

    -- Enabled, validated single-column FK from p_owner.p_table(p_column) to
    -- p_r_owner.p_r_table(p_r_column); NULL when there is none.
    FUNCTION protecting_fk(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_column IN VARCHAR2,
                           p_r_owner IN VARCHAR2, p_r_table IN VARCHAR2, p_r_column IN VARCHAR2)
        RETURN VARCHAR2 IS
        l_name VARCHAR2(128);
    BEGIN
        SELECT MAX(c.constraint_name)
          INTO l_name
          FROM dba_constraints c
          JOIN dba_cons_columns cc ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name
          JOIN dba_constraints p ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
          JOIN dba_cons_columns pc ON pc.owner = p.owner AND pc.constraint_name = p.constraint_name
         WHERE c.owner = p_owner
           AND c.table_name = p_table
           AND c.constraint_type = 'R'
           AND c.status = 'ENABLED'
           AND c.validated = 'VALIDATED'
           AND cc.column_name = p_column
           AND p.owner = p_r_owner
           AND p.table_name = p_r_table
           AND pc.column_name = p_r_column
           AND (SELECT COUNT(*) FROM dba_cons_columns x
                 WHERE x.owner = c.owner AND x.constraint_name = c.constraint_name) = 1;
        RETURN l_name;
    END protecting_fk;

    -- Orphans of every link of the module's tables (EPF_LINK_STAT): rows on the
    -- pointing side whose value is not found on the pointed side. A link
    -- protected by an FK is recorded with 0 orphans and the FK name.
    PROCEDURE count_orphans(p_module IN VARCHAR2, p_phase IN VARCHAR2) IS
        l_links    t_links;
        l_src      NUMBER;
        l_from     NUMBER;
        l_from_col VARCHAR2(128);
        l_to       NUMBER;
        l_to_col   VARCHAR2(128);
        l_fk       VARCHAR2(128);
        l_orphans  NUMBER;
        l_before   NUMBER;
        l_run      NUMBER := g_run.run_id;
        l_link_id  NUMBER;
    BEGIN
        FOR e IN (SELECT table_id
                    FROM epf_table
                   WHERE active = 'Y' AND module_code = p_module AND role = 'DEPENDENT'
                   ORDER BY table_id) LOOP
            CONTINUE WHEN NOT g_tables(e.table_id).reachable;
            l_links := links_of(e.table_id);
            FOR i IN 1 .. l_links.COUNT LOOP
                l_src := l_links(i).source_table_id;
                IF l_links(i).direct THEN
                    l_from := e.table_id;
                    l_from_col := l_links(i).match_column;
                    l_to := l_src;
                    l_to_col := l_links(i).source_column;
                ELSE
                    l_from := l_src;
                    l_from_col := l_links(i).source_column;
                    l_to := e.table_id;
                    l_to_col := l_links(i).match_column;
                END IF;
                l_fk := protecting_fk(g_tables(l_from).owner, g_tables(l_from).table_name, l_from_col,
                                      g_tables(l_to).owner, g_tables(l_to).table_name, l_to_col);
                IF l_fk IS NOT NULL THEN
                    l_orphans := 0;
                ELSE
                    EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM ' || tq(l_from) || ' a WHERE a.' || qc(l_from_col)
                                      || ' IS NOT NULL AND NOT EXISTS (SELECT 1 FROM ' || tq(l_to) || ' b WHERE b.'
                                      || qc(l_to_col) || ' = a.' || qc(l_from_col) || ')'
                        INTO l_orphans;
                END IF;
                l_link_id := l_links(i).link_id;
                INSERT INTO epf_link_stat (run_id, link_id, phase, pointing_table_id, orphan_rows, protected_by)
                VALUES (l_run, l_link_id, p_phase, l_from, l_orphans, l_fk);
                COMMIT;
                IF l_orphans > 0 THEN
                    -- Orphans found before the purge, and orphans after it that
                    -- were already there, describe the application data: INFO.
                    -- Orphans the purge added are a WARN (and fail check P4).
                    l_before := NULL;
                    IF p_phase <> 'BEFORE' THEN
                        SELECT MAX(orphan_rows) INTO l_before
                          FROM epf_link_stat
                         WHERE run_id = l_run AND link_id = l_link_id AND phase = 'BEFORE';
                    END IF;
                    epf_log.event(CASE WHEN p_phase <> 'BEFORE' AND l_orphans > NVL(l_before, 0)
                                       THEN epf_log.c_warn ELSE epf_log.c_info END,
                                  'LINK_ORPHANS',
                                  epf_util.fmt_int(l_orphans) || ' rows point at no row of ' || tname(l_to) || ' ('
                                  || l_from_col || ' -> ' || l_to_col || ', link ' || l_link_id || ', ' || p_phase || ')'
                                  || CASE WHEN p_phase = 'BEFORE' THEN '; they exist before the purge'
                                          WHEN l_before IS NOT NULL THEN '; ' || epf_util.fmt_int(l_before)
                                                                         || ' before the purge'
                                     END,
                                  p_object_owner => g_tables(l_from).owner,
                                  p_object_name => g_tables(l_from).table_name, p_rows => l_orphans);
                END IF;
            END LOOP;
        END LOOP;
        UPDATE epf_table_stat t
           SET t.orphan_rows = (SELECT SUM(s.orphan_rows)
                                  FROM epf_link_stat s
                                 WHERE s.run_id = t.run_id AND s.phase = t.phase
                                   AND s.pointing_table_id = t.table_id)
         WHERE t.run_id = l_run AND t.phase = p_phase
           AND t.table_id IN (SELECT s.pointing_table_id FROM epf_link_stat s
                               WHERE s.run_id = l_run AND s.phase = p_phase);
        COMMIT;
    END count_orphans;

    -- ------------------------------------------------------------------
    -- Temporary supporting indexes
    -- ------------------------------------------------------------------

    -- Indexes the purge of a module relies on (see t_need).
    FUNCTION index_needs(p_module IN VARCHAR2) RETURN t_needs IS
        l_out  t_needs;
        l_seen t_position_map;
        l_cols SYS.ODCIVARCHAR2LIST;
        i      PLS_INTEGER := g_links.FIRST;

        PROCEDURE add_need(p_table_id IN NUMBER, p_owner IN VARCHAR2, p_table IN VARCHAR2,
                      p_columns IN SYS.ODCIVARCHAR2LIST, p_fk IN BOOLEAN, p_detail IN VARCHAR2) IS
            l_key VARCHAR2(4000) := p_owner || '.' || p_table || ':' || column_text(p_columns);
            l_new t_need;
        BEGIN
            IF l_seen.EXISTS(l_key) THEN
                IF p_fk AND NOT l_out(l_seen(l_key)).fk THEN
                    l_out(l_seen(l_key)).fk     := TRUE;
                    l_out(l_seen(l_key)).detail := l_out(l_seen(l_key)).detail || ', ' || p_detail;
                END IF;
                RETURN;
            END IF;
            l_new.table_id   := p_table_id;
            l_new.owner      := p_owner;
            l_new.table_name := p_table;
            l_new.col_list   := p_columns;
            l_new.fk         := p_fk;
            l_new.detail     := p_detail;
            l_out(l_out.COUNT + 1) := l_new;
            l_seen(l_key) := l_out.COUNT;
        END add_need;
    BEGIN
        WHILE i IS NOT NULL LOOP
            IF g_links(i).usable AND g_tables(g_links(i).table_id).module_code = p_module THEN
                add_need(g_links(i).table_id, g_tables(g_links(i).table_id).owner, g_tables(g_links(i).table_id).table_name,
                    SYS.ODCIVARCHAR2LIST(g_links(i).match_column), FALSE, 'link ' || g_links(i).link_id);
                IF NOT g_links(i).direct THEN
                    add_need(g_links(i).source_table_id, g_tables(g_links(i).source_table_id).owner,
                        g_tables(g_links(i).source_table_id).table_name,
                        SYS.ODCIVARCHAR2LIST(g_links(i).source_column), FALSE, 'link ' || g_links(i).link_id);
                END IF;
            END IF;
            i := g_links.NEXT(i);
        END LOOP;

        IF module_action(p_module) = c_delete THEN
            FOR f IN (SELECT c.owner AS c_owner, c.table_name AS c_table, c.constraint_name,
                             p.table_name AS p_table, pt.table_id AS p_id, ct.table_id AS c_id
                        FROM dba_constraints c
                        JOIN dba_constraints p
                          ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
                        JOIN epf_table pt
                          ON pt.owner = p.owner AND pt.table_name = p.table_name
                         AND pt.active = 'Y' AND pt.module_code = p_module
                        LEFT JOIN epf_table ct
                          ON ct.owner = c.owner AND ct.table_name = c.table_name AND ct.active = 'Y'
                       WHERE c.constraint_type = 'R'
                         AND c.status = 'ENABLED'
                       ORDER BY c.owner, c.table_name, c.constraint_name) LOOP
                CONTINUE WHEN NOT g_tables(f.p_id).reachable;
                CONTINUE WHEN f.c_id IS NOT NULL AND NOT g_tables(f.c_id).reachable;
                SELECT column_name BULK COLLECT INTO l_cols
                  FROM dba_cons_columns
                 WHERE owner = f.c_owner AND constraint_name = f.constraint_name
                 ORDER BY position;
                add_need(f.c_id, f.c_owner, f.c_table, l_cols, TRUE, 'FK ' || f.constraint_name || ' -> ' || f.p_table);
            END LOOP;
        END IF;
        RETURN l_out;
    END index_needs;

    PROCEDURE register_temp_index(p_name IN VARCHAR2, p_owner IN VARCHAR2, p_table IN VARCHAR2,
                                  p_columns IN VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_run NUMBER := g_run.run_id;
    BEGIN
        INSERT INTO epf_temp_index (run_id, owner, index_name, table_owner, table_name, column_name)
        VALUES (l_run, g_owner, p_name, p_owner, p_table, SUBSTR(p_columns, 1, 128));
        COMMIT;
    END register_temp_index;

    PROCEDURE close_temp_index(p_name IN VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE epf_temp_index
           SET dropped_at = CAST(SYSTIMESTAMP AS TIMESTAMP)
         WHERE owner = g_owner AND index_name = p_name;
        COMMIT;
    END close_temp_index;

    PROCEDURE create_temp_indexes(p_module IN VARCHAR2, p_created OUT NUMBER) IS
        l_needs  t_needs := index_needs(p_module);
        l_min    NUMBER := epf_util.setting_num('temp_index_min_mb') * 1048576;
        l_online VARCHAR2(10) := CASE WHEN epf_util.is_enterprise THEN ' ONLINE' END;
        l_seq    NUMBER;
        l_bytes  NUMBER;
        l_name   VARCHAR2(128);
        l_cols   VARCHAR2(4000);
        l_start  TIMESTAMP;
    BEGIN
        p_created := 0;
        FOR k IN 1 .. l_needs.COUNT LOOP
            CONTINUE WHEN index_covers(l_needs(k).owner, l_needs(k).table_name, l_needs(k).col_list);
            l_cols  := column_text(l_needs(k).col_list);
            l_bytes := table_bytes(l_needs(k).owner, l_needs(k).table_name);
            IF l_needs(k).table_id IS NULL THEN
                g_warnings := g_warnings + 1;
                epf_log.event(epf_log.c_warn, 'FK_UNINDEXED',
                              'No index on ' || l_cols || ' (' || l_needs(k).detail || ', table '
                              || epf_util.fmt_bytes(l_bytes) || '); the table is outside the registry and is '
                              || 'scanned for every deleted parent row',
                              p_object_owner => l_needs(k).owner, p_object_name => l_needs(k).table_name);
                CONTINUE;
            END IF;
            CONTINUE WHEN NOT l_needs(k).fk AND l_bytes < l_min;

            SELECT COUNT(*) + 1 INTO l_seq FROM epf_temp_index WHERE run_id = g_run.run_id;
            l_name := 'EPF_TMP_' || g_run.run_id || '_' || l_seq;
            register_temp_index(l_name, l_needs(k).owner, l_needs(k).table_name, l_cols);
            l_start := epf_util.now_ts;
            BEGIN
                EXECUTE IMMEDIATE 'CREATE INDEX ' || qc(l_name) || ' ON '
                                  || epf_util.qname(l_needs(k).owner, l_needs(k).table_name)
                                  || ' (' || column_text(l_needs(k).col_list, p_quoted => TRUE) || ')' || l_online;
                p_created := p_created + 1;
                epf_log.event(epf_log.c_info, 'TEMP_INDEX_CREATED',
                              l_name || ' on ' || l_cols || ' (' || l_needs(k).detail || ', table '
                              || epf_util.fmt_bytes(l_bytes) || ')',
                              p_object_owner => l_needs(k).owner, p_object_name => l_needs(k).table_name,
                              p_elapsed_s => epf_util.elapsed_s(l_start));
            EXCEPTION
                WHEN OTHERS THEN
                    close_temp_index(l_name);
                    g_warnings := g_warnings + 1;
                    epf_log.event(epf_log.c_warn, 'TEMP_INDEX_FAILED',
                                  'Index on ' || l_cols || ' not created; the purge continues without it: ' || SQLERRM,
                                  p_object_owner => l_needs(k).owner, p_object_name => l_needs(k).table_name,
                                  p_ora_code => ABS(SQLCODE));
            END;
        END LOOP;
    END create_temp_indexes;

    -- Drops the temporary indexes of this run, or of every run (indexes left
    -- by an interrupted run).
    PROCEDURE drop_temp_indexes(p_all_runs IN BOOLEAN, p_dropped OUT NUMBER) IS
        l_all   VARCHAR2(1) := CASE WHEN p_all_runs THEN 'Y' ELSE 'N' END;
        l_count NUMBER;
    BEGIN
        p_dropped := 0;
        FOR x IN (SELECT run_id, index_name, table_owner, table_name, column_name
                    FROM epf_temp_index
                   WHERE owner = g_owner
                     AND dropped_at IS NULL
                     AND (l_all = 'Y' OR run_id = g_run.run_id)
                   ORDER BY run_id, index_name) LOOP
            BEGIN
                SELECT COUNT(*) INTO l_count FROM user_indexes WHERE index_name = x.index_name;
                IF l_count > 0 THEN
                    EXECUTE IMMEDIATE 'DROP INDEX ' || qc(x.index_name);
                END IF;
                close_temp_index(x.index_name);
                p_dropped := p_dropped + 1;
                epf_log.event(CASE WHEN x.run_id = g_run.run_id THEN epf_log.c_info ELSE epf_log.c_warn END,
                              CASE WHEN x.run_id = g_run.run_id THEN 'TEMP_INDEX_DROPPED' ELSE 'TEMP_INDEX_LEFTOVER' END,
                              x.index_name || ' on ' || x.column_name || ' dropped'
                              || CASE WHEN x.run_id <> g_run.run_id
                                      THEN ' (left by ' || epf_util.run_label(x.run_id) || ')' END,
                              p_object_owner => x.table_owner, p_object_name => x.table_name);
            EXCEPTION
                WHEN OTHERS THEN
                    g_warnings := g_warnings + 1;
                    epf_log.event(epf_log.c_warn, 'TEMP_INDEX_KEPT',
                                  x.index_name || ' could not be dropped; it is dropped by the next purge: ' || SQLERRM,
                                  p_object_owner => x.table_owner, p_object_name => x.table_name,
                                  p_ora_code => ABS(SQLCODE));
            END;
        END LOOP;
    END drop_temp_indexes;

    -- ------------------------------------------------------------------
    -- Batches
    -- ------------------------------------------------------------------

    FUNCTION batch_statements(p_root_id IN NUMBER, p_action IN VARCHAR2) RETURN t_stmts IS
        l_out   t_stmts;
        l_ids   SYS.ODCINUMBERLIST := tree_tables(p_root_id);
        l_preds t_texts;
        l_lobs  t_lobs;
        l_tid   NUMBER;
        n       PLS_INTEGER := 0;
    BEGIN
        FOR k IN 1 .. l_ids.COUNT LOOP
            l_tid := l_ids(k);
            CONTINUE WHEN NOT g_tables(l_tid).reachable;
            l_preds := batch_preds(l_tid);
            IF p_action = c_delete THEN
                FOR i IN 1 .. l_preds.COUNT LOOP
                    n := n + 1;
                    l_out(n).table_id := l_tid;
                    l_out(n).sql_text := 'DELETE FROM ' || tq(l_tid) || ' t WHERE ' || l_preds(i);
                END LOOP;
            ELSIF g_tables(l_tid).lob_clear = 'Y' THEN
                l_lobs := lob_columns(l_tid);
                FOR c IN 1 .. l_lobs.COUNT LOOP
                    FOR i IN 1 .. l_preds.COUNT LOOP
                        n := n + 1;
                        l_out(n).table_id := l_tid;
                        l_out(n).sql_text := 'UPDATE ' || tq(l_tid) || ' t SET t.' || qc(l_lobs(c).column_name) || ' = '
                                             || CASE l_lobs(c).data_type WHEN 'BLOB' THEN 'EMPTY_BLOB()' ELSE 'EMPTY_CLOB()' END
                                             || ' WHERE ' || l_preds(i)
                                             || ' AND DBMS_LOB.GETLENGTH(t.' || qc(l_lobs(c).column_name) || ') > 0';
                    END LOOP;
                END LOOP;
            END IF;
        END LOOP;
        RETURN l_out;
    END batch_statements;

    -- Statistic of this session so far (V$MYSTAT), e.g. 'redo size' or
    -- 'undo change vector size'.
    FUNCTION session_stat(p_name IN VARCHAR2) RETURN NUMBER IS
        l_value NUMBER;
    BEGIN
        SELECT m.value
          INTO l_value
          FROM v$mystat m
          JOIN v$statname n ON n.statistic# = m.statistic#
         WHERE n.name = p_name;
        RETURN l_value;
    END session_stat;

    FUNCTION session_redo RETURN NUMBER IS
    BEGIN
        RETURN session_stat('redo size');
    END session_redo;

    FUNCTION session_undo RETURN NUMBER IS
    BEGIN
        RETURN session_stat('undo change vector size');
    END session_undo;

    PROCEDURE process_batches(p_module IN VARCHAR2, p_action IN VARCHAR2, p_roots IN SYS.ODCINUMBERLIST,
                              p_total IN NUMBER, p_processed IN OUT NOCOPY t_numbers, p_result OUT VARCHAR2,
                              p_redo OUT NUMBER, p_undo OUT NUMBER) IS
        l_stmts      t_stmts;
        l_batch      t_numbers;
        l_max        NUMBER;
        l_done       NUMBER := 0;
        l_rows       NUMBER := 0;
        l_batch_rows NUMBER;
        l_n          NUMBER;
        l_current    NUMBER;
        l_start      TIMESTAMP := epf_util.now_ts;
        l_last       TIMESTAMP;
        l_elapsed    NUMBER;
        l_pct        NUMBER;
        l_interval   NUMBER := epf_util.setting_num('progress_interval_s');
        l_pause      NUMBER := epf_util.setting_num('lob_throttle_ms') / 1000;
        l_unit       VARCHAR2(20) := CASE p_action WHEN c_delete THEN 'rows' ELSE 'LOB values' END;
        l_code       NUMBER;
        l_error      VARCHAR2(4000);
        l_run        NUMBER := g_run.run_id;
        l_redo_start NUMBER := session_redo;
        l_undo_start NUMBER := session_undo;
        l_tree_redo  NUMBER;
        l_tree_undo  NUMBER;
        l_tree_start TIMESTAMP;
        l_tree_roots NUMBER;
        k            PLS_INTEGER;

        -- Records the redo and undo of one root tree (TREE_REDO / TREE_UNDO:
        -- rows = roots processed, bytes = redo or undo, elapsed seconds);
        -- preflight uses them to recommend a batch size and to estimate undo
        -- growth.
        PROCEDURE tree_done(p_root_id IN NUMBER) IS
            l_redo    NUMBER := session_redo - l_tree_redo;
            l_undo    NUMBER := session_undo - l_tree_undo;
            l_elapsed NUMBER := epf_util.elapsed_s(l_tree_start);
        BEGIN
            IF l_tree_roots > 0 THEN
                epf_log.event(epf_log.c_info, 'TREE_REDO',
                              epf_util.fmt_bytes(l_redo) || ' redo for ' || epf_util.fmt_int(l_tree_roots)
                              || ' roots (' || epf_util.fmt_bytes(l_redo / l_tree_roots) || ' per root)',
                              p_object_owner => g_tables(p_root_id).owner,
                              p_object_name => g_tables(p_root_id).table_name,
                              p_rows => l_tree_roots, p_bytes => l_redo, p_elapsed_s => l_elapsed);
                epf_log.event(epf_log.c_info, 'TREE_UNDO',
                              epf_util.fmt_bytes(l_undo) || ' undo for ' || epf_util.fmt_int(l_tree_roots)
                              || ' roots (' || epf_util.fmt_bytes(l_undo / l_tree_roots) || ' per root, '
                              || epf_util.fmt_bytes(l_undo / GREATEST(l_elapsed, 1)) || '/s)',
                              p_object_owner => g_tables(p_root_id).owner,
                              p_object_name => g_tables(p_root_id).table_name,
                              p_rows => l_tree_roots, p_bytes => l_undo, p_elapsed_s => l_elapsed);
            END IF;
        END tree_done;
    BEGIN
        p_result := 'DONE';
        epf_log.step_start('PROCESS_BATCHES', p_module, p_units_total => p_total);
        <<trees>>
        FOR r IN 1 .. p_roots.COUNT LOOP
            l_stmts := batch_statements(p_roots(r), p_action);
            SELECT NVL(MAX(batch_no), 0) INTO l_max
              FROM epf_work_key
             WHERE run_id = l_run AND table_id = p_roots(r);
            l_tree_redo  := session_redo;
            l_tree_undo  := session_undo;
            l_tree_start := epf_util.now_ts;
            l_tree_roots := 0;
            FOR b IN 1 .. l_max LOOP
                IF epf_control.stop_requested(l_run) THEN
                    p_result := 'STOPPED';
                    epf_log.warn('STOP_HONORED', p_module || ' stopped after batch ' || epf_util.fmt_int(l_done)
                                                 || ' of ' || epf_util.fmt_int(p_total));
                    tree_done(p_roots(r));
                    EXIT trees;
                END IF;
                l_batch.DELETE;
                l_batch_rows := 0;
                l_current    := p_roots(r);
                BEGIN
                    FOR s IN 1 .. l_stmts.COUNT LOOP
                        l_current := l_stmts(s).table_id;
                        EXECUTE IMMEDIATE l_stmts(s).sql_text USING b;
                        l_n := SQL%ROWCOUNT;
                        l_batch(l_current) := CASE WHEN l_batch.EXISTS(l_current) THEN l_batch(l_current) ELSE 0 END + l_n;
                        l_batch_rows := l_batch_rows + l_n;
                    END LOOP;
                    COMMIT;
                EXCEPTION
                    WHEN OTHERS THEN
                        l_code  := SQLCODE;
                        l_error := SQLERRM;
                        ROLLBACK;
                        epf_log.event(epf_log.c_error, 'BATCH_FAILED',
                                      'Batch ' || b || ' of ' || l_max || ' of ' || tname(p_roots(r))
                                      || ' rolled back; failed on ' || tname(l_current) || ': ' || l_error,
                                      p_object_owner => g_tables(l_current).owner,
                                      p_object_name => g_tables(l_current).table_name,
                                      p_ora_code => ABS(l_code));
                        p_result := 'FAILED';
                        tree_done(p_roots(r));
                        EXIT trees;
                END;

                k := l_batch.FIRST;
                WHILE k IS NOT NULL LOOP
                    p_processed(k) := CASE WHEN p_processed.EXISTS(k) THEN p_processed(k) ELSE 0 END + l_batch(k);
                    k := l_batch.NEXT(k);
                END LOOP;
                l_tree_roots := l_tree_roots
                                + CASE WHEN l_batch.EXISTS(p_roots(r)) THEN l_batch(p_roots(r)) ELSE 0 END;
                l_done := l_done + 1;
                l_rows := l_rows + l_batch_rows;
                p_redo := session_redo - l_redo_start;
                p_undo := session_undo - l_undo_start;
                epf_log.step_progress(l_done, p_redo);

                IF l_done = 1 OR l_done = p_total OR l_last IS NULL OR epf_util.elapsed_s(l_last) >= l_interval THEN
                    l_elapsed := epf_util.elapsed_s(l_start);
                    l_pct := ROUND(100 * l_done / NULLIF(p_total, 0), 1);
                    epf_log.event(epf_log.c_progress, 'BATCH_PROGRESS',
                                  p_module || ' batch ' || epf_util.fmt_int(l_done) || '/' || epf_util.fmt_int(p_total)
                                  || ' ' || TO_CHAR(l_pct, 'FM990.0') || '% ' || l_unit || ' ' || epf_util.fmt_int(l_rows)
                                  || ' ' || epf_util.fmt_int(CASE WHEN l_elapsed > 0 THEN l_rows / l_elapsed END) || '/s'
                                  || ' redo ' || epf_util.fmt_bytes(p_redo / l_done) || '/batch'
                                  || ' undo ' || epf_util.fmt_bytes(p_undo / l_done) || '/batch'
                                  || ' ETA ' || epf_util.fmt_duration(l_elapsed / l_done * (p_total - l_done)),
                                  p_rows => l_rows, p_bytes => p_redo, p_pct => l_pct, p_elapsed_s => l_elapsed);
                    l_last := epf_util.now_ts;
                END IF;
                IF p_action = c_clear AND l_pause > 0 THEN
                    DBMS_LOCK.SLEEP(l_pause);
                END IF;
            END LOOP;
            tree_done(p_roots(r));
        END LOOP trees;

        p_redo := session_redo - l_redo_start;
        p_undo := session_undo - l_undo_start;
        epf_log.step_end(CASE p_result WHEN 'FAILED' THEN 'FAILED' ELSE 'DONE' END,
                         epf_util.fmt_int(l_done) || '/' || epf_util.fmt_int(p_total) || ' batches, '
                         || epf_util.fmt_int(l_rows) || ' ' || l_unit || ', ' || epf_util.fmt_bytes(p_redo) || ' redo, '
                         || epf_util.fmt_bytes(p_undo) || ' undo'
                         || CASE p_result WHEN 'STOPPED' THEN ', stopped on request' END);
    END process_batches;

    -- ------------------------------------------------------------------
    -- Modules
    -- ------------------------------------------------------------------

    PROCEDURE process_module(p_module IN VARCHAR2, p_result OUT VARCHAR2) IS
        l_action    VARCHAR2(10) := module_action(p_module);
        l_roots     SYS.ODCINUMBERLIST;
        l_active    SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST();
        l_processed t_numbers;
        l_batches   NUMBER;
        l_total     NUMBER := 0;
        l_created   NUMBER;
        l_dropped   NUMBER;
        l_failed    BOOLEAN := FALSE;
        l_batch_res VARCHAR2(10) := 'DONE';
        l_redo      NUMBER;
        l_undo      NUMBER;
        l_sum       NUMBER := 0;
        l_start     TIMESTAMP := epf_util.now_ts;
        k           PLS_INTEGER;
    BEGIN
        SELECT table_id BULK COLLECT INTO l_roots
          FROM epf_table
         WHERE active = 'Y' AND role = 'ROOT' AND module_code = p_module
         ORDER BY table_id;

        BEGIN
            epf_log.step_start('SNAPSHOT_KEYS', p_module);
            FOR r IN 1 .. l_roots.COUNT LOOP
                IF g_tables(l_roots(r)).reachable THEN
                    snapshot_tree(l_roots(r), l_action, l_batches);
                    l_total := l_total + l_batches;
                    l_active.EXTEND;
                    l_active(l_active.COUNT) := l_roots(r);
                ELSE
                    g_warnings := g_warnings + 1;
                    epf_log.warn('ROOT_MISSING', 'Root table not present; its tree is skipped',
                                 g_tables(l_roots(r)).owner, g_tables(l_roots(r)).table_name);
                END IF;
            END LOOP;
            epf_log.step_end('DONE', epf_util.fmt_int(l_total) || ' batches');
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                p_result := 'FAILED';
                RETURN;
        END;

        BEGIN
            epf_log.step_start('COUNT_BEFORE', p_module);
            count_tables(p_module, l_action, 'BEFORE', l_processed);
            count_orphans(p_module, 'BEFORE');
            epf_log.step_end('DONE');
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                p_result := 'FAILED';
                RETURN;
        END;

        IF g_run.dry_run = 'N' THEN
            BEGIN
                epf_log.step_start('TEMP_INDEXES', p_module);
                create_temp_indexes(p_module, l_created);
                epf_log.step_end('DONE', l_created || ' created');
            EXCEPTION
                WHEN OTHERS THEN
                    fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                    l_failed := TRUE;
            END;

            IF NOT l_failed THEN
                BEGIN
                    process_batches(p_module, l_action, l_active, l_total, l_processed, l_batch_res, l_redo, l_undo);
                    l_failed := l_batch_res = 'FAILED';
                EXCEPTION
                    WHEN OTHERS THEN
                        fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                        l_failed := TRUE;
                END;
            END IF;

            BEGIN
                epf_log.step_start('COUNT_AFTER', p_module);
                count_tables(p_module, l_action, 'AFTER', l_processed,
                             p_complete => NOT l_failed AND l_batch_res = 'DONE');
                count_orphans(p_module, 'AFTER');
                epf_log.step_end('DONE');
            EXCEPTION
                WHEN OTHERS THEN
                    fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                    l_failed := TRUE;
            END;

            BEGIN
                epf_log.step_start('DROP_TEMP_INDEXES', p_module);
                drop_temp_indexes(FALSE, l_dropped);
                epf_log.step_end('DONE', l_dropped || ' dropped');
            EXCEPTION
                WHEN OTHERS THEN
                    fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                    l_failed := TRUE;
            END;
        END IF;

        p_result := CASE WHEN l_failed THEN 'FAILED' WHEN l_batch_res = 'STOPPED' THEN 'STOPPED' ELSE 'DONE' END;
        k := l_processed.FIRST;
        WHILE k IS NOT NULL LOOP
            l_sum := l_sum + l_processed(k);
            k := l_processed.NEXT(k);
        END LOOP;
        epf_log.event(CASE p_result WHEN 'DONE' THEN epf_log.c_ok WHEN 'STOPPED' THEN epf_log.c_warn
                                    ELSE epf_log.c_error END,
                      'MODULE_END',
                      p_module || ' ' || p_result
                      || CASE WHEN g_run.dry_run = 'Y' THEN ' (dry run, nothing changed)'
                              ELSE ': ' || epf_util.fmt_int(l_sum) || ' '
                                   || CASE l_action WHEN c_delete THEN 'rows deleted' ELSE 'LOB values cleared' END
                                   || CASE WHEN l_redo IS NOT NULL THEN ', ' || epf_util.fmt_bytes(l_redo) || ' redo, '
                                                                        || epf_util.fmt_bytes(l_undo) || ' undo' END
                         END
                      || ' in ' || epf_util.fmt_duration(epf_util.elapsed_s(l_start)),
                      p_rows => l_sum, p_bytes => l_redo, p_elapsed_s => epf_util.elapsed_s(l_start));
    END process_module;

    FUNCTION capture_space(p_phase IN VARCHAR2, p_step IN VARCHAR2) RETURN BOOLEAN IS
        l_failed PLS_INTEGER;
    BEGIN
        epf_log.step_start(p_step);
        epf_space.capture(g_run.run_id, p_phase, l_failed);
        IF l_failed > 0 THEN
            g_warnings := g_warnings + 1;
        END IF;
        epf_log.step_end('DONE', CASE WHEN l_failed > 0 THEN l_failed || ' segments not measured' END);
        RETURN TRUE;
    EXCEPTION
        WHEN OTHERS THEN
            fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
            RETURN FALSE;
    END capture_space;

    -- Optional compaction (with_compact = Y, purge-only runs): shrinks the
    -- registry tables of the deleting modules whose table segment has at least
    -- compact_min_free_pct of free space after the purge (POST_PURGE, ASSM
    -- measurement), largest free space first. Per table: row movement enabled
    -- when disabled, SHRINK SPACE COMPACT (online), SHRINK SPACE CASCADE (short
    -- lock bounded by ddl_lock_timeout; table-only SHRINK SPACE when the
    -- cascade is refused, e.g. SECUREFILE LOBs), row movement restored. Tables
    -- shrink does not support are skipped with the reason; a failed shrink is
    -- a warning. Stop requests are honoured between tables.
    PROCEDURE compact_tables(p_compacted OUT NUMBER, p_skipped OUT NUMBER, p_stopped OUT BOOLEAN) IS
        l_min_pct  NUMBER := epf_util.setting_num('compact_min_free_pct');
        l_run      NUMBER := g_run.run_id;
        l_tid      NUMBER;
        l_owner    VARCHAR2(128);
        l_table    VARCHAR2(128);
        l_reason   VARCHAR2(400);
        l_movement VARCHAR2(8);
        l_count    NUMBER;
        l_before   NUMBER;
        l_after    NUMBER;
        l_start    TIMESTAMP;
        l_cascade  BOOLEAN;
        l_note     VARCHAR2(4000);
        l_code     NUMBER;
        l_error    VARCHAR2(4000);

        -- Bytes of the table, its indexes and its LOB segments.
        FUNCTION footprint RETURN NUMBER IS
            l_bytes NUMBER;
        BEGIN
            SELECT NVL(SUM(s.bytes), 0)
              INTO l_bytes
              FROM dba_segments s
             WHERE (s.owner, s.segment_name) IN (
                       SELECT l_owner, l_table FROM dual
                       UNION ALL
                       SELECT i.owner, i.index_name FROM dba_indexes i
                        WHERE i.table_owner = l_owner AND i.table_name = l_table
                       UNION ALL
                       SELECT l.owner, l.segment_name FROM dba_lobs l
                        WHERE l.owner = l_owner AND l.table_name = l_table);
            RETURN l_bytes;
        END footprint;
    BEGIN
        p_compacted := 0;
        p_skipped   := 0;
        p_stopped   := FALSE;
        FOR c IN (SELECT e.table_id, u.allocated_bytes, u.free_bytes
                    FROM epf_space_usage u
                    JOIN epf_table e
                      ON e.owner = u.owner AND e.table_name = u.segment_name AND e.active = 'Y'
                   WHERE u.run_id = l_run
                     AND u.phase = epf_space.c_post_purge
                     AND u.segment_type = 'TABLE'
                     AND u.method = 'ASSM'
                     AND u.allocated_bytes > 0
                     AND u.free_bytes >= u.allocated_bytes * l_min_pct / 100
                   ORDER BY u.free_bytes DESC) LOOP
            l_tid := c.table_id;
            CONTINUE WHEN NOT in_scope(g_tables(l_tid).module_code)
                          OR NOT g_tables(l_tid).reachable
                          OR module_action(g_tables(l_tid).module_code) <> c_delete;
            IF epf_control.stop_requested(l_run) THEN
                p_stopped := TRUE;
                epf_log.warn('STOP_HONORED', 'Compaction stopped before ' || tname(l_tid));
                EXIT;
            END IF;
            l_owner := g_tables(l_tid).owner;
            l_table := g_tables(l_tid).table_name;

            SELECT MAX(CASE WHEN t.iot_type IS NOT NULL THEN 'index-organized table'
                            WHEN t.cluster_name IS NOT NULL THEN 'clustered table'
                            WHEN t.compression = 'ENABLED' THEN 'compressed table' END),
                   MAX(t.row_movement)
              INTO l_reason, l_movement
              FROM dba_tables t
             WHERE t.owner = l_owner AND t.table_name = l_table;
            IF l_reason IS NULL THEN
                SELECT COUNT(*) INTO l_count
                  FROM dba_indexes
                 WHERE table_owner = l_owner AND table_name = l_table
                   AND (index_type LIKE 'FUNCTION-BASED%' OR index_type = 'DOMAIN' OR join_index = 'YES');
                IF l_count > 0 THEN
                    l_reason := 'function-based, domain or join index';
                END IF;
            END IF;
            IF l_reason IS NULL THEN
                SELECT COUNT(*) INTO l_count
                  FROM dba_tab_columns
                 WHERE owner = l_owner AND table_name = l_table AND data_type IN ('LONG', 'LONG RAW');
                IF l_count > 0 THEN
                    l_reason := 'LONG column';
                END IF;
            END IF;
            IF l_reason IS NOT NULL THEN
                p_skipped := p_skipped + 1;
                epf_log.event(epf_log.c_info, 'COMPACT_SKIPPED', 'Not compacted: ' || l_reason,
                              p_object_owner => l_owner, p_object_name => l_table);
                CONTINUE;
            END IF;

            l_before := footprint;
            l_start  := epf_util.now_ts;
            BEGIN
                IF l_movement = 'DISABLED' THEN
                    EXECUTE IMMEDIATE 'ALTER TABLE ' || tq(l_tid) || ' ENABLE ROW MOVEMENT';
                END IF;
                EXECUTE IMMEDIATE 'ALTER TABLE ' || tq(l_tid) || ' SHRINK SPACE COMPACT';
                l_cascade := TRUE;
                l_note    := NULL;
                BEGIN
                    EXECUTE IMMEDIATE 'ALTER TABLE ' || tq(l_tid) || ' SHRINK SPACE CASCADE';
                EXCEPTION
                    WHEN OTHERS THEN
                        -- The cascade is refused for some LOB or index types;
                        -- the table itself is still shrunk.
                        l_cascade := FALSE;
                        l_note    := SQLERRM;
                        EXECUTE IMMEDIATE 'ALTER TABLE ' || tq(l_tid) || ' SHRINK SPACE';
                END;
                IF l_movement = 'DISABLED' THEN
                    EXECUTE IMMEDIATE 'ALTER TABLE ' || tq(l_tid) || ' DISABLE ROW MOVEMENT';
                END IF;
                l_after := footprint;
                p_compacted := p_compacted + 1;
                epf_log.event(epf_log.c_ok, 'COMPACTED',
                              epf_util.fmt_bytes(l_before) || ' -> ' || epf_util.fmt_bytes(l_after)
                              || ' (table, indexes and LOB segments)'
                              || CASE WHEN NOT l_cascade THEN '; indexes and LOB segments not shrunk: ' || l_note END,
                              p_object_owner => l_owner, p_object_name => l_table,
                              p_bytes => l_before - l_after, p_elapsed_s => epf_util.elapsed_s(l_start));
            EXCEPTION
                WHEN OTHERS THEN
                    l_code  := SQLCODE;
                    l_error := SQLERRM;
                    IF l_movement = 'DISABLED' THEN
                        BEGIN
                            EXECUTE IMMEDIATE 'ALTER TABLE ' || tq(l_tid) || ' DISABLE ROW MOVEMENT';
                        EXCEPTION
                            WHEN OTHERS THEN
                                epf_log.event(epf_log.c_warn, 'ROW_MOVEMENT_KEPT',
                                              'Row movement could not be disabled again: ' || SQLERRM,
                                              p_object_owner => l_owner, p_object_name => l_table,
                                              p_ora_code => ABS(SQLCODE));
                        END;
                    END IF;
                    p_skipped  := p_skipped + 1;
                    g_warnings := g_warnings + 1;
                    epf_log.event(epf_log.c_warn, 'COMPACT_FAILED', 'Not compacted: ' || l_error,
                                  p_object_owner => l_owner, p_object_name => l_table, p_ora_code => ABS(l_code));
            END;
        END LOOP;
    END compact_tables;

    PROCEDURE plan_steps IS
    BEGIN
        epf_log.step_plan('REGISTRY');
        epf_log.step_plan('PREPARE');
        epf_log.step_plan('SPACE_BASELINE');
        FOR i IN 1 .. g_modules.COUNT LOOP
            epf_log.step_plan('SNAPSHOT_KEYS', g_modules(i));
            epf_log.step_plan('COUNT_BEFORE', g_modules(i));
            IF g_run.dry_run = 'N' THEN
                epf_log.step_plan('TEMP_INDEXES', g_modules(i));
                epf_log.step_plan('PROCESS_BATCHES', g_modules(i));
                epf_log.step_plan('COUNT_AFTER', g_modules(i));
                epf_log.step_plan('DROP_TEMP_INDEXES', g_modules(i));
            END IF;
        END LOOP;
        IF g_run.dry_run = 'N' THEN
            epf_log.step_plan('SPACE_POST_PURGE');
        ELSE
            epf_log.step_plan('FORECAST');
        END IF;
        IF g_run.with_compact = 'Y' THEN
            epf_log.step_plan('COMPACT');
            epf_log.step_plan('SPACE_POST_COMPACT');
        END IF;
        epf_log.step_plan('CLEANUP');
    END plan_steps;

    -- ------------------------------------------------------------------
    -- Preflight checks
    -- ------------------------------------------------------------------

    PROCEDURE check_indexes IS
        l_needs   t_needs;
        l_min     NUMBER := epf_util.setting_num('temp_index_min_mb') * 1048576;
        l_needed  NUMBER := 0;
        l_indexed NUMBER := 0;
        l_temp    NUMBER := 0;
        l_small   NUMBER := 0;
        l_outside NUMBER := 0;
        l_bytes   NUMBER;
        l_note    VARCHAR2(400);
    BEGIN
        FOR m IN 1 .. g_modules.COUNT LOOP
            l_needs := index_needs(g_modules(m));
            FOR k IN 1 .. l_needs.COUNT LOOP
                l_needed := l_needed + 1;
                IF index_covers(l_needs(k).owner, l_needs(k).table_name, l_needs(k).col_list) THEN
                    l_indexed := l_indexed + 1;
                ELSE
                    l_bytes := table_bytes(l_needs(k).owner, l_needs(k).table_name);
                    IF l_needs(k).table_id IS NULL THEN
                        l_outside := l_outside + 1;
                        g_warnings := g_warnings + 1;
                        l_note := 'outside the registry, not indexed by the tool: scanned for every deleted parent '
                                  || 'row; create this index before purging';
                    ELSIF l_needs(k).fk THEN
                        l_temp := l_temp + 1;
                        l_note := 'without it every deleted parent row scans this table; a temporary index is created';
                    ELSIF l_bytes >= l_min THEN
                        l_temp := l_temp + 1;
                        l_note := 'a temporary index is created for the purge';
                    ELSE
                        l_small := l_small + 1;
                        l_note := 'below temp_index_min_mb, the table is scanned once per batch';
                    END IF;
                    epf_log.event(CASE WHEN l_needs(k).table_id IS NULL THEN epf_log.c_warn ELSE epf_log.c_info END,
                                  'IDX_MISSING',
                                  'No index on ' || column_text(l_needs(k).col_list) || ' (' || l_needs(k).detail
                                  || ', table ' || epf_util.fmt_bytes(l_bytes) || '): ' || l_note,
                                  p_object_owner => l_needs(k).owner, p_object_name => l_needs(k).table_name,
                                  p_bytes => l_bytes);
                END IF;
            END LOOP;
        END LOOP;
        epf_log.event(CASE WHEN l_outside > 0 THEN epf_log.c_warn ELSE epf_log.c_ok END, 'IDX_SUMMARY',
                      l_indexed || '/' || l_needed || ' link and FK columns indexed; ' || l_temp
                      || ' temporary indexes would be created, ' || l_small || ' small tables scanned per batch'
                      || CASE WHEN l_outside > 0 THEN ', ' || l_outside || ' unindexed FK columns outside the registry' END);
    END check_indexes;

    -- Approximate redo of deleting one row: the row goes to undo and its
    -- deletion to redo (about twice the row length plus fixed overhead), and
    -- every index entry of the row is removed the same way.
    FUNCTION row_redo_estimate(p_table_id IN NUMBER) RETURN NUMBER IS
        l_owner VARCHAR2(128) := g_tables(p_table_id).owner;
        l_table VARCHAR2(128) := g_tables(p_table_id).table_name;
        l_row   NUMBER;
        l_total NUMBER;
    BEGIN
        SELECT MAX(avg_row_len) INTO l_row FROM dba_tables WHERE owner = l_owner AND table_name = l_table;
        l_total := 2 * NVL(l_row, 100) + 300;
        FOR x IN (SELECT (SELECT NVL(SUM(tc.avg_col_len), 0)
                            FROM dba_ind_columns ic
                            JOIN dba_tab_columns tc
                              ON tc.owner = ic.table_owner AND tc.table_name = ic.table_name
                             AND tc.column_name = ic.column_name
                           WHERE ic.index_owner = i.owner AND ic.index_name = i.index_name) AS key_len
                    FROM dba_indexes i
                   WHERE i.table_owner = l_owner AND i.table_name = l_table AND i.index_type <> 'LOB') LOOP
            l_total := l_total + 2 * (x.key_len + 10) + 250;
        END LOOP;
        RETURN l_total;
    END row_redo_estimate;

    -- Redo per root of a tree: measured by the latest purge of the tree on
    -- this database that did the same (deleting or clearing LOB values:
    -- TREE_REDO events), otherwise estimated from optimizer statistics (rows
    -- per root of each table x row_redo_estimate).
    PROCEDURE tree_redo(p_root_id IN NUMBER, p_per_root OUT NUMBER, p_source OUT VARCHAR2) IS
        l_owner     VARCHAR2(128) := g_tables(p_root_id).owner;
        l_table     VARCHAR2(128) := g_tables(p_root_id).table_name;
        l_module    VARCHAR2(30)  := g_tables(p_root_id).module_code;
        l_action    VARCHAR2(10)  := module_action(g_tables(p_root_id).module_code);
        l_ids       SYS.ODCINUMBERLIST := tree_tables(p_root_id);
        l_run       NUMBER;
        l_root_rows NUMBER;
        l_rows      NUMBER;
        l_t_owner   VARCHAR2(128);
        l_t_table   VARCHAR2(128);
    BEGIN
        SELECT MAX(ev.bytes / ev.rows_affected) KEEP (DENSE_RANK LAST ORDER BY ev.event_id),
               MAX(ev.run_id) KEEP (DENSE_RANK LAST ORDER BY ev.event_id)
          INTO p_per_root, l_run
          FROM epf_event ev
          JOIN epf_run rn ON rn.run_id = ev.run_id
         WHERE ev.event_code = 'TREE_REDO'
           AND ev.object_owner = l_owner AND ev.object_name = l_table
           AND ev.rows_affected > 0 AND ev.bytes > 0
           AND CASE WHEN rn.purge_mode IN ('FULL', 'LOGS')
                         OR (rn.purge_mode = 'CLOB_N_LOGS' AND l_module = c_logs_module)
                    THEN c_delete ELSE c_clear END = l_action;
        IF p_per_root IS NOT NULL THEN
            p_source := 'measured by ' || epf_util.run_label(l_run);
            RETURN;
        END IF;

        SELECT MAX(num_rows) INTO l_root_rows FROM dba_tables WHERE owner = l_owner AND table_name = l_table;
        IF NVL(l_root_rows, 0) = 0 THEN
            p_source := 'no optimizer statistics on the root table';
            RETURN;
        END IF;
        p_per_root := 0;
        FOR k IN 1 .. l_ids.COUNT LOOP
            CONTINUE WHEN NOT g_tables(l_ids(k)).reachable;
            l_t_owner := g_tables(l_ids(k)).owner;
            l_t_table := g_tables(l_ids(k)).table_name;
            SELECT MAX(num_rows) INTO l_rows FROM dba_tables WHERE owner = l_t_owner AND table_name = l_t_table;
            p_per_root := p_per_root + NVL(l_rows, 0) / l_root_rows * row_redo_estimate(l_ids(k));
        END LOOP;
        p_source := 'estimated from optimizer statistics';
    END tree_redo;

    -- Batch size rounded down to two significant digits, between 100 and 100000.
    FUNCTION round_batch(p_value IN NUMBER) RETURN NUMBER IS
        l_scale NUMBER;
    BEGIN
        IF p_value IS NULL OR p_value <= 100 THEN
            RETURN 100;
        ELSIF p_value >= 100000 THEN
            RETURN 100000;
        END IF;
        l_scale := POWER(10, FLOOR(LOG(10, p_value)) - 1);
        RETURN TRUNC(p_value / l_scale) * l_scale;
    END round_batch;

    -- Eligible roots of a root table counted by check_roots; NULL when not counted.
    FUNCTION eligible_roots(p_root_id IN NUMBER) RETURN NUMBER IS
    BEGIN
        IF g_eligible.EXISTS(p_root_id) THEN
            RETURN g_eligible(p_root_id);
        END IF;
        RETURN NULL;
    END eligible_roots;

    -- Root rows in one batch: the batch size, or fewer when fewer roots are eligible.
    FUNCTION batch_roots(p_root_id IN NUMBER) RETURN NUMBER IS
    BEGIN
        RETURN LEAST(g_run.batch_size, NVL(eligible_roots(p_root_id), g_run.batch_size));
    END batch_roots;

    -- Redo and undo per root of a tree, kept with the preflight run
    -- (EPF_TREE_EST) for the requirements and the forecasts.
    PROCEDURE save_tree_redo(p_root_id IN NUMBER, p_per_root IN NUMBER, p_basis IN VARCHAR2) IS
        l_run NUMBER := g_run.run_id;
    BEGIN
        UPDATE epf_tree_est
           SET redo_root = p_per_root, redo_basis = SUBSTR(p_basis, 1, 400)
         WHERE run_id = l_run AND table_id = p_root_id;
        COMMIT;
    END save_tree_redo;

    PROCEDURE save_tree_undo(p_root_id IN NUMBER, p_per_root IN NUMBER, p_basis IN VARCHAR2, p_rate IN NUMBER) IS
        l_run NUMBER := g_run.run_id;
    BEGIN
        UPDATE epf_tree_est
           SET undo_root = p_per_root, undo_basis = SUBSTR(p_basis, 1, 400), undo_rate = p_rate
         WHERE run_id = l_run AND table_id = p_root_id;
        COMMIT;
    END save_tree_undo;

    -- Events of the redo and undo checks. None while the requirements are
    -- checked again with the operator's choices (recheck): the first check
    -- already reported them.
    PROCEDURE note(p_severity IN VARCHAR2, p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                   p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL,
                   p_rows IN NUMBER DEFAULT NULL, p_bytes IN NUMBER DEFAULT NULL) IS
    BEGIN
        IF NOT g_silent THEN
            epf_log.event(p_severity, p_event_code, p_message, p_object_owner => p_object_owner,
                          p_object_name => p_object_name, p_rows => p_rows, p_bytes => p_bytes);
        END IF;
    END note;

    -- Online redo logs against the redo a batch writes. The recommended batch
    -- size keeps one batch within half of the smallest online log, so a batch
    -- causes at most one log switch. A batch larger than a whole log is a
    -- warning: the session then waits on 'log file switch (checkpoint
    -- incomplete)'; larger online logs remove those waits, a smaller batch
    -- only spreads them. Trees without eligible roots are not estimated.
    PROCEDURE check_redo IS
        l_groups     NUMBER;
        l_min_log    NUMBER;
        l_log_mode   VARCHAR2(12);
        l_switches   NUMBER;
        l_peak       NUMBER;
        l_per_root   NUMBER;
        l_source     VARCHAR2(200);
        l_batch_redo NUMBER;
        l_recommend  NUMBER;
        l_overall    NUMBER;
        l_over       BOOLEAN := FALSE;
    BEGIN
        SELECT COUNT(*), MIN(bytes) INTO l_groups, l_min_log FROM v$log;
        SELECT log_mode INTO l_log_mode FROM v$database;
        g_min_log  := l_min_log;
        g_log_mode := l_log_mode;
        SELECT NVL(SUM(cnt), 0), NVL(MAX(cnt), 0)
          INTO l_switches, l_peak
          FROM (SELECT COUNT(*) AS cnt
                  FROM v$log_history
                 WHERE first_time > SYSDATE - 1
                 GROUP BY TRUNC(first_time, 'HH24'));
        note(epf_log.c_info, 'REDO_LOGS',
             l_groups || ' online redo log groups, smallest ' || epf_util.fmt_bytes(l_min_log)
             || ' (' || l_log_mode || '); ' || l_switches || ' log switches in the last 24 hours, at most '
             || l_peak || ' in one hour',
             p_bytes => l_min_log);

        FOR r IN (SELECT e.table_id
                    FROM epf_table e
                    JOIN epf_module m ON m.module_code = e.module_code
                   WHERE e.active = 'Y' AND e.role = 'ROOT'
                   ORDER BY m.display_order, e.table_id) LOOP
            CONTINUE WHEN NOT in_scope(g_tables(r.table_id).module_code)
                          OR NOT g_tables(r.table_id).reachable;
            IF eligible_roots(r.table_id) = 0 THEN
                IF module_action(g_tables(r.table_id).module_code) = c_delete THEN
                    note(epf_log.c_info, 'REDO_ESTIMATE', 'No rows before the cutoff: no redo',
                         p_object_owner => g_tables(r.table_id).owner,
                         p_object_name => g_tables(r.table_id).table_name);
                END IF;
                CONTINUE;
            END IF;
            tree_redo(r.table_id, l_per_root, l_source);
            IF module_action(g_tables(r.table_id).module_code) <> c_delete THEN
                -- LOB clearing: only a measurement by an earlier clearing purge
                -- of the tree is used (no estimate from statistics).
                IF l_source NOT LIKE 'measured%' THEN
                    l_per_root := NULL;
                    l_source   := 'no LOB clearing measured on this database yet';
                END IF;
                save_tree_redo(r.table_id, l_per_root, l_source);
                CONTINUE;
            END IF;
            save_tree_redo(r.table_id, l_per_root, l_source);
            IF l_per_root IS NULL THEN
                note(epf_log.c_info, 'REDO_ESTIMATE', 'No redo estimate: ' || l_source,
                     p_object_owner => g_tables(r.table_id).owner,
                     p_object_name => g_tables(r.table_id).table_name);
                CONTINUE;
            END IF;
            l_batch_redo := l_per_root * batch_roots(r.table_id);
            l_recommend  := round_batch(0.5 * l_min_log / l_per_root);
            l_overall    := LEAST(NVL(l_overall, l_recommend), l_recommend);
            IF l_batch_redo > l_min_log THEN
                l_over := TRUE;
            END IF;
            note(CASE WHEN l_batch_redo > l_min_log THEN epf_log.c_warn ELSE epf_log.c_info END,
                 'REDO_ESTIMATE',
                 'about ' || epf_util.fmt_bytes(l_per_root) || ' redo per root (' || l_source || '): '
                 || epf_util.fmt_bytes(l_batch_redo) || ' per batch of '
                 || epf_util.fmt_int(batch_roots(r.table_id))
                 || ' = ' || TO_CHAR(ROUND(l_batch_redo / l_min_log, 1), 'FM999990.0')
                 || ' online logs; recommended batch size ' || epf_util.fmt_int(l_recommend),
                 p_object_owner => g_tables(r.table_id).owner,
                 p_object_name => g_tables(r.table_id).table_name,
                 p_rows => l_recommend, p_bytes => l_per_root);
        END LOOP;

        IF l_overall IS NOT NULL THEN
            IF l_over THEN
                g_warnings := g_warnings + 1;
            END IF;
            note(CASE WHEN l_over THEN epf_log.c_warn ELSE epf_log.c_ok END, 'REDO_SUMMARY',
                 'Recommended batch size: ' || epf_util.fmt_int(l_overall)
                 || ' (one batch within half of a ' || epf_util.fmt_bytes(l_min_log) || ' online log)'
                 || CASE WHEN l_over THEN
                        '. With batch ' || epf_util.fmt_int(g_run.batch_size)
                        || ' a batch fills more than one online log: expect ''log file switch (checkpoint '
                        || 'incomplete)'' waits. Larger online redo logs remove them (run/redo_logs.sql as '
                        || 'SYS); a smaller batch only spreads the switches.'
                    END,
                 p_rows => l_overall);
        END IF;
    END check_redo;

    -- Active undo tuning recorded by epf_tuning (NULL when none).
    FUNCTION undo_tuning_text RETURN VARCHAR2 IS
        l_text VARCHAR2(4000);
    BEGIN
        FOR c IN (SELECT item, target, original_value, original_maxbytes, applied_value
                    FROM epf_instance_change
                   WHERE restored_at IS NULL AND item LIKE 'UNDO%'
                   ORDER BY change_id) LOOP
            l_text := l_text || CASE WHEN l_text IS NOT NULL THEN '; ' END
                      || CASE c.item
                             WHEN 'UNDO_RETENTION'
                             THEN 'undo_retention ' || c.original_value || ' s -> ' || c.applied_value || ' s'
                             ELSE c.target || ' growth limit ' || epf_util.fmt_bytes(c.original_maxbytes) || ' -> '
                                  || epf_util.fmt_bytes(c.applied_value)
                         END;
        END LOOP;
        RETURN l_text;
    END undo_tuning_text;

    -- Undo tablespace against the undo of a batch and of the purge. Undo per
    -- root comes from the latest measurement of the tree (TREE_UNDO), else it
    -- is estimated as 45% of the redo estimate. With a measured rate, the undo
    -- kept for undo_retention is estimated as rate x undo_retention, at most
    -- the undo of all eligible roots; without one (first purge of the tree on
    -- this database) it can be up to the undo of all eligible roots. When that
    -- exceeds the current size, the undo tablespace grows during the purge
    -- unless undo tuning is applied or planned for the run (with_undo_tuning):
    -- undo tuning limits the growth to epf_tuning.undo_cap (UNDO_CAP event).
    -- A batch needing more than half of what the tablespace can hold is a
    -- warning. Trees without eligible roots are not estimated.
    PROCEDURE check_undo IS
        l_ts        VARCHAR2(128);
        l_retention NUMBER;
        l_tuned     NUMBER;
        l_size      NUMBER;
        l_max       NUMBER;
        l_guarantee VARCHAR2(11);
        l_tuning    VARCHAR2(4000) := undo_tuning_text;
        l_owner     VARCHAR2(128);
        l_table     VARCHAR2(128);
        l_module    VARCHAR2(30);
        l_action    VARCHAR2(10);
        l_per_root  NUMBER;
        l_rate      NUMBER;
        l_run       NUMBER;
        l_redo      NUMBER;
        l_source    VARCHAR2(400);
        l_batch     NUMBER;
        l_eligible  NUMBER;
        l_total     NUMBER;
        l_kept      NUMBER;
        l_warn      BOOLEAN;
        l_limited   BOOLEAN := l_tuning IS NOT NULL OR g_run.with_undo_tuning = 'Y';
        l_largest   NUMBER := 0;
        l_cap       NUMBER;
    BEGIN
        SELECT UPPER(value) INTO l_ts FROM v$parameter WHERE name = 'undo_tablespace';
        SELECT TO_NUMBER(value) INTO l_retention FROM v$parameter WHERE name = 'undo_retention';
        SELECT MAX(tuned_undoretention) INTO l_tuned FROM v$undostat WHERE begin_time > SYSDATE - 1;
        SELECT SUM(bytes), SUM(CASE WHEN autoextensible = 'YES' THEN GREATEST(maxbytes, bytes) ELSE bytes END)
          INTO l_size, l_max
          FROM dba_data_files
         WHERE tablespace_name = l_ts;
        SELECT MAX(retention) INTO l_guarantee FROM dba_tablespaces WHERE tablespace_name = l_ts;
        g_undo_ts    := l_ts;
        g_undo_size  := l_size;
        g_undo_max   := l_max;
        g_undo_limit := l_limited;
        note(epf_log.c_info, 'UNDO',
             l_ts || ' ' || epf_util.fmt_bytes(l_size) || ', can grow to ' || epf_util.fmt_bytes(l_max)
             || '; undo_retention ' || l_retention || ' s (tuned up to ' || NVL(TO_CHAR(l_tuned), '-')
             || ' s in the last 24 hours), retention ' || LOWER(l_guarantee)
             || CASE WHEN l_tuning IS NOT NULL THEN '; undo tuning active: ' || l_tuning
                     WHEN g_run.with_undo_tuning = 'Y' THEN '; undo tuning planned for this purge'
                     ELSE '; undo tuning not applied' END,
             p_bytes => l_size);

        FOR r IN (SELECT e.table_id
                    FROM epf_table e
                    JOIN epf_module m ON m.module_code = e.module_code
                   WHERE e.active = 'Y' AND e.role = 'ROOT'
                   ORDER BY m.display_order, e.table_id) LOOP
            CONTINUE WHEN NOT in_scope(g_tables(r.table_id).module_code)
                          OR NOT g_tables(r.table_id).reachable
                          OR module_action(g_tables(r.table_id).module_code) <> c_delete;
            l_owner := g_tables(r.table_id).owner;
            l_table := g_tables(r.table_id).table_name;
            l_eligible := eligible_roots(r.table_id);
            IF l_eligible = 0 THEN
                note(epf_log.c_info, 'UNDO_ESTIMATE', 'No rows before the cutoff: no undo',
                     p_object_owner => l_owner, p_object_name => l_table);
                CONTINUE;
            END IF;
            -- Measured only by purges that did the same (deleting or clearing).
            l_module := g_tables(r.table_id).module_code;
            l_action := module_action(l_module);
            SELECT MAX(ev.bytes / ev.rows_affected) KEEP (DENSE_RANK LAST ORDER BY ev.event_id),
                   MAX(ev.bytes / GREATEST(ev.elapsed_s, 1)) KEEP (DENSE_RANK LAST ORDER BY ev.event_id),
                   MAX(ev.run_id) KEEP (DENSE_RANK LAST ORDER BY ev.event_id)
              INTO l_per_root, l_rate, l_run
              FROM epf_event ev
              JOIN epf_run rn ON rn.run_id = ev.run_id
             WHERE ev.event_code = 'TREE_UNDO'
               AND ev.object_owner = l_owner AND ev.object_name = l_table
               AND ev.rows_affected > 0 AND ev.bytes > 0
               AND CASE WHEN rn.purge_mode IN ('FULL', 'LOGS')
                             OR (rn.purge_mode = 'CLOB_N_LOGS' AND l_module = c_logs_module)
                        THEN c_delete ELSE c_clear END = l_action;
            IF l_per_root IS NOT NULL THEN
                l_source := 'measured by ' || epf_util.run_label(l_run);
            ELSE
                tree_redo(r.table_id, l_redo, l_source);
                CONTINUE WHEN l_redo IS NULL;
                l_per_root := 0.45 * l_redo;
                l_source   := 'estimated from the redo, ' || l_source;
                l_rate     := NULL;
            END IF;
            l_batch := l_per_root * batch_roots(r.table_id);
            l_largest := GREATEST(l_largest, l_batch);
            l_total := l_per_root * l_eligible;
            IF l_rate IS NOT NULL THEN
                -- Retention cannot keep more undo than the purge writes.
                l_kept := LEAST(l_rate * l_retention, NVL(l_total, l_rate * l_retention));
            ELSE
                -- No measured rate (first purge of the tree on this database):
                -- retention can keep up to all the undo the purge writes.
                l_kept := l_total;
            END IF;
            save_tree_undo(r.table_id, l_per_root, l_source, l_rate);
            g_undo_kept := GREATEST(g_undo_kept, NVL(l_kept, 0));
            l_warn  := l_batch > 0.5 * l_max OR (NOT l_limited AND l_kept > l_size);
            IF l_warn THEN
                g_warnings := g_warnings + 1;
            END IF;
            note(CASE WHEN l_warn THEN epf_log.c_warn ELSE epf_log.c_info END, 'UNDO_ESTIMATE',
                 'about ' || epf_util.fmt_bytes(l_per_root) || ' undo per root (' || l_source || '): '
                 || epf_util.fmt_bytes(l_batch) || ' per batch of ' || epf_util.fmt_int(batch_roots(r.table_id))
                 || CASE WHEN l_total IS NOT NULL THEN
                        ', ' || epf_util.fmt_bytes(l_total) || ' for the ' || epf_util.fmt_int(l_eligible)
                        || ' eligible roots'
                    END
                 || CASE WHEN l_rate IS NOT NULL AND l_kept IS NOT NULL THEN
                        '; at ' || epf_util.fmt_bytes(l_rate) || '/s, undo_retention ' || l_retention
                        || ' s keeps about ' || epf_util.fmt_bytes(l_kept)
                        WHEN l_kept IS NOT NULL THEN
                        '; no measured rate yet: undo_retention ' || l_retention || ' s can keep up to '
                        || epf_util.fmt_bytes(l_kept)
                    END
                 || CASE WHEN l_batch > 0.5 * l_max THEN
                        '; a batch needs more than half of what ' || l_ts || ' can hold: lower the batch size'
                    END
                 || CASE WHEN NOT l_limited AND l_kept > l_size THEN
                        '; ' || l_ts || CASE WHEN l_rate IS NULL THEN ' may grow' ELSE ' grows' END
                        || ' during the purge (up to ' || epf_util.fmt_bytes(l_max)
                        || ') unless undo tuning is applied (undo.sql APPLY as SYS)'
                    END,
                 p_object_owner => l_owner, p_object_name => l_table, p_bytes => l_per_root);
        END LOOP;

        IF l_tuning IS NULL AND g_run.with_undo_tuning = 'Y' AND l_largest > 0 THEN
            l_cap := epf_tuning.undo_cap(l_largest);
            note(epf_log.c_info, 'UNDO_CAP',
                 'Undo tuning for this purge limits ' || l_ts || ' to about ' || epf_util.fmt_bytes(l_cap)
                 || ' (the largest of its size, undo_cap_mb and 4 x the undo of one batch, '
                 || epf_util.fmt_bytes(l_largest) || '); committed undo is reused instead of growing it',
                 p_bytes => l_cap);
        END IF;
        g_undo_batch := l_largest;
        g_undo_cap   := l_cap;
        IF g_undo_cap IS NULL AND l_limited AND l_largest > 0 THEN
            g_undo_cap := epf_tuning.undo_cap(l_largest);
        END IF;
    END check_undo;

    -- p_run when its root counts can stand for this run's: a PREFLIGHT run
    -- ended SUCCESS or WARNING, with the same cutoff, mode and depth, created
    -- within preflight_valid_h, and no purge has processed batches since.
    -- Otherwise NULL, with the reason (ROOTS_RECOUNTED).
    FUNCTION reusable_run(p_run IN NUMBER) RETURN NUMBER IS
        l_cutoff DATE := g_run.cutoff_date;
        l_mode   VARCHAR2(30) := g_run.purge_mode;
        l_depth  VARCHAR2(4000) := g_run.depth;
        l_hours  NUMBER := epf_util.setting_num('preflight_valid_h');
        l_prev   epf_run%ROWTYPE;
        l_reason VARCHAR2(400);
        l_purged NUMBER;
    BEGIN
        IF p_run IS NULL THEN
            RETURN NULL;
        END IF;
        BEGIN
            SELECT * INTO l_prev FROM epf_run WHERE run_id = p_run;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                l_reason := 'not found';
        END;
        IF l_reason IS NULL THEN
            l_reason := CASE WHEN l_prev.action <> 'PREFLIGHT' THEN 'not a preflight run'
                             WHEN NVL(l_prev.status, '-') NOT IN ('SUCCESS', 'WARNING')
                             THEN 'ended ' || NVL(l_prev.status, 'without a status')
                             WHEN l_prev.cutoff_date <> l_cutoff
                             THEN 'cutoff ' || TO_CHAR(l_prev.cutoff_date, 'YYYY-MM-DD') || ', this run '
                                  || TO_CHAR(l_cutoff, 'YYYY-MM-DD')
                             WHEN l_prev.purge_mode <> l_mode OR l_prev.depth <> l_depth
                             THEN 'mode ' || l_prev.purge_mode || ' depth ' || l_prev.depth
                             WHEN l_prev.created_at < epf_util.now_ts - NUMTODSINTERVAL(l_hours, 'HOUR')
                             THEN 'older than ' || l_hours || ' hours (preflight_valid_h)'
                        END;
        END IF;
        IF l_reason IS NULL THEN
            -- A purge that processed batches since then changed the counts.
            SELECT MAX(p.run_id)
              INTO l_purged
              FROM epf_run p
              JOIN epf_step st ON st.run_id = p.run_id
             WHERE p.action = 'PURGE' AND p.dry_run = 'N' AND p.run_id > p_run
               AND st.step_code = 'PROCESS_BATCHES' AND st.started_at IS NOT NULL;
            IF l_purged IS NOT NULL THEN
                l_reason := epf_util.run_label(l_purged) || ' purged since';
            END IF;
        END IF;
        IF l_reason IS NULL THEN
            RETURN p_run;
        END IF;
        epf_log.info('ROOTS_RECOUNTED', 'The root counts of ' || epf_util.run_label(p_run) || ' are not reused ('
                                        || l_reason || '): counted again');
        RETURN NULL;
    END reusable_run;

    -- Eligible roots of every root table in scope (ROOTS_ELIGIBLE), kept with
    -- the run per tree (EPF_TREE_EST), per month of their date
    -- (EPF_ROOT_MONTH) and for longer retentions (EPF_RETENTION_OPTION: the
    -- requested retention and 1.5, 2 and 3 times it). With g_reuse_run they
    -- are copied from that preflight instead of counted (the wizard's
    -- preflight, minutes earlier); a table it did not count is counted.
    PROCEDURE check_roots IS
        l_total    NUMBER;
        l_eligible NUMBER;
        l_n2       NUMBER;
        l_n3       NUMBER;
        l_n4       NUMBER;
        l_run      NUMBER := g_run.run_id;
        l_cutoff   DATE := g_run.cutoff_date;
        l_days     NUMBER := g_run.retention_days;
        l_opt_days SYS.ODCINUMBERLIST := SYS.ODCINUMBERLIST(g_run.retention_days,
                                                            ROUND(g_run.retention_days * 1.5),
                                                            g_run.retention_days * 2,
                                                            g_run.retention_days * 3);
        l_counts   SYS.ODCINUMBERLIST;
        l_cut2     DATE := g_run.cutoff_date - (ROUND(g_run.retention_days * 1.5) - g_run.retention_days);
        l_cut3     DATE := g_run.cutoff_date - g_run.retention_days;
        l_cut4     DATE := g_run.cutoff_date - 2 * g_run.retention_days;
        l_date     VARCHAR2(300);
        l_tid      NUMBER;
        l_action   VARCHAR2(10);
        l_opt      NUMBER;
        l_roots    NUMBER;
        l_reuse    NUMBER := g_reuse_run;
        l_shift    NUMBER;
        l_reused   BOOLEAN;
    BEGIN
        DELETE FROM epf_tree_est WHERE run_id = l_run;
        DELETE FROM epf_root_month WHERE run_id = l_run;
        DELETE FROM epf_retention_option WHERE run_id = l_run;
        COMMIT;
        IF l_reuse IS NOT NULL THEN
            -- Same cutoff on a later day: the retention days of the options shift.
            SELECT l_days - retention_days INTO l_shift FROM epf_run WHERE run_id = l_reuse;
        END IF;
        FOR r IN (SELECT e.table_id
                    FROM epf_table e
                    JOIN epf_module m ON m.module_code = e.module_code
                   WHERE e.active = 'Y' AND e.role = 'ROOT'
                   ORDER BY m.display_order, e.table_id) LOOP
            l_tid := r.table_id;
            CONTINUE WHEN NOT in_scope(g_tables(l_tid).module_code) OR NOT g_tables(l_tid).reachable;
            l_action := module_action(g_tables(l_tid).module_code);
            l_reused := FALSE;
            IF l_reuse IS NOT NULL THEN
                BEGIN
                    SELECT roots INTO l_eligible FROM epf_tree_est WHERE run_id = l_reuse AND table_id = l_tid;
                    l_reused := l_eligible IS NOT NULL;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        l_reused := FALSE;
                END;
            END IF;
            IF l_reused THEN
                g_eligible(l_tid) := l_eligible;
                INSERT INTO epf_tree_est (run_id, table_id, action, roots)
                VALUES (l_run, l_tid, l_action, l_eligible);
                INSERT INTO epf_root_month (run_id, table_id, month_start, roots)
                SELECT l_run, table_id, month_start, roots
                  FROM epf_root_month
                 WHERE run_id = l_reuse AND table_id = l_tid;
                INSERT INTO epf_retention_option (run_id, retention_days, table_id, cutoff_date, roots)
                SELECT l_run, retention_days + l_shift, table_id, cutoff_date, roots
                  FROM epf_retention_option
                 WHERE run_id = l_reuse AND table_id = l_tid;
                COMMIT;
                epf_log.event(epf_log.c_info, 'ROOTS_ELIGIBLE',
                              epf_util.fmt_int(l_eligible) || ' rows before ' || cutoff_text || ' ('
                              || g_tables(l_tid).module_code || '; counted by ' || epf_util.run_label(l_reuse) || ')',
                              p_object_owner => g_tables(l_tid).owner,
                              p_object_name => g_tables(l_tid).table_name, p_rows => l_eligible);
                CONTINUE;
            END IF;
            l_date := 't.' || qc(g_tables(l_tid).date_column);
            EXECUTE IMMEDIATE 'SELECT COUNT(*), COUNT(CASE WHEN ' || l_date || ' < ' || cutoff_literal || ' THEN 1 END),'
                              || ' COUNT(CASE WHEN ' || l_date || ' < :c2 THEN 1 END),'
                              || ' COUNT(CASE WHEN ' || l_date || ' < :c3 THEN 1 END),'
                              || ' COUNT(CASE WHEN ' || l_date || ' < :c4 THEN 1 END)'
                              || ' FROM ' || tq(l_tid) || ' t'
                INTO l_total, l_eligible, l_n2, l_n3, l_n4
                USING l_cut2, l_cut3, l_cut4;
            g_eligible(l_tid) := l_eligible;
            INSERT INTO epf_tree_est (run_id, table_id, action, roots)
            VALUES (l_run, l_tid, l_action, l_eligible);
            EXECUTE IMMEDIATE 'INSERT INTO epf_root_month (run_id, table_id, month_start, roots)'
                              || ' SELECT :r, :t, TRUNC(' || l_date || ', ''MM''), COUNT(*) FROM ' || tq(l_tid) || ' t'
                              || ' WHERE ' || l_date || ' < ' || cutoff_literal
                              || ' GROUP BY TRUNC(' || l_date || ', ''MM'')'
                USING l_run, l_tid;
            l_counts := SYS.ODCINUMBERLIST(l_eligible, l_n2, l_n3, l_n4);
            FOR d IN 1 .. l_opt_days.COUNT LOOP
                CONTINUE WHEN d > 1 AND l_opt_days(d) = l_opt_days(d - 1);
                l_opt   := l_opt_days(d);
                l_roots := l_counts(d);
                INSERT INTO epf_retention_option (run_id, retention_days, table_id, cutoff_date, roots)
                VALUES (l_run, l_opt, l_tid, l_cutoff - (l_opt - l_days), l_roots);
            END LOOP;
            COMMIT;
            epf_log.event(epf_log.c_info, 'ROOTS_ELIGIBLE',
                          epf_util.fmt_int(l_eligible) || ' of ' || epf_util.fmt_int(l_total) || ' rows before '
                          || cutoff_text || ' (' || g_tables(l_tid).module_code || ')',
                          p_object_owner => g_tables(l_tid).owner,
                          p_object_name => g_tables(l_tid).table_name, p_rows => l_eligible);
        END LOOP;
    END check_roots;

    -- ------------------------------------------------------------------
    -- Requirements and forecasts
    -- ------------------------------------------------------------------

    -- Redo written per second for the time forecast: measured by the latest
    -- purge on this database that processed trees with the same action
    -- (TREE_REDO bytes over their seconds), otherwise the setting
    -- redo_rate_mb_s.
    PROCEDURE redo_rate(p_action IN VARCHAR2, p_rate OUT NUMBER, p_basis OUT VARCHAR2) IS
        l_last NUMBER;
    BEGIN
        SELECT MAX(ev.run_id)
          INTO l_last
          FROM epf_event ev
          JOIN epf_run rn ON rn.run_id = ev.run_id
          JOIN epf_table e ON e.owner = ev.object_owner AND e.table_name = ev.object_name
         WHERE ev.event_code = 'TREE_REDO' AND ev.bytes > 0 AND ev.elapsed_s > 0
           AND CASE WHEN rn.purge_mode IN ('FULL', 'LOGS')
                         OR (rn.purge_mode = 'CLOB_N_LOGS' AND e.module_code = c_logs_module)
                    THEN c_delete ELSE c_clear END = p_action;
        IF l_last IS NOT NULL THEN
            SELECT SUM(ev.bytes) / SUM(ev.elapsed_s)
              INTO p_rate
              FROM epf_event ev
              JOIN epf_run rn ON rn.run_id = ev.run_id
              JOIN epf_table e ON e.owner = ev.object_owner AND e.table_name = ev.object_name
             WHERE ev.run_id = l_last
               AND ev.event_code = 'TREE_REDO' AND ev.bytes > 0 AND ev.elapsed_s > 0
               AND CASE WHEN rn.purge_mode IN ('FULL', 'LOGS')
                             OR (rn.purge_mode = 'CLOB_N_LOGS' AND e.module_code = c_logs_module)
                        THEN c_delete ELSE c_clear END = p_action;
            p_basis := 'redo rate measured by ' || epf_util.run_label(l_last) || ', ' || epf_util.fmt_bytes(p_rate) || '/s';
        ELSE
            p_rate  := epf_util.setting_num('redo_rate_mb_s') * 1048576;
            p_basis := 'assumed redo rate ' || epf_util.setting('redo_rate_mb_s')
                       || ' MB/s (no purge measured on this database yet)';
        END IF;
    END redo_rate;

    -- Free space for archived logs: the smallest free space of the valid local
    -- archive destinations (recovery area: limit - used + reclaimable; ASM
    -- disk group: free). NULL when a destination cannot be measured from the
    -- database (a directory); p_where describes every destination.
    PROCEDURE archive_room(p_room OUT NUMBER, p_where OUT VARCHAR2) IS
        TYPE t_dests IS TABLE OF VARCHAR2(4000);
        l_dests      t_dests;
        l_bytes      NUMBER;
        l_name       VARCHAR2(513);
        l_limit      NUMBER;
        l_used       NUMBER;
        l_reclaim    NUMBER;
        l_group      VARCHAR2(128);
        l_unmeasured BOOLEAN := FALSE;
        l_text       VARCHAR2(4000);
    BEGIN
        EXECUTE IMMEDIATE q'[SELECT destination FROM v$archive_dest
                              WHERE status = 'VALID' AND NVL(target, 'PRIMARY') <> 'STANDBY'
                                AND destination IS NOT NULL
                              ORDER BY dest_id]'
            BULK COLLECT INTO l_dests;
        IF l_dests.COUNT = 0 THEN
            p_where := 'no valid archive destination found';
            RETURN;
        END IF;
        FOR i IN 1 .. l_dests.COUNT LOOP
            l_bytes := NULL;
            IF UPPER(l_dests(i)) = 'USE_DB_RECOVERY_FILE_DEST' THEN
                EXECUTE IMMEDIATE 'SELECT MAX(name), MAX(space_limit), MAX(space_used), MAX(space_reclaimable)'
                                  || ' FROM v$recovery_file_dest'
                    INTO l_name, l_limit, l_used, l_reclaim;
                IF l_limit > 0 THEN
                    l_bytes := l_limit - l_used + l_reclaim;
                    l_text  := 'recovery area ' || l_name || ': limit ' || epf_util.fmt_bytes(l_limit) || ', used '
                               || epf_util.fmt_bytes(l_used) || ', reclaimable ' || epf_util.fmt_bytes(l_reclaim)
                               || ', free ' || epf_util.fmt_bytes(l_bytes) || ' (the disk must also have this room)';
                ELSE
                    l_text := 'recovery area: not configured';
                END IF;
            ELSIF SUBSTR(l_dests(i), 1, 1) = '+' THEN
                l_group := UPPER(REGEXP_SUBSTR(l_dests(i), '^\+([^/]+)', 1, 1, NULL, 1));
                EXECUTE IMMEDIATE 'SELECT MAX(free_mb) * 1048576 FROM v$asm_diskgroup WHERE name = :g'
                    INTO l_bytes USING l_group;
                l_text := 'ASM disk group +' || l_group || ': free ' || NVL(epf_util.fmt_bytes(l_bytes), 'unknown');
            ELSE
                l_text := 'directory ' || l_dests(i) || ': its free space cannot be read from the database';
            END IF;
            IF l_bytes IS NULL THEN
                l_unmeasured := TRUE;
            ELSE
                p_room := LEAST(NVL(p_room, l_bytes), l_bytes);
            END IF;
            p_where := SUBSTR(p_where || CASE WHEN p_where IS NOT NULL THEN '; ' END || l_text, 1, 1500);
        END LOOP;
        IF l_unmeasured THEN
            p_room := NULL;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            p_room  := NULL;
            p_where := 'the archive space could not be measured: ' || SQLERRM;
    END archive_room;

    -- Latest cutoff (largest purge, oldest data first) whose redo fits
    -- p_redo_room, by month of the root dates; the run's cutoff when all of it
    -- fits, NULL when the oldest month alone does not.
    FUNCTION fit_cutoff(p_redo_room IN NUMBER) RETURN DATE IS
        l_run    NUMBER := g_run.run_id;
        l_cutoff DATE := g_run.cutoff_date;
        l_sum    NUMBER := 0;
        l_fit    DATE;
    BEGIN
        FOR m IN (SELECT rm.month_start, SUM(rm.roots * te.redo_root) AS redo
                    FROM epf_root_month rm
                    JOIN epf_tree_est te ON te.run_id = rm.run_id AND te.table_id = rm.table_id
                   WHERE rm.run_id = l_run AND te.redo_root IS NOT NULL
                   GROUP BY rm.month_start
                   ORDER BY rm.month_start) LOOP
            l_sum := l_sum + m.redo;
            EXIT WHEN l_sum > p_redo_room;
            l_fit := LEAST(ADD_MONTHS(m.month_start, 1), l_cutoff);
        END LOOP;
        RETURN l_fit;
    END fit_cutoff;

    FUNCTION stat_rows(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN NUMBER IS
        l_rows NUMBER;
    BEGIN
        SELECT MAX(num_rows) INTO l_rows FROM dba_tables WHERE owner = p_owner AND table_name = p_table;
        RETURN NVL(l_rows, 0);
    END stat_rows;

    -- Size of an index on p_columns of a table: rows x (key length + row
    -- address) plus block overhead, from optimizer statistics.
    FUNCTION index_bytes_estimate(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_columns IN SYS.ODCIVARCHAR2LIST)
        RETURN NUMBER IS
        l_len NUMBER;
    BEGIN
        SELECT NVL(SUM(avg_col_len), 0)
          INTO l_len
          FROM dba_tab_columns
         WHERE owner = p_owner AND table_name = p_table
           AND column_name IN (SELECT column_value FROM TABLE(p_columns));
        RETURN stat_rows(p_owner, p_table) * (l_len + 12) * 1.15;
    END index_bytes_estimate;

    PROCEDURE add_req(p_code IN VARCHAR2, p_seq IN NUMBER, p_met IN BOOLEAN, p_blocking IN VARCHAR2,
                      p_title IN VARCHAR2, p_why IN VARCHAR2, p_measured IN VARCHAR2,
                      p_needed IN NUMBER, p_room IN NUMBER, p_met_by IN VARCHAR2,
                      p_applies IN BOOLEAN DEFAULT TRUE) IS
        l_run      NUMBER := g_run.run_id;
        l_status   VARCHAR2(20) := CASE WHEN NOT p_applies THEN 'NOT_APPLICABLE'
                                        WHEN p_met THEN 'MET' ELSE 'NOT_MET' END;
        l_met_by   VARCHAR2(30) := p_met_by;
        l_measured VARCHAR2(4000) := p_measured;
    BEGIN
        -- A blocking requirement the operator confirms (confirmed_reqs) is met
        -- by that confirmation.
        IF p_blocking = 'Y' AND l_status = 'NOT_MET'
           AND INSTR(',' || g_run.confirmed_reqs || ',', ',' || p_code || ',') > 0 THEN
            l_status   := 'MET';
            l_met_by   := 'CONFIRMED';
            l_measured := l_measured || '; confirmed by the operator (--confirm ' || p_code || ')';
        END IF;
        INSERT INTO epf_requirement (run_id, req_code, seq, status, blocking, title, why, measured,
                                     needed_bytes, room_bytes, met_by)
        VALUES (l_run, p_code, p_seq, l_status, p_blocking, p_title, SUBSTR(p_why, 1, 1000),
                SUBSTR(l_measured, 1, 2000), p_needed, p_room,
                CASE WHEN l_status = 'MET' THEN l_met_by END);
    END add_req;

    PROCEDURE add_opt(p_code IN VARCHAR2, p_option IN VARCHAR2, p_seq IN NUMBER, p_met IN BOOLEAN,
                      p_title IN VARCHAR2, p_detail IN VARCHAR2) IS
        l_run NUMBER := g_run.run_id;
        l_met VARCHAR2(1) := CASE WHEN p_met THEN 'Y' ELSE 'N' END;
    BEGIN
        INSERT INTO epf_req_option (run_id, req_code, option_code, seq, met, title, detail)
        VALUES (l_run, p_code, p_option, p_seq, l_met, p_title, SUBSTR(p_detail, 1, 2000));
    END add_opt;

    -- The six requirements of a purge (EPF_REQUIREMENT, EPF_REQ_OPTION), each
    -- with the ways to meet it, from the estimates of the preflight:
    --   ARCHIVE      archived logs fit the archive destination (ARCHIVELOG)
    --   UNDO         the undo tablespace holds the batches
    --   TEMP         TEMP holds the work keys
    --   INDEX_SPACE  the tool tablespace holds the temporary indexes
    --   REDO_LOGS    one batch fits an online log (slower otherwise)
    --   BACKUP       a recent backup, or the operator's choice
    -- ARCHIVE, UNDO, TEMP and BACKUP are blocking.
    PROCEDURE check_requirements IS
        c_why_archive CONSTANT VARCHAR2(400) := 'Every deleted row is written to the redo log. In ARCHIVELOG mode each '
            || 'full log is kept as a file until it is backed up; if the archive space fills, the whole database stops.';
        c_why_undo    CONSTANT VARCHAR2(400) := 'Each batch keeps a copy of its rows in undo until it commits; if undo '
            || 'cannot hold a batch, the batch fails and the purge of its module stops.';
        c_why_temp    CONSTANT VARCHAR2(400) := 'The purge keeps the keys of the rows it will delete in a temporary '
            || 'table; without room in TEMP it stops before deleting anything.';
        c_why_index   CONSTANT VARCHAR2(400) := 'Tables without an index on the column the purge searches by get one '
            || 'for the run, dropped after; without room it is not created and each batch scans the whole table.';
        c_why_redo    CONSTANT VARCHAR2(400) := 'Small online logs fill every few seconds and the purge waits on each '
            || 'switch. Slower, not a failure.';
        c_why_backup  CONSTANT VARCHAR2(400) := 'A purge cannot be undone; a backup taken just before it is the only '
            || 'way back.';
        l_run        NUMBER := g_run.run_id;
        l_owner      VARCHAR2(128) := g_owner;
        l_choice     VARCHAR2(10) := g_run.backup_choice;
        l_margin_pct NUMBER := epf_util.setting_num('archive_margin_pct');
        l_min_idx    NUMBER := epf_util.setting_num('temp_index_min_mb') * 1048576;
        l_max_age    NUMBER := epf_util.setting_num('backup_max_age_h');
        l_redo       NUMBER := 0;
        l_unknown    NUMBER := 0;
        l_need       NUMBER;
        l_room       NUMBER;
        l_where      VARCHAR2(2000);
        l_fit        DATE;
        l_text       VARCHAR2(2000);
        l_met        BOOLEAN;
        l_ok         BOOLEAN;
        l_met_by     VARCHAR2(30);
        l_keys       NUMBER := 0;
        l_root_rows  NUMBER;
        l_ids        SYS.ODCINUMBERLIST;
        l_tool_ts    VARCHAR2(128);
        l_temp_ts    VARCHAR2(128);
        l_free       NUMBER;
        l_ext        NUMBER;
        l_needs      t_needs;
        l_idx_count  NUMBER := 0;
        l_idx_bytes  NUMBER := 0;
        l_batch_redo NUMBER := 0;
        l_per_root   NUMBER := 0;
        l_recommend  NUMBER;
        l_planned    BOOLEAN;
        l_log        NUMBER;
        l_last_bkp   DATE;
        l_bkp_note   VARCHAR2(400);
        l_recent     BOOLEAN;
        l_met_n      NUMBER;
        l_total_n    NUMBER;
        l_blocking   NUMBER;
        l_unmet      VARCHAR2(400);
        l_confirmed  VARCHAR2(100) := g_run.confirmed_reqs;

        -- Last way to meet a blocking requirement: the operator's confirmation.
        PROCEDURE add_confirm(p_code IN VARCHAR2, p_seq IN NUMBER) IS
        BEGIN
            add_opt(p_code, 'CONFIRMED', p_seq, INSTR(',' || l_confirmed || ',', ',' || p_code || ',') > 0,
                    'The DBA confirms it is handled (--confirm ' || p_code || ')',
                    'the purge then starts although the preflight finds this requirement not met');
        END add_confirm;
    BEGIN
        DELETE FROM epf_requirement WHERE run_id = l_run;
        DELETE FROM epf_req_option WHERE run_id = l_run;

        -- Redo of the run: eligible roots x redo per root of each tree.
        FOR t IN (SELECT roots, redo_root FROM epf_tree_est WHERE run_id = l_run) LOOP
            IF NVL(t.roots, 0) > 0 THEN
                IF t.redo_root IS NULL THEN
                    l_unknown := l_unknown + 1;
                ELSE
                    l_redo := l_redo + t.redo_root * t.roots;
                END IF;
            END IF;
        END LOOP;

        -- ARCHIVE
        IF NVL(g_log_mode, 'NOARCHIVELOG') = 'NOARCHIVELOG' THEN
            add_req('ARCHIVE', 1, TRUE, 'Y', 'Archived logs fit', c_why_archive,
                    'NOARCHIVELOG: redo is not archived (estimate ' || epf_util.fmt_bytes(l_redo) || ' of redo)',
                    NULL, NULL, 'NOARCHIVELOG');
            add_opt('ARCHIVE', 'NOARCHIVELOG', 1, TRUE, 'Database in NOARCHIVELOG', 'nothing is archived');
        ELSE
            l_need := l_redo * (1 + l_margin_pct / 100);
            archive_room(l_room, l_where);
            l_met := l_room IS NOT NULL AND l_unknown = 0 AND l_room >= l_need;
            l_text := 'needs ' || epf_util.fmt_bytes(l_need) || ' (redo estimate ' || epf_util.fmt_bytes(l_redo)
                      || ' + ' || l_margin_pct || '%)'
                      || CASE WHEN l_unknown > 0 THEN ', ' || l_unknown || ' trees without a redo estimate' END
                      || '; ' || l_where;
            add_req('ARCHIVE', 1, l_met, 'Y', 'Archived logs fit', c_why_archive, l_text, l_need, l_room, 'ROOM');
            add_opt('ARCHIVE', 'NOARCHIVELOG', 1, FALSE, 'Database in NOARCHIVELOG',
                    'ARCHIVELOG now. Switching needs 2 restarts and a new full backup: the DBA''s decision, '
                    || 'never made by this tool');
            add_opt('ARCHIVE', 'ROOM', 2, l_met, 'Enough room for the whole purge',
                    CASE WHEN l_room IS NULL THEN 'free space not measurable: the DBA checks it'
                         ELSE 'free ' || epf_util.fmt_bytes(l_room) || ', needed ' || epf_util.fmt_bytes(l_need) END
                    || '. The DBA backs up and deletes archived logs, or raises the limit; then run the preflight again');
            IF l_room IS NOT NULL THEN
                l_fit := fit_cutoff(l_room / (1 + l_margin_pct / 100));
            END IF;
            add_opt('ARCHIVE', 'SMALLER_RUNS', 3, FALSE, 'Purge in smaller runs, older data first',
                    CASE WHEN l_room IS NULL THEN 'needs a measurable free space'
                         WHEN l_fit IS NULL THEN 'the oldest month alone does not fit the free space'
                         WHEN l_fit >= g_run.cutoff_date THEN 'the whole purge fits in one run'
                         ELSE 'largest purge that fits now: retention ' || (TRUNC(SYSDATE) - l_fit) || ' days (cutoff '
                              || TO_CHAR(l_fit, 'YYYY-MM-DD') || '); the DBA backs up and deletes archived logs '
                              || 'between runs' END);
            add_confirm('ARCHIVE', 4);
        END IF;

        -- UNDO: the undo tablespace holds 4 batches, and the undo kept for
        -- undo_retention fits without growing (or undo tuning limits it).
        l_ok  := 4 * NVL(g_undo_batch, 0) <= NVL(g_undo_max, 0);
        l_met := l_ok AND (g_undo_limit OR NVL(g_undo_kept, 0) <= NVL(g_undo_size, 0));
        l_met_by := CASE WHEN g_undo_limit THEN 'UNDO_TUNING' ELSE 'ROOM' END;
        add_req('UNDO', 2, l_met, 'Y', 'Undo fits', c_why_undo,
                g_undo_ts || ' ' || epf_util.fmt_bytes(g_undo_size) || ', can grow to ' || epf_util.fmt_bytes(g_undo_max)
                || '; one batch needs about ' || epf_util.fmt_bytes(g_undo_batch)
                || CASE WHEN g_undo_limit THEN
                       '; undo tuning keeps undo ' || epf_util.setting('undo_retention_s') || ' s and caps ' || g_undo_ts
                       || ' at about ' || NVL(epf_util.fmt_bytes(g_undo_cap), epf_util.fmt_bytes(g_undo_size))
                       || ' (without it undo_retention would keep about ' || epf_util.fmt_bytes(g_undo_kept) || ')'
                   ELSE '; undo_retention keeps about ' || epf_util.fmt_bytes(g_undo_kept) END,
                g_undo_batch, g_undo_max, l_met_by);
        add_opt('UNDO', 'UNDO_TUNING', 1, g_undo_limit AND l_ok, 'Undo tuning (--undo-tuning)',
                'undo kept 60 s and its growth limited'
                || CASE WHEN g_undo_cap IS NOT NULL THEN ' to about ' || epf_util.fmt_bytes(g_undo_cap) END
                || ' for the purge, restored after (SYS)');
        add_opt('UNDO', 'ROOM', 2, l_ok AND NVL(g_undo_kept, 0) <= NVL(g_undo_size, 0),
                'The undo tablespace holds the purge without tuning',
                'the undo kept for undo_retention (about ' || epf_util.fmt_bytes(g_undo_kept) || ') fits in its '
                || epf_util.fmt_bytes(g_undo_size) || ' without growing');
        IF NOT l_ok THEN
            add_opt('UNDO', 'SMALLER_BATCH', 3, FALSE, 'Smaller batch (--batch-size)',
                    'one batch needs ' || epf_util.fmt_bytes(g_undo_batch) || '; ' || g_undo_ts || ' can hold '
                    || epf_util.fmt_bytes(g_undo_max) || ': lower the batch size');
        END IF;
        add_confirm('UNDO', 4);

        -- TEMP: the work keys (roots and the keys of the link sources below
        -- them, about 150 bytes each with their indexes).
        FOR t IN (SELECT table_id, roots FROM epf_tree_est WHERE run_id = l_run AND roots > 0) LOOP
            l_keys := l_keys + t.roots;
            l_root_rows := stat_rows(g_tables(t.table_id).owner, g_tables(t.table_id).table_name);
            l_ids := tree_tables(t.table_id);
            FOR k IN 1 .. l_ids.COUNT LOOP
                IF l_ids(k) <> t.table_id AND g_tables(l_ids(k)).reachable AND has_keys(l_ids(k)) AND l_root_rows > 0 THEN
                    l_keys := l_keys + t.roots * stat_rows(g_tables(l_ids(k)).owner, g_tables(l_ids(k)).table_name)
                                       / l_root_rows;
                END IF;
            END LOOP;
        END LOOP;
        l_need := l_keys * 150;
        SELECT MAX(default_tablespace), MAX(temporary_tablespace)
          INTO l_tool_ts, l_temp_ts
          FROM dba_users
         WHERE username = l_owner;
        BEGIN
            EXECUTE IMMEDIATE 'SELECT NVL(MAX(free_space), 0) FROM dba_temp_free_space WHERE tablespace_name = :t'
                INTO l_free USING l_temp_ts;
            EXECUTE IMMEDIATE 'SELECT NVL(SUM(CASE WHEN autoextensible = ''YES'' THEN GREATEST(maxbytes - bytes, 0)'
                              || ' ELSE 0 END), 0) FROM dba_temp_files WHERE tablespace_name = :t'
                INTO l_ext USING l_temp_ts;
            l_room := l_free + l_ext;
            add_req('TEMP', 3, l_room >= l_need, 'Y', 'Room for the work keys', c_why_temp,
                    'about ' || epf_util.fmt_int(ROUND(l_keys)) || ' keys, ' || epf_util.fmt_bytes(l_need) || '; '
                    || l_temp_ts || ' free ' || epf_util.fmt_bytes(l_free) || ', can grow by ' || epf_util.fmt_bytes(l_ext),
                    l_need, l_room, 'ROOM');
            add_opt('TEMP', 'ROOM', 1, l_room >= l_need, 'Room in ' || l_temp_ts,
                    'needs ' || epf_util.fmt_bytes(l_need) || ', free ' || epf_util.fmt_bytes(l_room));
            add_confirm('TEMP', 2);
        EXCEPTION
            WHEN OTHERS THEN
                add_req('TEMP', 3, FALSE, 'Y', 'Room for the work keys', c_why_temp,
                        'about ' || epf_util.fmt_bytes(l_need) || '; the free space of ' || l_temp_ts
                        || ' could not be measured: ' || SQLERRM,
                        l_need, NULL, NULL, p_applies => FALSE);
        END;

        -- INDEX_SPACE: temporary indexes the purge will create (as
        -- create_temp_indexes decides), in the tool's default tablespace.
        FOR m IN 1 .. g_modules.COUNT LOOP
            l_needs := index_needs(g_modules(m));
            FOR k IN 1 .. l_needs.COUNT LOOP
                CONTINUE WHEN l_needs(k).table_id IS NULL;
                CONTINUE WHEN index_covers(l_needs(k).owner, l_needs(k).table_name, l_needs(k).col_list);
                CONTINUE WHEN NOT l_needs(k).fk AND table_bytes(l_needs(k).owner, l_needs(k).table_name) < l_min_idx;
                l_idx_count := l_idx_count + 1;
                l_idx_bytes := l_idx_bytes + index_bytes_estimate(l_needs(k).owner, l_needs(k).table_name,
                                                                  l_needs(k).col_list);
            END LOOP;
        END LOOP;
        SELECT NVL(SUM(bytes), 0) INTO l_free FROM dba_free_space WHERE tablespace_name = l_tool_ts;
        SELECT NVL(SUM(CASE WHEN autoextensible = 'YES' THEN GREATEST(maxbytes - bytes, 0) ELSE 0 END), 0)
          INTO l_ext
          FROM dba_data_files
         WHERE tablespace_name = l_tool_ts;
        l_room := l_free + l_ext;
        l_met := l_idx_count = 0 OR l_room >= 1.2 * l_idx_bytes;
        add_req('INDEX_SPACE', 4, l_met, 'N', 'Room for temporary indexes', c_why_index,
                CASE WHEN l_idx_count = 0 THEN 'no temporary index needed'
                     ELSE l_idx_count || ' temporary indexes, about ' || epf_util.fmt_bytes(l_idx_bytes) END
                || '; ' || l_tool_ts || ' free ' || epf_util.fmt_bytes(l_free) || ', can grow by '
                || epf_util.fmt_bytes(l_ext),
                l_idx_bytes, l_room, CASE WHEN l_idx_count = 0 THEN 'NONE_NEEDED' ELSE 'ROOM' END);
        add_opt('INDEX_SPACE', 'NONE_NEEDED', 1, l_idx_count = 0, 'The indexes already exist',
                CASE WHEN l_idx_count = 0 THEN 'every column the purge searches by is indexed'
                     ELSE l_idx_count || ' columns without an index' END);
        add_opt('INDEX_SPACE', 'ROOM', 2, l_idx_count > 0 AND l_room >= 1.2 * l_idx_bytes, 'Room in ' || l_tool_ts,
                'needs about ' || epf_util.fmt_bytes(l_idx_bytes) || ', free ' || epf_util.fmt_bytes(l_room));

        -- REDO_LOGS: the redo of one batch against the smallest online log.
        FOR t IN (SELECT table_id, redo_root FROM epf_tree_est
                   WHERE run_id = l_run AND roots > 0 AND redo_root IS NOT NULL AND action = 'DELETE') LOOP
            l_batch_redo := GREATEST(l_batch_redo, t.redo_root * batch_roots(t.table_id));
            l_per_root   := GREATEST(l_per_root, t.redo_root);
        END LOOP;
        IF l_per_root > 0 AND g_min_log > 0 THEN
            l_recommend := round_batch(0.5 * g_min_log / l_per_root);
        END IF;
        -- Redo log sizing planned for the purge (with_redo_logs): 1 GB logs.
        l_planned := g_run.with_redo_logs = 'Y' AND NVL(g_min_log, 0) < 1073741824;
        l_log     := CASE WHEN l_planned THEN 1073741824 ELSE NVL(g_min_log, 0) END;
        l_met     := l_batch_redo <= l_log;
        add_req('REDO_LOGS', 5, l_met, 'N', 'Redo log size', c_why_redo,
                'smallest online log ' || epf_util.fmt_bytes(g_min_log)
                || CASE WHEN l_planned THEN ', 4 x 1 GB when the purge starts' END
                || '; one batch writes about ' || epf_util.fmt_bytes(l_batch_redo),
                l_batch_redo, l_log,
                CASE WHEN g_min_log >= 1073741824 THEN 'LOGS_1GB' WHEN l_planned THEN 'REDO_LOGS' ELSE 'BATCH' END);
        add_opt('REDO_LOGS', 'LOGS_1GB', 1, g_min_log >= 1073741824, 'Online logs of at least 1 GB',
                'smallest now ' || epf_util.fmt_bytes(g_min_log));
        add_opt('REDO_LOGS', 'REDO_LOGS', 2, l_planned AND l_met, 'Enlarge the logs when the purge starts (--redo-logs)',
                'replaces them with 4 x 1 GB (permanent; SYS)');
        add_opt('REDO_LOGS', 'SMALLER_BATCH', 3, l_met AND NOT l_planned AND g_min_log < 1073741824,
                'Smaller batch (--batch-size)',
                CASE WHEN l_recommend IS NOT NULL THEN 'batch ' || epf_util.fmt_int(l_recommend)
                                                       || ' keeps one batch within half an online log'
                     ELSE 'no redo estimate' END);

        -- BACKUP: a successful RMAN database backup newer than backup_max_age_h,
        -- or the operator's choice (CONFIRMED, NONE).
        BEGIN
            EXECUTE IMMEDIATE q'[SELECT MAX(end_time) FROM v$rman_backup_job_details
                                  WHERE status IN ('COMPLETED', 'COMPLETED WITH WARNINGS')
                                    AND input_type IN ('DB FULL', 'DB INCR')]'
                INTO l_last_bkp;
        EXCEPTION
            WHEN OTHERS THEN
                l_last_bkp := NULL;
                l_bkp_note := '; RMAN history could not be read: ' || SQLERRM;
        END;
        l_recent := l_last_bkp > SYSDATE - l_max_age / 24;
        l_met    := l_recent OR l_choice IN ('CONFIRMED', 'NONE');
        add_req('BACKUP', 6, l_met, 'Y', 'Backup before the purge', c_why_backup,
                'last successful RMAN database backup: ' || NVL(TO_CHAR(l_last_bkp, 'YYYY-MM-DD HH24:MI'), 'none recorded')
                || l_bkp_note
                || CASE l_choice WHEN 'CONFIRMED' THEN '; a backup made another way is confirmed'
                                 WHEN 'NONE' THEN '; purge without a backup confirmed' END,
                NULL, NULL,
                CASE WHEN l_recent THEN 'RECENT' WHEN l_choice = 'CONFIRMED' THEN 'CONFIRMED' ELSE 'NO_BACKUP' END);
        add_opt('BACKUP', 'RECENT', 1, l_recent, 'Database backup newer than ' || l_max_age || ' h',
                'RMAN: ' || NVL(TO_CHAR(l_last_bkp, 'YYYY-MM-DD HH24:MI'), 'no successful database backup recorded'));
        add_opt('BACKUP', 'CONFIRMED', 2, l_choice = 'CONFIRMED', 'Backup made another way (--backup confirmed)',
                'storage snapshot, export: the operator confirms it');
        add_opt('BACKUP', 'NO_BACKUP', 3, l_choice = 'NONE', 'Purge without a backup (--backup none)',
                'test copies, data that can be restored elsewhere: the operator confirms it');
        COMMIT;

        SELECT COUNT(CASE WHEN status = 'MET' THEN 1 END), COUNT(*),
               COUNT(CASE WHEN status = 'NOT_MET' AND blocking = 'Y' THEN 1 END),
               LISTAGG(CASE WHEN status = 'NOT_MET' THEN req_code END, ', ') WITHIN GROUP (ORDER BY seq)
          INTO l_met_n, l_total_n, l_blocking, l_unmet
          FROM epf_requirement
         WHERE run_id = l_run;
        IF l_blocking > 0 THEN
            g_warnings := g_warnings + 1;
        END IF;
        epf_log.event(CASE WHEN l_blocking > 0 THEN epf_log.c_warn
                           WHEN l_unmet IS NOT NULL THEN epf_log.c_info ELSE epf_log.c_ok END,
                      'REQUIREMENTS',
                      l_met_n || ' of ' || l_total_n || ' requirements met'
                      || CASE WHEN l_unmet IS NOT NULL THEN '; not met: ' || l_unmet END
                      || CASE WHEN l_blocking > 0 THEN ' (' || l_blocking || ' blocking)' END,
                      p_rows => l_blocking);
    END check_requirements;

    -- Forecast of the preflight per module (EPF_FORECAST, origin PREFLIGHT):
    -- eligible roots, batches, redo and undo from the estimates per root, and
    -- the deleting time at the measured (or assumed) redo rate.
    PROCEDURE forecast_preflight IS
        l_run     NUMBER := g_run.run_id;
        l_batch   NUMBER := g_run.batch_size;
        l_module  VARCHAR2(30);
        l_action  VARCHAR2(10);
        l_roots   NUMBER;
        l_batches NUMBER;
        l_redo    NUMBER;
        l_undo    NUMBER;
        l_rbasis  VARCHAR2(400);
        l_rate    NUMBER;
        l_tbasis  VARCHAR2(400);
    BEGIN
        DELETE FROM epf_forecast WHERE run_id = l_run AND origin = 'PREFLIGHT';
        FOR m IN 1 .. g_modules.COUNT LOOP
            l_module := g_modules(m);
            l_action := module_action(l_module);
            SELECT SUM(te.roots), SUM(CEIL(te.roots / l_batch)),
                   CASE WHEN COUNT(CASE WHEN te.roots > 0 AND te.redo_root IS NULL THEN 1 END) = 0
                        THEN NVL(SUM(te.roots * te.redo_root), 0) END,
                   CASE WHEN COUNT(CASE WHEN te.roots > 0 AND te.undo_root IS NULL THEN 1 END) = 0
                        THEN NVL(SUM(te.roots * te.undo_root), 0) END,
                   MAX(te.redo_basis) KEEP (DENSE_RANK FIRST ORDER BY
                       CASE WHEN te.roots > 0 AND te.redo_root IS NULL THEN 0
                            WHEN te.redo_basis NOT LIKE 'measured%' THEN 1 ELSE 2 END)
              INTO l_roots, l_batches, l_redo, l_undo, l_rbasis
              FROM epf_tree_est te
              JOIN epf_table t ON t.table_id = te.table_id
             WHERE te.run_id = l_run AND t.module_code = l_module;
            redo_rate(l_action, l_rate, l_tbasis);
            INSERT INTO epf_forecast (run_id, origin, module_code, action, roots, row_count, batches, redo_bytes,
                                      undo_bytes, delete_seconds, freed_bytes, redo_basis, time_basis)
            VALUES (l_run, 'PREFLIGHT', l_module, l_action, l_roots, NULL, l_batches, l_redo,
                    l_undo, l_redo / NULLIF(l_rate, 0), NULL, l_rbasis, l_tbasis);
        END LOOP;
        COMMIT;
    END forecast_preflight;

    -- Forecast of a dry run per module (EPF_FORECAST, origin DRY_RUN): rows
    -- (or non-empty LOB values) and roots exactly as counted after holding
    -- back, batches of the key snapshot, redo and undo from the estimates per
    -- root of the run's preflight, the deleting time, and the space freed
    -- inside the segments (used space of each table x its eligible share; LOB
    -- segments only when clearing). Runs before the work keys are released.
    PROCEDURE forecast_dry_run IS
        l_run     NUMBER := g_run.run_id;
        l_module  VARCHAR2(30);
        l_action  VARCHAR2(10);
        l_rows    NUMBER;
        l_roots   NUMBER;
        l_batches NUMBER;
        l_redo    NUMBER;
        l_undo    NUMBER;
        l_freed   NUMBER;
        l_rbasis  VARCHAR2(400);
        l_rate    NUMBER;
        l_tbasis  VARCHAR2(400);
    BEGIN
        DELETE FROM epf_forecast WHERE run_id = l_run AND origin = 'DRY_RUN';
        FOR m IN 1 .. g_modules.COUNT LOOP
            l_module := g_modules(m);
            l_action := module_action(l_module);
            SELECT SUM(CASE WHEN s.action = 'CLEAR' THEN s.nonempty_lob_rows ELSE s.eligible_rows END)
              INTO l_rows
              FROM epf_table_stat s
              JOIN epf_table t ON t.table_id = s.table_id
             WHERE s.run_id = l_run AND s.phase = 'BEFORE' AND t.module_code = l_module;
            SELECT SUM(k.roots), SUM(k.batches),
                   CASE WHEN COUNT(CASE WHEN k.roots > 0 AND te.redo_root IS NULL THEN 1 END) = 0
                        THEN NVL(SUM(k.roots * te.redo_root), 0) END,
                   CASE WHEN COUNT(CASE WHEN k.roots > 0 AND te.undo_root IS NULL THEN 1 END) = 0
                        THEN NVL(SUM(k.roots * te.undo_root), 0) END,
                   MAX(te.redo_basis) KEEP (DENSE_RANK FIRST ORDER BY
                       CASE WHEN k.roots > 0 AND te.redo_root IS NULL THEN 0
                            WHEN te.redo_basis NOT LIKE 'measured%' THEN 1 ELSE 2 END)
              INTO l_roots, l_batches, l_redo, l_undo, l_rbasis
              FROM (SELECT wk.table_id, COUNT(*) AS roots, MAX(wk.batch_no) AS batches
                      FROM epf_work_key wk
                      JOIN epf_table t ON t.table_id = wk.table_id
                     WHERE wk.run_id = l_run AND t.role = 'ROOT' AND t.module_code = l_module
                     GROUP BY wk.table_id) k
              LEFT JOIN epf_tree_est te ON te.run_id = l_run AND te.table_id = k.table_id;
            SELECT SUM(x.used * x.eligible / NULLIF(x.total, 0))
              INTO l_freed
              FROM (SELECT s.total_rows AS total, s.eligible_rows AS eligible,
                           (SELECT SUM(su.used_bytes)
                              FROM epf_segment_snap ss
                              JOIN epf_space_usage su
                                ON su.run_id = ss.run_id AND su.phase = ss.phase AND su.owner = ss.owner
                               AND su.segment_name = ss.segment_name
                               AND NVL(su.partition_name, '-') = NVL(ss.partition_name, '-')
                             WHERE ss.run_id = s.run_id AND ss.phase = 'BASELINE'
                               AND ss.parent_owner = t.owner AND ss.parent_table = t.table_name
                               AND (s.action <> 'CLEAR' OR ss.segment_type LIKE 'LOB%')) AS used
                      FROM epf_table_stat s
                      JOIN epf_table t ON t.table_id = s.table_id
                     WHERE s.run_id = l_run AND s.phase = 'BEFORE' AND t.module_code = l_module) x;
            redo_rate(l_action, l_rate, l_tbasis);
            INSERT INTO epf_forecast (run_id, origin, module_code, action, roots, row_count, batches, redo_bytes,
                                      undo_bytes, delete_seconds, freed_bytes, redo_basis, time_basis)
            VALUES (l_run, 'DRY_RUN', l_module, l_action, l_roots, l_rows, l_batches, l_redo,
                    l_undo, l_redo / NULLIF(l_rate, 0), l_freed, l_rbasis, l_tbasis);
            COMMIT;
            epf_log.event(epf_log.c_info, 'FORECAST',
                          l_module || ': ' || epf_util.fmt_int(l_rows) || ' '
                          || CASE l_action WHEN c_delete THEN 'rows' ELSE 'LOB values' END
                          || ', ' || epf_util.fmt_int(l_batches) || ' batches'
                          || CASE WHEN l_redo IS NOT NULL THEN
                                 ', about ' || epf_util.fmt_bytes(l_redo) || ' redo, '
                                 || NVL(epf_util.fmt_bytes(l_undo), '-') || ' undo, '
                                 || epf_util.fmt_duration(l_redo / NULLIF(l_rate, 0)) || ' deleting'
                                 ELSE ', no redo estimate' END
                          || CASE WHEN l_freed IS NOT NULL THEN ', about ' || epf_util.fmt_bytes(l_freed) || ' freed' END,
                          p_rows => l_rows, p_bytes => l_redo);
        END LOOP;
    END forecast_dry_run;

    -- ------------------------------------------------------------------
    -- Public
    -- ------------------------------------------------------------------

    PROCEDURE preflight(p_run_id IN NUMBER, p_errors OUT PLS_INTEGER, p_warnings OUT PLS_INTEGER,
                        p_reuse_run IN NUMBER DEFAULT NULL) IS
        l_errors   PLS_INTEGER;
        l_warnings PLS_INTEGER;
    BEGIN
        init(p_run_id, 'PURGE,PREFLIGHT');
        scope_event;
        g_reuse_run := reusable_run(p_reuse_run);

        epf_log.step_start('REGISTRY');
        epf_registry.validate(l_errors, l_warnings);
        epf_log.step_end(CASE WHEN l_errors > 0 THEN 'FAILED' ELSE 'DONE' END,
                         l_errors || ' errors, ' || l_warnings || ' warnings');
        p_errors := l_errors;
        IF l_errors = 0 THEN
            epf_log.step_start('SUPPORTING_INDEXES');
            check_indexes;
            epf_log.step_end('DONE');
            epf_log.step_start('ELIGIBLE_ROOTS');
            check_roots;
            epf_log.step_end('DONE');
            epf_log.step_start('REDO_LOGS');
            check_redo;
            epf_log.step_end('DONE');
            epf_log.step_start('UNDO');
            check_undo;
            epf_log.step_end('DONE');
            epf_log.step_start('REQUIREMENTS');
            check_requirements;
            epf_log.step_end('DONE');
            epf_log.step_start('FORECAST');
            forecast_preflight;
            epf_log.step_end('DONE');
        END IF;
        p_warnings := l_warnings + g_warnings;
    END preflight;

    PROCEDURE recheck(p_run_id IN NUMBER, p_warnings OUT PLS_INTEGER) IS
    BEGIN
        init(p_run_id, 'PURGE,PREFLIGHT');
        FOR t IN (SELECT table_id, roots FROM epf_tree_est WHERE run_id = p_run_id) LOOP
            g_eligible(t.table_id) := t.roots;
        END LOOP;
        epf_log.step_start('CHOICES');
        epf_log.event(epf_log.c_info, 'CHOICES',
                      'Batch ' || epf_util.fmt_int(g_run.batch_size)
                      || '; undo tuning ' || CASE g_run.with_undo_tuning WHEN 'Y' THEN 'planned' ELSE 'no' END
                      || '; redo logs ' || CASE g_run.with_redo_logs WHEN 'Y' THEN 'enlarged when the purge starts'
                                                                      ELSE 'as they are' END
                      || '; backup ' || NVL(LOWER(g_run.backup_choice), 'RMAN')
                      || CASE WHEN g_run.confirmed_reqs IS NOT NULL
                              THEN '; confirmed by the DBA: ' || g_run.confirmed_reqs END,
                      p_rows => g_run.batch_size);
        g_silent := TRUE;
        BEGIN
            check_redo;
            check_undo;
        EXCEPTION
            WHEN OTHERS THEN
                g_silent := FALSE;
                RAISE;
        END;
        g_silent := FALSE;
        check_requirements;
        forecast_preflight;
        epf_log.step_end('DONE');
        p_warnings := g_warnings;
    END recheck;

    PROCEDURE run(p_run_id IN NUMBER, p_status OUT VARCHAR2) IS
        l_errors   PLS_INTEGER;
        l_warnings PLS_INTEGER;
        l_result   VARCHAR2(10);
        l_failed   BOOLEAN := FALSE;
        l_stopped  BOOLEAN := FALSE;
        l_dropped  NUMBER;
        l_tuning   VARCHAR2(4000);
        l_compacted    NUMBER;
        l_skipped      NUMBER;
        l_compact_stop BOOLEAN;
        l_start    TIMESTAMP := epf_util.now_ts;
        l_unmet    VARCHAR2(400);
    BEGIN
        init(p_run_id, 'PURGE');
        epf_log.set_phase('PURGE');
        EXECUTE IMMEDIATE 'ALTER SESSION SET ddl_lock_timeout = '
                          || TO_CHAR(TRUNC(epf_util.setting_num('ddl_lock_timeout_s')));
        -- The work keys (temporary table EPF_WORK_KEY) keep their undo in the
        -- temporary tablespace: no redo, no undo tablespace growth for them.
        -- Effective when set before the session's first use of a temporary table.
        EXECUTE IMMEDIATE 'ALTER SESSION SET temp_undo_enabled = TRUE';
        plan_steps;
        scope_event;
        l_tuning := undo_tuning_text;
        epf_log.info('UNDO_TUNING',
                     CASE WHEN l_tuning IS NOT NULL THEN 'Undo tuning active: ' || l_tuning
                          WHEN g_run.dry_run = 'Y' THEN
                              'Dry run: nothing is deleted, so no undo is written'
                              || CASE WHEN g_run.with_undo_tuning = 'Y' THEN '; undo tuning is planned for the purge' END
                          ELSE 'Undo tuning not applied: the undo tablespace keeps undo for undo_retention and may '
                               || 'grow during the purge (preflight step UNDO)' END);

        epf_log.step_start('REGISTRY');
        epf_registry.validate(l_errors, l_warnings);
        g_warnings := g_warnings + l_warnings;
        IF l_errors > 0 THEN
            epf_log.step_end('FAILED', l_errors || ' errors, ' || l_warnings || ' warnings');
            epf_log.step_skip_pending('registry validation failed');
            p_status := 'FAILED';
            RETURN;
        END IF;
        epf_log.step_end('DONE', l_errors || ' errors, ' || l_warnings || ' warnings');

        -- A purge that deletes starts only when the preflight of the run found
        -- every blocking requirement met or confirmed (no preflight: no gate).
        IF g_run.dry_run = 'N' THEN
            SELECT LISTAGG(req_code, ', ') WITHIN GROUP (ORDER BY seq)
              INTO l_unmet
              FROM epf_requirement
             WHERE run_id = p_run_id AND blocking = 'Y' AND status = 'NOT_MET';
            IF l_unmet IS NOT NULL THEN
                epf_log.error('REQUIREMENTS_NOT_MET', 'The purge did not start: blocking requirements not met: '
                                                      || l_unmet || ' (REQUIREMENTS in the report: ways to meet them)');
                epf_log.step_skip_pending('blocking requirements not met');
                p_status := 'FAILED';
                RETURN;
            END IF;
        END IF;

        BEGIN
            epf_log.step_start('PREPARE');
            drop_temp_indexes(TRUE, l_dropped);
            EXECUTE IMMEDIATE 'TRUNCATE TABLE epf_work_key';
            epf_log.step_end('DONE', l_dropped || ' leftover temporary indexes dropped');
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                epf_log.step_skip_pending('preparation failed');
                p_status := 'FAILED';
                RETURN;
        END;

        IF NOT capture_space(epf_space.c_baseline, 'SPACE_BASELINE') THEN
            l_failed := TRUE;
        END IF;

        FOR i IN 1 .. g_modules.COUNT LOOP
            IF epf_control.stop_requested(g_run.run_id) THEN
                l_stopped := TRUE;
                epf_log.warn('STOP_HONORED', 'Stopped before module ' || g_modules(i));
            END IF;
            EXIT WHEN l_stopped;
            process_module(g_modules(i), l_result);
            l_failed  := l_failed OR l_result = 'FAILED';
            l_stopped := l_result = 'STOPPED';
        END LOOP;

        IF g_run.dry_run = 'N' AND NOT capture_space(epf_space.c_post_purge, 'SPACE_POST_PURGE') THEN
            l_failed := TRUE;
        END IF;

        -- A dry run ends with its forecast, while the work keys still hold the
        -- roots that would be purged.
        IF g_run.dry_run = 'Y' AND NOT l_stopped AND NOT l_failed THEN
            BEGIN
                epf_log.step_start('FORECAST');
                forecast_dry_run;
                epf_log.step_end('DONE');
            EXCEPTION
                WHEN OTHERS THEN
                    fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                    l_failed := TRUE;
            END;
        END IF;

        IF g_run.with_compact = 'Y' AND NOT l_stopped THEN
            BEGIN
                epf_log.step_start('COMPACT');
                compact_tables(l_compacted, l_skipped, l_compact_stop);
                l_stopped := l_compact_stop;
                epf_log.step_end('DONE', l_compacted || ' tables compacted, ' || l_skipped || ' skipped'
                                         || CASE WHEN l_compact_stop THEN ', stopped on request' END);
            EXCEPTION
                WHEN OTHERS THEN
                    fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                    l_failed := TRUE;
            END;
            IF NOT capture_space(epf_space.c_post_compact, 'SPACE_POST_COMPACT') THEN
                l_failed := TRUE;
            END IF;
        END IF;

        BEGIN
            epf_log.step_start('CLEANUP');
            EXECUTE IMMEDIATE 'TRUNCATE TABLE epf_work_key';
            epf_log.step_end('DONE', 'work keys released');
        EXCEPTION
            WHEN OTHERS THEN
                fail_step(SQLCODE, SQLERRM, DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
                l_failed := TRUE;
        END;

        epf_log.step_skip_pending(CASE WHEN l_stopped THEN 'stop requested'
                                       WHEN l_failed THEN 'an earlier step failed' END);
        IF undo_tuning_text IS NOT NULL THEN
            epf_log.info('UNDO_TUNING', 'Undo tuning is still active; restore it with src/sql/run/undo.sql RESTORE '
                                        || 'as SYS');
        END IF;
        p_status := CASE WHEN l_failed THEN 'FAILED'
                         WHEN l_stopped THEN 'STOPPED'
                         WHEN g_warnings > 0 THEN 'WARNING'
                         ELSE 'SUCCESS' END;
        epf_log.event(CASE p_status WHEN 'SUCCESS' THEN epf_log.c_ok WHEN 'FAILED' THEN epf_log.c_error
                                    ELSE epf_log.c_warn END,
                      'PURGE_END',
                      'Purge ' || p_status || CASE WHEN g_run.dry_run = 'Y' THEN ' (dry run)' END
                      || ' in ' || epf_util.fmt_duration(epf_util.elapsed_s(l_start))
                      || CASE WHEN g_warnings > 0 THEN ', ' || g_warnings || ' warnings' END,
                      p_elapsed_s => epf_util.elapsed_s(l_start));
    END run;

END epf_purge;
/

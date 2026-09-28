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

    PROCEDURE count_tables(p_module IN VARCHAR2, p_action IN VARCHAR2, p_phase IN VARCHAR2,
                           p_processed IN t_numbers) IS
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
                                        nonempty_lob_rows, processed_rows, held_rows)
            VALUES (l_run, l_tid, p_phase, l_total, l_eligible, l_total - l_eligible,
                    l_lob, l_processed, l_held);
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
                epf_log.event(CASE WHEN NVL(l_residual, 0) = 0 THEN epf_log.c_ok ELSE epf_log.c_warn END,
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
                count_tables(p_module, l_action, 'AFTER', l_processed);
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
    -- this database (TREE_REDO events), otherwise estimated from optimizer
    -- statistics (rows per root of each table x row_redo_estimate).
    PROCEDURE tree_redo(p_root_id IN NUMBER, p_per_root OUT NUMBER, p_source OUT VARCHAR2) IS
        l_owner     VARCHAR2(128) := g_tables(p_root_id).owner;
        l_table     VARCHAR2(128) := g_tables(p_root_id).table_name;
        l_ids       SYS.ODCINUMBERLIST := tree_tables(p_root_id);
        l_run       NUMBER;
        l_root_rows NUMBER;
        l_rows      NUMBER;
        l_t_owner   VARCHAR2(128);
        l_t_table   VARCHAR2(128);
    BEGIN
        SELECT MAX(bytes / rows_affected) KEEP (DENSE_RANK LAST ORDER BY event_id),
               MAX(run_id) KEEP (DENSE_RANK LAST ORDER BY event_id)
          INTO p_per_root, l_run
          FROM epf_event
         WHERE event_code = 'TREE_REDO'
           AND object_owner = l_owner AND object_name = l_table
           AND rows_affected > 0 AND bytes > 0;
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

    -- Online redo logs against the redo a batch writes. The recommended batch
    -- size keeps one batch within half of the smallest online log, so a batch
    -- causes at most one log switch. A batch larger than a whole log is a
    -- warning: the session then waits on 'log file switch (checkpoint
    -- incomplete)'; larger online logs remove those waits, a smaller batch
    -- only spreads them.
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
        SELECT NVL(SUM(cnt), 0), NVL(MAX(cnt), 0)
          INTO l_switches, l_peak
          FROM (SELECT COUNT(*) AS cnt
                  FROM v$log_history
                 WHERE first_time > SYSDATE - 1
                 GROUP BY TRUNC(first_time, 'HH24'));
        epf_log.event(epf_log.c_info, 'REDO_LOGS',
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
                          OR NOT g_tables(r.table_id).reachable
                          OR module_action(g_tables(r.table_id).module_code) <> c_delete;
            tree_redo(r.table_id, l_per_root, l_source);
            IF l_per_root IS NULL THEN
                epf_log.event(epf_log.c_info, 'REDO_ESTIMATE', 'No redo estimate: ' || l_source,
                              p_object_owner => g_tables(r.table_id).owner,
                              p_object_name => g_tables(r.table_id).table_name);
                CONTINUE;
            END IF;
            l_batch_redo := l_per_root * g_run.batch_size;
            l_recommend  := round_batch(0.5 * l_min_log / l_per_root);
            l_overall    := LEAST(NVL(l_overall, l_recommend), l_recommend);
            IF l_batch_redo > l_min_log THEN
                l_over := TRUE;
            END IF;
            epf_log.event(CASE WHEN l_batch_redo > l_min_log THEN epf_log.c_warn ELSE epf_log.c_info END,
                          'REDO_ESTIMATE',
                          'about ' || epf_util.fmt_bytes(l_per_root) || ' redo per root (' || l_source || '): '
                          || epf_util.fmt_bytes(l_batch_redo) || ' per batch of ' || epf_util.fmt_int(g_run.batch_size)
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
            epf_log.event(CASE WHEN l_over THEN epf_log.c_warn ELSE epf_log.c_ok END, 'REDO_SUMMARY',
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
    -- kept for undo_retention is estimated as rate x undo_retention: when that
    -- exceeds the current size, the undo tablespace grows during the purge
    -- unless undo tuning is applied.
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
        l_per_root  NUMBER;
        l_rate      NUMBER;
        l_run       NUMBER;
        l_redo      NUMBER;
        l_source    VARCHAR2(400);
        l_batch     NUMBER;
        l_kept      NUMBER;
        l_warn      BOOLEAN;
    BEGIN
        SELECT UPPER(value) INTO l_ts FROM v$parameter WHERE name = 'undo_tablespace';
        SELECT TO_NUMBER(value) INTO l_retention FROM v$parameter WHERE name = 'undo_retention';
        SELECT MAX(tuned_undoretention) INTO l_tuned FROM v$undostat WHERE begin_time > SYSDATE - 1;
        SELECT SUM(bytes), SUM(CASE WHEN autoextensible = 'YES' THEN GREATEST(maxbytes, bytes) ELSE bytes END)
          INTO l_size, l_max
          FROM dba_data_files
         WHERE tablespace_name = l_ts;
        SELECT MAX(retention) INTO l_guarantee FROM dba_tablespaces WHERE tablespace_name = l_ts;
        epf_log.event(epf_log.c_info, 'UNDO',
                      l_ts || ' ' || epf_util.fmt_bytes(l_size) || ', can grow to ' || epf_util.fmt_bytes(l_max)
                      || '; undo_retention ' || l_retention || ' s (tuned up to ' || NVL(TO_CHAR(l_tuned), '-')
                      || ' s in the last 24 hours), retention ' || LOWER(l_guarantee)
                      || CASE WHEN l_tuning IS NOT NULL THEN '; undo tuning active: ' || l_tuning
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
            SELECT MAX(bytes / rows_affected) KEEP (DENSE_RANK LAST ORDER BY event_id),
                   MAX(bytes / GREATEST(elapsed_s, 1)) KEEP (DENSE_RANK LAST ORDER BY event_id),
                   MAX(run_id) KEEP (DENSE_RANK LAST ORDER BY event_id)
              INTO l_per_root, l_rate, l_run
              FROM epf_event
             WHERE event_code = 'TREE_UNDO'
               AND object_owner = l_owner AND object_name = l_table
               AND rows_affected > 0 AND bytes > 0;
            IF l_per_root IS NOT NULL THEN
                l_source := 'measured by ' || epf_util.run_label(l_run);
            ELSE
                tree_redo(r.table_id, l_redo, l_source);
                CONTINUE WHEN l_redo IS NULL;
                l_per_root := 0.45 * l_redo;
                l_source   := 'estimated from the redo, ' || l_source;
                l_rate     := NULL;
            END IF;
            l_batch := l_per_root * g_run.batch_size;
            l_kept  := l_rate * l_retention;
            l_warn  := l_batch > 0.5 * l_max OR (l_tuning IS NULL AND l_kept > l_size);
            IF l_warn THEN
                g_warnings := g_warnings + 1;
            END IF;
            epf_log.event(CASE WHEN l_warn THEN epf_log.c_warn ELSE epf_log.c_info END, 'UNDO_ESTIMATE',
                          'about ' || epf_util.fmt_bytes(l_per_root) || ' undo per root (' || l_source || '): '
                          || epf_util.fmt_bytes(l_batch) || ' per batch of ' || epf_util.fmt_int(g_run.batch_size)
                          || CASE WHEN l_kept IS NOT NULL THEN
                                 '; at ' || epf_util.fmt_bytes(l_rate) || '/s, undo_retention ' || l_retention
                                 || ' s keeps about ' || epf_util.fmt_bytes(l_kept)
                             END
                          || CASE WHEN l_batch > 0.5 * l_max THEN
                                 '; a batch needs more than half of what ' || l_ts || ' can hold: lower the batch size'
                             END
                          || CASE WHEN l_tuning IS NULL AND l_kept > l_size THEN
                                 '; ' || l_ts || ' grows during the purge (up to ' || epf_util.fmt_bytes(l_max)
                                 || ') unless undo tuning is applied (undo.sql APPLY as SYS)'
                             END,
                          p_object_owner => l_owner, p_object_name => l_table, p_bytes => l_per_root);
        END LOOP;
    END check_undo;

    PROCEDURE check_roots IS
        l_total    NUMBER;
        l_eligible NUMBER;
    BEGIN
        FOR r IN (SELECT e.table_id
                    FROM epf_table e
                    JOIN epf_module m ON m.module_code = e.module_code
                   WHERE e.active = 'Y' AND e.role = 'ROOT'
                   ORDER BY m.display_order, e.table_id) LOOP
            CONTINUE WHEN NOT in_scope(g_tables(r.table_id).module_code) OR NOT g_tables(r.table_id).reachable;
            EXECUTE IMMEDIATE 'SELECT COUNT(*), COUNT(CASE WHEN t.' || qc(g_tables(r.table_id).date_column)
                              || ' < ' || cutoff_literal || ' THEN 1 END) FROM ' || tq(r.table_id) || ' t'
                INTO l_total, l_eligible;
            epf_log.event(epf_log.c_info, 'ROOTS_ELIGIBLE',
                          epf_util.fmt_int(l_eligible) || ' of ' || epf_util.fmt_int(l_total) || ' rows before '
                          || cutoff_text || ' (' || g_tables(r.table_id).module_code || ')',
                          p_object_owner => g_tables(r.table_id).owner,
                          p_object_name => g_tables(r.table_id).table_name, p_rows => l_eligible);
        END LOOP;
    END check_roots;

    -- ------------------------------------------------------------------
    -- Public
    -- ------------------------------------------------------------------

    PROCEDURE preflight(p_run_id IN NUMBER, p_errors OUT PLS_INTEGER, p_warnings OUT PLS_INTEGER) IS
        l_errors   PLS_INTEGER;
        l_warnings PLS_INTEGER;
    BEGIN
        init(p_run_id, 'PURGE,PREFLIGHT');
        scope_event;

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
        END IF;
        p_warnings := l_warnings + g_warnings;
    END preflight;

    PROCEDURE run(p_run_id IN NUMBER, p_status OUT VARCHAR2) IS
        l_errors   PLS_INTEGER;
        l_warnings PLS_INTEGER;
        l_result   VARCHAR2(10);
        l_failed   BOOLEAN := FALSE;
        l_stopped  BOOLEAN := FALSE;
        l_dropped  NUMBER;
        l_tuning   VARCHAR2(4000);
        l_start    TIMESTAMP := epf_util.now_ts;
    BEGIN
        init(p_run_id, 'PURGE');
        epf_log.set_phase('PURGE');
        EXECUTE IMMEDIATE 'ALTER SESSION SET ddl_lock_timeout = '
                          || TO_CHAR(TRUNC(epf_util.setting_num('ddl_lock_timeout_s')));
        plan_steps;
        scope_event;
        l_tuning := undo_tuning_text;
        epf_log.info('UNDO_TUNING',
                     CASE WHEN l_tuning IS NOT NULL THEN 'Undo tuning active: ' || l_tuning
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

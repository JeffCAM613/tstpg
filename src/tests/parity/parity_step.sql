-- ============================================================================
-- EPF Data Purge - Parity snapshot step (called by parity.sql)
-- ============================================================================
-- Arguments: <owner> <table>   row classes of one table, and with scope CLOB
--                              the non-empty LOB values per column and class
--            HEAD -            snapshot header
--            FKS -             enabled foreign keys into the 27 tables
--            RUNS -            purge runs recorded by both tools
-- Uses p_label, p_cutoff and p_scope, defined by parity.sql.
--
-- Row class: four flags, '-' when not set.
--   D  the previous tool deletes the row (FULL), by its rules in
--      legacy/sql/03_epf_purge_pkg_body.sql
--   X  the row is not D but references a D row through an ON DELETE CASCADE
--      foreign key: deleting that row deletes it too
--   N  this tool selects the row through the registry links
--      (src/sql/install/registry_data.sql), before any row is held back
--   C  the previous tool clears the LOB values of the row (CLOB_ONLY,
--      CLOB_N_LOGS)
-- Checksum: sum over the rows of ORA_HASH of the primary key (otherwise the
-- first unique key, otherwise every column that is not a LOB or LONG).
--
-- Output lines (all start with PARITY|)
--   HEAD|<label>|<db>|<cutoff>|<scope>|<taken at>|<version>
--   KEY|<table>|<key used for the checksum>
--   ROWS|<table>|<class>|<rows>|<checksum>
--   LOB|<table>|<column>|<class>|<non-empty values>|<checksum of their rows>
--   TIME|<table>|<seconds>
--   MISSING|<table>            ERROR|<step>|<message>
--   FK|<child>|<constraint>|<delete rule>|<parent>|<rows>|COVERED
--       rows of the child that are not deleted with the parent row they
--       reference (D of the child, or X for NO ACTION and SET NULL), while
--       that parent row is D; COVERED when the child's own rule follows
--       the key, so no such row can exist
--   LEGACYRUN|<run>|<started>|<message>   LEGACYEND|<run>|<status>|<at>|<text>
--   LEGACYERR|<run>|<module>|<table>|<code>|<message>
--   NEWRUN|<run>|<status>|<verdict>|<cutoff>|<depth>|<mode>|<dry run>|<created>
--   NEWHELD|<run>|<table>|<held rows>
-- ============================================================================
DECLARE
    c_cut   CONSTANT VARCHAR2(40)  := 'DATE ''&p_cutoff''';
    c_scope CONSTANT VARCHAR2(10)  := '&p_scope';
    c_label CONSTANT VARCHAR2(30)  := '&p_label';
    c_step  CONSTANT VARCHAR2(128) := UPPER('&1');
    c_arg   CONSTANT VARCHAR2(128) := UPPER('&2');

    TYPE t_def IS RECORD (
        owner      VARCHAR2(128),
        table_name VARCHAR2(128),
        joins      VARCHAR2(8000),
        del_pred   VARCHAR2(1000),
        new_pred   VARCHAR2(1000),
        clr_pred   VARCHAR2(1000),
        covers     VARCHAR2(1000)
    );
    TYPE t_defs  IS TABLE OF t_def INDEX BY VARCHAR2(260);
    TYPE t_lines IS TABLE OF VARCHAR2(32767);

    g_defs t_defs;
    -- Keys the previous tool selects, by its rules (one column k, distinct).
    l_ebp  VARCHAR2(1000);
    l_epay VARCHAR2(1000);
    l_eia  VARCHAR2(1000);
    l_eweo VARCHAR2(1000);
    l_ewe  VARCHAR2(2000);
    l_einv VARCHAR2(2000);
    l_earc VARCHAR2(1000);
    l_efd  VARCHAR2(1000);
    l_efdd VARCHAR2(1000);
    c_bp   CONSTANT VARCHAR2(100) := 'BULK_PAYMENT_ID>OPPAYMENTS.BULK_PAYMENT';
    c_pay  CONSTANT VARCHAR2(100) := 'PAYMENT_ID>OPPAYMENTS.PAYMENT';

    PROCEDURE emit(p_text IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE('PARITY|' || p_text);
    END emit;

    FUNCTION qc(p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN '"' || p_name || '"';
    END qc;

    FUNCTION qn(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN qc(p_owner) || '.' || qc(p_table);
    END qn;

    FUNCTION field(p_text IN VARCHAR2, p_n IN PLS_INTEGER) RETURN VARCHAR2 IS
    BEGIN
        RETURN REGEXP_SUBSTR(p_text, '[^|]+', 1, p_n);
    END field;

    FUNCTION clean(p_text IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN REPLACE(REPLACE(SUBSTR(p_text, 1, 400), '|', '/'), CHR(10), ' ');
    END clean;

    -- Left join of key set p_set (column k) on column p_column of t.
    FUNCTION kj(p_alias IN VARCHAR2, p_set IN VARCHAR2, p_column IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN ' LEFT JOIN (' || p_set || ') ' || p_alias || ' ON ' || p_alias || '.k = t.' || p_column;
    END kj;

    -- p_del: deleted by the previous tool (FULL); p_new: selected by this
    -- tool (default p_del); p_clr: LOB values cleared by the previous tool
    -- (default p_del); p_covers: column>parent pairs the table's own rule
    -- follows.
    PROCEDURE def(p_table IN VARCHAR2, p_joins IN VARCHAR2, p_del IN VARCHAR2,
                  p_new IN VARCHAR2 DEFAULT NULL, p_clr IN VARCHAR2 DEFAULT NULL,
                  p_covers IN VARCHAR2 DEFAULT NULL, p_owner IN VARCHAR2 DEFAULT 'OPPAYMENTS') IS
        l_def t_def;
    BEGIN
        l_def.owner      := p_owner;
        l_def.table_name := p_table;
        l_def.joins      := p_joins;
        l_def.del_pred   := p_del;
        l_def.new_pred   := NVL(p_new, p_del);
        l_def.clr_pred   := NVL(p_clr, p_del);
        l_def.covers     := p_covers;
        g_defs(p_owner || '.' || p_table) := l_def;
    END def;

    FUNCTION present(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN BOOLEAN IS
        l_n NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_n FROM dba_tables WHERE owner = p_owner AND table_name = p_table;
        RETURN l_n > 0;
    END present;

    -- Text of a key column for the checksum; NULL for types left out.
    FUNCTION conv(p_column IN VARCHAR2, p_type IN VARCHAR2) RETURN VARCHAR2 IS
        l_col VARCHAR2(200) := 't.' || qc(p_column);
    BEGIN
        IF p_type IN ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR') THEN
            RETURN l_col;
        ELSIF p_type = 'DATE' THEN
            RETURN 'TO_CHAR(' || l_col || ', ''YYYYMMDDHH24MISS'')';
        ELSIF p_type LIKE 'TIMESTAMP%' THEN
            RETURN 'TO_CHAR(' || l_col || ', ''YYYYMMDDHH24MISSFF9'')';
        ELSIF p_type = 'RAW' THEN
            RETURN 'RAWTOHEX(' || l_col || ')';
        ELSIF p_type IN ('NUMBER', 'FLOAT', 'BINARY_FLOAT', 'BINARY_DOUBLE') THEN
            RETURN 'TO_CHAR(' || l_col || ')';
        END IF;
        RETURN NULL;
    END conv;

    -- Hash of the key of a row of t; p_desc names the key used.
    FUNCTION key_expr(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_desc OUT VARCHAR2) RETURN VARCHAR2 IS
        l_cons  VARCHAR2(128);
        l_parts VARCHAR2(32767);
        l_cols  VARCHAR2(4000);
        l_one   VARCHAR2(4000);
    BEGIN
        SELECT MAX(constraint_name) KEEP (DENSE_RANK FIRST ORDER BY DECODE(constraint_type, 'P', 0, 1), constraint_name)
          INTO l_cons
          FROM dba_constraints
         WHERE owner = p_owner AND table_name = p_table
           AND constraint_type IN ('P', 'U') AND status = 'ENABLED';
        IF l_cons IS NOT NULL THEN
            FOR c IN (SELECT tc.column_name, tc.data_type
                        FROM dba_cons_columns cc
                        JOIN dba_tab_columns tc
                          ON tc.owner = cc.owner AND tc.table_name = cc.table_name AND tc.column_name = cc.column_name
                       WHERE cc.owner = p_owner AND cc.constraint_name = l_cons
                       ORDER BY cc.position) LOOP
                l_one := conv(c.column_name, c.data_type);
                IF l_one IS NOT NULL THEN
                    l_parts := l_parts || CASE WHEN l_parts IS NOT NULL THEN ' || ''|'' || ' END
                               || 'ORA_HASH(NVL(' || l_one || ', ''~''))';
                    l_cols  := l_cols || CASE WHEN l_cols IS NOT NULL THEN ', ' END || c.column_name;
                END IF;
            END LOOP;
            p_desc := l_cons || ' (' || l_cols || ')';
        END IF;
        IF l_parts IS NULL THEN
            FOR c IN (SELECT column_name, data_type
                        FROM dba_tab_columns
                       WHERE owner = p_owner AND table_name = p_table
                       ORDER BY column_id) LOOP
                l_one := conv(c.column_name, c.data_type);
                IF l_one IS NOT NULL THEN
                    l_parts := l_parts || CASE WHEN l_parts IS NOT NULL THEN ' || ''|'' || ' END
                               || 'ORA_HASH(NVL(' || l_one || ', ''~''))';
                END IF;
            END LOOP;
            p_desc := 'all columns except LOB and LONG (no primary or unique key)';
        END IF;
        RETURN 'ORA_HASH(' || l_parts || ', 4294967295, 7)';
    END key_expr;

    -- Columns of foreign key p_cons: p_select lists the referenced parent
    -- columns as c1..cn, p_on joins alias p_alias to t, p_child lists the
    -- child columns.
    PROCEDURE fk_cols(p_owner IN VARCHAR2, p_cons IN VARCHAR2, p_powner IN VARCHAR2, p_pcons IN VARCHAR2,
                      p_alias IN VARCHAR2, p_select OUT VARCHAR2, p_on OUT VARCHAR2, p_child OUT VARCHAR2) IS
        l_n PLS_INTEGER := 0;
    BEGIN
        FOR c IN (SELECT cc.column_name AS c_col, pc.column_name AS p_col
                    FROM dba_cons_columns cc
                    JOIN dba_cons_columns pc
                      ON pc.owner = p_powner AND pc.constraint_name = p_pcons AND pc.position = cc.position
                   WHERE cc.owner = p_owner AND cc.constraint_name = p_cons
                   ORDER BY cc.position) LOOP
            l_n := l_n + 1;
            p_select := p_select || CASE WHEN l_n > 1 THEN ', ' END || 't.' || qc(c.p_col) || ' AS c' || l_n;
            p_on     := p_on || CASE WHEN l_n > 1 THEN ' AND ' END || p_alias || '.c' || l_n || ' = t.' || qc(c.c_col);
            p_child  := p_child || CASE WHEN l_n > 1 THEN ',' END || c.c_col;
        END LOOP;
    END fk_cols;

    -- Values of the referenced columns (p_select) of the D rows of p_name.
    FUNCTION dset(p_name IN VARCHAR2, p_select IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN 'SELECT DISTINCT ' || p_select || ' FROM ' || qn(g_defs(p_name).owner, g_defs(p_name).table_name)
               || ' t' || g_defs(p_name).joins || ' WHERE ' || g_defs(p_name).del_pred;
    END dset;

    -- The table's own rule already follows foreign key column p_child to
    -- p_parent: a row referencing a D row is D itself.
    FUNCTION covered(p_name IN VARCHAR2, p_child IN VARCHAR2, p_parent IN VARCHAR2) RETURN BOOLEAN IS
    BEGIN
        IF NOT g_defs.EXISTS(p_name) OR g_defs(p_name).covers IS NULL OR INSTR(p_child, ',') > 0 THEN
            RETURN FALSE;
        END IF;
        RETURN INSTR(',' || g_defs(p_name).covers || ',', ',' || p_child || '>' || p_parent || ',') > 0;
    END covered;

    -- Joins and condition for X: an ON DELETE CASCADE foreign key of the
    -- table references a D row of one of the 27 tables.
    PROCEDURE cascade_x(p_name IN VARCHAR2, p_joins OUT VARCHAR2, p_x OUT VARCHAR2) IS
        l_owner  VARCHAR2(128) := g_defs(p_name).owner;
        l_table  VARCHAR2(128) := g_defs(p_name).table_name;
        l_i      PLS_INTEGER := 0;
        l_select VARCHAR2(4000);
        l_on     VARCHAR2(4000);
        l_child  VARCHAR2(4000);
        l_parent VARCHAR2(260);
    BEGIN
        p_x := '1 = 0';
        FOR f IN (SELECT c.owner, c.constraint_name, p.owner AS p_owner, p.table_name AS p_table,
                         p.constraint_name AS p_cons
                    FROM dba_constraints c
                    JOIN dba_constraints p
                      ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
                   WHERE c.owner = l_owner AND c.table_name = l_table
                     AND c.constraint_type = 'R' AND c.status = 'ENABLED' AND c.delete_rule = 'CASCADE'
                   ORDER BY c.constraint_name) LOOP
            l_parent := f.p_owner || '.' || f.p_table;
            CONTINUE WHEN NOT g_defs.EXISTS(l_parent);
            l_select := NULL;
            l_on     := NULL;
            l_child  := NULL;
            l_i      := l_i + 1;
            fk_cols(f.owner, f.constraint_name, f.p_owner, f.p_cons, 'kx' || l_i, l_select, l_on, l_child);
            CONTINUE WHEN covered(p_name, l_child, l_parent);
            p_joins := p_joins || ' LEFT JOIN (' || dset(l_parent, l_select) || ') kx' || l_i || ' ON ' || l_on;
            p_x     := p_x || ' OR kx' || l_i || '.c1 IS NOT NULL';
        END LOOP;
    END cascade_x;

    PROCEDURE head IS
        l_db  VARCHAR2(30);
        l_ver VARCHAR2(30);
    BEGIN
        SELECT name INTO l_db FROM v$database;
        SELECT version INTO l_ver FROM v$instance;
        emit('HEAD|' || c_label || '|' || l_db || '|&p_cutoff|' || c_scope || '|'
            || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') || '|' || l_ver);
    END head;

    PROCEDURE snap_table(p_name IN VARCHAR2) IS
        l_def    t_def;
        l_key    VARCHAR2(32767);
        l_desc   VARCHAR2(4000);
        l_xjoins VARCHAR2(32767);
        l_x      VARCHAR2(32767);
        l_inner  VARCHAR2(32767);
        l_outer  VARCHAR2(32767);
        l_lobs   SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        l_lines  t_lines;
        l_start  NUMBER := DBMS_UTILITY.GET_TIME;
    BEGIN
        IF NOT g_defs.EXISTS(p_name) THEN
            emit('ERROR|' || p_name || '|not one of the 27 tables the previous tool purges');
            RETURN;
        END IF;
        l_def := g_defs(p_name);
        IF NOT present(l_def.owner, l_def.table_name) THEN
            emit('MISSING|' || p_name);
            RETURN;
        END IF;
        l_key := key_expr(l_def.owner, l_def.table_name, l_desc);
        emit('KEY|' || p_name || '|' || l_desc);
        cascade_x(p_name, l_xjoins, l_x);
        IF c_scope = 'CLOB' THEN
            SELECT l.column_name BULK COLLECT INTO l_lobs
              FROM dba_lobs l
              JOIN dba_tab_columns c
                ON c.owner = l.owner AND c.table_name = l.table_name AND c.column_name = l.column_name
             WHERE l.owner = l_def.owner AND l.table_name = l_def.table_name
               AND c.data_type IN ('CLOB', 'NCLOB', 'BLOB')
             ORDER BY l.column_name;
        END IF;

        l_inner := 'SELECT CASE WHEN ' || l_def.del_pred || ' THEN ''D'' ELSE ''-'' END'
                || ' || CASE WHEN ' || l_def.del_pred || ' THEN ''-'' WHEN ' || l_x || ' THEN ''X'' ELSE ''-'' END'
                || ' || CASE WHEN ' || l_def.new_pred || ' THEN ''N'' ELSE ''-'' END'
                || ' || CASE WHEN ' || l_def.clr_pred || ' THEN ''C'' ELSE ''-'' END AS cls, '
                || l_key || ' AS h';
        FOR i IN 1 .. l_lobs.COUNT LOOP
            l_inner := l_inner || ', CASE WHEN DBMS_LOB.GETLENGTH(t.' || qc(l_lobs(i)) || ') > 0 THEN 1 ELSE 0 END AS l' || i;
        END LOOP;
        l_inner := l_inner || ' FROM ' || qn(l_def.owner, l_def.table_name) || ' t' || l_def.joins || l_xjoins;

        l_outer := 'SELECT cls || ''|'' || COUNT(*) || ''|'' || TO_CHAR(NVL(SUM(h), 0))';
        FOR i IN 1 .. l_lobs.COUNT LOOP
            l_outer := l_outer || ' || ''|'' || SUM(l' || i || ') || ''|'' || TO_CHAR(NVL(SUM(CASE WHEN l' || i
                       || ' = 1 THEN h END), 0))';
        END LOOP;
        l_outer := l_outer || ' FROM (' || l_inner || ') GROUP BY cls ORDER BY cls';

        EXECUTE IMMEDIATE l_outer BULK COLLECT INTO l_lines;
        FOR r IN 1 .. l_lines.COUNT LOOP
            emit('ROWS|' || p_name || '|' || field(l_lines(r), 1) || '|' || field(l_lines(r), 2) || '|' || field(l_lines(r), 3));
            FOR i IN 1 .. l_lobs.COUNT LOOP
                emit('LOB|' || p_name || '|' || l_lobs(i) || '|' || field(l_lines(r), 1) || '|'
                    || field(l_lines(r), 2 + 2 * i) || '|' || field(l_lines(r), 3 + 2 * i));
            END LOOP;
        END LOOP;
        emit('TIME|' || p_name || '|' || ROUND((DBMS_UTILITY.GET_TIME - l_start) / 100));
    EXCEPTION
        WHEN OTHERS THEN
            emit('ERROR|' || p_name || '|' || clean(SQLERRM));
    END snap_table;

    PROCEDURE snap_fks IS
        l_parent VARCHAR2(260);
        l_child  VARCHAR2(260);
        l_select VARCHAR2(4000);
        l_on     VARCHAR2(4000);
        l_cols   VARCHAR2(4000);
        l_xjoins VARCHAR2(32767);
        l_x      VARCHAR2(32767);
        l_sql    VARCHAR2(32767);
        l_rows   NUMBER;
        l_def    t_def;
    BEGIN
        FOR f IN (SELECT c.owner, c.table_name, c.constraint_name, c.delete_rule,
                         p.owner AS p_owner, p.table_name AS p_table, p.constraint_name AS p_cons
                    FROM dba_constraints c
                    JOIN dba_constraints p
                      ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
                   WHERE c.constraint_type = 'R' AND c.status = 'ENABLED'
                     AND p.owner IN ('OPPAYMENTS', 'OP')
                   ORDER BY p.owner, p.table_name, c.owner, c.table_name, c.constraint_name) LOOP
            l_parent := f.p_owner || '.' || f.p_table;
            CONTINUE WHEN NOT g_defs.EXISTS(l_parent);
            l_child  := f.owner || '.' || f.table_name;
            l_select := NULL;
            l_on     := NULL;
            l_cols   := NULL;
            fk_cols(f.owner, f.constraint_name, f.p_owner, f.p_cons, 'kp', l_select, l_on, l_cols);
            IF covered(l_child, l_cols, l_parent) THEN
                emit('FK|' || l_child || '|' || f.constraint_name || '|' || f.delete_rule || '|' || l_parent || '|0|COVERED');
                CONTINUE;
            END IF;
            BEGIN
                IF g_defs.EXISTS(l_child) THEN
                    l_def    := g_defs(l_child);
                    l_xjoins := NULL;
                    l_x      := NULL;
                    cascade_x(l_child, l_xjoins, l_x);
                    l_sql := 'SELECT COUNT(*) FROM ' || qn(l_def.owner, l_def.table_name) || ' t' || l_def.joins || l_xjoins
                             || ' JOIN (' || dset(l_parent, l_select) || ') kp ON ' || l_on
                             || ' WHERE CASE WHEN ' || l_def.del_pred || ' THEN 1'
                             || CASE WHEN f.delete_rule <> 'CASCADE' THEN ' WHEN ' || l_x || ' THEN 1' END
                             || ' ELSE 0 END = 0';
                ELSE
                    l_sql := 'SELECT COUNT(*) FROM ' || qn(f.owner, f.table_name) || ' t JOIN ('
                             || dset(l_parent, l_select) || ') kp ON ' || l_on;
                END IF;
                EXECUTE IMMEDIATE l_sql INTO l_rows;
                emit('FK|' || l_child || '|' || f.constraint_name || '|' || f.delete_rule || '|' || l_parent || '|' || l_rows || '|');
            EXCEPTION
                WHEN OTHERS THEN
                    emit('ERROR|FK ' || f.owner || '.' || f.constraint_name || '|' || clean(SQLERRM));
            END;
        END LOOP;
    END snap_fks;

    PROCEDURE snap_runs IS
        l_lines t_lines;
        l_last  VARCHAR2(64);
    BEGIN
        IF present('OPPAYMENTS', 'EPF_PURGE_LOG') THEN
            EXECUTE IMMEDIATE
                'SELECT RAWTOHEX(run_id) || ''|'' || TO_CHAR(log_timestamp, ''YYYY-MM-DD HH24:MI:SS'') || ''|'''
                || ' || NVL(REPLACE(message, ''|'', ''/''), ''-'')'
                || ' FROM (SELECT run_id, log_timestamp, message FROM oppayments.epf_purge_log'
                || ' WHERE operation = ''RUN_START'' ORDER BY log_timestamp DESC) WHERE ROWNUM <= 5'
                BULK COLLECT INTO l_lines;
            FOR i IN 1 .. l_lines.COUNT LOOP
                emit('LEGACYRUN|' || l_lines(i));
            END LOOP;
            IF l_lines.COUNT > 0 THEN
                l_last := field(l_lines(1), 1);
                EXECUTE IMMEDIATE
                    'SELECT status || ''|'' || TO_CHAR(log_timestamp, ''YYYY-MM-DD HH24:MI:SS'') || ''|'''
                    || ' || NVL(REPLACE(REPLACE(SUBSTR(NVL(error_message, message), 1, 400), ''|'', ''/''), CHR(10), '' ''), ''-'')'
                    || ' FROM oppayments.epf_purge_log WHERE run_id = HEXTORAW(:r) AND operation = ''RUN_END'''
                    || ' ORDER BY log_timestamp'
                    BULK COLLECT INTO l_lines USING l_last;
                FOR i IN 1 .. l_lines.COUNT LOOP
                    emit('LEGACYEND|' || l_last || '|' || l_lines(i));
                END LOOP;
                EXECUTE IMMEDIATE
                    'SELECT NVL(module, ''-'') || ''|'' || NVL(table_name, ''-'') || ''|'' || NVL(TO_CHAR(error_code), ''-'')'
                    || ' || ''|'' || NVL(REPLACE(REPLACE(SUBSTR(NVL(error_message, message), 1, 400), ''|'', ''/''), CHR(10), '' ''), ''-'')'
                    || ' FROM oppayments.epf_purge_log WHERE run_id = HEXTORAW(:r) AND status = ''ERROR'''
                    || ' ORDER BY log_timestamp'
                    BULK COLLECT INTO l_lines USING l_last;
                FOR i IN 1 .. LEAST(l_lines.COUNT, 20) LOOP
                    emit('LEGACYERR|' || l_last || '|' || l_lines(i));
                END LOOP;
            END IF;
        END IF;

        IF present('EPFPG', 'EPF_RUN') THEN
            EXECUTE IMMEDIATE
                'SELECT run_id || ''|'' || status || ''|'' || NVL(verdict, ''-'') || ''|'''
                || ' || NVL(TO_CHAR(cutoff_date, ''YYYY-MM-DD''), ''-'') || ''|'' || NVL(depth, ''-'') || ''|'''
                || ' || NVL(purge_mode, ''-'') || ''|'' || dry_run || ''|'' || TO_CHAR(created_at, ''YYYY-MM-DD HH24:MI:SS'')'
                || ' FROM (SELECT * FROM epfpg.epf_run WHERE action = ''PURGE'' ORDER BY run_id DESC) WHERE ROWNUM <= 10'
                BULK COLLECT INTO l_lines;
            FOR i IN 1 .. l_lines.COUNT LOOP
                emit('NEWRUN|' || l_lines(i));
            END LOOP;
            IF present('EPFPG', 'EPF_TABLE_STAT') THEN
                EXECUTE IMMEDIATE
                    'SELECT s.run_id || ''|'' || t.owner || ''.'' || t.table_name || ''|'' || MAX(s.held_rows)'
                    || ' FROM epfpg.epf_table_stat s'
                    || ' JOIN epfpg.epf_table t ON t.table_id = s.table_id'
                    || ' JOIN epfpg.epf_run r ON r.run_id = s.run_id AND r.action = ''PURGE'' AND r.dry_run = ''N'''
                    || ' WHERE s.held_rows > 0'
                    || ' GROUP BY s.run_id, t.owner, t.table_name ORDER BY s.run_id, t.owner, t.table_name'
                    BULK COLLECT INTO l_lines;
                FOR i IN 1 .. l_lines.COUNT LOOP
                    emit('NEWHELD|' || l_lines(i));
                END LOOP;
            END IF;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            emit('ERROR|RUNS|' || clean(SQLERRM));
    END snap_runs;
BEGIN
    l_ebp  := 'SELECT DISTINCT bulk_payment_id AS k FROM oppayments.bulk_payment WHERE value_date < ' || c_cut;
    l_epay := 'SELECT DISTINCT payment_id AS k FROM oppayments.payment WHERE bulk_payment_id IN (' || l_ebp || ')';
    l_eia  := 'SELECT DISTINCT import_audit_id AS k FROM oppayments.import_audit WHERE bulk_payment_id IN (' || l_ebp || ')';
    l_eweo := 'SELECT DISTINCT execution_id AS k FROM oppayments.workflow_execution_opt WHERE bulk_payment_id IN ('
              || l_ebp || ')';
    l_ewe  := 'SELECT DISTINCT execution_id AS k FROM oppayments.workflow_execution WHERE payment_id IN (' || l_epay || ')';
    l_einv := 'SELECT DISTINCT invoice_id AS k FROM oppayments.invoice WHERE payment_id IN (' || l_epay || ')';
    l_earc := 'SELECT DISTINCT audit_archive_id AS k FROM oppayments.audit_trail WHERE audit_timestamp < ' || c_cut;
    l_efd  := 'SELECT DISTINCT file_dispatching_id AS k FROM oppayments.file_dispatching WHERE date_reception < ' || c_cut;
    l_efdd := 'SELECT DISTINCT dd.file_dispatching_id AS k FROM oppayments.directory_dispatching dd'
              || ' JOIN oppayments.file_dispatching fd ON fd.file_dispatching_id = dd.file_dispatching_id'
              || ' WHERE fd.date_reception < ' || c_cut;

    -- PAYMENTS (purge_bulk_payments, purge_file_integrations)
    def('BULK_PAYMENT_ADDITIONAL_INFO', kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('BULK_SIGNATURE',               kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('MANDATORY_SIGNERS',            kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('OIDC_REQUEST_TOKEN',           kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    -- Deleted by bulk payment and by payment; LOB values cleared by bulk
    -- payment only.
    def('PAYMENT_AUDIT', kj('k1', l_ebp, 'bulk_payment_id') || kj('k2', l_epay, 'payment_id'),
        '(k1.k IS NOT NULL OR k2.k IS NOT NULL)', p_clr => 'k1.k IS NOT NULL', p_covers => c_bp || ',' || c_pay);
    def('TRANSMISSION_EXECUTION_AUDIT', kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('IMPORT_AUDIT_MESSAGES', kj('k1', l_eia, 'import_audit_id'), 'k1.k IS NOT NULL',
        p_covers => 'IMPORT_AUDIT_ID>OPPAYMENTS.IMPORT_AUDIT');
    def('NOTIFICATION_EXECUTION',       kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('IMPORT_AUDIT',                 kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('TRANSMISSION_EXECUTION',       kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('TRANSMISSION_EXCEPTION',       kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('APPROBATION_EXECUTION_OPT', kj('k1', l_eweo, 'execution_id'), 'k1.k IS NOT NULL',
        p_covers => 'EXECUTION_ID>OPPAYMENTS.WORKFLOW_EXECUTION_OPT');
    def('WORKFLOW_EXECUTION_OPT',       kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('APPROBATION_EXECUTION', kj('k1', l_ewe, 'execution_id'), 'k1.k IS NOT NULL',
        p_covers => 'EXECUTION_ID>OPPAYMENTS.WORKFLOW_EXECUTION');
    def('WORKFLOW_EXECUTION',           kj('k1', l_epay, 'payment_id'), 'k1.k IS NOT NULL', p_covers => c_pay);
    def('BULKPAYMENT_EXCEPTION',        kj('k1', l_epay, 'payment_id'), 'k1.k IS NOT NULL', p_covers => c_pay);
    def('INVOICE_ADDITIONAL_INFO', kj('k1', l_einv, 'invoice_id'), 'k1.k IS NOT NULL',
        p_covers => 'INVOICE_ID>OPPAYMENTS.INVOICE');
    def('INVOICE',                      kj('k1', l_epay, 'payment_id'), 'k1.k IS NOT NULL', p_covers => c_pay);
    def('PAYMENT_ADDITIONAL_INFO',      kj('k1', l_epay, 'payment_id'), 'k1.k IS NOT NULL', p_covers => c_pay);
    def('PAYMENT',                      kj('k1', l_ebp, 'bulk_payment_id'), 'k1.k IS NOT NULL', p_covers => c_bp);
    def('BULK_PAYMENT', NULL, 't.value_date < ' || c_cut);
    def('FILE_INTEGRATION', NULL, 't.integration_date < ' || c_cut);

    -- LOGS (purge_audit_logs, purge_tech_logs)
    def('AUDIT_ARCHIVE', kj('k1', l_earc, 'audit_archive_id'), 'k1.k IS NOT NULL');
    def('AUDIT_TRAIL', NULL, 't.audit_timestamp < ' || c_cut);
    def('SPEC_TRT_LOG', NULL, 't.dtlog < ' || c_cut, p_owner => 'OP');

    -- BANK_STATEMENTS (purge_bank_statements): the previous tool selects
    -- the files that have directory rows; this tool every file before the
    -- cutoff.
    def('DIRECTORY_DISPATCHING', kj('k1', l_efd, 'file_dispatching_id'), 'k1.k IS NOT NULL',
        p_covers => 'FILE_DISPATCHING_ID>OPPAYMENTS.FILE_DISPATCHING');
    def('FILE_DISPATCHING', kj('k1', l_efdd, 'file_dispatching_id'), 'k1.k IS NOT NULL',
        p_new => 't.date_reception < ' || c_cut);

    IF c_step = 'HEAD' THEN
        head;
    ELSIF c_step = 'FKS' THEN
        snap_fks;
    ELSIF c_step = 'RUNS' THEN
        snap_runs;
    ELSE
        snap_table(c_step || '.' || c_arg);
    END IF;
END;
/

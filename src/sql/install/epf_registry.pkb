CREATE OR REPLACE PACKAGE BODY epf_registry AS

    PROCEDURE validate(p_errors OUT PLS_INTEGER, p_warnings OUT PLS_INTEGER) IS
        l_tool       VARCHAR2(128) := $$PLSQL_UNIT_OWNER;
        l_tables     PLS_INTEGER := 0;
        l_present    PLS_INTEGER := 0;
        l_links      PLS_INTEGER := 0;
        l_fks        PLS_INTEGER := 0;
        l_fk_covered PLS_INTEGER := 0;
        l_count      PLS_INTEGER;
        l_label      VARCHAR2(1000);

        PROCEDURE add_error(p_code IN VARCHAR2, p_message IN VARCHAR2,
                            p_owner IN VARCHAR2 DEFAULT NULL, p_object IN VARCHAR2 DEFAULT NULL) IS
        BEGIN
            p_errors := p_errors + 1;
            epf_log.error(p_code, p_message, p_owner, p_object);
        END add_error;

        PROCEDURE add_warning(p_code IN VARCHAR2, p_message IN VARCHAR2,
                              p_owner IN VARCHAR2 DEFAULT NULL, p_object IN VARCHAR2 DEFAULT NULL) IS
        BEGIN
            p_warnings := p_warnings + 1;
            epf_log.warn(p_code, p_message, p_owner, p_object);
        END add_warning;

        PROCEDURE check_column(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_column IN VARCHAR2,
                               p_role IN VARCHAR2) IS
        BEGIN
            IF p_column IS NOT NULL AND NOT epf_util.column_exists(p_owner, p_table, p_column) THEN
                add_error('REG_COLUMN_MISSING', p_role || ' column ' || p_column || ' not found',
                          p_owner, p_table);
            END IF;
        END check_column;
    BEGIN
        p_errors   := 0;
        p_warnings := 0;

        -- Tables: presence, columns, grants, role consistency.
        FOR t IN (SELECT e.table_id, e.owner, e.table_name, e.role, e.root_table_id,
                         e.key_column, e.date_column,
                         (SELECT COUNT(*) FROM dba_tables d
                           WHERE d.owner = e.owner AND d.table_name = e.table_name) AS present,
                         (SELECT COUNT(*) FROM epf_link k WHERE k.table_id = e.table_id) AS links
                    FROM epf_table e
                   WHERE e.active = 'Y'
                   ORDER BY e.table_id) LOOP
            l_tables := l_tables + 1;

            IF t.role = 'ROOT' AND (t.date_column IS NULL OR t.root_table_id <> t.table_id) THEN
                add_error('REG_ROOT_INVALID', 'Root table must have a date column and be its own root',
                          t.owner, t.table_name);
            ELSIF t.role = 'DEPENDENT' AND t.links = 0 THEN
                add_error('REG_DEPENDENT_UNLINKED', 'Dependent table has no link to a source table',
                          t.owner, t.table_name);
            END IF;

            IF t.present = 0 THEN
                add_warning('REG_TABLE_MISSING', 'Table not present in this database; it is skipped',
                            t.owner, t.table_name);
            ELSE
                l_present := l_present + 1;
                check_column(t.owner, t.table_name, t.key_column, 'Key');
                check_column(t.owner, t.table_name, t.date_column, 'Date');

                SELECT COUNT(DISTINCT privilege)
                  INTO l_count
                  FROM dba_tab_privs
                 WHERE grantee = l_tool
                   AND owner = t.owner
                   AND table_name = t.table_name
                   AND privilege IN ('SELECT', 'DELETE');
                IF l_count < 2 THEN
                    add_warning('REG_GRANT_MISSING', 'SELECT/DELETE not granted to ' || l_tool
                                || '; re-run install.sql', t.owner, t.table_name);
                END IF;
            END IF;
        END LOOP;

        -- Links: same tree, processing order, columns.
        FOR l IN (SELECT k.link_id, k.match_column, k.source_column,
                         d.owner AS d_owner, d.table_name AS d_table,
                         d.delete_order AS d_order, d.root_table_id AS d_root,
                         s.owner AS s_owner, s.table_name AS s_table,
                         s.delete_order AS s_order, s.root_table_id AS s_root
                    FROM epf_link k
                    JOIN epf_table d ON d.table_id = k.table_id
                    JOIN epf_table s ON s.table_id = k.source_table_id
                   WHERE d.active = 'Y'
                     AND s.active = 'Y'
                   ORDER BY k.link_id) LOOP
            l_links := l_links + 1;
            l_label := 'link ' || l.link_id || ': ' || l.d_table || '.' || l.match_column
                       || ' <- ' || l.s_table || '.' || l.source_column;
            IF l.d_root <> l.s_root THEN
                add_error('REG_LINK_TREE', 'Link joins two different root trees (' || l_label || ')',
                          l.d_owner, l.d_table);
            ELSIF l.d_order >= l.s_order THEN
                add_error('REG_LINK_ORDER', 'Dependent must be processed before its source (' || l_label
                          || ', delete_order ' || l.d_order || ' >= ' || l.s_order || ')',
                          l.d_owner, l.d_table);
            END IF;
            IF epf_util.table_exists(l.d_owner, l.d_table) THEN
                check_column(l.d_owner, l.d_table, l.match_column, 'Match');
            END IF;
            IF epf_util.table_exists(l.s_owner, l.s_table) THEN
                check_column(l.s_owner, l.s_table, l.source_column, 'Source');
            END IF;
        END LOOP;

        -- Foreign keys from any schema into registry tables.
        FOR f IN (SELECT c.owner AS c_owner, c.table_name AS c_table, c.constraint_name,
                         c.delete_rule, c.status,
                         p.owner AS p_owner, p.table_name AS p_table,
                         pt.table_id AS p_id, pt.delete_order AS p_order, pt.root_table_id AS p_root,
                         ct.table_id AS c_id, ct.delete_order AS c_order, ct.root_table_id AS c_root
                    FROM dba_constraints c
                    JOIN dba_constraints p
                      ON p.owner = c.r_owner
                     AND p.constraint_name = c.r_constraint_name
                    JOIN epf_table pt
                      ON pt.owner = p.owner
                     AND pt.table_name = p.table_name
                     AND pt.active = 'Y'
                    LEFT JOIN epf_table ct
                      ON ct.owner = c.owner
                     AND ct.table_name = c.table_name
                     AND ct.active = 'Y'
                   WHERE c.constraint_type = 'R'
                   ORDER BY p.owner, p.table_name, c.owner, c.table_name, c.constraint_name) LOOP
            l_fks := l_fks + 1;
            l_label := f.c_owner || '.' || f.c_table || ' (' || f.constraint_name || ') -> '
                       || f.p_owner || '.' || f.p_table;
            IF f.status <> 'ENABLED' THEN
                epf_log.info('REG_FK_DISABLED', 'Disabled FK ignored: ' || l_label, f.c_owner, f.c_table);
            ELSIF f.c_id IS NOT NULL AND f.c_id = f.p_id THEN
                add_warning('REG_FK_SELF', 'Self-referencing FK: ' || l_label
                            || '; a batch may fail if a row references a row of a later batch',
                            f.c_owner, f.c_table);
            ELSIF f.c_id IS NOT NULL THEN
                IF f.c_root <> f.p_root THEN
                    add_error('REG_FK_CROSS_TREE', 'FK between two different root trees: ' || l_label,
                              f.c_owner, f.c_table);
                ELSIF f.c_order >= f.p_order THEN
                    add_error('REG_FK_ORDER', 'FK child is processed after its parent: ' || l_label
                              || ' (delete_order ' || f.c_order || ' >= ' || f.p_order || ')',
                              f.c_owner, f.c_table);
                ELSE
                    l_fk_covered := l_fk_covered + 1;
                END IF;
            ELSIF f.delete_rule IN ('CASCADE', 'SET NULL') THEN
                add_error('REG_FK_EXTERNAL_CASCADE', 'FK from a table outside the registry with ON DELETE '
                          || f.delete_rule || ' would change rows outside the purge scope: ' || l_label,
                          f.c_owner, f.c_table);
            ELSE
                add_warning('REG_FK_EXTERNAL', 'FK from a table outside the registry: ' || l_label
                            || '; the purge fails if it references an eligible row',
                            f.c_owner, f.c_table);
            END IF;
        END LOOP;

        epf_log.event(
            p_severity   => CASE WHEN p_errors > 0 THEN epf_log.c_error
                                 WHEN p_warnings > 0 THEN epf_log.c_warn
                                 ELSE epf_log.c_ok END,
            p_event_code => 'REG_SUMMARY',
            p_message    => 'Registry: ' || l_present || '/' || l_tables || ' tables present, '
                            || l_links || ' links, ' || l_fks || ' FKs into registry tables ('
                            || l_fk_covered || ' covered by the processing order), '
                            || p_errors || ' errors, ' || p_warnings || ' warnings');
    END validate;

END epf_registry;
/

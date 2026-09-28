CREATE OR REPLACE PACKAGE BODY epf_util AS

    FUNCTION now_ts RETURN TIMESTAMP IS
    BEGIN
        RETURN CAST(SYSTIMESTAMP AS TIMESTAMP);
    END now_ts;

    FUNCTION elapsed_s(p_from IN TIMESTAMP, p_to IN TIMESTAMP DEFAULT NULL) RETURN NUMBER IS
        l_interval INTERVAL DAY(9) TO SECOND(6);
    BEGIN
        IF p_from IS NULL THEN
            RETURN NULL;
        END IF;
        l_interval := NVL(p_to, now_ts) - p_from;
        RETURN EXTRACT(DAY FROM l_interval) * 86400
             + EXTRACT(HOUR FROM l_interval) * 3600
             + EXTRACT(MINUTE FROM l_interval) * 60
             + EXTRACT(SECOND FROM l_interval);
    END elapsed_s;

    FUNCTION run_label(p_run_id IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_run_id IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN 'R-' || LPAD(TO_CHAR(p_run_id), 6, '0');
    END run_label;

    FUNCTION fmt_int(p_value IN NUMBER) RETURN VARCHAR2 IS
    BEGIN
        IF p_value IS NULL THEN
            RETURN NULL;
        END IF;
        RETURN TO_CHAR(ROUND(p_value), 'FM999,999,999,999,999,990');
    END fmt_int;

    FUNCTION fmt_bytes(p_bytes IN NUMBER) RETURN VARCHAR2 IS
        c_kb CONSTANT NUMBER := 1024;
        c_mb CONSTANT NUMBER := 1024 * 1024;
        c_gb CONSTANT NUMBER := 1024 * 1024 * 1024;
        c_tb CONSTANT NUMBER := 1099511627776;
        l_abs NUMBER := ABS(p_bytes);
    BEGIN
        IF p_bytes IS NULL THEN
            RETURN NULL;
        ELSIF l_abs < c_kb THEN
            RETURN TO_CHAR(p_bytes) || ' B';
        ELSIF l_abs < c_mb THEN
            RETURN TO_CHAR(p_bytes / c_kb, 'FM999999990.0') || ' KB';
        ELSIF l_abs < c_gb THEN
            RETURN TO_CHAR(p_bytes / c_mb, 'FM999999990.0') || ' MB';
        ELSIF l_abs < c_tb THEN
            RETURN TO_CHAR(p_bytes / c_gb, 'FM999999990.0') || ' GB';
        END IF;
        RETURN TO_CHAR(p_bytes / c_tb, 'FM999999990.0') || ' TB';
    END fmt_bytes;

    FUNCTION fmt_duration(p_seconds IN NUMBER) RETURN VARCHAR2 IS
        l_total NUMBER := ROUND(NVL(p_seconds, 0));
    BEGIN
        RETURN LPAD(TO_CHAR(TRUNC(l_total / 3600)), 2, '0') || ':'
            || LPAD(TO_CHAR(TRUNC(MOD(l_total, 3600) / 60)), 2, '0') || ':'
            || LPAD(TO_CHAR(MOD(l_total, 60)), 2, '0');
    END fmt_duration;

    FUNCTION setting(p_name IN VARCHAR2) RETURN VARCHAR2 IS
        l_value epf_setting.value%TYPE;
    BEGIN
        SELECT value INTO l_value FROM epf_setting WHERE name = LOWER(p_name);
        RETURN l_value;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20100, 'Unknown setting: ' || p_name);
    END setting;

    FUNCTION setting_num(p_name IN VARCHAR2) RETURN NUMBER IS
        l_value epf_setting.value%TYPE := setting(p_name);
    BEGIN
        RETURN TO_NUMBER(l_value);
    EXCEPTION
        WHEN VALUE_ERROR OR INVALID_NUMBER THEN
            RAISE_APPLICATION_ERROR(-20101, 'Setting ' || p_name || ' is not numeric: ' || l_value);
    END setting_num;

    FUNCTION qname(p_owner IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN DBMS_ASSERT.ENQUOTE_NAME(p_owner, FALSE) || '.' || DBMS_ASSERT.ENQUOTE_NAME(p_name, FALSE);
    END qname;

    FUNCTION table_exists(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN BOOLEAN IS
        l_count PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
          INTO l_count
          FROM dba_tables
         WHERE owner = UPPER(p_owner)
           AND table_name = UPPER(p_table);
        RETURN l_count > 0;
    END table_exists;

    FUNCTION column_exists(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_column IN VARCHAR2) RETURN BOOLEAN IS
        l_count PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
          INTO l_count
          FROM dba_tab_columns
         WHERE owner = UPPER(p_owner)
           AND table_name = UPPER(p_table)
           AND column_name = UPPER(p_column);
        RETURN l_count > 0;
    END column_exists;

    FUNCTION split_list(p_list IN VARCHAR2) RETURN SYS.ODCIVARCHAR2LIST IS
        l_items SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        l_src   VARCHAR2(32767) := p_list || ',';
        l_pos   PLS_INTEGER := 1;
        l_next  PLS_INTEGER;
        l_item  VARCHAR2(4000);
    BEGIN
        IF p_list IS NULL THEN
            RETURN l_items;
        END IF;
        LOOP
            l_next := INSTR(l_src, ',', l_pos);
            EXIT WHEN l_next = 0;
            l_item := UPPER(TRIM(SUBSTR(l_src, l_pos, l_next - l_pos)));
            IF l_item IS NOT NULL THEN
                l_items.EXTEND;
                l_items(l_items.COUNT) := l_item;
            END IF;
            l_pos := l_next + 1;
        END LOOP;
        RETURN l_items;
    END split_list;

    FUNCTION db_version RETURN VARCHAR2 IS
        l_version VARCHAR2(40);
    BEGIN
        -- version_full exists from 18c; version is used on 12.2.
        BEGIN
            EXECUTE IMMEDIATE 'SELECT version_full FROM v$instance' INTO l_version;
        EXCEPTION
            WHEN OTHERS THEN
                IF SQLCODE = -904 THEN
                    EXECUTE IMMEDIATE 'SELECT version FROM v$instance' INTO l_version;
                ELSE
                    RAISE;
                END IF;
        END;
        RETURN l_version;
    END db_version;

    FUNCTION is_enterprise RETURN BOOLEAN IS
        l_count PLS_INTEGER;
    BEGIN
        SELECT COUNT(*) INTO l_count FROM v$version WHERE banner LIKE '%Enterprise Edition%';
        RETURN l_count > 0;
    END is_enterprise;

    FUNCTION container_name RETURN VARCHAR2 IS
    BEGIN
        RETURN SYS_CONTEXT('USERENV', 'CON_NAME');
    END container_name;

    FUNCTION is_cdb_root RETURN BOOLEAN IS
    BEGIN
        RETURN SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT';
    END is_cdb_root;

END epf_util;
/

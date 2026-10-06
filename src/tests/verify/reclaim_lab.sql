-- ============================================================================
-- EPF Data Purge - Reclaim lab
-- ============================================================================
-- Purpose : A scratch tablespace with a known layout for the reclaim tests.
--           SETUP creates tablespace EPF_RT_DATA (autoextensible), its owner
--           EPF_RT, two accounts that may write its tables (EPF_RT_APP with a
--           direct grant, EPF_RT_APP2 through role EPF_RT_WRITER) and tables
--           of the kinds the reclaim moves (heap tables with SECUREFILE and
--           BASICFILE LOB columns stored out of line, an index-organized
--           table with an overflow segment, a primary, unique, foreign key,
--           function-based and secondary IOT index) and of kinds it leaves
--           where they are (a LONG column, a partitioned table). The tables
--           are filled in rounds so that their extents interleave; then a
--           table is dropped (free space low in the datafile), another goes
--           to the recycle bin when it is on, rows are deleted (free space
--           inside segments: RT_FAT keeps a fifth of its rows), and RT_TOP,
--           created last, holds the top of the datafile. RT_TOP does not fit
--           in the free space at first: RT_FAT moves first to make room.
--           CHECK prints the state the tests compare (LAB| lines). CLEANUP
--           removes the accounts, the role and the tablespace.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/tests/verify/reclaim_lab.sql SETUP|CHECK|CLEANUP
-- Requires: SYS AS SYSDBA, in the PDB in a multitenant database; about
--           400 MB of disk (db_create_file_dest, or the directory of the
--           SYSTEM datafile).
-- Effects : SETUP removes an earlier lab first. Nothing outside EPF_RT,
--           EPF_RT_APP, EPF_RT_APP2, EPF_RT_WRITER and EPF_RT_DATA is
--           touched.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 400 TRIMSPOOL ON TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE lab_mode = "&1"

DECLARE
    c_ts    CONSTANT VARCHAR2(30) := 'EPF_RT_DATA';
    l_mode  VARCHAR2(10) := UPPER(TRIM('&lab_mode'));
    l_count NUMBER;
    l_dest  VARCHAR2(512);
    l_file  VARCHAR2(513);
    l_dir   VARCHAR2(513);
    l_pw    VARCHAR2(40);
    l_bin   VARCHAR2(10);
    l_value NUMBER;

    PROCEDURE run(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    END run;

    PROCEDURE put(p_line IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p_line);
    END put;

    PROCEDURE drop_lab IS
    BEGIN
        FOR u IN (SELECT username FROM dba_users WHERE username IN ('EPF_RT', 'EPF_RT_APP', 'EPF_RT_APP2')
                   ORDER BY username) LOOP
            run('DROP USER ' || u.username || ' CASCADE');
            put('LAB|DROPPED|USER|' || u.username);
        END LOOP;
        FOR r IN (SELECT role FROM dba_roles WHERE role = 'EPF_RT_WRITER') LOOP
            run('DROP ROLE epf_rt_writer');
            put('LAB|DROPPED|ROLE|EPF_RT_WRITER');
        END LOOP;
        SELECT COUNT(*) INTO l_count FROM dba_tablespaces WHERE tablespace_name = c_ts;
        IF l_count > 0 THEN
            run('DROP TABLESPACE ' || c_ts || ' INCLUDING CONTENTS AND DATAFILES');
            put('LAB|DROPPED|TABLESPACE|' || c_ts);
        END IF;
    END drop_lab;
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') <> 'SYS' THEN
        RAISE_APPLICATION_ERROR(-20000, 'Run reclaim_lab.sql as SYS AS SYSDBA.');
    END IF;
    IF l_mode NOT IN ('SETUP', 'CHECK', 'CLEANUP') THEN
        RAISE_APPLICATION_ERROR(-20000, 'Mode must be SETUP, CHECK or CLEANUP, got: ' || l_mode);
    END IF;

    IF l_mode = 'CLEANUP' THEN
        drop_lab;
        put('LAB|CLEANUP|DONE');
        RETURN;
    END IF;

    IF l_mode = 'SETUP' THEN
        drop_lab;
        SELECT MAX(value) INTO l_dest FROM v$parameter WHERE name = 'db_create_file_dest';
        IF l_dest IS NOT NULL THEN
            run('CREATE TABLESPACE ' || c_ts || ' DATAFILE SIZE 64M AUTOEXTEND ON NEXT 8M MAXSIZE 2G '
                || 'EXTENT MANAGEMENT LOCAL AUTOALLOCATE SEGMENT SPACE MANAGEMENT AUTO');
        ELSE
            SELECT MIN(file_name) INTO l_file FROM dba_data_files WHERE tablespace_name = 'SYSTEM';
            l_dir := SUBSTR(l_file, 1, GREATEST(INSTR(l_file, '/', -1), INSTR(l_file, '\', -1)));
            run('CREATE TABLESPACE ' || c_ts || ' DATAFILE ''' || l_dir || 'epf_rt_data01.dbf'' SIZE 64M REUSE '
                || 'AUTOEXTEND ON NEXT 8M MAXSIZE 2G EXTENT MANAGEMENT LOCAL AUTOALLOCATE SEGMENT SPACE MANAGEMENT AUTO');
        END IF;

        -- Accounts nobody logs in with: a random password each.
        l_pw := 'Rt' || DBMS_RANDOM.STRING('U', 6) || DBMS_RANDOM.STRING('L', 6) || TRUNC(DBMS_RANDOM.VALUE(100, 999));
        run('CREATE USER epf_rt IDENTIFIED BY "' || l_pw || '#a" DEFAULT TABLESPACE ' || c_ts || ' QUOTA UNLIMITED ON '
            || c_ts);
        run('CREATE USER epf_rt_app IDENTIFIED BY "' || l_pw || '#b"');
        run('CREATE USER epf_rt_app2 IDENTIFIED BY "' || l_pw || '#c"');
        run('CREATE ROLE epf_rt_writer');

        -- Segments that stay, created first (low in the datafile).
        run('CREATE TABLE epf_rt.rt_long (id NUMBER CONSTRAINT rt_long_pk PRIMARY KEY, txt LONG) TABLESPACE ' || c_ts);
        run('CREATE TABLE epf_rt.rt_part (id NUMBER, d DATE) TABLESPACE ' || c_ts
            || ' PARTITION BY RANGE (d) (PARTITION p1 VALUES LESS THAN (DATE ''2020-01-01''), '
            || 'PARTITION p2 VALUES LESS THAN (MAXVALUE))');
        FOR i IN 1 .. 200 LOOP
            run('INSERT INTO epf_rt.rt_long (id, txt) VALUES (' || i || ', RPAD(''l'', 3000, ''l''))');
        END LOOP;
        run('INSERT INTO epf_rt.rt_part SELECT LEVEL, DATE ''2019-01-01'' + MOD(LEVEL, 900) FROM dual '
            || 'CONNECT BY LEVEL <= 2000');
        COMMIT;

        -- Tables that move.
        run('CREATE TABLE epf_rt.rt_heap (id NUMBER CONSTRAINT rt_heap_pk PRIMARY KEY, '
            || 'code VARCHAR2(30) CONSTRAINT rt_heap_uk UNIQUE, pad VARCHAR2(1000), c CLOB) TABLESPACE ' || c_ts
            || ' LOB (c) STORE AS SECUREFILE (DISABLE STORAGE IN ROW)');
        run('CREATE INDEX epf_rt.rt_heap_fx ON epf_rt.rt_heap (UPPER(code)) TABLESPACE ' || c_ts);
        run('CREATE TABLE epf_rt.rt_basic (id NUMBER CONSTRAINT rt_basic_pk PRIMARY KEY, b BLOB) TABLESPACE ' || c_ts
            || ' LOB (b) STORE AS BASICFILE (DISABLE STORAGE IN ROW)');
        run('CREATE TABLE epf_rt.rt_iot (id NUMBER, k VARCHAR2(30), v VARCHAR2(100), big VARCHAR2(2000), '
            || 'CONSTRAINT rt_iot_pk PRIMARY KEY (id)) ORGANIZATION INDEX TABLESPACE ' || c_ts
            || ' INCLUDING v OVERFLOW TABLESPACE ' || c_ts);
        run('CREATE INDEX epf_rt.rt_iot_k ON epf_rt.rt_iot (k) TABLESPACE ' || c_ts);
        run('CREATE TABLE epf_rt.rt_child (id NUMBER CONSTRAINT rt_child_pk PRIMARY KEY, '
            || 'heap_id NUMBER CONSTRAINT rt_child_fk REFERENCES epf_rt.rt_heap, note VARCHAR2(500)) TABLESPACE ' || c_ts);
        run('CREATE INDEX epf_rt.rt_child_ix ON epf_rt.rt_child (heap_id) TABLESPACE ' || c_ts);
        run('CREATE TABLE epf_rt.rt_fat (id NUMBER, pad VARCHAR2(2000)) TABLESPACE ' || c_ts);
        -- Dropped later: free space low in the datafile, and the recycle bin.
        run('CREATE TABLE epf_rt.rt_fill (id NUMBER, pad VARCHAR2(2000)) TABLESPACE ' || c_ts);
        run('CREATE TABLE epf_rt.rt_bin (id NUMBER, pad VARCHAR2(2000)) TABLESPACE ' || c_ts);
        run('GRANT SELECT, INSERT, UPDATE, DELETE ON epf_rt.rt_heap TO epf_rt_app');
        run('GRANT INSERT, UPDATE, DELETE ON epf_rt.rt_basic TO epf_rt_writer');
        run('GRANT epf_rt_writer TO epf_rt_app2');

        -- Ten rounds, so that the extents of the tables interleave.
        FOR r IN 1 .. 10 LOOP
            run('INSERT INTO epf_rt.rt_heap (id, code, pad, c) SELECT ' || (r - 1) * 1000 || ' + LEVEL, ''C'' || ('
                || (r - 1) * 1000 || ' + LEVEL), RPAD(''h'', 900, ''h''), CASE WHEN MOD(LEVEL, 4) = 0 THEN '
                || 'TO_CLOB(RPAD(''c'', 1500, ''c'')) END FROM dual CONNECT BY LEVEL <= 1000');
            run('INSERT INTO epf_rt.rt_basic (id, b) SELECT ' || (r - 1) * 300 || ' + LEVEL, '
                || 'TO_BLOB(UTL_RAW.CAST_TO_RAW(RPAD(''b'', 2000, ''b''))) FROM dual CONNECT BY LEVEL <= 300');
            run('INSERT INTO epf_rt.rt_iot (id, k, v, big) SELECT ' || (r - 1) * 2000 || ' + LEVEL, ''K'' || '
                || 'MOD(LEVEL, 97), RPAD(''v'', 50, ''v''), RPAD(''o'', 1500, ''o'') FROM dual CONNECT BY LEVEL <= 2000');
            run('INSERT INTO epf_rt.rt_child (id, heap_id, note) SELECT ' || (r - 1) * 2000 || ' + LEVEL, '
                || (r - 1) * 1000 || ' + 5 * (1 + MOD(LEVEL, 200)), RPAD(''n'', 400, ''n'') FROM dual '
                || 'CONNECT BY LEVEL <= 2000');
            run('INSERT INTO epf_rt.rt_fat (id, pad) SELECT ' || (r - 1) * 3500 || ' + LEVEL, RPAD(''f'', 1700, ''f'') '
                || 'FROM dual CONNECT BY LEVEL <= 3500');
            run('INSERT INTO epf_rt.rt_fill (id, pad) SELECT ' || (r - 1) * 2200 || ' + LEVEL, RPAD(''x'', 1800, ''x'') '
                || 'FROM dual CONNECT BY LEVEL <= 2200');
            run('INSERT INTO epf_rt.rt_bin (id, pad) SELECT ' || (r - 1) * 500 || ' + LEVEL, RPAD(''r'', 1800, ''r'') '
                || 'FROM dual CONNECT BY LEVEL <= 500');
            COMMIT;
        END LOOP;

        -- The top of the datafile: RT_TOP, about 70 MB.
        run('CREATE TABLE epf_rt.rt_top (id NUMBER CONSTRAINT rt_top_pk PRIMARY KEY, pad VARCHAR2(2000)) TABLESPACE '
            || c_ts);
        run('INSERT INTO epf_rt.rt_top (id, pad) SELECT LEVEL, RPAD(''t'', 1800, ''t'') FROM dual '
            || 'CONNECT BY LEVEL <= 38000');
        COMMIT;

        -- Free space: low in the datafile (RT_FILL), in the recycle bin
        -- (RT_BIN, when it is on), inside segments (deleted rows).
        run('DROP TABLE epf_rt.rt_fill PURGE');
        run('DROP TABLE epf_rt.rt_bin');
        run('DELETE FROM epf_rt.rt_heap WHERE MOD(id, 5) IN (1, 2, 3)');
        run('DELETE FROM epf_rt.rt_iot WHERE MOD(id, 2) = 0');
        run('DELETE FROM epf_rt.rt_fat WHERE MOD(id, 5) <> 0');
        COMMIT;
        DBMS_STATS.GATHER_SCHEMA_STATS(ownname => 'EPF_RT', cascade => TRUE);
        put('LAB|SETUP|DONE');
    END IF;

    -- CHECK (and the end of SETUP): the state the tests compare.
    SELECT COUNT(*) INTO l_count FROM dba_tablespaces WHERE tablespace_name = c_ts;
    IF l_count = 0 THEN
        put('LAB|ABSENT');
        RETURN;
    END IF;
    FOR f IN (SELECT d.file_id, d.bytes, d.autoextensible, d.maxbytes, d.increment_by * t.block_size AS incr,
                     (SELECT NVL(MAX(e.block_id + e.blocks - 1), 0) * t.block_size FROM dba_extents e
                       WHERE e.file_id = d.file_id) AS hwm,
                     (SELECT NVL(SUM(s.bytes), 0) FROM dba_free_space s WHERE s.file_id = d.file_id) AS free
                FROM dba_data_files d
                JOIN dba_tablespaces t ON t.tablespace_name = d.tablespace_name
               WHERE d.tablespace_name = c_ts
               ORDER BY d.file_id) LOOP
        put('LAB|FILE|' || f.file_id || '|' || f.bytes || '|' || f.autoextensible || '|' || f.maxbytes || '|' || f.incr
            || '|' || f.hwm || '|' || f.free);
    END LOOP;
    SELECT NVL(SUM(bytes), 0) INTO l_value FROM dba_segments WHERE tablespace_name = c_ts;
    put('LAB|SEGMENTS|' || l_value);
    FOR i IN (SELECT owner, index_name, status FROM dba_indexes
               WHERE table_owner = 'EPF_RT' AND index_type <> 'LOB' AND dropped = 'NO'
               ORDER BY owner, index_name) LOOP
        put('LAB|INDEX|' || i.owner || '.' || i.index_name || '|' || i.status);
    END LOOP;
    FOR a IN (SELECT username, account_status FROM dba_users WHERE username IN ('EPF_RT', 'EPF_RT_APP', 'EPF_RT_APP2')
               ORDER BY username) LOOP
        put('LAB|ACCOUNT|' || a.username || '|' || a.account_status);
    END LOOP;
    FOR t IN (SELECT table_name FROM dba_tables
               WHERE owner = 'EPF_RT' AND dropped = 'NO' AND (iot_type IS NULL OR iot_type = 'IOT')
               ORDER BY table_name) LOOP
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM epf_rt.' || DBMS_ASSERT.ENQUOTE_NAME(t.table_name, FALSE) INTO l_value;
        put('LAB|ROWS|' || t.table_name || '|' || l_value);
    END LOOP;
    FOR l IN (SELECT table_name, column_name, securefile, in_row, tablespace_name FROM dba_lobs
               WHERE owner = 'EPF_RT' ORDER BY table_name, column_name) LOOP
        put('LAB|LOB|' || l.table_name || '.' || l.column_name || '|securefile=' || l.securefile || '|in_row='
            || l.in_row || '|' || l.tablespace_name);
    END LOOP;
    SELECT MAX(value) INTO l_bin FROM v$parameter WHERE name = 'recyclebin';
    SELECT COUNT(*) INTO l_count FROM dba_recyclebin WHERE ts_name = c_ts;
    put('LAB|RECYCLEBIN|' || UPPER(l_bin) || '|' || l_count);
END;
/
EXIT SUCCESS

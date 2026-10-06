-- ============================================================================
-- EPF Data Purge - Reclaim lab, second layout
-- ============================================================================
-- Purpose : A second scratch layout for the reclaim tests, with what the
--           first (reclaim_lab.sql) does not have. SETUP creates:
--             EPF_RT2_DATA  two datafiles with uniform 1 MB extents; the
--                           second datafile is not autoextensible
--             EPF_RT2_INDX  the indexes (uniform 256 KB extents)
--             EPF_RT2_SIDE  the LOB segments and the IOT overflow segment
--                           (AUTOALLOCATE)
--           and, owned by EPF_RT2: segments that stay, created first (low in
--           the datafiles): a table with a LONG column and a queue table with
--           the tables Oracle keeps for it (their indexes are left as they
--           are); then a table in EPF_RT2_DATA and one in EPF_RT2_SIDE,
--           dropped later (free space low in the datafiles); then the tables
--           that move, filled in rounds so that their extents interleave, each
--           with an INITIAL larger than it needs once most of its rows are
--           deleted (as an exported segment has): a compressed table (BASIC)
--           with its primary key index, an index-organized table and its
--           overflow segment, a SECUREFILE LOB (CACHE) and a BASICFILE LOB
--           (PCTVERSION 0); RT2_TOP, created last, holds the top of the
--           datafiles. When the tool is installed, the space a purge would
--           have measured in the LOB and overflow segments is written
--           (EPFPG.EPF_SPACE_USAGE, run 0, method LAB), so that the reclaim
--           estimates them as after a purge. EPF_RT2 ends above its quota on
--           EPF_RT2_DATA (requirement QUOTA not met) until mode QUOTA gives it
--           an unlimited quota.
--           CHECK prints the state the tests compare (LAB| lines, as
--           reclaim_lab.sql), the segments with an INITIAL above 1 MB
--           (LAB|INITIAL) and the quotas (LAB|QUOTA). CLEANUP removes the
--           queue table, the account, the measurements and the tablespaces.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/tests/verify/reclaim_lab2.sql SETUP|CHECK|QUOTA|CLEANUP
-- Requires: SYS AS SYSDBA, in the PDB in a multitenant database; about
--           250 MB of disk (db_create_file_dest, or the directory of the
--           SYSTEM datafile).
-- Effects : SETUP removes an earlier second lab first. Nothing outside
--           EPF_RT2, EPF_RT2_DATA, EPF_RT2_INDX, EPF_RT2_SIDE and the
--           measurements of EPF_RT2 (run 0) is touched.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 400 TRIMSPOOL ON TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE lab_mode = "&1"

DECLARE
    l_mode  VARCHAR2(10) := UPPER(TRIM('&lab_mode'));
    l_count NUMBER;
    l_dest  VARCHAR2(512);
    l_file  VARCHAR2(513);
    l_dir   VARCHAR2(513);
    l_pw    VARCHAR2(40);
    l_bin   VARCHAR2(10);
    l_value NUMBER;
    l_tool  NUMBER;

    PROCEDURE run(p_sql IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE p_sql;
    END run;

    PROCEDURE put(p_line IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(p_line);
    END put;

    -- The datafile clause of a new datafile: its size only with Oracle
    -- Managed Files, otherwise its name in the directory of the SYSTEM
    -- datafile.
    FUNCTION file_spec(p_name IN VARCHAR2, p_size IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF l_dest IS NOT NULL THEN
            RETURN 'SIZE ' || p_size;
        END IF;
        RETURN '''' || l_dir || p_name || ''' SIZE ' || p_size || ' REUSE';
    END file_spec;

    -- Writes the space a purge would have measured in segment p_segment of
    -- EPF_RT2 (EPFPG.EPF_SPACE_USAGE, run 0): p_used bytes used.
    PROCEDURE measure(p_segment IN VARCHAR2, p_used IN NUMBER) IS
    BEGIN
        EXECUTE IMMEDIATE 'INSERT INTO epfpg.epf_space_usage (run_id, phase, owner, segment_name, segment_type, '
                          || 'allocated_bytes, used_bytes, free_bytes, method, raw_used_bytes) '
                          || 'SELECT 0, ''POST_PURGE'', owner, segment_name, segment_type, bytes, :u1, bytes - :u2, '
                          || '''LAB'', :u3 FROM dba_segments WHERE owner = ''EPF_RT2'' AND segment_name = :s'
            USING p_used, p_used, p_used, p_segment;
        put('LAB|MEASURED|' || p_segment || '|' || p_used);
    END measure;

    PROCEDURE drop_lab IS
    BEGIN
        FOR q IN (SELECT owner, queue_table FROM dba_queue_tables WHERE owner = 'EPF_RT2' ORDER BY queue_table) LOOP
            DBMS_AQADM.DROP_QUEUE_TABLE(queue_table => q.owner || '.' || q.queue_table, force => TRUE);
            put('LAB|DROPPED|QUEUE_TABLE|' || q.owner || '.' || q.queue_table);
        END LOOP;
        FOR u IN (SELECT username FROM dba_users WHERE username = 'EPF_RT2') LOOP
            run('DROP USER ' || u.username || ' CASCADE');
            put('LAB|DROPPED|USER|' || u.username);
        END LOOP;
        FOR t IN (SELECT tablespace_name FROM dba_tablespaces
                   WHERE tablespace_name IN ('EPF_RT2_DATA', 'EPF_RT2_INDX', 'EPF_RT2_SIDE')
                   ORDER BY tablespace_name) LOOP
            run('DROP TABLESPACE ' || t.tablespace_name || ' INCLUDING CONTENTS AND DATAFILES');
            put('LAB|DROPPED|TABLESPACE|' || t.tablespace_name);
        END LOOP;
        IF l_tool > 0 THEN
            EXECUTE IMMEDIATE 'DELETE FROM epfpg.epf_space_usage WHERE run_id = 0 AND owner = ''EPF_RT2''';
            IF SQL%ROWCOUNT > 0 THEN
                put('LAB|DROPPED|MEASUREMENTS|' || SQL%ROWCOUNT);
            END IF;
            COMMIT;
        END IF;
    END drop_lab;
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') <> 'SYS' THEN
        RAISE_APPLICATION_ERROR(-20000, 'Run reclaim_lab2.sql as SYS AS SYSDBA.');
    END IF;
    IF l_mode NOT IN ('SETUP', 'CHECK', 'QUOTA', 'CLEANUP') THEN
        RAISE_APPLICATION_ERROR(-20000, 'Mode must be SETUP, CHECK, QUOTA or CLEANUP, got: ' || l_mode);
    END IF;
    SELECT COUNT(*) INTO l_tool FROM dba_tables WHERE owner = 'EPFPG' AND table_name = 'EPF_SPACE_USAGE';

    IF l_mode = 'CLEANUP' THEN
        drop_lab;
        put('LAB|CLEANUP|DONE');
        RETURN;
    END IF;

    IF l_mode = 'QUOTA' THEN
        SELECT COUNT(*) INTO l_count FROM dba_users WHERE username = 'EPF_RT2';
        IF l_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20000, 'The second lab is not set up (no account EPF_RT2).');
        END IF;
        run('ALTER USER epf_rt2 QUOTA UNLIMITED ON epf_rt2_data');
        put('LAB|QUOTA|DONE');
    END IF;

    IF l_mode = 'SETUP' THEN
        drop_lab;
        -- Every table and index gets its segment when it is created, also the
        -- tables Oracle creates for the queue table.
        run('ALTER SESSION SET deferred_segment_creation = FALSE');
        SELECT MAX(value) INTO l_dest FROM v$parameter WHERE name = 'db_create_file_dest';
        IF l_dest IS NULL THEN
            SELECT MIN(file_name) INTO l_file FROM dba_data_files WHERE tablespace_name = 'SYSTEM';
            l_dir := SUBSTR(l_file, 1, GREATEST(INSTR(l_file, '/', -1), INSTR(l_file, '\', -1)));
        END IF;
        run('CREATE TABLESPACE epf_rt2_data DATAFILE ' || file_spec('epf_rt2_data01.dbf', '16M')
            || ' AUTOEXTEND ON NEXT 4M MAXSIZE 1G EXTENT MANAGEMENT LOCAL UNIFORM SIZE 1M SEGMENT SPACE MANAGEMENT AUTO');
        run('ALTER TABLESPACE epf_rt2_data ADD DATAFILE ' || file_spec('epf_rt2_data02.dbf', '40M') || ' AUTOEXTEND OFF');
        run('CREATE TABLESPACE epf_rt2_indx DATAFILE ' || file_spec('epf_rt2_indx01.dbf', '16M')
            || ' AUTOEXTEND ON NEXT 4M MAXSIZE 512M EXTENT MANAGEMENT LOCAL UNIFORM SIZE 256K '
            || 'SEGMENT SPACE MANAGEMENT AUTO');
        run('CREATE TABLESPACE epf_rt2_side DATAFILE ' || file_spec('epf_rt2_side01.dbf', '16M')
            || ' AUTOEXTEND ON NEXT 4M MAXSIZE 512M EXTENT MANAGEMENT LOCAL AUTOALLOCATE SEGMENT SPACE MANAGEMENT AUTO');

        -- An account nobody logs in with: a random password.
        l_pw := 'Rt' || DBMS_RANDOM.STRING('U', 6) || DBMS_RANDOM.STRING('L', 6) || TRUNC(DBMS_RANDOM.VALUE(100, 999));
        run('CREATE USER epf_rt2 IDENTIFIED BY "' || l_pw || '#d" DEFAULT TABLESPACE epf_rt2_data '
            || 'QUOTA UNLIMITED ON epf_rt2_data QUOTA UNLIMITED ON epf_rt2_indx QUOTA UNLIMITED ON epf_rt2_side');

        -- Segments that stay, created first (low in the datafiles).
        run('CREATE TABLE epf_rt2.rt2_long (id NUMBER CONSTRAINT rt2_long_pk PRIMARY KEY USING INDEX TABLESPACE '
            || 'epf_rt2_indx, txt LONG) TABLESPACE epf_rt2_data');
        FOR i IN 1 .. 200 LOOP
            run('INSERT INTO epf_rt2.rt2_long (id, txt) VALUES (' || i || ', RPAD(''l'', 3000, ''l''))');
        END LOOP;
        COMMIT;
        DBMS_AQADM.CREATE_QUEUE_TABLE(queue_table => 'EPF_RT2.RT2_QT', queue_payload_type => 'RAW',
                                      storage_clause => 'TABLESPACE EPF_RT2_DATA', multiple_consumers => TRUE);

        -- Dropped later: free space low in EPF_RT2_DATA (about 32 MB) and in
        -- EPF_RT2_SIDE (about 13 MB).
        run('CREATE TABLE epf_rt2.rt2_fill (id NUMBER, pad VARCHAR2(2000)) TABLESPACE epf_rt2_data');
        run('INSERT INTO epf_rt2.rt2_fill (id, pad) SELECT LEVEL, RPAD(''x'', 1800, ''x'') FROM dual '
            || 'CONNECT BY LEVEL <= 16000');
        run('CREATE TABLE epf_rt2.rt2_lfill (id NUMBER, c CLOB) TABLESPACE epf_rt2_side '
            || 'LOB (c) STORE AS SECUREFILE (TABLESPACE epf_rt2_side DISABLE STORAGE IN ROW)');
        run('INSERT INTO epf_rt2.rt2_lfill (id, c) SELECT LEVEL, TO_CLOB(RPAD(''f'', 3000, ''f'')) FROM dual '
            || 'CONNECT BY LEVEL <= 1600');
        COMMIT;

        -- Tables that move, each segment with an INITIAL larger than it needs
        -- once most of its rows are deleted.
        run('CREATE TABLE epf_rt2.rt2_heap (id NUMBER, code VARCHAR2(30), pad VARCHAR2(400), '
            || 'CONSTRAINT rt2_heap_pk PRIMARY KEY (id) USING INDEX TABLESPACE epf_rt2_indx STORAGE (INITIAL 8M)) '
            || 'TABLESPACE epf_rt2_data STORAGE (INITIAL 12M) ROW STORE COMPRESS BASIC');
        run('CREATE TABLE epf_rt2.rt2_iot (id NUMBER, k VARCHAR2(30), v VARCHAR2(40), big VARCHAR2(600), '
            || 'CONSTRAINT rt2_iot_pk PRIMARY KEY (id)) ORGANIZATION INDEX TABLESPACE epf_rt2_data '
            || 'STORAGE (INITIAL 8M) INCLUDING v OVERFLOW TABLESPACE epf_rt2_side STORAGE (INITIAL 8M)');
        run('CREATE INDEX epf_rt2.rt2_iot_k ON epf_rt2.rt2_iot (k) TABLESPACE epf_rt2_indx');
        run('CREATE TABLE epf_rt2.rt2_slob (id NUMBER CONSTRAINT rt2_slob_pk PRIMARY KEY USING INDEX TABLESPACE '
            || 'epf_rt2_indx, c CLOB) TABLESPACE epf_rt2_data LOB (c) STORE AS SECUREFILE (TABLESPACE epf_rt2_side '
            || 'DISABLE STORAGE IN ROW CACHE STORAGE (INITIAL 8M))');
        run('CREATE TABLE epf_rt2.rt2_blob (id NUMBER CONSTRAINT rt2_blob_pk PRIMARY KEY USING INDEX TABLESPACE '
            || 'epf_rt2_indx, b BLOB) TABLESPACE epf_rt2_data LOB (b) STORE AS BASICFILE (TABLESPACE epf_rt2_side '
            || 'DISABLE STORAGE IN ROW PCTVERSION 0 STORAGE (INITIAL 8M))');

        -- Ten rounds, so that the extents of the tables interleave; RT2_HEAP
        -- is filled by direct-path inserts (BASIC compression).
        FOR r IN 1 .. 10 LOOP
            run('INSERT /*+ APPEND */ INTO epf_rt2.rt2_heap (id, code, pad) SELECT ' || (r - 1) * 1000 || ' + LEVEL, '
                || '''C'' || MOD(LEVEL, 50), RPAD(''h'', 300, ''h'') FROM dual CONNECT BY LEVEL <= 1000');
            run('INSERT INTO epf_rt2.rt2_iot (id, k, v, big) SELECT ' || (r - 1) * 1000 || ' + LEVEL, ''K'' || '
                || 'MOD(LEVEL, 97), RPAD(''v'', 30, ''v''), RPAD(''o'', 500, ''o'') FROM dual CONNECT BY LEVEL <= 1000');
            run('INSERT INTO epf_rt2.rt2_slob (id, c) SELECT ' || (r - 1) * 100 || ' + LEVEL, '
                || 'TO_CLOB(RPAD(''c'', 3000, ''c'')) FROM dual CONNECT BY LEVEL <= 100');
            run('INSERT INTO epf_rt2.rt2_blob (id, b) SELECT ' || (r - 1) * 100 || ' + LEVEL, '
                || 'TO_BLOB(UTL_RAW.CAST_TO_RAW(RPAD(''b'', 2000, ''b''))) FROM dual CONNECT BY LEVEL <= 100');
            COMMIT;
        END LOOP;

        -- The top of the datafiles: RT2_TOP, about 16 MB.
        run('CREATE TABLE epf_rt2.rt2_top (id NUMBER CONSTRAINT rt2_top_pk PRIMARY KEY USING INDEX TABLESPACE '
            || 'epf_rt2_indx, pad VARCHAR2(2000)) TABLESPACE epf_rt2_data');
        run('INSERT INTO epf_rt2.rt2_top (id, pad) SELECT LEVEL, RPAD(''t'', 1800, ''t'') FROM dual '
            || 'CONNECT BY LEVEL <= 8000');
        COMMIT;

        -- Free space: low in the datafiles (the dropped tables), inside the
        -- segments (deleted rows).
        run('DROP TABLE epf_rt2.rt2_fill PURGE');
        run('DROP TABLE epf_rt2.rt2_lfill PURGE');
        run('DELETE FROM epf_rt2.rt2_heap WHERE MOD(id, 10) <> 0');
        run('DELETE FROM epf_rt2.rt2_iot WHERE MOD(id, 2) = 0');
        run('DELETE FROM epf_rt2.rt2_slob WHERE MOD(id, 4) <> 0');
        run('DELETE FROM epf_rt2.rt2_blob WHERE MOD(id, 4) <> 0');
        COMMIT;
        -- Statistics of the lab's own tables (Oracle locks those of the
        -- queue tables).
        FOR t IN (SELECT column_value AS table_name
                    FROM TABLE(SYS.ODCIVARCHAR2LIST('RT2_LONG', 'RT2_HEAP', 'RT2_IOT', 'RT2_SLOB', 'RT2_BLOB',
                                                    'RT2_TOP'))) LOOP
            DBMS_STATS.GATHER_TABLE_STATS(ownname => 'EPF_RT2', tabname => t.table_name, cascade => TRUE);
        END LOOP;

        -- What a purge would have measured: each LOB value takes one 8 KB
        -- block, each overflow row about 520 bytes.
        IF l_tool > 0 THEN
            FOR s IN (SELECT l.segment_name, l.table_name, 8192 AS row_bytes
                        FROM dba_lobs l
                       WHERE l.owner = 'EPF_RT2' AND l.table_name IN ('RT2_SLOB', 'RT2_BLOB')
                      UNION ALL
                      SELECT t.table_name, t.iot_name, 520
                        FROM dba_tables t
                       WHERE t.owner = 'EPF_RT2' AND t.iot_name = 'RT2_IOT' AND t.iot_type = 'IOT_OVERFLOW'
                       ORDER BY 2) LOOP
                EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM epf_rt2.' || DBMS_ASSERT.ENQUOTE_NAME(s.table_name, FALSE)
                    INTO l_value;
                measure(s.segment_name, l_value * s.row_bytes);
            END LOOP;
            COMMIT;
        ELSE
            put('LAB|NOTE|EPFPG.EPF_SPACE_USAGE not found: the LOB and overflow segments are estimated at their size');
        END IF;

        -- Above its quota on EPF_RT2_DATA until mode QUOTA.
        run('ALTER USER epf_rt2 QUOTA 1M ON epf_rt2_data');
        put('LAB|SETUP|DONE');
    END IF;

    -- CHECK (and the end of SETUP and QUOTA): the state the tests compare.
    SELECT COUNT(*) INTO l_count FROM dba_tablespaces
     WHERE tablespace_name IN ('EPF_RT2_DATA', 'EPF_RT2_INDX', 'EPF_RT2_SIDE');
    IF l_count < 3 THEN
        put('LAB|ABSENT');
        RETURN;
    END IF;
    FOR f IN (SELECT d.file_id, d.bytes, d.autoextensible, d.maxbytes, d.increment_by * t.block_size AS incr,
                     (SELECT NVL(MAX(e.block_id + e.blocks - 1), 0) * t.block_size FROM dba_extents e
                       WHERE e.file_id = d.file_id) AS hwm,
                     (SELECT NVL(SUM(s.bytes), 0) FROM dba_free_space s WHERE s.file_id = d.file_id) AS free
                FROM dba_data_files d
                JOIN dba_tablespaces t ON t.tablespace_name = d.tablespace_name
               WHERE d.tablespace_name IN ('EPF_RT2_DATA', 'EPF_RT2_INDX', 'EPF_RT2_SIDE')
               ORDER BY d.file_id) LOOP
        put('LAB|FILE|' || f.file_id || '|' || f.bytes || '|' || f.autoextensible || '|' || f.maxbytes || '|' || f.incr
            || '|' || f.hwm || '|' || f.free);
    END LOOP;
    SELECT NVL(SUM(bytes), 0) INTO l_value FROM dba_segments
     WHERE tablespace_name IN ('EPF_RT2_DATA', 'EPF_RT2_INDX', 'EPF_RT2_SIDE');
    put('LAB|SEGMENTS|' || l_value);
    FOR i IN (SELECT owner, index_name, status FROM dba_indexes
               WHERE table_owner = 'EPF_RT2' AND index_type <> 'LOB' AND dropped = 'NO'
               ORDER BY owner, index_name) LOOP
        put('LAB|INDEX|' || i.owner || '.' || i.index_name || '|' || i.status);
    END LOOP;
    FOR a IN (SELECT username, account_status FROM dba_users WHERE username = 'EPF_RT2') LOOP
        put('LAB|ACCOUNT|' || a.username || '|' || a.account_status);
    END LOOP;
    -- The tables Oracle keeps for the queue table are not counted.
    FOR t IN (SELECT table_name FROM dba_tables
               WHERE owner = 'EPF_RT2' AND dropped = 'NO' AND (iot_type IS NULL OR iot_type = 'IOT')
                 AND table_name NOT LIKE 'AQ$%'
               ORDER BY table_name) LOOP
        EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM epf_rt2.' || DBMS_ASSERT.ENQUOTE_NAME(t.table_name, FALSE) INTO l_value;
        put('LAB|ROWS|' || t.table_name || '|' || l_value);
    END LOOP;
    FOR l IN (SELECT table_name, column_name, securefile, in_row, cache, chunk, pctversion, tablespace_name FROM dba_lobs
               WHERE owner = 'EPF_RT2' AND table_name NOT LIKE 'AQ$%'
               ORDER BY table_name, column_name) LOOP
        put('LAB|LOB|' || l.table_name || '.' || l.column_name || '|securefile=' || l.securefile || '|in_row='
            || l.in_row || '|cache=' || l.cache || '|chunk=' || l.chunk || '|pctversion=' || l.pctversion || '|'
            || l.tablespace_name);
    END LOOP;
    SELECT MAX(value) INTO l_bin FROM v$parameter WHERE name = 'recyclebin';
    SELECT COUNT(*) INTO l_count FROM dba_recyclebin
     WHERE ts_name IN ('EPF_RT2_DATA', 'EPF_RT2_INDX', 'EPF_RT2_SIDE');
    put('LAB|RECYCLEBIN|' || UPPER(l_bin) || '|' || l_count);
    -- Segments with an INITIAL above 1 MB: a LOB segment as TABLE.COLUMN, an
    -- overflow segment as TABLE.OVERFLOW.
    FOR s IN (SELECT CASE WHEN g.segment_type = 'LOBSEGMENT'
                          THEN (SELECT MAX(l.table_name || '.' || l.column_name) FROM dba_lobs l
                                 WHERE l.owner = g.owner AND l.segment_name = g.segment_name)
                          WHEN t.iot_type = 'IOT_OVERFLOW' THEN t.iot_name || '.OVERFLOW'
                          ELSE g.segment_name END AS label,
                     g.segment_type, g.initial_extent, g.bytes
                FROM dba_segments g
                LEFT JOIN dba_tables t ON t.owner = g.owner AND t.table_name = g.segment_name
               WHERE g.owner = 'EPF_RT2' AND g.initial_extent > 1048576
               ORDER BY 1) LOOP
        put('LAB|INITIAL|' || s.label || '|' || s.segment_type || '|' || s.initial_extent || '|' || s.bytes);
    END LOOP;
    FOR q IN (SELECT tablespace_name, max_bytes, bytes FROM dba_ts_quotas WHERE username = 'EPF_RT2'
               ORDER BY tablespace_name) LOOP
        put('LAB|QUOTA|' || q.tablespace_name || '|' || q.max_bytes || '|' || q.bytes);
    END LOOP;
END;
/
EXIT SUCCESS

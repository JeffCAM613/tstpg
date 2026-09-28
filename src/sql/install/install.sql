-- ============================================================================
-- EPF Data Purge - Installer
-- ============================================================================
-- Purpose : Creates or upgrades the EPFPG tool schema and all its objects.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/install/install.sql <password>
--             <password>    password of EPFPG (set on create and on every upgrade;
--                           must not contain quotes)
-- Requires: SYS AS SYSDBA, Oracle 12.2 or later. In a multitenant database,
--           connect to the PDB service (CDB$ROOT is refused).
-- Effects : Creates tablespace EPFPG_DATA when it does not exist. It holds the
--           tool's objects only and is never a reclaim target. Its single
--           datafile is placed in the directory of the first datafile of the
--           tablespace holding most of the OPPAYMENTS segments, whatever that
--           tablespace is named (fallbacks: OP, OPREPORTS, the default
--           tablespace of those users, the database default tablespace,
--           SYSTEM). On ASM the file goes to the same disk group.
--           Creates user EPFPG (or updates password, default tablespace and
--           quota), creates missing tables, synchronises the registry and
--           settings, grants privileges, compiles the packages and stops with
--           an error if any EPFPG object is invalid. Safe to re-run.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 200 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET SQLBLANKLINES ON
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK
WHENEVER OSERROR EXIT FAILURE

DEFINE epf_password   = "&1"
DEFINE epf_tablespace = "EPFPG_DATA"

PROMPT
PROMPT == EPF install: checks
BEGIN
    IF SYS_CONTEXT('USERENV', 'SESSION_USER') <> 'SYS' THEN
        RAISE_APPLICATION_ERROR(-20900, 'Run install.sql as SYS AS SYSDBA.');
    END IF;
    IF SYS_CONTEXT('USERENV', 'CON_NAME') = 'CDB$ROOT' THEN
        RAISE_APPLICATION_ERROR(-20900, 'Connected to CDB$ROOT. Connect to the PDB service instead.');
    END IF;
    IF DBMS_DB_VERSION.VERSION < 12 OR (DBMS_DB_VERSION.VERSION = 12 AND DBMS_DB_VERSION.RELEASE < 2) THEN
        RAISE_APPLICATION_ERROR(-20900, 'Oracle 12.2 or later is required.');
    END IF;
    IF INSTR('&epf_password', '"') > 0 OR '&epf_password' IS NULL THEN
        RAISE_APPLICATION_ERROR(-20900, 'The EPFPG password must not be empty or contain double quotes.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('  container ' || SYS_CONTEXT('USERENV', 'CON_NAME'));
END;
/

PROMPT == EPF install: tool tablespace
DECLARE
    c_ts        CONSTANT VARCHAR2(30) := '&epf_tablespace';
    l_count     PLS_INTEGER;
    l_ref_ts    VARCHAR2(128);
    l_ref_basis VARCHAR2(200);
    l_ref_file  VARCHAR2(513);
    l_sep_pos   PLS_INTEGER;
    l_upper     BOOLEAN;
    l_file      VARCHAR2(513);
    l_created   BOOLEAN := FALSE;

    PROCEDURE create_ts(p_file IN VARCHAR2) IS
    BEGIN
        EXECUTE IMMEDIATE 'CREATE SMALLFILE TABLESPACE ' || c_ts
                       || ' DATAFILE ''' || REPLACE(p_file, '''', '''''') || ''''
                       || ' SIZE 128M AUTOEXTEND ON NEXT 128M MAXSIZE UNLIMITED'
                       || ' EXTENT MANAGEMENT LOCAL AUTOALLOCATE SEGMENT SPACE MANAGEMENT AUTO';
    END create_ts;
BEGIN
    SELECT COUNT(*) INTO l_count FROM dba_tablespaces WHERE tablespace_name = c_ts;
    IF l_count > 0 THEN
        SELECT COUNT(*)
          INTO l_count
          FROM dba_tablespaces
         WHERE tablespace_name = c_ts AND contents = 'PERMANENT' AND status = 'ONLINE';
        IF l_count = 0 THEN
            RAISE_APPLICATION_ERROR(-20900, 'Tablespace ' || c_ts || ' exists but is not an online permanent tablespace.');
        END IF;
        SELECT COUNT(*) INTO l_count FROM dba_segments WHERE tablespace_name = c_ts AND owner <> 'EPFPG';
        IF l_count > 0 THEN
            RAISE_APPLICATION_ERROR(-20900, 'Tablespace ' || c_ts || ' holds ' || l_count
                || ' segments not owned by EPFPG. It must contain the tool''s objects only.');
        END IF;
        FOR f IN (SELECT file_name FROM dba_data_files WHERE tablespace_name = c_ts ORDER BY file_id) LOOP
            DBMS_OUTPUT.PUT_LINE('  present  tablespace ' || c_ts || ', datafile ' || f.file_name);
        END LOOP;
        RETURN;
    END IF;

    -- Reference datafile: first datafile of the tablespace that holds the
    -- largest share of the OPPAYMENTS segments. Fallbacks, in order: the same
    -- for OP and OPREPORTS, the default tablespace of those users, the
    -- database default permanent tablespace, SYSTEM.
    SELECT tablespace_name, basis, file_name
      INTO l_ref_ts, l_ref_basis, l_ref_file
      FROM (SELECT c.tablespace_name, c.basis, f.file_name
              FROM (SELECT s.tablespace_name, 'largest share of ' || s.owner || ' segments' AS basis,
                           DECODE(s.owner, 'OPPAYMENTS', 10, 'OP', 20, 30) AS prio, SUM(s.bytes) AS bytes
                      FROM dba_segments s
                     WHERE s.owner IN ('OPPAYMENTS', 'OP', 'OPREPORTS')
                     GROUP BY s.owner, s.tablespace_name
                    UNION ALL
                    SELECT u.default_tablespace, 'default tablespace of ' || u.username,
                           DECODE(u.username, 'OPPAYMENTS', 11, 'OP', 21, 31), 0
                      FROM dba_users u
                     WHERE u.username IN ('OPPAYMENTS', 'OP', 'OPREPORTS')
                    UNION ALL
                    SELECT p.property_value, 'database default tablespace', 90, 0
                      FROM database_properties p
                     WHERE p.property_name = 'DEFAULT_PERMANENT_TABLESPACE'
                    UNION ALL
                    SELECT 'SYSTEM', 'SYSTEM tablespace', 99, 0 FROM dual) c
              JOIN dba_data_files f ON f.tablespace_name = c.tablespace_name
             ORDER BY c.prio, c.bytes DESC, f.file_id)
     WHERE ROWNUM = 1;
    DBMS_OUTPUT.PUT_LINE('  reference tablespace ' || l_ref_ts || ' (' || l_ref_basis || ')');
    DBMS_OUTPUT.PUT_LINE('  reference datafile   ' || l_ref_file);

    IF SUBSTR(l_ref_file, 1, 1) = '+' THEN
        -- ASM: the disk group name alone lets Oracle create and name the file.
        create_ts(SUBSTR(l_ref_file, 1, INSTR(l_ref_file || '/', '/') - 1));
    ELSE
        -- File system: same directory, file name in the letter case of the
        -- reference file. A name already used by the database or present on
        -- disk (ORA-27038) is skipped; an existing file is never reused.
        l_sep_pos := GREATEST(INSTR(l_ref_file, '/', -1), INSTR(l_ref_file, '\', -1));
        IF l_sep_pos = 0 THEN
            RAISE_APPLICATION_ERROR(-20900, 'Datafile name ' || l_ref_file || ' has no directory part.');
        END IF;
        l_upper := SUBSTR(l_ref_file, l_sep_pos + 1) = UPPER(SUBSTR(l_ref_file, l_sep_pos + 1));
        FOR i IN 1 .. 20 LOOP
            l_file := LOWER(c_ts) || TO_CHAR(i, 'FM00') || '.dbf';
            l_file := SUBSTR(l_ref_file, 1, l_sep_pos) || CASE WHEN l_upper THEN UPPER(l_file) ELSE l_file END;
            SELECT COUNT(*) INTO l_count FROM dba_data_files WHERE UPPER(file_name) = UPPER(l_file);
            IF l_count = 0 THEN
                BEGIN
                    create_ts(l_file);
                    l_created := TRUE;
                EXCEPTION
                    WHEN OTHERS THEN
                        IF INSTR(DBMS_UTILITY.FORMAT_ERROR_STACK, 'ORA-27038') = 0 THEN
                            RAISE;
                        END IF;
                        DBMS_OUTPUT.PUT_LINE('  skip     ' || l_file || ' (file already exists on disk)');
                END;
            END IF;
            EXIT WHEN l_created;
        END LOOP;
        IF NOT l_created THEN
            RAISE_APPLICATION_ERROR(-20900, 'No free datafile name for ' || c_ts || ' in '
                                            || SUBSTR(l_ref_file, 1, l_sep_pos) || '.');
        END IF;
    END IF;

    FOR f IN (SELECT file_name FROM dba_data_files WHERE tablespace_name = c_ts ORDER BY file_id) LOOP
        DBMS_OUTPUT.PUT_LINE('  created  tablespace ' || c_ts || ', datafile ' || f.file_name);
    END LOOP;
END;
/

PROMPT == EPF install: user EPFPG
DECLARE
    l_ts    VARCHAR2(128) := '&epf_tablespace';
    l_count PLS_INTEGER;
BEGIN
    SELECT COUNT(*) INTO l_count FROM dba_users WHERE username = 'EPFPG';
    IF l_count = 0 THEN
        EXECUTE IMMEDIATE 'CREATE USER epfpg IDENTIFIED BY "' || q'[&epf_password]' || '"'
                       || ' DEFAULT TABLESPACE ' || l_ts || ' QUOTA UNLIMITED ON ' || l_ts;
        DBMS_OUTPUT.PUT_LINE('  created  user EPFPG');
    ELSE
        EXECUTE IMMEDIATE 'ALTER USER epfpg IDENTIFIED BY "' || q'[&epf_password]' || '"'
                       || ' DEFAULT TABLESPACE ' || l_ts || ' QUOTA UNLIMITED ON ' || l_ts
                       || ' ACCOUNT UNLOCK';
        DBMS_OUTPUT.PUT_LINE('  updated  user EPFPG');
    END IF;
END;
/

ALTER SESSION SET CURRENT_SCHEMA = EPFPG;

PROMPT == EPF install: tables
@@tables.sql

PROMPT == EPF install: registry and settings
@@registry_data.sql

PROMPT == EPF install: privileges
@@grants.sql

PROMPT == EPF install: packages
@@epf_util.pks
@@epf_log.pks
@@epf_control.pks
@@epf_registry.pks
@@epf_util.pkb
@@epf_log.pkb
@@epf_control.pkb
@@epf_registry.pkb

ALTER SESSION SET CURRENT_SCHEMA = SYS;

PROMPT == EPF install: verification
DECLARE
    l_invalid PLS_INTEGER;
    l_version VARCHAR2(30);
BEGIN
    FOR e IN (SELECT name, type, line, position, text
                FROM dba_errors
               WHERE owner = 'EPFPG'
               ORDER BY name, type, sequence) LOOP
        DBMS_OUTPUT.PUT_LINE('  ' || e.type || ' ' || e.name || ' line ' || e.line || ':' || e.position
                             || '  ' || e.text);
    END LOOP;
    SELECT COUNT(*) INTO l_invalid FROM dba_objects WHERE owner = 'EPFPG' AND status <> 'VALID';
    IF l_invalid > 0 THEN
        RAISE_APPLICATION_ERROR(-20901, l_invalid || ' EPFPG objects are invalid (errors listed above).');
    END IF;
    EXECUTE IMMEDIATE 'SELECT value FROM epfpg.epf_setting WHERE name = ''tool_version''' INTO l_version;
    DBMS_OUTPUT.PUT_LINE('  EPFPG objects valid, tool version ' || l_version);
END;
/

PROMPT == EPF install: completed
EXIT SUCCESS

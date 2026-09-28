-- ============================================================================
-- EPF Data Purge - Installer
-- ============================================================================
-- Purpose : Creates or upgrades the EPFPG tool schema and all its objects.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/sql/install/install.sql <password> <tablespace>
--             <password>    password of EPFPG (set on create and on every upgrade;
--                           must not contain quotes)
--             <tablespace>  permanent tablespace for the tool's tables; it must
--                           not hold segments of the application schemas
--                           (OP, OPPAYMENTS, OPREPORTS), because those
--                           tablespaces are reclaim targets
-- Requires: SYS AS SYSDBA, Oracle 12.2 or later. In a multitenant database,
--           connect to the PDB service (CDB$ROOT is refused).
-- Effects : Creates user EPFPG (or updates password, default tablespace and
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
DEFINE epf_tablespace = "&2"

PROMPT
PROMPT == EPF install: checks
DECLARE
    l_ts    VARCHAR2(128) := UPPER(TRIM('&epf_tablespace'));
    l_count PLS_INTEGER;
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
    IF l_ts IN ('SYSTEM', 'SYSAUX') THEN
        RAISE_APPLICATION_ERROR(-20900, 'Choose a tablespace other than SYSTEM or SYSAUX.');
    END IF;
    SELECT COUNT(*)
      INTO l_count
      FROM dba_tablespaces
     WHERE tablespace_name = l_ts AND contents = 'PERMANENT' AND status = 'ONLINE';
    IF l_count = 0 THEN
        RAISE_APPLICATION_ERROR(-20900, 'Tablespace ' || l_ts || ' is not an online permanent tablespace.');
    END IF;
    SELECT COUNT(*)
      INTO l_count
      FROM dba_segments
     WHERE tablespace_name = l_ts
       AND owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS');
    IF l_count > 0 THEN
        RAISE_APPLICATION_ERROR(-20900, 'Tablespace ' || l_ts || ' holds ' || l_count
            || ' segments of the application schemas and would be a reclaim target. Choose another one.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('  container ' || SYS_CONTEXT('USERENV', 'CON_NAME')
                         || ', tool tablespace ' || l_ts);
END;
/

PROMPT == EPF install: user EPFPG
DECLARE
    l_ts    VARCHAR2(128) := DBMS_ASSERT.SIMPLE_SQL_NAME(UPPER(TRIM('&epf_tablespace')));
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

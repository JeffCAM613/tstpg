-- ============================================================================
-- EPF Data Purge - Parity check: purge by the previous tool
-- ============================================================================
-- Purpose : Runs the purge of the previous tool (legacy/) the way its wrapper
--           legacy/bin/epf_purge.bat does, without the wrapper: installs the
--           log tables and the package from legacy/sql (01, 02, 03), stops
--           when the package has compilation errors, then calls
--           oppayments.epf_purge_pkg.run_purge with the wrapper's arguments
--           (no dry run). The wrapper's optional steps around it (06, 08,
--           06b, 06c) end with EXIT and are run as separate commands, in the
--           order of plan 12.6.
-- Usage   : sqlplus -L "oppayments@<tns>" @src/tests/parity/legacy_purge.sql <retention_days> [<mode> [<depth> [<batch_size>]]]
--             mode        FULL (default), CLOB_ONLY or CLOB_N_LOGS
--             depth       ALL (default), or PAYMENTS, LOGS, BANK_STATEMENTS
--                         separated by commas
--             batch_size  1000 (default, the wrapper's)
--           Run from the top folder of the tool (the one with src, legacy
--           and logs).
-- Requires: OPPAYMENTS, the schema the previous tool installs into and runs as.
-- Effects : Deletes (FULL) or clears (CLOB modes) application data. Creates or
--           replaces the previous tool's objects in OPPAYMENTS. Writes
--           logs/parity/legacy_purge.txt.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

-- Optional arguments 2 to 4: defined as empty when not given (a query without
-- rows defines a NEW_VALUE variable that is not defined yet).
SET TERMOUT OFF
COLUMN 2 NEW_VALUE 2 NOPRINT
COLUMN 3 NEW_VALUE 3 NOPRINT
COLUMN 4 NEW_VALUE 4 NOPRINT
SELECT NULL AS "2", NULL AS "3", NULL AS "4" FROM dual WHERE 1 = 0;
COLUMN days_value  NEW_VALUE p_days  NOPRINT
COLUMN mode_value  NEW_VALUE p_mode  NOPRINT
COLUMN depth_value NEW_VALUE p_depth NOPRINT
COLUMN batch_value NEW_VALUE p_batch NOPRINT
SELECT TRIM('&1') AS days_value, NVL(UPPER(TRIM('&2')), 'FULL') AS mode_value,
       NVL(UPPER(REPLACE('&3', ' ')), 'ALL') AS depth_value, NVL(TRIM('&4'), '1000') AS batch_value
  FROM dual;
SET TERMOUT ON

BEGIN
    IF USER <> 'OPPAYMENTS' THEN
        RAISE_APPLICATION_ERROR(-20193, 'Connect as OPPAYMENTS: the previous tool installs into and runs as that schema (connected as ' || USER || ').');
    END IF;
    IF NOT REGEXP_LIKE('&p_days', '^\d+$') THEN
        RAISE_APPLICATION_ERROR(-20194, 'Retention: a number of days (got &p_days).');
    END IF;
    IF '&p_mode' NOT IN ('FULL', 'CLOB_ONLY', 'CLOB_N_LOGS') THEN
        RAISE_APPLICATION_ERROR(-20195, 'Mode: FULL, CLOB_ONLY or CLOB_N_LOGS (got &p_mode).');
    END IF;
    IF NOT REGEXP_LIKE('&p_batch', '^\d+$') THEN
        RAISE_APPLICATION_ERROR(-20196, 'Batch size: a number (got &p_batch).');
    END IF;
END;
/

HOST mkdir logs\parity 2>NUL
SPOOL logs\parity\legacy_purge.txt

-- Installation as the wrapper does it: errors of the individual statements
-- do not stop it (the scripts create what is missing); the compilation
-- check below does.
PROMPT == Previous tool: install (legacy/sql 01, 02, 03)
WHENEVER SQLERROR CONTINUE
SET FEEDBACK ON DEFINE OFF
@legacy/sql/01_create_purge_log_table.sql
@legacy/sql/02_epf_purge_pkg_spec.sql
@legacy/sql/03_epf_purge_pkg_body.sql
SET FEEDBACK OFF DEFINE ON
SET ECHO OFF TAB OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED

WHENEVER SQLERROR EXIT FAILURE
DECLARE
    l_errors NUMBER;
    l_valid  NUMBER;
BEGIN
    SELECT COUNT(*) INTO l_errors FROM user_errors WHERE name = 'EPF_PURGE_PKG';
    SELECT COUNT(*) INTO l_valid FROM user_objects
     WHERE object_name = 'EPF_PURGE_PKG' AND object_type IN ('PACKAGE', 'PACKAGE BODY') AND status = 'VALID';
    FOR e IN (SELECT type, line, text FROM user_errors WHERE name = 'EPF_PURGE_PKG' ORDER BY type, sequence) LOOP
        DBMS_OUTPUT.PUT_LINE('  ' || e.type || ' line ' || e.line || ': ' || e.text);
    END LOOP;
    IF l_errors > 0 OR l_valid < 2 THEN
        RAISE_APPLICATION_ERROR(-20197, 'The package of the previous tool is missing or did not compile: nothing was purged.');
    END IF;
    DBMS_OUTPUT.PUT_LINE('  package OPPAYMENTS.EPF_PURGE_PKG valid');
END;
/

PROMPT == Previous tool: run_purge (retention &p_days days, depth &p_depth, mode &p_mode, batch &p_batch); output at the end
PROMPT    Progress meanwhile, from another session: SELECT module, operation, table_name, rows_affected, status, log_timestamp
PROMPT    FROM oppayments.epf_purge_log ORDER BY log_timestamp DESC FETCH FIRST 5 ROWS ONLY;
SET TIMING ON
BEGIN
    oppayments.epf_purge_pkg.run_purge(
        p_retention_days => &p_days,
        p_purge_depth    => '&p_depth',
        p_batch_size     => &p_batch,
        p_dry_run        => FALSE,
        p_purge_mode     => '&p_mode'
    );
END;
/
SET TIMING OFF

PROMPT == Errors logged by the previous tool in this run
SELECT '  ' || module || ' ' || NVL(table_name, '-') || ': ' || NVL(error_message, message)
  FROM oppayments.epf_purge_log
 WHERE status = 'ERROR'
   AND run_id = (SELECT run_id FROM (SELECT run_id FROM oppayments.epf_purge_log
                                      WHERE operation = 'RUN_START' ORDER BY log_timestamp DESC)
                  WHERE ROWNUM = 1)
 ORDER BY log_timestamp;
PROMPT == End (no lines above: no errors)
SPOOL OFF
PROMPT Written: logs\parity\legacy_purge.txt
EXIT SUCCESS

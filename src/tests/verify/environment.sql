-- ============================================================================
-- EPF Data Purge - Environment survey (read-only)
-- ============================================================================
-- Purpose : Collects the facts the purge and reclaim design depends on:
--           version, container, tablespace layout of the application schemas,
--           owners and object kinds in those tablespaces, LONG columns,
--           foreign keys into purge tables, indexes on purge paths.
-- Usage   : sqlplus -L "sys@<service> AS SYSDBA" @src/tests/verify/environment.sql
--           Writes epf_environment.txt in the current directory.
-- Requires: SYS AS SYSDBA (or a user with SELECT ANY DICTIONARY).
-- Effects : None. Only SELECT statements.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF TRIMSPOOL ON PAGESIZE 200 LINESIZE 250
SET HEADING ON TAB OFF
COLUMN name              FORMAT A40
COLUMN value             FORMAT A80
COLUMN owner             FORMAT A20
COLUMN tablespace_name   FORMAT A24
COLUMN segment_type      FORMAT A20
COLUMN table_name        FORMAT A32
COLUMN column_name       FORMAT A30
COLUMN constraint_name   FORMAT A30
COLUMN detail            FORMAT A80
COLUMN index_name        FORMAT A32
COLUMN file_name         FORMAT A70

SPOOL epf_environment.txt

PROMPT ==== 1. Database
SELECT 'version' AS name, version AS value FROM v$instance
UNION ALL SELECT 'banner', banner FROM v$version WHERE ROWNUM = 1
UNION ALL SELECT 'container', SYS_CONTEXT('USERENV', 'CON_NAME') FROM dual
UNION ALL SELECT 'cdb', cdb FROM v$database
UNION ALL SELECT 'log_mode', log_mode FROM v$database
UNION ALL SELECT 'force_logging', force_logging FROM v$database
UNION ALL SELECT 'database_role', database_role FROM v$database
UNION ALL SELECT 'platform', platform_name FROM v$database
UNION ALL SELECT 'db_create_file_dest (OMF)', NVL(value, '(not set)') FROM v$parameter WHERE name = 'db_create_file_dest'
UNION ALL SELECT 'standby_file_management', value FROM v$parameter WHERE name = 'standby_file_management'
UNION ALL SELECT 'default_permanent_tablespace', property_value FROM database_properties WHERE property_name = 'DEFAULT_PERMANENT_TABLESPACE'
UNION ALL SELECT 'local_undo_enabled', property_value FROM database_properties WHERE property_name = 'LOCAL_UNDO_ENABLED';

PROMPT ==== 2. Application schemas
SELECT username AS owner, account_status AS name, default_tablespace AS tablespace_name
  FROM dba_users
 WHERE username IN ('OP', 'OPPAYMENTS', 'OPREPORTS', 'EPFPG')
 ORDER BY username;

PROMPT ==== 3. Tablespaces holding application segments
SELECT t.tablespace_name, t.bigfile, t.extent_management || '/' || t.allocation_type AS name,
       t.segment_space_management AS value, t.encrypted,
       (SELECT COUNT(*) FROM dba_data_files f WHERE f.tablespace_name = t.tablespace_name) AS files,
       (SELECT ROUND(SUM(bytes) / 1073741824, 2) FROM dba_data_files f WHERE f.tablespace_name = t.tablespace_name) AS file_gb,
       (SELECT ROUND(SUM(bytes) / 1073741824, 2) FROM dba_segments s WHERE s.tablespace_name = t.tablespace_name) AS used_gb
  FROM dba_tablespaces t
 WHERE t.tablespace_name IN (SELECT DISTINCT tablespace_name FROM dba_segments
                              WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS'))
 ORDER BY t.tablespace_name;

PROMPT ==== 4. Datafiles of those tablespaces
SELECT f.tablespace_name, f.file_id, f.file_name, ROUND(f.bytes / 1073741824, 2) AS gb,
       f.autoextensible, ROUND(f.maxbytes / 1073741824, 2) AS max_gb
  FROM dba_data_files f
 WHERE f.tablespace_name IN (SELECT DISTINCT tablespace_name FROM dba_segments
                              WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS'))
 ORDER BY f.tablespace_name, f.file_id;

PROMPT ==== 5. Owners and segment types in those tablespaces
SELECT s.tablespace_name, s.owner, s.segment_type, COUNT(*) AS segments,
       ROUND(SUM(s.bytes) / 1048576, 1) AS mb
  FROM dba_segments s
 WHERE s.tablespace_name IN (SELECT DISTINCT tablespace_name FROM dba_segments
                              WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS'))
 GROUP BY s.tablespace_name, s.owner, s.segment_type
 ORDER BY s.tablespace_name, s.owner, s.segment_type;

PROMPT ==== 6. Users whose default tablespace or quota is one of those tablespaces
SELECT u.username AS owner, 'DEFAULT' AS name, u.default_tablespace AS tablespace_name
  FROM dba_users u
 WHERE u.default_tablespace IN (SELECT DISTINCT tablespace_name FROM dba_segments
                                 WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS'))
UNION ALL
SELECT q.username, 'QUOTA ' || DECODE(q.max_bytes, -1, 'UNLIMITED', ROUND(q.max_bytes / 1048576) || ' MB'), q.tablespace_name
  FROM dba_ts_quotas q
 WHERE q.tablespace_name IN (SELECT DISTINCT tablespace_name FROM dba_segments
                              WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS'))
 ORDER BY 3, 1;

PROMPT ==== 7. Tables without a segment (deferred) assigned to those tablespaces
SELECT t.owner, t.tablespace_name, COUNT(*) AS tables
  FROM dba_tables t
 WHERE t.segment_created = 'NO'
   AND t.tablespace_name IN (SELECT DISTINCT tablespace_name FROM dba_segments
                              WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS'))
 GROUP BY t.owner, t.tablespace_name
 ORDER BY 1, 2;

PROMPT ==== 8. LONG / LONG RAW columns in tables of those tablespaces
SELECT c.owner, c.table_name, c.column_name, c.data_type AS name, t.tablespace_name, t.num_rows
  FROM dba_tab_columns c
  JOIN dba_tables t ON t.owner = c.owner AND t.table_name = c.table_name
 WHERE c.data_type IN ('LONG', 'LONG RAW')
   AND t.tablespace_name IN (SELECT DISTINCT tablespace_name FROM dba_segments
                              WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS'))
 ORDER BY c.owner, c.table_name;

PROMPT ==== 9. Objects that need special handling (partitioned, IOT, cluster, queue, nested)
SELECT owner, table_name, 'PARTITIONED' AS name FROM dba_tables WHERE partitioned = 'YES' AND owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS')
UNION ALL SELECT owner, table_name, 'IOT ' || iot_type FROM dba_tables WHERE iot_type IS NOT NULL AND owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS')
UNION ALL SELECT owner, table_name, 'CLUSTER ' || cluster_name FROM dba_tables WHERE cluster_name IS NOT NULL AND owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS')
UNION ALL SELECT owner, queue_table, 'QUEUE TABLE' FROM dba_queue_tables WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS')
UNION ALL SELECT owner, table_name, 'NESTED' FROM dba_nested_tables WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS')
 ORDER BY 1, 2;

PROMPT ==== 10. Recycle bin objects in those tablespaces
SELECT owner, original_name AS table_name, type AS name, ts_name AS tablespace_name, space
  FROM dba_recyclebin
 WHERE ts_name IN (SELECT DISTINCT tablespace_name FROM dba_segments
                    WHERE owner IN ('OP', 'OPPAYMENTS', 'OPREPORTS'))
 ORDER BY owner, original_name;

PROMPT ==== 11. Purge tables: presence, rows (statistics), size
WITH reg (owner, table_name) AS (
    SELECT 'OPPAYMENTS', 'BULK_PAYMENT' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'BULK_PAYMENT_ADDITIONAL_INFO' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'BULK_SIGNATURE' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'MANDATORY_SIGNERS' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'OIDC_REQUEST_TOKEN' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'PAYMENT_AUDIT' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'TRANSMISSION_EXECUTION_AUDIT' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'IMPORT_AUDIT_MESSAGES' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'NOTIFICATION_EXECUTION' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'IMPORT_AUDIT' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'TRANSMISSION_EXECUTION' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'TRANSMISSION_EXCEPTION' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'APPROBATION_EXECUTION_OPT' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'WORKFLOW_EXECUTION_OPT' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'APPROBATION_EXECUTION' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'WORKFLOW_EXECUTION' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'BULKPAYMENT_EXCEPTION' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'INVOICE_ADDITIONAL_INFO' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'INVOICE' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'PAYMENT_ADDITIONAL_INFO' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'PAYMENT' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'FILE_INTEGRATION' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'AUDIT_ARCHIVE' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'AUDIT_TRAIL' FROM dual
    UNION ALL SELECT 'OP', 'SPEC_TRT_LOG' FROM dual UNION ALL SELECT 'OPPAYMENTS', 'DIRECTORY_DISPATCHING' FROM dual
    UNION ALL SELECT 'OPPAYMENTS', 'FILE_DISPATCHING' FROM dual)
SELECT r.owner, r.table_name, NVL2(t.table_name, 'present', 'MISSING') AS name, t.tablespace_name,
       t.num_rows, TO_CHAR(t.last_analyzed, 'YYYY-MM-DD') AS analyzed,
       (SELECT ROUND(SUM(s.bytes) / 1048576, 1)
          FROM dba_segments s
         WHERE s.owner = r.owner
           AND (s.segment_name = r.table_name
                OR s.segment_name IN (SELECT l.segment_name FROM dba_lobs l
                                       WHERE l.owner = r.owner AND l.table_name = r.table_name))) AS mb
  FROM reg r
  LEFT JOIN dba_tables t ON t.owner = r.owner AND t.table_name = r.table_name
 ORDER BY r.owner, r.table_name;

PROMPT ==== 12. Foreign keys into purge tables (any schema)
SELECT c.owner, c.table_name, c.constraint_name, c.delete_rule AS name, c.status AS value,
       p.owner || '.' || p.table_name AS detail
  FROM dba_constraints c
  JOIN dba_constraints p ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
 WHERE c.constraint_type = 'R'
   AND (p.owner, p.table_name) IN (
        SELECT 'OP', 'SPEC_TRT_LOG' FROM dual
        UNION ALL
        SELECT 'OPPAYMENTS', table_name FROM dba_tables
         WHERE owner = 'OPPAYMENTS'
           AND table_name IN ('BULK_PAYMENT', 'BULK_PAYMENT_ADDITIONAL_INFO', 'BULK_SIGNATURE', 'MANDATORY_SIGNERS',
                              'OIDC_REQUEST_TOKEN', 'PAYMENT_AUDIT', 'TRANSMISSION_EXECUTION_AUDIT',
                              'IMPORT_AUDIT_MESSAGES', 'NOTIFICATION_EXECUTION', 'IMPORT_AUDIT',
                              'TRANSMISSION_EXECUTION', 'TRANSMISSION_EXCEPTION', 'APPROBATION_EXECUTION_OPT',
                              'WORKFLOW_EXECUTION_OPT', 'APPROBATION_EXECUTION', 'WORKFLOW_EXECUTION',
                              'BULKPAYMENT_EXCEPTION', 'INVOICE_ADDITIONAL_INFO', 'INVOICE',
                              'PAYMENT_ADDITIONAL_INFO', 'PAYMENT', 'FILE_INTEGRATION', 'AUDIT_ARCHIVE',
                              'AUDIT_TRAIL', 'DIRECTORY_DISPATCHING', 'FILE_DISPATCHING'))
 ORDER BY p.owner, p.table_name, c.owner, c.table_name;

PROMPT ==== 13. Leading index columns on purge paths
SELECT i.table_owner AS owner, i.table_name, c.column_name, i.index_name, i.status AS name
  FROM dba_indexes i
  JOIN dba_ind_columns c ON c.index_owner = i.owner AND c.index_name = i.index_name AND c.column_position = 1
 WHERE (i.table_owner, i.table_name, c.column_name) IN (
        SELECT 'OPPAYMENTS', 'BULK_PAYMENT', 'VALUE_DATE' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'FILE_INTEGRATION', 'INTEGRATION_DATE' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'AUDIT_TRAIL', 'AUDIT_TIMESTAMP' FROM dual
        UNION ALL SELECT 'OP', 'SPEC_TRT_LOG', 'DTLOG' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'FILE_DISPATCHING', 'DATE_RECEPTION' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'DIRECTORY_DISPATCHING', 'FILE_DISPATCHING_ID' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'AUDIT_ARCHIVE', 'AUDIT_ARCHIVE_ID' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'PAYMENT', 'BULK_PAYMENT_ID' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'IMPORT_AUDIT_MESSAGES', 'IMPORT_AUDIT_ID' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'APPROBATION_EXECUTION', 'EXECUTION_ID' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'APPROBATION_EXECUTION_OPT', 'EXECUTION_ID' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'WORKFLOW_EXECUTION', 'PAYMENT_ID' FROM dual
        UNION ALL SELECT 'OPPAYMENTS', 'INVOICE_ADDITIONAL_INFO', 'INVOICE_ID' FROM dual)
 ORDER BY 1, 2, 3;

PROMPT ==== 14. Previous tool objects in OPPAYMENTS
SELECT owner, object_name AS table_name, object_type AS name, status AS value
  FROM dba_objects
 WHERE owner = 'OPPAYMENTS'
   AND object_name LIKE 'EPF%'
 ORDER BY object_type, object_name;

PROMPT ==== 15. INHERIT PRIVILEGES granted on SYS
SELECT grantee AS owner, privilege AS name
  FROM dba_tab_privs
 WHERE table_name = 'SYS' AND privilege = 'INHERIT PRIVILEGES'
 ORDER BY grantee;

PROMPT ==== end of survey
SPOOL OFF
EXIT

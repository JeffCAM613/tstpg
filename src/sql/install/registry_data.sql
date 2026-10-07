-- ============================================================================
-- EPF Data Purge - Registry and settings
-- ============================================================================
-- Purpose : Single source of truth for the purge scope: modules, tables,
--           relationships (links) and tunable settings.
-- Usage   : Called by install.sql with CURRENT_SCHEMA set to EPFPG.
-- Effects : Modules, tables and links are synchronised with the content of
--           this file (rows no longer listed are deactivated or removed).
--           Settings are inserted when missing; values already present are
--           kept, only their description is refreshed; settings no longer
--           listed are removed. tool_version is always set to the value in
--           this file.
--
-- Table roles
--   ROOT       selected by date_column < cutoff date
--   DEPENDENT  selected through EPF_LINK: rows whose match_column is in the
--              key set of the source table's source_column
-- Within a root tree, tables are processed in ascending delete_order:
-- a dependent always has a lower delete_order than every source it uses.
-- ============================================================================

DECLARE
    g_tables   SYS.ODCINUMBERLIST   := SYS.ODCINUMBERLIST();
    g_links    SYS.ODCINUMBERLIST   := SYS.ODCINUMBERLIST();
    g_settings SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();

    PROCEDURE put_module(p_code IN VARCHAR2, p_order IN NUMBER, p_description IN VARCHAR2) IS
    BEGIN
        MERGE INTO epf_module m
        USING (SELECT p_code AS module_code FROM dual) x
           ON (m.module_code = x.module_code)
         WHEN MATCHED THEN
              UPDATE SET m.display_order = p_order, m.description = p_description
         WHEN NOT MATCHED THEN
              INSERT (module_code, display_order, description)
              VALUES (p_code, p_order, p_description);
    END put_module;

    PROCEDURE put_table(
        p_id          IN NUMBER,
        p_module      IN VARCHAR2,
        p_root_id     IN NUMBER,
        p_owner       IN VARCHAR2,
        p_table       IN VARCHAR2,
        p_role        IN VARCHAR2,
        p_key_column  IN VARCHAR2,
        p_date_column IN VARCHAR2,
        p_order       IN NUMBER,
        p_description IN VARCHAR2
    ) IS
    BEGIN
        MERGE INTO epf_table t
        USING (SELECT p_id AS table_id FROM dual) x
           ON (t.table_id = x.table_id)
         WHEN MATCHED THEN
              UPDATE SET t.module_code   = p_module,
                         t.root_table_id = p_root_id,
                         t.owner         = p_owner,
                         t.table_name    = p_table,
                         t.role          = p_role,
                         t.key_column    = p_key_column,
                         t.date_column   = p_date_column,
                         t.delete_order  = p_order,
                         t.lob_clear     = 'Y',
                         t.active        = 'Y',
                         t.description   = p_description
         WHEN NOT MATCHED THEN
              INSERT (table_id, module_code, root_table_id, owner, table_name, role,
                      key_column, date_column, delete_order, lob_clear, active, description)
              VALUES (p_id, p_module, p_root_id, p_owner, p_table, p_role,
                      p_key_column, p_date_column, p_order, 'Y', 'Y', p_description);
        g_tables.EXTEND;
        g_tables(g_tables.COUNT) := p_id;
    END put_table;

    PROCEDURE put_link(
        p_id            IN NUMBER,
        p_table_id      IN NUMBER,
        p_match_column  IN VARCHAR2,
        p_source_id     IN NUMBER,
        p_source_column IN VARCHAR2
    ) IS
    BEGIN
        MERGE INTO epf_link l
        USING (SELECT p_id AS link_id FROM dual) x
           ON (l.link_id = x.link_id)
         WHEN MATCHED THEN
              UPDATE SET l.table_id        = p_table_id,
                         l.match_column    = p_match_column,
                         l.source_table_id = p_source_id,
                         l.source_column   = p_source_column
         WHEN NOT MATCHED THEN
              INSERT (link_id, table_id, match_column, source_table_id, source_column)
              VALUES (p_id, p_table_id, p_match_column, p_source_id, p_source_column);
        g_links.EXTEND;
        g_links(g_links.COUNT) := p_id;
    END put_link;

    PROCEDURE put_setting(p_name IN VARCHAR2, p_value IN VARCHAR2, p_description IN VARCHAR2,
                          p_force IN BOOLEAN DEFAULT FALSE) IS
    BEGIN
        MERGE INTO epf_setting s
        USING (SELECT p_name AS name FROM dual) x
           ON (s.name = x.name)
         WHEN MATCHED THEN
              UPDATE SET s.description = p_description
         WHEN NOT MATCHED THEN
              INSERT (name, value, description) VALUES (p_name, p_value, p_description);
        IF p_force THEN
            UPDATE epf_setting
               SET value = p_value, updated_at = SYSTIMESTAMP
             WHERE name = p_name;
        END IF;
        g_settings.EXTEND;
        g_settings(g_settings.COUNT) := p_name;
    END put_setting;
BEGIN
    -- ------------------------------------------------------------------
    -- Modules
    -- ------------------------------------------------------------------
    put_module('PAYMENTS',        1, 'Bulk payments with all dependent records, and file integrations');
    put_module('LOGS',            2, 'Functional audit trail and technical logs');
    put_module('BANK_STATEMENTS', 3, 'Bank statement dispatching');

    -- ------------------------------------------------------------------
    -- PAYMENTS: bulk_payment tree (root 121)
    -- ------------------------------------------------------------------
    put_table(101, 'PAYMENTS', 121, 'OPPAYMENTS', 'BULK_PAYMENT_ADDITIONAL_INFO', 'DEPENDENT', NULL, NULL,  10, 'Additional information of a bulk payment');
    put_table(102, 'PAYMENTS', 121, 'OPPAYMENTS', 'BULK_SIGNATURE',               'DEPENDENT', NULL, NULL,  20, 'Signatures of a bulk payment');
    put_table(103, 'PAYMENTS', 121, 'OPPAYMENTS', 'MANDATORY_SIGNERS',            'DEPENDENT', NULL, NULL,  30, 'Mandatory signers of a bulk payment');
    put_table(104, 'PAYMENTS', 121, 'OPPAYMENTS', 'OIDC_REQUEST_TOKEN',           'DEPENDENT', NULL, NULL,  40, 'OIDC request tokens of a bulk payment');
    put_table(105, 'PAYMENTS', 121, 'OPPAYMENTS', 'PAYMENT_AUDIT',                'DEPENDENT', NULL, NULL,  50, 'Payment audit rows (by bulk payment and by payment)');
    put_table(106, 'PAYMENTS', 121, 'OPPAYMENTS', 'TRANSMISSION_EXECUTION_AUDIT', 'DEPENDENT', NULL, NULL,  60, 'Transmission execution audit');
    put_table(107, 'PAYMENTS', 121, 'OPPAYMENTS', 'IMPORT_AUDIT_MESSAGES',        'DEPENDENT', NULL, NULL,  70, 'Messages of an import audit');
    put_table(108, 'PAYMENTS', 121, 'OPPAYMENTS', 'NOTIFICATION_EXECUTION',       'DEPENDENT', NULL, NULL,  80, 'Notification executions');
    put_table(109, 'PAYMENTS', 121, 'OPPAYMENTS', 'IMPORT_AUDIT',                 'DEPENDENT', 'IMPORT_AUDIT_ID', NULL,  90, 'Import audit of a bulk payment');
    put_table(110, 'PAYMENTS', 121, 'OPPAYMENTS', 'TRANSMISSION_EXECUTION',       'DEPENDENT', NULL, NULL, 100, 'Transmission executions');
    put_table(111, 'PAYMENTS', 121, 'OPPAYMENTS', 'TRANSMISSION_EXCEPTION',       'DEPENDENT', NULL, NULL, 110, 'Transmission exceptions');
    put_table(112, 'PAYMENTS', 121, 'OPPAYMENTS', 'APPROBATION_EXECUTION_OPT',    'DEPENDENT', NULL, NULL, 120, 'Approbation executions (optimised workflow)');
    put_table(113, 'PAYMENTS', 121, 'OPPAYMENTS', 'WORKFLOW_EXECUTION_OPT',       'DEPENDENT', 'EXECUTION_ID', NULL, 130, 'Workflow executions (optimised workflow)');
    put_table(114, 'PAYMENTS', 121, 'OPPAYMENTS', 'APPROBATION_EXECUTION',        'DEPENDENT', NULL, NULL, 140, 'Approbation executions');
    put_table(115, 'PAYMENTS', 121, 'OPPAYMENTS', 'WORKFLOW_EXECUTION',           'DEPENDENT', 'EXECUTION_ID', NULL, 150, 'Workflow executions of a payment');
    put_table(116, 'PAYMENTS', 121, 'OPPAYMENTS', 'BULKPAYMENT_EXCEPTION',        'DEPENDENT', NULL, NULL, 160, 'Payment exceptions');
    put_table(117, 'PAYMENTS', 121, 'OPPAYMENTS', 'INVOICE_ADDITIONAL_INFO',      'DEPENDENT', NULL, NULL, 170, 'Additional information of an invoice');
    put_table(118, 'PAYMENTS', 121, 'OPPAYMENTS', 'INVOICE',                      'DEPENDENT', 'INVOICE_ID', NULL, 180, 'Invoices of a payment');
    put_table(119, 'PAYMENTS', 121, 'OPPAYMENTS', 'PAYMENT_ADDITIONAL_INFO',      'DEPENDENT', NULL, NULL, 190, 'Additional information of a payment');
    put_table(120, 'PAYMENTS', 121, 'OPPAYMENTS', 'PAYMENT',                      'DEPENDENT', 'PAYMENT_ID', NULL, 200, 'Payments of a bulk payment');
    put_table(121, 'PAYMENTS', 121, 'OPPAYMENTS', 'BULK_PAYMENT',                 'ROOT', 'BULK_PAYMENT_ID', 'VALUE_DATE', 210, 'Bulk payments (root, by value date)');

    -- PAYMENTS: file_integration (standalone root 131)
    put_table(131, 'PAYMENTS', 131, 'OPPAYMENTS', 'FILE_INTEGRATION', 'ROOT', NULL, 'INTEGRATION_DATE', 10, 'Fast-import payment files (root, by integration date)');

    -- LOGS: audit_trail tree (root 202) and spec_trt_log (root 211)
    put_table(201, 'LOGS', 202, 'OPPAYMENTS', 'AUDIT_ARCHIVE', 'DEPENDENT', NULL, NULL, 10, 'Archived audit payloads referenced by audit_trail');
    put_table(202, 'LOGS', 202, 'OPPAYMENTS', 'AUDIT_TRAIL',   'ROOT', 'AUDIT_ID', 'AUDIT_TIMESTAMP', 20, 'Functional audit trail (root, by audit timestamp)');
    put_table(211, 'LOGS', 211, 'OP',         'SPEC_TRT_LOG',  'ROOT', NULL, 'DTLOG', 10, 'Technical log (root, by log date)');

    -- BANK_STATEMENTS: file_dispatching tree (root 302)
    put_table(301, 'BANK_STATEMENTS', 302, 'OPPAYMENTS', 'DIRECTORY_DISPATCHING', 'DEPENDENT', NULL, NULL, 10, 'Directory dispatching of a received file');
    put_table(302, 'BANK_STATEMENTS', 302, 'OPPAYMENTS', 'FILE_DISPATCHING',      'ROOT', 'FILE_DISPATCHING_ID', 'DATE_RECEPTION', 20, 'Received bank statement files (root, by reception date)');

    -- ------------------------------------------------------------------
    -- Links: (link, dependent table, match column, source table, source column)
    -- ------------------------------------------------------------------
    put_link( 1, 101, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link( 2, 102, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link( 3, 103, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link( 4, 104, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link( 5, 105, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link( 6, 105, 'PAYMENT_ID',      120, 'PAYMENT_ID');
    put_link( 7, 106, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link( 8, 107, 'IMPORT_AUDIT_ID', 109, 'IMPORT_AUDIT_ID');
    put_link( 9, 108, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link(10, 109, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link(11, 110, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link(12, 111, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link(13, 112, 'EXECUTION_ID',    113, 'EXECUTION_ID');
    put_link(14, 113, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link(15, 114, 'EXECUTION_ID',    115, 'EXECUTION_ID');
    put_link(16, 115, 'PAYMENT_ID',      120, 'PAYMENT_ID');
    put_link(17, 116, 'PAYMENT_ID',      120, 'PAYMENT_ID');
    put_link(18, 117, 'INVOICE_ID',      118, 'INVOICE_ID');
    put_link(19, 118, 'PAYMENT_ID',      120, 'PAYMENT_ID');
    put_link(20, 119, 'PAYMENT_ID',      120, 'PAYMENT_ID');
    put_link(21, 120, 'BULK_PAYMENT_ID', 121, 'BULK_PAYMENT_ID');
    put_link(22, 201, 'AUDIT_ARCHIVE_ID', 202, 'AUDIT_ARCHIVE_ID');
    put_link(23, 301, 'FILE_DISPATCHING_ID', 302, 'FILE_DISPATCHING_ID');

    -- Remove links and deactivate tables that are no longer listed above.
    DELETE FROM epf_link
     WHERE link_id NOT IN (SELECT column_value FROM TABLE(g_links));
    UPDATE epf_table
       SET active = 'N'
     WHERE table_id NOT IN (SELECT column_value FROM TABLE(g_tables));

    -- ------------------------------------------------------------------
    -- Settings
    -- ------------------------------------------------------------------
    put_setting('tool_version',           '0.7.11', 'Version of the installed tool objects', p_force => TRUE);
    put_setting('app_schemas',            'OP,OPPAYMENTS,OPREPORTS', 'Application schemas; the tablespaces they occupy are reclaim candidates');
    put_setting('retention_days_default', '30',    'Retention in days when none is given');
    put_setting('retention_days_min',     '1',     'Smallest retention accepted');
    put_setting('batch_size_default',     '1000',  'Root rows per purge batch when none is given');
    put_setting('batch_rows_max',         '200000', 'Rows a purge batch holds at most besides its batch size in root rows; a root whose tree alone holds more is a batch of its own');
    put_setting('progress_interval_s',    '5',     'Minimum seconds between progress events of one module');
    put_setting('lob_throttle_ms',        '500',   'Pause between LOB-clearing batches (space management background process)');
    put_setting('history_retention_days', '180',   'Runs older than this are removed at the start of a new run');
    put_setting('ddl_lock_timeout_s',     '30',    'ddl_lock_timeout used for every DDL issued by the tool');
    put_setting('ddl_retries',            '3',     'Retries after ORA-00054 before a DDL is reported as failed');
    put_setting('resumable_timeout_s',    '1800',  'A reclaim''s index rebuild waits this many seconds for space (resumable) before it fails');
    put_setting('disconnect_timeout_s',   '300',   'Seconds a reclaim waits for POST_TRANSACTION disconnects before IMMEDIATE');
    put_setting('reclaim_growth_mb',      '0',     'How far a reclaim may grow a datafile above its size at the start, to move a table that does not fit below');
    put_setting('reclaim_margin_mb',      '64',    'Free space a reclaim leaves at the end of each datafile it compacts');
    put_setting('reclaim_unit_moves',     '3',     'Moves of one table in a reclaim after which its copy holds the top of its datafile again; then it is not moved again (10 moves at most)');
    put_setting('reclaim_test_pause_s',   '0',     'Tests only: the next compaction pauses this many seconds (at most 600) after each table that moves, or until a stop is requested, then sets this back to 0', p_force => TRUE);
    put_setting('reclaim_row_counts',     'Y',     'A reclaim counts the rows of every table it moves before and after (Y or N)');
    put_setting('compact_min_free_pct',   '20',    'Compaction only processes tables with at least this share freed inside');
    put_setting('temp_index_min_mb',      '64',    'A missing index on a link column is created for the purge only on tables at least this large');
    put_setting('undo_retention_s',       '60',    'undo_retention set by undo tuning (undo.sql APPLY) for the duration of a purge');
    put_setting('undo_cap_mb',            '4096',  'Undo tuning limits the growth of the undo tablespace to the largest of its current size, this value and 4 x the undo of one batch');
    put_setting('archive_margin_pct',     '20',    'Margin added to the redo estimate when the preflight checks the archive destination (requirement ARCHIVE)');
    put_setting('backup_max_age_h',       '24',    'A successful RMAN database backup newer than this many hours meets the BACKUP requirement');
    put_setting('delete_rows_s',          '50000', 'Rows deleted per second assumed for the time forecast until a purge on the database has measured it');
    put_setting('preflight_valid_h',      '8',     'A purge reuses the root counts of a preflight with the same cutoff, mode and depth for this many hours; the wizard checks a plan again when its last check is older');

    -- Remove settings that are no longer listed above.
    DELETE FROM epf_setting
     WHERE name NOT IN (SELECT column_value FROM TABLE(g_settings));

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('  registry: ' || g_tables.COUNT || ' tables, ' || g_links.COUNT || ' links');
END;
/

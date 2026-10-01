-- ============================================================================
-- EPF Data Purge - Parity snapshot (previous tool vs this tool)
-- ============================================================================
-- Purpose : Records, for the 27 tables the previous tool (legacy/) purges,
--           which rows each tool deletes or clears for a cutoff date: per
--           table, the row count and a checksum of the keys of every row
--           class (see parity_step.sql), the non-empty LOB values per column
--           (scope CLOB), the foreign keys into the tables, and the purge
--           runs both tools recorded. Taken before and after a purge on two
--           copies of the same database, one purged by each tool, the
--           snapshots are compared by compare.ps1.
-- Usage   : sqlplus -L "sys@<tns> AS SYSDBA" @src/tests/parity/parity.sql <label> <cutoff> [FULL|CLOB]
--             label   LEGACY_BEFORE, LEGACY_AFTER (copy purged by the
--                     previous tool), NEW_BEFORE, NEW_AFTER (copy purged by
--                     this tool)
--             cutoff  YYYY-MM-DD: rows dated before it are purged; both tools
--                     use TRUNC(SYSDATE) - retention on the day of the purge
--             FULL    row classes (default; purges that delete)
--             CLOB    row classes and non-empty LOB values (CLOB_ONLY and
--                     CLOB_N_LOGS purges)
--           Run from the top folder of the tool (the one with src and logs).
-- Requires: SYS AS SYSDBA (or SELECT ANY TABLE and SELECT ANY DICTIONARY).
-- Effects : None in the database (SELECT only). Writes logs/parity/<label>.txt.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

-- Optional argument 3: defined as empty when not given (a query without rows
-- defines a NEW_VALUE variable that is not defined yet).
SET TERMOUT OFF
COLUMN 3 NEW_VALUE 3 NOPRINT
SELECT NULL AS "3" FROM dual WHERE 1 = 0;
COLUMN label_value  NEW_VALUE p_label  NOPRINT
COLUMN cutoff_value NEW_VALUE p_cutoff NOPRINT
COLUMN scope_value  NEW_VALUE p_scope  NOPRINT
SELECT UPPER(TRIM('&1')) AS label_value, TRIM('&2') AS cutoff_value,
       NVL(UPPER(TRIM('&3')), 'FULL') AS scope_value
  FROM dual;
SET TERMOUT ON

BEGIN
    IF '&p_label' NOT IN ('LEGACY_BEFORE', 'LEGACY_AFTER', 'NEW_BEFORE', 'NEW_AFTER') THEN
        RAISE_APPLICATION_ERROR(-20190, 'Label: LEGACY_BEFORE, LEGACY_AFTER, NEW_BEFORE or NEW_AFTER (got &p_label).');
    END IF;
    IF '&p_scope' NOT IN ('FULL', 'CLOB') THEN
        RAISE_APPLICATION_ERROR(-20191, 'Scope: FULL or CLOB (got &p_scope).');
    END IF;
    IF NOT REGEXP_LIKE('&p_cutoff', '^\d{4}-\d{2}-\d{2}$')
       OR TO_CHAR(TO_DATE('&p_cutoff', 'YYYY-MM-DD'), 'YYYY-MM-DD') <> '&p_cutoff' THEN
        RAISE_APPLICATION_ERROR(-20192, 'Cutoff: a date as YYYY-MM-DD (got &p_cutoff).');
    END IF;
END;
/

HOST mkdir logs\parity 2>NUL
SPOOL logs\parity\&p_label..txt

WHENEVER SQLERROR CONTINUE
PROMPT Parity snapshot &p_label, cutoff &p_cutoff, scope &p_scope (the largest tables take several minutes each)
@@parity_step.sql HEAD -

PROMPT -- PAYMENTS
@@parity_step.sql OPPAYMENTS BULK_PAYMENT_ADDITIONAL_INFO
@@parity_step.sql OPPAYMENTS BULK_SIGNATURE
@@parity_step.sql OPPAYMENTS MANDATORY_SIGNERS
@@parity_step.sql OPPAYMENTS OIDC_REQUEST_TOKEN
@@parity_step.sql OPPAYMENTS PAYMENT_AUDIT
@@parity_step.sql OPPAYMENTS TRANSMISSION_EXECUTION_AUDIT
@@parity_step.sql OPPAYMENTS IMPORT_AUDIT_MESSAGES
@@parity_step.sql OPPAYMENTS NOTIFICATION_EXECUTION
@@parity_step.sql OPPAYMENTS IMPORT_AUDIT
@@parity_step.sql OPPAYMENTS TRANSMISSION_EXECUTION
@@parity_step.sql OPPAYMENTS TRANSMISSION_EXCEPTION
@@parity_step.sql OPPAYMENTS APPROBATION_EXECUTION_OPT
@@parity_step.sql OPPAYMENTS WORKFLOW_EXECUTION_OPT
@@parity_step.sql OPPAYMENTS APPROBATION_EXECUTION
@@parity_step.sql OPPAYMENTS WORKFLOW_EXECUTION
@@parity_step.sql OPPAYMENTS BULKPAYMENT_EXCEPTION
@@parity_step.sql OPPAYMENTS INVOICE_ADDITIONAL_INFO
@@parity_step.sql OPPAYMENTS INVOICE
@@parity_step.sql OPPAYMENTS PAYMENT_ADDITIONAL_INFO
@@parity_step.sql OPPAYMENTS PAYMENT
@@parity_step.sql OPPAYMENTS BULK_PAYMENT
@@parity_step.sql OPPAYMENTS FILE_INTEGRATION

PROMPT -- LOGS
@@parity_step.sql OPPAYMENTS AUDIT_ARCHIVE
@@parity_step.sql OPPAYMENTS AUDIT_TRAIL
@@parity_step.sql OP SPEC_TRT_LOG

PROMPT -- BANK_STATEMENTS
@@parity_step.sql OPPAYMENTS DIRECTORY_DISPATCHING
@@parity_step.sql OPPAYMENTS FILE_DISPATCHING

PROMPT -- Foreign keys into the tables
@@parity_step.sql FKS -
PROMPT -- Purge runs recorded by both tools
@@parity_step.sql RUNS -

SELECT 'PARITY|END|' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') FROM dual;
SPOOL OFF
PROMPT Written: logs\parity\&p_label..txt
EXIT SUCCESS

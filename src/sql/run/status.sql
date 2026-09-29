-- ============================================================================
-- EPF Data Purge - Status
-- ============================================================================
-- Purpose : Prints the state of the active run, or of the latest run when none
--           is active (epf_report.print_status), and anything left pending:
--           temporary indexes, undo tuning, accounts locked by a reclaim.
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/status.sql
-- Requires: EPFPG.
-- Effects : None (reads only).
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR EXIT FAILURE

BEGIN
    epfpg.epf_report.print_status;
END;
/

EXIT SUCCESS

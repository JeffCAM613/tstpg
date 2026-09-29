-- ============================================================================
-- EPF Data Purge - Preflight advice
-- ============================================================================
-- Purpose : Prints the preflight findings of a run as EPF_ADVICE lines for the
--           wizard (epf_report.print_advice): recommended batch size, redo
--           and undo warnings, eligible roots.
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/advice.sql <run_id>
-- Requires: EPFPG.
-- Effects : None (reads only).
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

BEGIN
    epfpg.epf_report.print_advice(TO_NUMBER('&1'));
END;
/

EXIT SUCCESS

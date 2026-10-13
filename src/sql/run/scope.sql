-- ============================================================================
-- EPF Data Purge - What a purge covers in this database
-- ============================================================================
-- Purpose : Prints the tables of the tool's registry with their module, their
--           sizes and the share of top-level records dated before a day, as
--           EPF_SCOPE lines for the wrapper's questions on the mode and the
--           depth (epf_report.print_scope).
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/scope.sql <YYYY-MM-DD>
-- Requires: EPFPG.
-- Effects : None (reads only; it counts the root tables once).
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

BEGIN
    epfpg.epf_report.print_scope('&1');
END;
/

EXIT SUCCESS

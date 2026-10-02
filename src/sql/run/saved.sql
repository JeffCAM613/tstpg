-- ============================================================================
-- EPF Data Purge - Choices saved with a preflight
-- ============================================================================
-- Purpose : Prints the choices saved with the latest preflight of a scope,
--           for a purge that follows them (epf_control.print_saved_choices).
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/saved.sql
--             <retention_days> <cutoff> <mode> <depth>
--           retention_days  whole number of days, or - (with a cutoff)
--           cutoff          YYYY-MM-DD, or - (with a retention)
--           mode            FULL | CLOB | LOGS | CLOB_N_LOGS
--           depth           ALL or modules separated by commas
-- Requires: EPFPG.
-- Effects : None (reads only). Prints one EPF_SAVED line, or nothing when no
--           preflight of the scope is recent enough (preflight_valid_h).
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE

DECLARE
    FUNCTION arg(p_value IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN CASE WHEN TRIM(p_value) = '-' THEN NULL ELSE TRIM(p_value) END;
    END arg;
BEGIN
    epfpg.epf_control.print_saved_choices(
        p_retention_days => TO_NUMBER(arg('&1')),
        p_cutoff_date    => TO_DATE(arg('&2'), 'YYYY-MM-DD'),
        p_mode           => arg('&3'),
        p_depth          => arg('&4'));
END;
/

EXIT SUCCESS

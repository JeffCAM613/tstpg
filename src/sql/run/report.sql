-- ============================================================================
-- EPF Data Purge - Report
-- ============================================================================
-- Purpose : Evaluates the checks of a run and prints its integrity and
--           results report (epf_report).
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/report.sql <run_id|LATEST>
--             <run_id>  run to report on
--             LATEST    the most recent run
-- Requires: EPFPG.
-- Effects : Replaces the stored check results of the run (EPF_CHECK); changes
--           nothing else. Exit code 0 PASS, 2 PASS WITH WARNINGS, 1 FAIL,
--           3 when the run was stopped.
-- ============================================================================
SET ECHO OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DEFINE run_arg = "&1"

VARIABLE rc NUMBER

DECLARE
    l_run_id  NUMBER;
    l_verdict VARCHAR2(30);
    l_status  VARCHAR2(20);
BEGIN
    IF UPPER(TRIM('&run_arg')) = 'LATEST' THEN
        l_run_id := epfpg.epf_control.latest_run_id;
    ELSE
        l_run_id := TO_NUMBER('&run_arg');
    END IF;
    IF l_run_id IS NULL THEN
        RAISE_APPLICATION_ERROR(-20124, 'No run to report on.');
    END IF;
    epfpg.epf_report.evaluate(l_run_id, l_verdict, :rc);
    SELECT status INTO l_status FROM epfpg.epf_run WHERE run_id = l_run_id;
    IF l_status = 'STOPPED' THEN
        :rc := 3;
    END IF;
    epfpg.epf_report.print_report(l_run_id);
END;
/

EXIT :rc

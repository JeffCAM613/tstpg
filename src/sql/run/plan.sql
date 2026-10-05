-- ============================================================================
-- EPF Data Purge - Plan of smaller runs
-- ============================================================================
-- Purpose : Shows a plan with its steps (epf_report.print_plan), or closes
--           the open plan (epf_control.close_plan).
-- Usage   : sqlplus -L -S "epfpg@<service>" @src/sql/run/plan.sql <SHOW|CLOSE> <which>
--             SHOW <OPEN|CURRENT|LATEST|plan>  the open plan; the open plan
--                                       or else the latest; the latest plan;
--                                       or a plan by its number (123 or
--                                       P-000123)
--             CLOSE -                   closes the open plan; the steps done
--                                       stay done
-- Requires: EPFPG.
-- Effects : SHOW reads only. CLOSE sets the open plan CLOSED and prints
--           EPF_PLAN_CLOSED|<plan>, or 'No open plan.'. Exit code 0.
-- ============================================================================
SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR EXIT FAILURE ROLLBACK

DECLARE
    l_plan NUMBER;
BEGIN
    IF UPPER(TRIM('&1')) = 'CLOSE' THEN
        epfpg.epf_control.close_plan('closed by ' || SYS_CONTEXT('USERENV', 'OS_USER') || ' (plan --close)', l_plan);
        IF l_plan IS NULL THEN
            DBMS_OUTPUT.PUT_LINE('No open plan.');
        ELSE
            DBMS_OUTPUT.PUT_LINE('Plan ' || epfpg.epf_util.plan_label(l_plan) || ' closed; the steps done stay done.');
            DBMS_OUTPUT.PUT_LINE('EPF_PLAN_CLOSED|' || epfpg.epf_util.plan_label(l_plan));
        END IF;
    ELSIF UPPER(TRIM('&1')) = 'SHOW' THEN
        epfpg.epf_report.print_plan(TRIM('&2'));
    ELSE
        RAISE_APPLICATION_ERROR(-20127, 'plan.sql: SHOW or CLOSE, got: &1');
    END IF;
END;
/

EXIT SUCCESS

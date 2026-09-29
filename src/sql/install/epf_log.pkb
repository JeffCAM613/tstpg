CREATE OR REPLACE PACKAGE BODY epf_log AS

    g_run_id       NUMBER;
    g_phase        VARCHAR2(30);
    g_step         VARCHAR2(40);
    g_scope        VARCHAR2(128);
    g_step_seq     NUMBER;
    g_step_started TIMESTAMP;

    FUNCTION require_run(p_run_id IN NUMBER) RETURN NUMBER IS
    BEGIN
        IF NVL(p_run_id, g_run_id) IS NULL THEN
            RAISE_APPLICATION_ERROR(-20110, 'No run is bound to this session (epf_control.enter).');
        END IF;
        RETURN NVL(p_run_id, g_run_id);
    END require_run;

    PROCEDURE set_context(p_run_id IN NUMBER, p_phase IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        g_run_id       := p_run_id;
        g_phase        := UPPER(p_phase);
        g_step         := NULL;
        g_scope        := NULL;
        g_step_seq     := NULL;
        g_step_started := NULL;
        DBMS_APPLICATION_INFO.SET_MODULE(module_name => 'EPF', action_name => g_phase);
        DBMS_APPLICATION_INFO.SET_CLIENT_INFO('run=' || p_run_id);
        DBMS_SESSION.SET_IDENTIFIER('EPF:' || p_run_id);
    END set_context;

    PROCEDURE set_phase(p_phase IN VARCHAR2) IS
    BEGIN
        g_phase := UPPER(p_phase);
        DBMS_APPLICATION_INFO.SET_ACTION(g_phase);
    END set_phase;

    FUNCTION current_run RETURN NUMBER IS
    BEGIN
        RETURN g_run_id;
    END current_run;

    PROCEDURE event(
        p_severity     IN VARCHAR2,
        p_event_code   IN VARCHAR2,
        p_message      IN VARCHAR2,
        p_object_owner IN VARCHAR2 DEFAULT NULL,
        p_object_name  IN VARCHAR2 DEFAULT NULL,
        p_sub_name     IN VARCHAR2 DEFAULT NULL,
        p_rows         IN NUMBER   DEFAULT NULL,
        p_bytes        IN NUMBER   DEFAULT NULL,
        p_pct          IN NUMBER   DEFAULT NULL,
        p_elapsed_s    IN NUMBER   DEFAULT NULL,
        p_ora_code     IN NUMBER   DEFAULT NULL,
        p_run_id       IN NUMBER   DEFAULT NULL
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_run_id NUMBER := require_run(p_run_id);
    BEGIN
        IF p_severity NOT IN (c_info, c_ok, c_warn, c_error, c_progress) THEN
            RAISE_APPLICATION_ERROR(-20111, 'Unknown event severity: ' || p_severity);
        END IF;
        INSERT INTO epf_event (
            run_id, ts, phase, step_code, scope, severity, event_code,
            object_owner, object_name, sub_name, rows_affected, bytes, pct,
            elapsed_s, ora_code, message, session_user
        ) VALUES (
            l_run_id, epf_util.now_ts, g_phase, g_step, g_scope, p_severity, UPPER(p_event_code),
            p_object_owner, p_object_name, p_sub_name, p_rows, p_bytes, p_pct,
            p_elapsed_s, p_ora_code, SUBSTR(p_message, 1, 4000), SYS_CONTEXT('USERENV', 'SESSION_USER')
        );
        COMMIT;
    END event;

    PROCEDURE info(p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                   p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        event(c_info, p_event_code, p_message, p_object_owner, p_object_name);
    END info;

    PROCEDURE ok(p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                 p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        event(c_ok, p_event_code, p_message, p_object_owner, p_object_name);
    END ok;

    PROCEDURE warn(p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                   p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL) IS
    BEGIN
        event(c_warn, p_event_code, p_message, p_object_owner, p_object_name);
    END warn;

    PROCEDURE error(p_event_code IN VARCHAR2, p_message IN VARCHAR2,
                    p_object_owner IN VARCHAR2 DEFAULT NULL, p_object_name IN VARCHAR2 DEFAULT NULL,
                    p_ora_code IN NUMBER DEFAULT NULL) IS
    BEGIN
        event(c_error, p_event_code, p_message, p_object_owner, p_object_name, p_ora_code => p_ora_code);
    END error;

    -- Returns the step_seq of (run, phase, step, scope), creating a PENDING
    -- row when it does not exist yet.
    FUNCTION ensure_step(p_run_id IN NUMBER, p_phase IN VARCHAR2, p_step_code IN VARCHAR2,
                         p_scope IN VARCHAR2) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_seq NUMBER;
    BEGIN
        SELECT MAX(step_seq)
          INTO l_seq
          FROM epf_step
         WHERE run_id = p_run_id AND phase = p_phase AND step_code = p_step_code AND scope = p_scope;
        IF l_seq IS NULL THEN
            SELECT NVL(MAX(step_seq), 0) + 1 INTO l_seq FROM epf_step WHERE run_id = p_run_id;
            INSERT INTO epf_step (run_id, step_seq, phase, step_code, scope, status)
            VALUES (p_run_id, l_seq, p_phase, p_step_code, p_scope, 'PENDING');
        END IF;
        COMMIT;
        RETURN l_seq;
    END ensure_step;

    PROCEDURE step_plan(p_step_code IN VARCHAR2, p_scope IN VARCHAR2 DEFAULT NULL,
                        p_phase IN VARCHAR2 DEFAULT NULL) IS
        l_seq NUMBER;
    BEGIN
        l_seq := ensure_step(require_run(NULL), UPPER(NVL(p_phase, g_phase)),
                             UPPER(p_step_code), NVL(p_scope, '-'));
    END step_plan;

    PROCEDURE update_step(p_status IN VARCHAR2, p_started IN BOOLEAN, p_ended IN BOOLEAN,
                          p_units_total IN NUMBER, p_bytes_total IN NUMBER,
                          p_units_done IN NUMBER, p_bytes_done IN NUMBER, p_message IN VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_started TIMESTAMP;
        l_ended   TIMESTAMP;
    BEGIN
        IF p_started THEN
            l_started := epf_util.now_ts;
        END IF;
        IF p_ended THEN
            l_ended := epf_util.now_ts;
        END IF;
        UPDATE epf_step
           SET status      = NVL(p_status, status),
               started_at  = NVL(l_started, started_at),
               ended_at    = NVL(l_ended, ended_at),
               units_total = NVL(p_units_total, units_total),
               bytes_total = NVL(p_bytes_total, bytes_total),
               units_done  = NVL(p_units_done, units_done),
               bytes_done  = NVL(p_bytes_done, bytes_done),
               message     = NVL(SUBSTR(p_message, 1, 4000), message)
         WHERE run_id = g_run_id
           AND step_seq = g_step_seq;
        COMMIT;
    END update_step;

    PROCEDURE step_start(p_step_code IN VARCHAR2, p_scope IN VARCHAR2 DEFAULT NULL,
                         p_units_total IN NUMBER DEFAULT NULL, p_bytes_total IN NUMBER DEFAULT NULL) IS
        l_run_id NUMBER := require_run(NULL);
    BEGIN
        g_step         := UPPER(p_step_code);
        g_scope        := NVL(p_scope, '-');
        g_step_seq     := ensure_step(l_run_id, g_phase, g_step, g_scope);
        g_step_started := epf_util.now_ts;
        update_step('RUNNING', TRUE, FALSE, p_units_total, p_bytes_total, NULL, NULL, NULL);
        DBMS_APPLICATION_INFO.SET_ACTION(SUBSTR(g_step || CASE WHEN g_scope <> '-' THEN ' ' || g_scope END, 1, 32));
        event(c_info, 'STEP_START', g_phase || ' ' || g_step || CASE WHEN g_scope <> '-' THEN ' ' || g_scope END);
    END step_start;

    PROCEDURE step_progress(p_units_done IN NUMBER, p_bytes_done IN NUMBER DEFAULT NULL) IS
    BEGIN
        IF g_step_seq IS NULL THEN
            RAISE_APPLICATION_ERROR(-20112, 'No step is running in this session.');
        END IF;
        update_step(NULL, FALSE, FALSE, NULL, NULL, p_units_done, p_bytes_done, NULL);
    END step_progress;

    PROCEDURE step_end(p_status IN VARCHAR2 DEFAULT 'DONE', p_message IN VARCHAR2 DEFAULT NULL) IS
        l_status   VARCHAR2(20) := UPPER(p_status);
        l_elapsed  NUMBER;
        l_severity VARCHAR2(10);
    BEGIN
        IF g_step_seq IS NULL THEN
            RAISE_APPLICATION_ERROR(-20112, 'No step is running in this session.');
        END IF;
        IF l_status NOT IN ('DONE', 'FAILED', 'SKIPPED') THEN
            RAISE_APPLICATION_ERROR(-20113, 'Invalid step end status: ' || p_status);
        END IF;
        l_elapsed  := epf_util.elapsed_s(g_step_started);
        l_severity := CASE l_status WHEN 'DONE' THEN c_ok WHEN 'FAILED' THEN c_error ELSE c_info END;
        update_step(l_status, FALSE, TRUE, NULL, NULL, NULL, NULL, p_message);
        event(l_severity, 'STEP_END',
              g_phase || ' ' || g_step || CASE WHEN g_scope <> '-' THEN ' ' || g_scope END
              || ' ' || l_status || ' in ' || epf_util.fmt_duration(l_elapsed)
              || CASE WHEN p_message IS NOT NULL THEN ': ' || p_message END,
              p_elapsed_s => l_elapsed);
        g_step         := NULL;
        g_scope        := NULL;
        g_step_seq     := NULL;
        g_step_started := NULL;
        DBMS_APPLICATION_INFO.SET_ACTION(g_phase);
    END step_end;

    PROCEDURE poll(p_run_id IN NUMBER, p_after_event_id IN NUMBER) IS
        l_own_sid NUMBER := TO_NUMBER(SYS_CONTEXT('USERENV', 'SID'));
        l_client  VARCHAR2(64) := 'EPF:' || p_run_id;
    BEGIN
        FOR e IN (SELECT event_id, ts, severity, phase, event_code, object_owner, object_name, message
                    FROM epf_event
                   WHERE run_id = p_run_id
                     AND event_id > NVL(p_after_event_id, 0)
                   ORDER BY event_id) LOOP
            DBMS_OUTPUT.PUT_LINE('EV|' || e.event_id || '|' || TO_CHAR(e.ts, 'HH24:MI:SS') || '|' || e.severity
                                 || '|' || e.phase || '|' || e.event_code || '|'
                                 || CASE WHEN e.object_name IS NOT NULL THEN e.object_owner || '.' || e.object_name END
                                 || '|' || REPLACE(REPLACE(e.message, CHR(13), ' '), CHR(10), ' '));
        END LOOP;
        FOR s IN (SELECT phase, step_code, scope, units_done, units_total, bytes_done
                    FROM epf_step
                   WHERE run_id = p_run_id AND status = 'RUNNING'
                   ORDER BY step_seq) LOOP
            DBMS_OUTPUT.PUT_LINE('ST|' || s.phase || '|' || s.step_code || '|' || s.scope || '|' || s.units_done
                                 || '|' || s.units_total || '|' || s.bytes_done);
        END LOOP;
        FOR h IN (SELECT w.sid, w.status, w.action, w.event, w.seconds_in_wait, w.wait_class, w.blocking_session,
                         w.sql_id,
                         (SELECT b.username || '@' || b.machine || ' ' || b.program
                            FROM v$session b
                           WHERE b.sid = w.blocking_session AND ROWNUM = 1) AS blocker,
                         (SELECT ROUND(100 * lo.sofar / NULLIF(lo.totalwork, 0), 1) || '|' || lo.time_remaining
                                 || '|' || lo.opname
                            FROM v$session_longops lo
                           WHERE lo.sid = w.sid AND lo.serial# = w.serial# AND lo.sofar < lo.totalwork
                           ORDER BY lo.last_update_time DESC
                           FETCH FIRST 1 ROWS ONLY) AS longops,
                         (SELECT MAX(rs.error_msg)
                            FROM dba_resumable rs
                           WHERE rs.session_id = w.sid AND rs.status = 'SUSPENDED') AS suspended
                    FROM v$session w
                   WHERE w.client_identifier = l_client
                     AND w.sid <> l_own_sid) LOOP
            DBMS_OUTPUT.PUT_LINE('HB|' || h.sid || '|' || h.status || '|' || h.action || '|' || h.event || '|'
                                 || h.seconds_in_wait || '|' || h.wait_class || '|' || h.blocking_session || '|'
                                 || h.blocker || '|' || h.sql_id || '|' || NVL(h.longops, '||') || '|'
                                 || REPLACE(REPLACE(h.suspended, CHR(13), ' '), CHR(10), ' '));
        END LOOP;
        FOR x IN (SELECT status, stop_requested FROM epf_run WHERE run_id = p_run_id) LOOP
            DBMS_OUTPUT.PUT_LINE('RUN|' || x.status || '|' || x.stop_requested);
        END LOOP;
    END poll;

    FUNCTION current_step RETURN VARCHAR2 IS
    BEGIN
        RETURN g_step;
    END current_step;

    PROCEDURE step_skip_pending(p_message IN VARCHAR2 DEFAULT NULL) IS
        l_run_id NUMBER := require_run(NULL);
        l_count  PLS_INTEGER;

        PROCEDURE save IS
            PRAGMA AUTONOMOUS_TRANSACTION;
        BEGIN
            UPDATE epf_step
               SET status  = 'SKIPPED',
                   message = NVL(SUBSTR(p_message, 1, 4000), message)
             WHERE run_id = l_run_id
               AND phase = g_phase
               AND status = 'PENDING';
            l_count := SQL%ROWCOUNT;
            COMMIT;
        END save;
    BEGIN
        save;
        IF l_count > 0 THEN
            event(c_info, 'STEPS_SKIPPED', l_count || ' planned ' || g_phase || ' steps skipped'
                                           || CASE WHEN p_message IS NOT NULL THEN ': ' || p_message END);
        END IF;
    END step_skip_pending;

    PROCEDURE print_events(p_run_id IN NUMBER, p_after_event_id IN NUMBER DEFAULT 0) IS
    BEGIN
        FOR e IN (SELECT ts, severity, phase, event_code, object_owner, object_name, sub_name, message
                    FROM epf_event
                   WHERE run_id = p_run_id
                     AND event_id > NVL(p_after_event_id, 0)
                   ORDER BY event_id) LOOP
            DBMS_OUTPUT.PUT_LINE(
                TO_CHAR(e.ts, 'HH24:MI:SS') || ' '
                || CASE e.severity
                       WHEN c_ok       THEN '[ OK ]'
                       WHEN c_info     THEN '[INFO]'
                       WHEN c_warn     THEN '[WARN]'
                       WHEN c_error    THEN '[FAIL]'
                       ELSE                 '[ .. ]'
                   END || ' '
                || RPAD(NVL(e.phase, '-'), 10) || ' '
                || RPAD(e.event_code, 24) || ' '
                || e.message
                || CASE WHEN e.object_name IS NOT NULL
                        THEN '  [' || e.object_owner || '.' || e.object_name
                             || CASE WHEN e.sub_name IS NOT NULL THEN ':' || e.sub_name END || ']'
                   END);
        END LOOP;
    END print_events;

END epf_log;
/

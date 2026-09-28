CREATE OR REPLACE PACKAGE BODY epf_control AS

    c_lock_name CONSTANT VARCHAR2(30) := 'EPFPG_RUN_ACTIVE';

    g_attached_run NUMBER;

    -- DBMS_LOCK.ALLOCATE_UNIQUE commits, so it runs in its own transaction.
    FUNCTION lock_handle RETURN VARCHAR2 IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_handle VARCHAR2(128);
    BEGIN
        DBMS_LOCK.ALLOCATE_UNIQUE(c_lock_name, l_handle);
        COMMIT;
        RETURN l_handle;
    END lock_handle;

    -- TRUE when no session holds the run lock.
    FUNCTION lock_is_free RETURN BOOLEAN IS
        l_handle VARCHAR2(128) := lock_handle;
        l_rc     INTEGER;
    BEGIN
        IF g_attached_run IS NOT NULL THEN
            RETURN FALSE;
        END IF;
        l_rc := DBMS_LOCK.REQUEST(lockhandle => l_handle, lockmode => DBMS_LOCK.X_MODE,
                                  timeout => 0, release_on_commit => FALSE);
        IF l_rc = 0 THEN
            l_rc := DBMS_LOCK.RELEASE(l_handle);
            RETURN TRUE;
        ELSIF l_rc IN (1, 4) THEN
            RETURN FALSE;
        END IF;
        RAISE_APPLICATION_ERROR(-20123, 'Run lock request failed with DBMS_LOCK code ' || l_rc);
    END lock_is_free;

    FUNCTION yes_no(p_value IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2 IS
        l_value VARCHAR2(10) := UPPER(TRIM(NVL(p_value, 'N')));
    BEGIN
        IF l_value NOT IN ('Y', 'N') THEN
            RAISE_APPLICATION_ERROR(-20127, p_name || ' must be Y or N, got: ' || p_value);
        END IF;
        RETURN l_value;
    END yes_no;

    FUNCTION normalize_depth(p_depth IN VARCHAR2) RETURN VARCHAR2 IS
        l_items   SYS.ODCIVARCHAR2LIST := epf_util.split_list(p_depth);
        l_valid   VARCHAR2(4000);
        l_count   PLS_INTEGER;
        l_modules PLS_INTEGER;
        l_result  VARCHAR2(4000);
    BEGIN
        SELECT LISTAGG(module_code, ', ') WITHIN GROUP (ORDER BY display_order), COUNT(*)
          INTO l_valid, l_modules
          FROM epf_module;
        IF l_items.COUNT = 0 THEN
            RAISE_APPLICATION_ERROR(-20125, 'Depth is empty. Valid values: ALL, ' || l_valid);
        END IF;
        FOR i IN 1 .. l_items.COUNT LOOP
            IF l_items(i) = 'ALL' THEN
                RETURN 'ALL';
            END IF;
            SELECT COUNT(*) INTO l_count FROM epf_module WHERE module_code = l_items(i);
            IF l_count = 0 THEN
                RAISE_APPLICATION_ERROR(-20125, 'Unknown depth: ' || l_items(i)
                                                || '. Valid values: ALL, ' || l_valid);
            END IF;
        END LOOP;
        SELECT LISTAGG(module_code, ',') WITHIN GROUP (ORDER BY display_order), COUNT(*)
          INTO l_result, l_count
          FROM epf_module
         WHERE module_code IN (SELECT column_value FROM TABLE(l_items));
        RETURN CASE WHEN l_count = l_modules THEN 'ALL' ELSE l_result END;
    END normalize_depth;

    FUNCTION normalize_mode(p_mode IN VARCHAR2) RETURN VARCHAR2 IS
        l_mode VARCHAR2(30) := UPPER(TRIM(p_mode));
    BEGIN
        IF l_mode IS NULL OR l_mode NOT IN ('FULL', 'CLOB', 'LOGS', 'CLOB_N_LOGS') THEN
            RAISE_APPLICATION_ERROR(-20126, 'Unknown mode: ' || p_mode
                                            || '. Valid values: FULL, CLOB, LOGS, CLOB_N_LOGS');
        END IF;
        RETURN l_mode;
    END normalize_mode;

    PROCEDURE prune_history IS
        l_cutoff TIMESTAMP := epf_util.now_ts
                              - NUMTODSINTERVAL(epf_util.setting_num('history_retention_days'), 'DAY');
    BEGIN
        FOR t IN (SELECT c.table_name
                    FROM user_tab_columns c
                    JOIN user_tables u ON u.table_name = c.table_name
                   WHERE c.column_name = 'RUN_ID'
                     AND c.table_name <> 'EPF_RUN'
                   ORDER BY c.table_name) LOOP
            EXECUTE IMMEDIATE 'DELETE FROM ' || DBMS_ASSERT.ENQUOTE_NAME(t.table_name, FALSE)
                           || ' WHERE run_id IN (SELECT run_id FROM epf_run WHERE created_at < :1)'
                USING l_cutoff;
        END LOOP;
        DELETE FROM epf_run WHERE created_at < l_cutoff;
    END prune_history;

    FUNCTION start_run(
        p_action         IN VARCHAR2,
        p_retention_days IN NUMBER   DEFAULT NULL,
        p_depth          IN VARCHAR2 DEFAULT NULL,
        p_mode           IN VARCHAR2 DEFAULT NULL,
        p_batch_size     IN NUMBER   DEFAULT NULL,
        p_dry_run        IN VARCHAR2 DEFAULT 'N',
        p_with_reclaim   IN VARCHAR2 DEFAULT 'N',
        p_with_compact   IN VARCHAR2 DEFAULT 'N'
    ) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_action    VARCHAR2(30) := UPPER(TRIM(p_action));
        l_retention NUMBER;
        l_cutoff    DATE;
        l_depth     VARCHAR2(4000);
        l_mode      VARCHAR2(30);
        l_batch     NUMBER;
        l_dry_run   VARCHAR2(1)  := yes_no(p_dry_run, 'dry_run');
        l_reclaim   VARCHAR2(1)  := yes_no(p_with_reclaim, 'with_reclaim');
        l_compact   VARCHAR2(1)  := yes_no(p_with_compact, 'with_compact');
        l_run_id    NUMBER;
    BEGIN
        IF l_action IS NULL OR l_action NOT IN ('PURGE', 'RECLAIM', 'PREFLIGHT') THEN
            RAISE_APPLICATION_ERROR(-20121, 'Unknown action: ' || p_action
                                            || '. Valid values: PURGE, RECLAIM, PREFLIGHT');
        END IF;
        IF l_compact = 'Y' THEN
            RAISE_APPLICATION_ERROR(-20127, 'Compaction (with_compact=Y) is not supported by this tool version.');
        END IF;
        IF NOT lock_is_free THEN
            RAISE_APPLICATION_ERROR(-20122, 'Another run is active: '
                                            || NVL(epf_util.run_label(active_run_id), 'unknown run'));
        END IF;

        IF l_action IN ('PURGE', 'PREFLIGHT') THEN
            l_mode  := normalize_mode(NVL(p_mode, 'FULL'));
            l_depth := normalize_depth(NVL(p_depth, 'ALL'));
            IF l_mode = 'LOGS' THEN
                l_depth := 'LOGS';
            ELSIF l_mode = 'CLOB_N_LOGS' AND l_depth <> 'ALL'
                  AND INSTR(',' || l_depth || ',', ',LOGS,') = 0 THEN
                l_depth := normalize_depth(l_depth || ',LOGS');
            END IF;

            l_retention := NVL(p_retention_days, epf_util.setting_num('retention_days_default'));
            IF l_retention <> TRUNC(l_retention)
               OR l_retention < epf_util.setting_num('retention_days_min') THEN
                RAISE_APPLICATION_ERROR(-20127, 'Retention must be a whole number of days >= '
                                                || epf_util.setting('retention_days_min')
                                                || ', got: ' || p_retention_days);
            END IF;
            l_cutoff := TRUNC(SYSDATE) - l_retention;

            l_batch := NVL(p_batch_size, epf_util.setting_num('batch_size_default'));
            IF l_batch <> TRUNC(l_batch) OR l_batch NOT BETWEEN 100 AND 100000 THEN
                RAISE_APPLICATION_ERROR(-20127, 'Batch size must be a whole number between 100 and 100000, got: '
                                                || p_batch_size);
            END IF;
        END IF;

        UPDATE epf_run
           SET status   = 'ABANDONED',
               ended_at = epf_util.now_ts,
               message  = 'No session held the run lock when run '
                          || 'was found in status ' || status || ' at the start of a new run.'
         WHERE status IN ('CREATED', 'RUNNING');

        prune_history;

        INSERT INTO epf_run (
            action, status, retention_days, cutoff_date, depth, purge_mode, batch_size,
            dry_run, with_reclaim, with_compact, created_at,
            db_name, container_name, client_host, os_user, tool_version
        ) VALUES (
            l_action, 'CREATED', l_retention, l_cutoff, l_depth, l_mode, l_batch,
            l_dry_run, l_reclaim, l_compact, epf_util.now_ts,
            SYS_CONTEXT('USERENV', 'DB_NAME'), SYS_CONTEXT('USERENV', 'CON_NAME'),
            SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'OS_USER'),
            epf_util.setting('tool_version')
        ) RETURNING run_id INTO l_run_id;
        COMMIT;
        RETURN l_run_id;
    END start_run;

    PROCEDURE set_running(p_run_id IN NUMBER) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE epf_run
           SET status = 'RUNNING', started_at = epf_util.now_ts
         WHERE run_id = p_run_id
           AND status = 'CREATED';
        COMMIT;
    END set_running;

    PROCEDURE attach(p_run_id IN NUMBER) IS
        l_rc     INTEGER;
        l_status epf_run.status%TYPE;
        l_run    epf_run%ROWTYPE;
    BEGIN
        BEGIN
            SELECT status INTO l_status FROM epf_run WHERE run_id = p_run_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20124, 'Run not found: ' || epf_util.run_label(p_run_id));
        END;
        IF l_status NOT IN ('CREATED', 'RUNNING') THEN
            RAISE_APPLICATION_ERROR(-20124, 'Run ' || epf_util.run_label(p_run_id)
                                            || ' cannot be attached in status ' || l_status);
        END IF;

        l_rc := DBMS_LOCK.REQUEST(lockhandle => lock_handle, lockmode => DBMS_LOCK.X_MODE,
                                  timeout => 0, release_on_commit => FALSE);
        IF l_rc NOT IN (0, 4) THEN
            RAISE_APPLICATION_ERROR(-20123, 'Run lock is held by another session (DBMS_LOCK code '
                                            || l_rc || ').');
        END IF;
        g_attached_run := p_run_id;

        set_running(p_run_id);
        epf_log.set_context(p_run_id, 'RUN');

        SELECT * INTO l_run FROM epf_run WHERE run_id = p_run_id;
        epf_log.info('RUN_START',
            epf_util.run_label(p_run_id) || ' ' || l_run.action
            || CASE WHEN l_run.purge_mode IS NOT NULL THEN
                   ' mode=' || l_run.purge_mode || ' depth=' || l_run.depth
                   || ' retention=' || l_run.retention_days
                   || ' cutoff=' || TO_CHAR(l_run.cutoff_date, 'YYYY-MM-DD')
                   || ' batch=' || l_run.batch_size || ' dry_run=' || l_run.dry_run
               END
            || ' reclaim=' || l_run.with_reclaim || ' compact=' || l_run.with_compact
            || ' db=' || l_run.db_name || ' container=' || l_run.container_name
            || ' version=' || l_run.tool_version);
    END attach;

    PROCEDURE enter(p_run_id IN NUMBER, p_phase IN VARCHAR2 DEFAULT NULL) IS
        l_status epf_run.status%TYPE;
    BEGIN
        BEGIN
            SELECT status INTO l_status FROM epf_run WHERE run_id = p_run_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                RAISE_APPLICATION_ERROR(-20124, 'Run not found: ' || epf_util.run_label(p_run_id));
        END;
        IF l_status <> 'RUNNING' THEN
            RAISE_APPLICATION_ERROR(-20124, 'Run ' || epf_util.run_label(p_run_id)
                                            || ' is not running (status ' || l_status || ')');
        END IF;
        epf_log.set_context(p_run_id, p_phase);
    END enter;

    PROCEDURE finish(
        p_run_id    IN NUMBER,
        p_status    IN VARCHAR2,
        p_verdict   IN VARCHAR2 DEFAULT NULL,
        p_exit_code IN NUMBER   DEFAULT NULL,
        p_message   IN VARCHAR2 DEFAULT NULL
    ) IS
        l_status  VARCHAR2(20) := UPPER(p_status);
        l_started TIMESTAMP;
        l_rc      INTEGER;

        PROCEDURE save IS
            PRAGMA AUTONOMOUS_TRANSACTION;
        BEGIN
            UPDATE epf_run
               SET status    = l_status,
                   verdict   = p_verdict,
                   exit_code = p_exit_code,
                   ended_at  = epf_util.now_ts,
                   message   = SUBSTR(p_message, 1, 4000)
             WHERE run_id = p_run_id;
            COMMIT;
        END save;
    BEGIN
        IF l_status NOT IN ('SUCCESS', 'WARNING', 'FAILED', 'STOPPED') THEN
            RAISE_APPLICATION_ERROR(-20127, 'Invalid final status: ' || p_status);
        END IF;
        SELECT started_at INTO l_started FROM epf_run WHERE run_id = p_run_id;
        save;
        epf_log.event(
            p_severity   => CASE l_status WHEN 'SUCCESS' THEN epf_log.c_ok
                                          WHEN 'FAILED'  THEN epf_log.c_error
                                          ELSE epf_log.c_warn END,
            p_event_code => 'RUN_END',
            p_message    => epf_util.run_label(p_run_id) || ' ' || l_status
                            || CASE WHEN p_verdict IS NOT NULL THEN ' verdict=' || p_verdict END
                            || CASE WHEN p_exit_code IS NOT NULL THEN ' exit=' || p_exit_code END
                            || ' duration=' || epf_util.fmt_duration(epf_util.elapsed_s(l_started))
                            || CASE WHEN p_message IS NOT NULL THEN ': ' || p_message END,
            p_elapsed_s  => epf_util.elapsed_s(l_started),
            p_run_id     => p_run_id);
        IF g_attached_run = p_run_id THEN
            l_rc := DBMS_LOCK.RELEASE(lock_handle);
            g_attached_run := NULL;
        END IF;
    END finish;

    PROCEDURE request_stop(p_run_id IN NUMBER) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        UPDATE epf_run SET stop_requested = 'Y' WHERE run_id = p_run_id AND status = 'RUNNING';
        IF SQL%ROWCOUNT = 0 THEN
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20124, 'Run ' || epf_util.run_label(p_run_id) || ' is not running.');
        END IF;
        COMMIT;
        epf_log.event(epf_log.c_warn, 'STOP_REQUESTED',
                      'Graceful stop requested; the run stops at the next safe point.',
                      p_run_id => p_run_id);
    END request_stop;

    FUNCTION stop_requested(p_run_id IN NUMBER) RETURN BOOLEAN IS
        l_flag epf_run.stop_requested%TYPE;
    BEGIN
        SELECT stop_requested INTO l_flag FROM epf_run WHERE run_id = p_run_id;
        RETURN l_flag = 'Y';
    END stop_requested;

    FUNCTION latest_run_id RETURN NUMBER IS
        l_run_id NUMBER;
    BEGIN
        SELECT MAX(run_id) INTO l_run_id FROM epf_run;
        RETURN l_run_id;
    END latest_run_id;

    FUNCTION active_run_id RETURN NUMBER IS
        l_run_id NUMBER;
    BEGIN
        IF g_attached_run IS NOT NULL THEN
            RETURN g_attached_run;
        END IF;
        IF lock_is_free THEN
            RETURN NULL;
        END IF;
        SELECT MAX(run_id) INTO l_run_id FROM epf_run WHERE status IN ('CREATED', 'RUNNING');
        RETURN l_run_id;
    END active_run_id;

END epf_control;
/

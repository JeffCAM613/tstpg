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

    -- Depth of a run in mode p_mode: LOGS mode purges the LOGS module only;
    -- CLOB_N_LOGS always includes it.
    FUNCTION scope_depth(p_mode IN VARCHAR2, p_depth IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_mode = 'LOGS' THEN
            RETURN 'LOGS';
        ELSIF p_mode = 'CLOB_N_LOGS' AND p_depth <> 'ALL' AND INSTR(',' || p_depth || ',', ',LOGS,') = 0 THEN
            RETURN normalize_depth(p_depth || ',LOGS');
        END IF;
        RETURN p_depth;
    END scope_depth;

    -- Backup choice: CONFIRMED, NONE or NULL.
    FUNCTION norm_backup(p_value IN VARCHAR2) RETURN VARCHAR2 IS
        l_value VARCHAR2(100) := UPPER(TRIM(p_value));
    BEGIN
        IF l_value IS NOT NULL AND l_value NOT IN ('CONFIRMED', 'NONE') THEN
            RAISE_APPLICATION_ERROR(-20127, 'Backup choice must be CONFIRMED or NONE, got: ' || p_value);
        END IF;
        RETURN l_value;
    END norm_backup;

    -- Confirmed requirements: ARCHIVE, UNDO, TEMP, in that order, or NULL.
    FUNCTION norm_confirm(p_value IN VARCHAR2) RETURN VARCHAR2 IS
        l_codes  SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST('ARCHIVE', 'UNDO', 'TEMP', 'RECYCLEBIN');
        l_result VARCHAR2(100);
    BEGIN
        IF TRIM(p_value) IS NULL THEN
            RETURN NULL;
        END IF;
        FOR i IN 1 .. REGEXP_COUNT(p_value, '[^,]+') LOOP
            IF UPPER(TRIM(REGEXP_SUBSTR(p_value, '[^,]+', 1, i))) NOT IN ('ARCHIVE', 'UNDO', 'TEMP', 'RECYCLEBIN') THEN
                RAISE_APPLICATION_ERROR(-20127, 'Requirements to confirm: ARCHIVE, UNDO, TEMP (purge), RECYCLEBIN '
                                                || '(reclaim) separated by commas, got: ' || p_value);
            END IF;
        END LOOP;
        FOR k IN 1 .. l_codes.COUNT LOOP
            IF INSTR(',' || REPLACE(UPPER(p_value), ' ') || ',', ',' || l_codes(k) || ',') > 0 THEN
                l_result := l_result || CASE WHEN l_result IS NOT NULL THEN ',' END || l_codes(k);
            END IF;
        END LOOP;
        RETURN l_result;
    END norm_confirm;

    FUNCTION norm_batch(p_value IN NUMBER) RETURN NUMBER IS
        l_batch NUMBER := NVL(p_value, epf_util.setting_num('batch_size_default'));
    BEGIN
        IF l_batch <> TRUNC(l_batch) OR l_batch NOT BETWEEN 100 AND 100000 THEN
            RAISE_APPLICATION_ERROR(-20127, 'Batch size must be a whole number between 100 and 100000, got: '
                                            || p_value);
        END IF;
        RETURN l_batch;
    END norm_batch;

    -- Progress of a plan: '<done> of <steps> steps done, next: rows before
    -- <cutoff>'.
    FUNCTION plan_progress(p_plan_id IN NUMBER) RETURN VARCHAR2 IS
        l_total NUMBER;
        l_done  NUMBER;
        l_next  DATE;
    BEGIN
        SELECT COUNT(*), COUNT(CASE WHEN status = 'DONE' THEN 1 END),
               MIN(CASE WHEN status = 'PENDING' THEN cutoff_date END)
          INTO l_total, l_done, l_next
          FROM epf_plan_step
         WHERE plan_id = p_plan_id;
        RETURN l_done || ' of ' || l_total || ' steps done'
               || CASE WHEN l_next IS NOT NULL THEN ', next: rows before ' || TO_CHAR(l_next, 'YYYY-MM-DD') END;
    END plan_progress;

    -- Ends an open plan as CLOSED with the OS user and the reason (in the
    -- caller's transaction).
    PROCEDURE end_plan(p_plan_id IN NUMBER, p_reason IN VARCHAR2) IS
    BEGIN
        UPDATE epf_plan
           SET status       = 'CLOSED',
               closed_at    = epf_util.now_ts,
               closed_by    = SYS_CONTEXT('USERENV', 'OS_USER'),
               close_reason = SUBSTR(p_reason, 1, 400)
         WHERE plan_id = p_plan_id
           AND status IN ('READY', 'IN_PROGRESS');
    END end_plan;

    PROCEDURE prune_history IS
        l_cutoff TIMESTAMP := epf_util.now_ts
                              - NUMTODSINTERVAL(epf_util.setting_num('history_retention_days'), 'DAY');
        -- Runs older than the history retention, except a run whose reclaim
        -- left something pending (an account still locked, a released index
        -- still unusable): the restore needs its records.
        l_old    VARCHAR2(1000) :=
            'SELECT r.run_id FROM epf_run r WHERE r.created_at < :1'
            || ' AND NOT EXISTS (SELECT 1 FROM epf_account_action a WHERE a.run_id = r.run_id'
            || ' AND a.locked_at IS NOT NULL AND a.unlocked_at IS NULL)'
            || ' AND NOT EXISTS (SELECT 1 FROM epf_reclaim_object o JOIN dba_indexes i'
            || ' ON i.owner = o.owner AND i.index_name = o.object_name WHERE o.run_id = r.run_id'
            || ' AND o.unit_type = ''INDEX'' AND o.move_status IN (''RELEASED'', ''FAILED'') AND i.status = ''UNUSABLE'')';
    BEGIN
        DELETE FROM epf_plan_step
         WHERE plan_id IN (SELECT plan_id FROM epf_plan WHERE status IN ('DONE', 'CLOSED') AND closed_at < l_cutoff);
        DELETE FROM epf_plan WHERE status IN ('DONE', 'CLOSED') AND closed_at < l_cutoff;
        FOR t IN (SELECT c.table_name
                    FROM user_tab_columns c
                    JOIN user_tables u ON u.table_name = c.table_name
                   WHERE c.column_name = 'RUN_ID'
                     AND c.table_name <> 'EPF_RUN'
                   ORDER BY c.table_name) LOOP
            EXECUTE IMMEDIATE 'DELETE FROM ' || DBMS_ASSERT.ENQUOTE_NAME(t.table_name, FALSE)
                           || ' WHERE run_id IN (' || l_old || ')'
                USING l_cutoff;
        END LOOP;
        EXECUTE IMMEDIATE 'DELETE FROM epf_run WHERE run_id IN (' || l_old || ')' USING l_cutoff;
    END prune_history;

    FUNCTION start_run(
        p_action           IN VARCHAR2,
        p_retention_days   IN NUMBER   DEFAULT NULL,
        p_depth            IN VARCHAR2 DEFAULT NULL,
        p_mode             IN VARCHAR2 DEFAULT NULL,
        p_batch_size       IN NUMBER   DEFAULT NULL,
        p_dry_run          IN VARCHAR2 DEFAULT 'N',
        p_with_reclaim     IN VARCHAR2 DEFAULT 'N',
        p_with_compact     IN VARCHAR2 DEFAULT 'N',
        p_with_undo_tuning IN VARCHAR2 DEFAULT 'N',
        p_backup_choice    IN VARCHAR2 DEFAULT NULL,
        p_cutoff_date      IN DATE     DEFAULT NULL,
        p_confirm          IN VARCHAR2 DEFAULT NULL,
        p_with_redo_logs   IN VARCHAR2 DEFAULT 'N',
        p_max_redo_bytes   IN NUMBER   DEFAULT NULL,
        p_new_plan         IN VARCHAR2 DEFAULT 'N',
        p_plan_id          IN NUMBER   DEFAULT NULL,
        p_plan_step        IN NUMBER   DEFAULT NULL
    ) RETURN NUMBER IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_action    VARCHAR2(30) := UPPER(TRIM(p_action));
        l_retention NUMBER;
        l_cutoff    DATE;
        l_depth     VARCHAR2(4000);
        l_mode      VARCHAR2(30);
        l_batch     NUMBER;
        l_rows      NUMBER;
        l_dry_run   VARCHAR2(1)  := yes_no(p_dry_run, 'dry_run');
        l_reclaim   VARCHAR2(1)  := yes_no(p_with_reclaim, 'with_reclaim');
        l_compact   VARCHAR2(1)  := yes_no(p_with_compact, 'with_compact');
        l_undo      VARCHAR2(1)  := yes_no(p_with_undo_tuning, 'with_undo_tuning');
        l_redo      VARCHAR2(1)  := yes_no(p_with_redo_logs, 'with_redo_logs');
        l_backup    VARCHAR2(10) := norm_backup(p_backup_choice);
        l_confirm   VARCHAR2(100) := norm_confirm(p_confirm);
        l_new_plan  VARCHAR2(1)  := yes_no(p_new_plan, 'new_plan');
        l_open      NUMBER;
        l_open_st   VARCHAR2(20);
        l_open_mode VARCHAR2(30);
        l_open_dep  VARCHAR2(200);
        l_step_cut  DATE;
        l_step_st   VARCHAR2(20);
        l_closed    VARCHAR2(400);
        l_run_id    NUMBER;
    BEGIN
        IF l_action IS NULL OR l_action NOT IN ('PURGE', 'RECLAIM', 'PREFLIGHT') THEN
            RAISE_APPLICATION_ERROR(-20121, 'Unknown action: ' || p_action
                                            || '. Valid values: PURGE, RECLAIM, PREFLIGHT');
        END IF;
        IF l_compact = 'Y' AND (l_action <> 'PURGE' OR l_dry_run = 'Y' OR l_reclaim = 'Y') THEN
            RAISE_APPLICATION_ERROR(-20127, 'Compaction (with_compact=Y) applies to purge runs that are not dry runs '
                                            || 'and do not reclaim.');
        END IF;
        IF l_undo = 'Y' AND l_action NOT IN ('PURGE', 'PREFLIGHT') THEN
            RAISE_APPLICATION_ERROR(-20127, 'Undo tuning (with_undo_tuning=Y) applies to purge and preflight runs.');
        END IF;
        IF l_redo = 'Y' AND l_action NOT IN ('PURGE', 'PREFLIGHT') THEN
            RAISE_APPLICATION_ERROR(-20127, 'Redo log sizing (with_redo_logs=Y) applies to purge and preflight runs.');
        END IF;
        IF l_action = 'RECLAIM' AND INSTR(',' || l_confirm || ',', ',UNDO,') > 0 THEN
            RAISE_APPLICATION_ERROR(-20127, 'UNDO is confirmed for a purge; a reclaim confirms ARCHIVE, TEMP or '
                                            || 'RECYCLEBIN.');
        END IF;
        IF l_action <> 'RECLAIM' AND INSTR(',' || l_confirm || ',', ',RECYCLEBIN,') > 0 THEN
            RAISE_APPLICATION_ERROR(-20127, 'RECYCLEBIN is confirmed for a reclaim; a purge confirms ARCHIVE, UNDO '
                                            || 'or TEMP.');
        END IF;
        IF NOT lock_is_free THEN
            RAISE_APPLICATION_ERROR(-20122, 'Another run is active: '
                                            || NVL(epf_util.run_label(active_run_id), 'unknown run'));
        END IF;

        IF l_action IN ('PURGE', 'PREFLIGHT') THEN
            l_mode  := normalize_mode(NVL(p_mode, 'FULL'));
            l_depth := scope_depth(l_mode, normalize_depth(NVL(p_depth, 'ALL')));

            IF p_cutoff_date IS NOT NULL AND p_retention_days IS NOT NULL THEN
                RAISE_APPLICATION_ERROR(-20127, 'Give the retention or the cutoff date, not both.');
            END IF;
            IF p_cutoff_date IS NOT NULL THEN
                l_retention := TRUNC(SYSDATE) - TRUNC(p_cutoff_date);
            ELSE
                l_retention := NVL(p_retention_days, epf_util.setting_num('retention_days_default'));
            END IF;
            IF l_retention <> TRUNC(l_retention)
               OR l_retention < epf_util.setting_num('retention_days_min') THEN
                RAISE_APPLICATION_ERROR(-20127, 'Retention must be a whole number of days >= '
                                                || epf_util.setting('retention_days_min')
                                                || CASE WHEN p_cutoff_date IS NOT NULL
                                                        THEN ' (cutoff ' || TO_CHAR(p_cutoff_date, 'YYYY-MM-DD')
                                                             || ' is ' || l_retention || ' days ago)'
                                                        ELSE ', got: ' || p_retention_days END);
            END IF;
            l_cutoff := TRUNC(SYSDATE) - l_retention;
            l_batch  := norm_batch(p_batch_size);
            l_rows   := epf_util.setting_num('batch_rows_max');
            IF l_rows IS NULL OR l_rows < 1 THEN
                RAISE_APPLICATION_ERROR(-20127, 'Setting batch_rows_max must be a positive number of rows.');
            END IF;
        END IF;
        IF p_max_redo_bytes IS NOT NULL AND (l_action NOT IN ('PURGE', 'PREFLIGHT') OR p_max_redo_bytes <= 0) THEN
            RAISE_APPLICATION_ERROR(-20127, 'The most redo per run applies to preflight and purge runs and must be '
                                            || 'a positive number of bytes, got: ' || p_max_redo_bytes);
        END IF;

        -- Plan checks, before any change: a plan step must be a pending step
        -- of the open plan with the run's scope; a purge that deletes outside
        -- the open plan needs new_plan while that plan is in progress.
        SELECT MAX(plan_id) KEEP (DENSE_RANK LAST ORDER BY plan_id),
               MAX(status) KEEP (DENSE_RANK LAST ORDER BY plan_id),
               MAX(purge_mode) KEEP (DENSE_RANK LAST ORDER BY plan_id),
               MAX(depth) KEEP (DENSE_RANK LAST ORDER BY plan_id)
          INTO l_open, l_open_st, l_open_mode, l_open_dep
          FROM epf_plan
         WHERE status IN ('READY', 'IN_PROGRESS');
        IF p_plan_id IS NOT NULL OR p_plan_step IS NOT NULL THEN
            IF l_action <> 'PURGE' OR p_plan_id IS NULL OR p_plan_step IS NULL THEN
                RAISE_APPLICATION_ERROR(-20127, 'A plan step applies to a purge run, given with its plan.');
            END IF;
            IF NVL(l_open, -1) <> p_plan_id THEN
                RAISE_APPLICATION_ERROR(-20128, epf_util.plan_label(p_plan_id) || ' is not the open plan.');
            END IF;
            SELECT MAX(cutoff_date), MAX(status)
              INTO l_step_cut, l_step_st
              FROM epf_plan_step
             WHERE plan_id = p_plan_id AND step_no = p_plan_step;
            IF NVL(l_step_st, '-') <> 'PENDING' THEN
                RAISE_APPLICATION_ERROR(-20128, 'Step ' || p_plan_step || ' of ' || epf_util.plan_label(p_plan_id)
                                                || ' is not a pending step.');
            END IF;
            IF l_mode <> l_open_mode OR l_depth <> l_open_dep OR l_cutoff <> l_step_cut THEN
                RAISE_APPLICATION_ERROR(-20128, 'The run does not match step ' || p_plan_step || ' of '
                                                || epf_util.plan_label(p_plan_id) || ' (mode ' || l_open_mode
                                                || ', depth ' || l_open_dep || ', cutoff '
                                                || TO_CHAR(l_step_cut, 'YYYY-MM-DD') || ').');
            END IF;
        ELSIF l_action = 'PURGE' AND l_dry_run = 'N' AND l_new_plan = 'N' AND l_open_st = 'IN_PROGRESS' THEN
            RAISE_APPLICATION_ERROR(-20128, 'Plan ' || epf_util.plan_label(l_open) || ' is in progress ('
                                            || plan_progress(l_open) || '): continue it, or start over (new plan).');
        END IF;

        UPDATE epf_run
           SET status   = 'ABANDONED',
               ended_at = epf_util.now_ts,
               message  = 'No session held the run lock when run '
                          || 'was found in status ' || status || ' at the start of a new run.'
         WHERE status IN ('CREATED', 'RUNNING');

        prune_history;

        INSERT INTO epf_run (
            action, status, retention_days, cutoff_date, depth, purge_mode, batch_size, batch_rows,
            dry_run, with_reclaim, with_compact, with_undo_tuning, with_redo_logs, backup_choice, confirmed_reqs,
            plan_id, plan_step, max_redo_bytes, new_plan,
            created_at, db_name, container_name, client_host, os_user, tool_version
        ) VALUES (
            l_action, 'CREATED', l_retention, l_cutoff, l_depth, l_mode, l_batch, l_rows,
            l_dry_run, l_reclaim, l_compact, l_undo, l_redo, l_backup, l_confirm,
            p_plan_id, p_plan_step, p_max_redo_bytes, l_new_plan, epf_util.now_ts,
            SYS_CONTEXT('USERENV', 'DB_NAME'), SYS_CONTEXT('USERENV', 'CON_NAME'),
            SYS_CONTEXT('USERENV', 'HOST'), SYS_CONTEXT('USERENV', 'OS_USER'),
            epf_util.setting('tool_version')
        ) RETURNING run_id INTO l_run_id;

        -- A purge that deletes a plan step puts the plan in progress; a run
        -- that starts over closes the open plan; any other purge that deletes
        -- replaces a plan not started yet. Dry runs change no plan. A closed
        -- plan is reported as an event of the run (PLAN).
        IF l_open IS NOT NULL THEN
            IF p_plan_id IS NOT NULL THEN
                IF l_dry_run = 'N' THEN
                    UPDATE epf_plan SET status = 'IN_PROGRESS' WHERE plan_id = p_plan_id;
                    UPDATE epf_plan_step
                       SET last_run_id = l_run_id
                     WHERE plan_id = p_plan_id AND step_no = p_plan_step;
                END IF;
            ELSIF l_new_plan = 'Y' AND (l_action = 'PREFLIGHT' OR (l_action = 'PURGE' AND l_dry_run = 'N')) THEN
                l_closed := 'started over by ' || epf_util.run_label(l_run_id);
            ELSIF l_action = 'PURGE' AND l_dry_run = 'N' THEN
                l_closed := 'replaced by purge ' || epf_util.run_label(l_run_id);
            END IF;
            IF l_closed IS NOT NULL THEN
                l_closed := l_closed || ' (' || plan_progress(l_open) || ')';
                end_plan(l_open, l_closed);
            END IF;
        END IF;
        COMMIT;
        IF l_closed IS NOT NULL THEN
            epf_log.event(epf_log.c_info, 'PLAN', epf_util.plan_label(l_open) || ' closed: ' || l_closed,
                          p_run_id => l_run_id);
        END IF;
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
                   || ' batch=' || l_run.batch_size || ' batch_rows=' || l_run.batch_rows
                   || ' dry_run=' || l_run.dry_run
               END
            || ' reclaim=' || l_run.with_reclaim || ' compact=' || l_run.with_compact
            || ' undo_tuning=' || l_run.with_undo_tuning || ' redo_logs=' || l_run.with_redo_logs
            || CASE WHEN l_run.backup_choice IS NOT NULL THEN ' backup=' || l_run.backup_choice END
            || CASE WHEN l_run.confirmed_reqs IS NOT NULL THEN ' confirmed=' || l_run.confirmed_reqs END
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

    PROCEDURE set_choices(
        p_run_id           IN NUMBER,
        p_batch_size       IN NUMBER,
        p_with_undo_tuning IN VARCHAR2,
        p_with_redo_logs   IN VARCHAR2,
        p_backup_choice    IN VARCHAR2,
        p_confirm          IN VARCHAR2
    ) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_batch   NUMBER        := norm_batch(p_batch_size);
        l_undo    VARCHAR2(1)   := yes_no(p_with_undo_tuning, 'with_undo_tuning');
        l_redo    VARCHAR2(1)   := yes_no(p_with_redo_logs, 'with_redo_logs');
        l_backup  VARCHAR2(10)  := norm_backup(p_backup_choice);
        l_confirm VARCHAR2(100) := norm_confirm(p_confirm);
    BEGIN
        UPDATE epf_run
           SET batch_size       = l_batch,
               with_undo_tuning = l_undo,
               with_redo_logs   = l_redo,
               backup_choice    = l_backup,
               confirmed_reqs   = l_confirm
         WHERE run_id = p_run_id
           AND action IN ('PURGE', 'PREFLIGHT')
           AND status = 'RUNNING';
        IF SQL%ROWCOUNT = 0 THEN
            ROLLBACK;
            RAISE_APPLICATION_ERROR(-20124, 'Run ' || epf_util.run_label(p_run_id)
                                            || ' is not a running purge or preflight run.');
        END IF;
        COMMIT;
    END set_choices;

    FUNCTION open_plan_id RETURN NUMBER IS
        l_plan NUMBER;
    BEGIN
        SELECT MAX(plan_id) INTO l_plan FROM epf_plan WHERE status IN ('READY', 'IN_PROGRESS');
        RETURN l_plan;
    END open_plan_id;

    PROCEDURE close_plan(p_reason IN VARCHAR2, p_plan_id OUT NUMBER) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
    BEGIN
        IF NOT lock_is_free THEN
            RAISE_APPLICATION_ERROR(-20122, 'Another run is active: '
                                            || NVL(epf_util.run_label(active_run_id), 'unknown run'));
        END IF;
        SELECT MAX(plan_id) INTO p_plan_id FROM epf_plan WHERE status IN ('READY', 'IN_PROGRESS');
        IF p_plan_id IS NOT NULL THEN
            end_plan(p_plan_id, p_reason);
        END IF;
        COMMIT;
    END close_plan;

    PROCEDURE end_plan_step(p_run_id IN NUMBER, p_complete IN BOOLEAN) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_plan  NUMBER;
        l_step  NUMBER;
        l_total NUMBER;
        l_done  NUMBER;
        l_next  DATE;
    BEGIN
        SELECT MAX(plan_id), MAX(plan_step)
          INTO l_plan, l_step
          FROM epf_run
         WHERE run_id = p_run_id AND action = 'PURGE' AND dry_run = 'N';
        IF l_plan IS NULL OR l_step IS NULL THEN
            RETURN;
        END IF;
        IF p_complete THEN
            UPDATE epf_plan_step
               SET status = 'DONE', done_at = epf_util.now_ts, last_run_id = p_run_id
             WHERE plan_id = l_plan AND step_no = l_step AND status = 'PENDING';
        END IF;
        SELECT COUNT(*), COUNT(CASE WHEN status = 'DONE' THEN 1 END),
               MIN(CASE WHEN status = 'PENDING' THEN cutoff_date END)
          INTO l_total, l_done, l_next
          FROM epf_plan_step
         WHERE plan_id = l_plan;
        IF l_done = l_total THEN
            UPDATE epf_plan
               SET status = 'DONE', closed_at = epf_util.now_ts
             WHERE plan_id = l_plan AND status IN ('READY', 'IN_PROGRESS');
        END IF;
        COMMIT;
        epf_log.event(CASE WHEN p_complete THEN epf_log.c_ok ELSE epf_log.c_warn END, 'PLAN_STEP',
                      epf_util.plan_label(l_plan) || ' step ' || l_step || ' of ' || l_total
                      || CASE WHEN p_complete THEN ' done' ELSE ' not done: the next purge of the plan carries it on' END
                      || CASE WHEN l_done = l_total THEN '; the plan is done'
                              WHEN l_next IS NOT NULL THEN '; next: rows before ' || TO_CHAR(l_next, 'YYYY-MM-DD') END,
                      p_rows => l_step, p_run_id => p_run_id);
    END end_plan_step;

    PROCEDURE end_plan_check(p_run_id IN NUMBER, p_status IN VARCHAR2) IS
        PRAGMA AUTONOMOUS_TRANSACTION;
        l_plan    NUMBER;
        l_created NUMBER;
        l_prev    NUMBER;
        l_text    VARCHAR2(400);
    BEGIN
        IF UPPER(p_status) IN ('SUCCESS', 'WARNING') THEN
            RETURN;
        END IF;
        SELECT MAX(plan_id), MAX(created_run_id)
          INTO l_plan, l_created
          FROM epf_plan
         WHERE preflight_run_id = p_run_id AND status IN ('READY', 'IN_PROGRESS');
        IF l_plan IS NULL THEN
            RETURN;
        END IF;
        IF l_created = p_run_id THEN
            end_plan(l_plan, 'its preflight ' || epf_util.run_label(p_run_id) || ' ended ' || UPPER(p_status));
            l_text := ' closed: its preflight ' || epf_util.run_label(p_run_id) || ' ended ' || UPPER(p_status)
                      || '; a preflight of the scope plans it again';
        ELSE
            SELECT MAX(run_id)
              INTO l_prev
              FROM epf_run
             WHERE plan_id = l_plan AND action = 'PREFLIGHT' AND run_id < p_run_id AND status IN ('SUCCESS', 'WARNING');
            IF l_prev IS NULL THEN
                RETURN;
            END IF;
            UPDATE epf_plan
               SET preflight_run_id = l_prev,
                   checked_at       = (SELECT NVL(started_at, created_at) FROM epf_run WHERE run_id = l_prev)
             WHERE plan_id = l_plan;
            l_text := ' keeps the check of ' || epf_util.run_label(l_prev) || ': the preflight '
                      || epf_util.run_label(p_run_id) || ' ended ' || UPPER(p_status);
        END IF;
        COMMIT;
        epf_log.event(epf_log.c_warn, 'PLAN', epf_util.plan_label(l_plan) || l_text, p_run_id => p_run_id);
    END end_plan_check;

END epf_control;
/

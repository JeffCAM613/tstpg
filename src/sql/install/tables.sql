-- ============================================================================
-- EPF Data Purge - Tool tables
-- ============================================================================
-- Purpose : Creates every table of the tool schema. Existing tables are kept
--           with their data; columns and indexes missing from them are added,
--           so the script can be re-run at any time.
-- Usage   : Called by install.sql with CURRENT_SCHEMA set to EPFPG.
--           Can also be run while connected as EPFPG.
-- Effects : Creates missing tables, columns and indexes in the current schema.
-- ============================================================================

DECLARE
    l_temporary VARCHAR2(1);

    PROCEDURE create_table(p_name IN VARCHAR2, p_ddl IN VARCHAR2) IS
        l_count PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
          INTO l_count
          FROM all_tables
         WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
           AND table_name = p_name;
        IF l_count = 0 THEN
            EXECUTE IMMEDIATE p_ddl;
            DBMS_OUTPUT.PUT_LINE('  created  table ' || p_name);
        ELSE
            DBMS_OUTPUT.PUT_LINE('  present  table ' || p_name);
        END IF;
    END create_table;

    PROCEDURE create_index(p_name IN VARCHAR2, p_ddl IN VARCHAR2) IS
        l_count PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
          INTO l_count
          FROM all_indexes
         WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
           AND index_name = p_name;
        IF l_count = 0 THEN
            EXECUTE IMMEDIATE p_ddl;
            DBMS_OUTPUT.PUT_LINE('  created  index ' || p_name);
        END IF;
    END create_index;

    -- Adds a column to an existing table when it is missing.
    PROCEDURE add_column(p_table IN VARCHAR2, p_column IN VARCHAR2, p_definition IN VARCHAR2) IS
        l_count PLS_INTEGER;
    BEGIN
        SELECT COUNT(*)
          INTO l_count
          FROM all_tab_columns
         WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
           AND table_name = p_table
           AND column_name = p_column;
        IF l_count = 0 THEN
            EXECUTE IMMEDIATE 'ALTER TABLE ' || p_table || ' ADD (' || p_column || ' ' || p_definition || ')';
            DBMS_OUTPUT.PUT_LINE('  added    column ' || p_table || '.' || p_column);
        END IF;
    END add_column;
BEGIN
    -- Settings: tunables with defaults. Values changed by the operator are
    -- kept on upgrade (registry_data.sql inserts missing names only).
    create_table('EPF_SETTING', q'[
        CREATE TABLE epf_setting (
            name         VARCHAR2(64)   NOT NULL,
            value        VARCHAR2(4000),
            description  VARCHAR2(400),
            updated_at   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            CONSTRAINT epf_setting_pk PRIMARY KEY (name)
        )]');

    -- Registry: purge modules.
    create_table('EPF_MODULE', q'[
        CREATE TABLE epf_module (
            module_code    VARCHAR2(30)  NOT NULL,
            display_order  NUMBER        NOT NULL,
            description    VARCHAR2(400),
            CONSTRAINT epf_module_pk PRIMARY KEY (module_code)
        )]');

    -- Registry: every table in purge scope. A ROOT table is selected by its
    -- date column; a DEPENDENT table is selected through EPF_LINK rows.
    -- Tables are processed in ascending delete_order within their root tree.
    create_table('EPF_TABLE', q'[
        CREATE TABLE epf_table (
            table_id       NUMBER         NOT NULL,
            module_code    VARCHAR2(30)   NOT NULL,
            root_table_id  NUMBER         NOT NULL,
            owner          VARCHAR2(128)  NOT NULL,
            table_name     VARCHAR2(128)  NOT NULL,
            role           VARCHAR2(10)   NOT NULL,
            key_column     VARCHAR2(128),
            date_column    VARCHAR2(128),
            delete_order   NUMBER         NOT NULL,
            lob_clear      CHAR(1)        DEFAULT 'Y' NOT NULL,
            active         CHAR(1)        DEFAULT 'Y' NOT NULL,
            description    VARCHAR2(400),
            CONSTRAINT epf_table_pk      PRIMARY KEY (table_id),
            CONSTRAINT epf_table_uk      UNIQUE (owner, table_name),
            CONSTRAINT epf_table_mod_fk  FOREIGN KEY (module_code) REFERENCES epf_module (module_code),
            CONSTRAINT epf_table_role_ck CHECK (role IN ('ROOT', 'DEPENDENT')),
            CONSTRAINT epf_table_lob_ck  CHECK (lob_clear IN ('Y', 'N')),
            CONSTRAINT epf_table_act_ck  CHECK (active IN ('Y', 'N'))
        )]');

    -- Registry: rows of table_id whose match_column is in the key set of
    -- source_table_id.source_column are dependents of those source rows.
    create_table('EPF_LINK', q'[
        CREATE TABLE epf_link (
            link_id          NUMBER         NOT NULL,
            table_id         NUMBER         NOT NULL,
            match_column     VARCHAR2(128)  NOT NULL,
            source_table_id  NUMBER         NOT NULL,
            source_column    VARCHAR2(128)  NOT NULL,
            CONSTRAINT epf_link_pk     PRIMARY KEY (link_id),
            CONSTRAINT epf_link_tab_fk FOREIGN KEY (table_id) REFERENCES epf_table (table_id),
            CONSTRAINT epf_link_src_fk FOREIGN KEY (source_table_id) REFERENCES epf_table (table_id)
        )]');

    -- One row per run.
    create_table('EPF_RUN', q'[
        CREATE TABLE epf_run (
            run_id          NUMBER GENERATED ALWAYS AS IDENTITY NOT NULL,
            action          VARCHAR2(30)   NOT NULL,
            status          VARCHAR2(20)   NOT NULL,
            verdict         VARCHAR2(30),
            exit_code       NUMBER,
            retention_days  NUMBER,
            cutoff_date     DATE,
            depth           VARCHAR2(200),
            purge_mode      VARCHAR2(30),
            batch_size      NUMBER,
            dry_run         CHAR(1)        DEFAULT 'N' NOT NULL,
            with_reclaim    CHAR(1)        DEFAULT 'N' NOT NULL,
            with_compact    CHAR(1)        DEFAULT 'N' NOT NULL,
            with_undo_tuning CHAR(1)       DEFAULT 'N' NOT NULL CHECK (with_undo_tuning IN ('Y', 'N')),
            with_redo_logs  CHAR(1)        DEFAULT 'N' NOT NULL CHECK (with_redo_logs IN ('Y', 'N')),
            backup_choice   VARCHAR2(10)   CHECK (backup_choice IN ('CONFIRMED', 'NONE')),
            confirmed_reqs  VARCHAR2(100),
            stop_requested  CHAR(1)        DEFAULT 'N' NOT NULL,
            created_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            started_at      TIMESTAMP,
            ended_at        TIMESTAMP,
            db_name         VARCHAR2(128),
            container_name  VARCHAR2(128),
            client_host     VARCHAR2(256),
            os_user         VARCHAR2(256),
            tool_version    VARCHAR2(30),
            message         VARCHAR2(4000),
            CONSTRAINT epf_run_pk        PRIMARY KEY (run_id),
            CONSTRAINT epf_run_status_ck CHECK (status IN ('CREATED', 'RUNNING', 'SUCCESS', 'WARNING',
                                                           'FAILED', 'STOPPED', 'ABANDONED')),
            CONSTRAINT epf_run_flags_ck  CHECK (dry_run IN ('Y', 'N') AND with_reclaim IN ('Y', 'N')
                                                AND with_compact IN ('Y', 'N')
                                                AND stop_requested IN ('Y', 'N'))
        )]');
    -- with_undo_tuning: undo tuning (epf_tuning.undo_apply) is applied for the
    -- purge by the caller; the preflight then assumes its growth limit.
    add_column('EPF_RUN', 'WITH_UNDO_TUNING', q'[CHAR(1) DEFAULT 'N' NOT NULL CHECK (with_undo_tuning IN ('Y', 'N'))]');
    -- with_redo_logs: the online redo logs are enlarged (redo_logs.sql) when
    -- the purge starts; a preflight checks the requirements as if they were.
    add_column('EPF_RUN', 'WITH_REDO_LOGS', q'[CHAR(1) DEFAULT 'N' NOT NULL CHECK (with_redo_logs IN ('Y', 'N'))]');
    -- backup_choice: how the operator meets the BACKUP requirement when no
    -- recent RMAN backup is found: CONFIRMED (a backup made another way) or
    -- NONE (purge without a backup); NULL when not given.
    add_column('EPF_RUN', 'BACKUP_CHOICE', q'[VARCHAR2(10) CHECK (backup_choice IN ('CONFIRMED', 'NONE'))]');
    -- confirmed_reqs: blocking requirements the operator confirms are handled
    -- although the preflight finds them not met (ARCHIVE, UNDO, TEMP;
    -- separated by commas), for example an archive directory whose free
    -- space the database cannot read.
    add_column('EPF_RUN', 'CONFIRMED_REQS', 'VARCHAR2(100)');

    -- Step checklist and state of each run. scope is '-' when not applicable.
    create_table('EPF_STEP', q'[
        CREATE TABLE epf_step (
            run_id       NUMBER         NOT NULL,
            step_seq     NUMBER         NOT NULL,
            phase        VARCHAR2(30)   NOT NULL,
            step_code    VARCHAR2(40)   NOT NULL,
            scope        VARCHAR2(128)  DEFAULT '-' NOT NULL,
            status       VARCHAR2(20)   NOT NULL,
            started_at   TIMESTAMP,
            ended_at     TIMESTAMP,
            units_done   NUMBER,
            units_total  NUMBER,
            bytes_done   NUMBER,
            bytes_total  NUMBER,
            message      VARCHAR2(4000),
            CONSTRAINT epf_step_pk        PRIMARY KEY (run_id, step_seq),
            CONSTRAINT epf_step_uk        UNIQUE (run_id, phase, step_code, scope),
            CONSTRAINT epf_step_status_ck CHECK (status IN ('PENDING', 'RUNNING', 'DONE', 'FAILED', 'SKIPPED'))
        )]');

    -- Event stream read by the live monitor and the report.
    create_table('EPF_EVENT', q'[
        CREATE TABLE epf_event (
            event_id       NUMBER GENERATED ALWAYS AS IDENTITY NOT NULL,
            run_id         NUMBER          NOT NULL,
            ts             TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
            phase          VARCHAR2(30),
            step_code      VARCHAR2(40),
            scope          VARCHAR2(128),
            severity       VARCHAR2(10)    NOT NULL,
            event_code     VARCHAR2(40)    NOT NULL,
            object_owner   VARCHAR2(128),
            object_name    VARCHAR2(128),
            sub_name       VARCHAR2(128),
            rows_affected  NUMBER,
            bytes          NUMBER,
            pct            NUMBER(5, 1),
            elapsed_s      NUMBER(12, 3),
            ora_code       NUMBER,
            message        VARCHAR2(4000),
            session_user   VARCHAR2(128),
            CONSTRAINT epf_event_pk     PRIMARY KEY (event_id),
            CONSTRAINT epf_event_sev_ck CHECK (severity IN ('INFO', 'OK', 'WARN', 'ERROR', 'PROGRESS'))
        )]');
    create_index('EPF_EVENT_RUN_IX',
        'CREATE INDEX epf_event_run_ix ON epf_event (run_id, event_id)');

    -- Key snapshot of eligible rows during a purge.
    --   Root rows      key_num (or key_rowid for roots purged by ROWID),
    --                  batch_no, root_key = key_num, group_key = smallest
    --                  root key of the roots that must share a batch.
    --   Derived rows   keys of link sources below the root: key_num and the
    --                  root_key they derive from; batch_no = 0 (their batch is
    --                  the batch of root_key). A key derived from several
    --                  roots has one row per root.
    -- A global temporary table: the keys belong to the purging session only,
    -- they write no redo, and with temp_undo_enabled (set by epf_purge) their
    -- undo goes to the temporary tablespace. A permanent EPF_WORK_KEY is
    -- replaced; its rows are transient work data of finished runs.
    SELECT MAX(temporary)
      INTO l_temporary
      FROM all_tables
     WHERE owner = SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA')
       AND table_name = 'EPF_WORK_KEY';
    IF l_temporary = 'N' THEN
        EXECUTE IMMEDIATE 'DROP TABLE epf_work_key PURGE';
        DBMS_OUTPUT.PUT_LINE('  dropped  table EPF_WORK_KEY (permanent; replaced by a temporary table)');
    END IF;
    create_table('EPF_WORK_KEY', q'[
        CREATE GLOBAL TEMPORARY TABLE epf_work_key (
            run_id     NUMBER  NOT NULL,
            table_id   NUMBER  NOT NULL,
            batch_no   NUMBER  NOT NULL,
            key_num    NUMBER,
            key_rowid  UROWID,
            root_key   NUMBER,
            group_key  NUMBER
        ) ON COMMIT PRESERVE ROWS]');
    create_index('EPF_WORK_KEY_IX',
        'CREATE INDEX epf_work_key_ix ON epf_work_key (run_id, table_id, batch_no)');
    create_index('EPF_WORK_KEY_ROOT_IX',
        'CREATE INDEX epf_work_key_root_ix ON epf_work_key (run_id, table_id, root_key)');
    create_index('EPF_WORK_KEY_KEY_IX',
        'CREATE INDEX epf_work_key_key_ix ON epf_work_key (run_id, table_id, key_num)');

    -- Roots left out of a purge because a row that is kept references a row
    -- of their tree (one row per root, with the first reference found).
    create_table('EPF_HELD_ROOT', q'[
        CREATE TABLE epf_held_root (
            run_id           NUMBER         NOT NULL,
            table_id         NUMBER         NOT NULL,
            root_key         NUMBER         NOT NULL,
            child_owner      VARCHAR2(128)  NOT NULL,
            child_table      VARCHAR2(128)  NOT NULL,
            constraint_name  VARCHAR2(128)  NOT NULL,
            parent_owner     VARCHAR2(128)  NOT NULL,
            parent_table     VARCHAR2(128)  NOT NULL,
            iteration        NUMBER         NOT NULL,
            CONSTRAINT epf_held_root_pk PRIMARY KEY (run_id, table_id, root_key)
        )]');

    -- Per-table row counts per phase (BEFORE / AFTER). In LOB-clearing modes
    -- nonempty_lob_rows counts non-empty LOB values (row x LOB column).
    -- held_rows: roots held back (root tables) or rows kept because a
    -- retained row still references them (tables reached by a reverse link).
    create_table('EPF_TABLE_STAT', q'[
        CREATE TABLE epf_table_stat (
            run_id             NUMBER        NOT NULL,
            table_id           NUMBER        NOT NULL,
            phase              VARCHAR2(20)  NOT NULL,
            total_rows         NUMBER,
            eligible_rows      NUMBER,
            retained_rows      NUMBER,
            nonempty_lob_rows  NUMBER,
            processed_rows     NUMBER,
            orphan_rows        NUMBER,
            held_rows          NUMBER,
            action             VARCHAR2(10),
            measured_at        TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
            CONSTRAINT epf_table_stat_pk PRIMARY KEY (run_id, table_id, phase)
        )]');
    add_column('EPF_TABLE_STAT', 'HELD_ROWS', 'NUMBER');
    add_column('EPF_TABLE_STAT', 'ACTION', 'VARCHAR2(10)');

    -- Orphans per registry link and phase: rows on the pointing side (the
    -- dependent for a direct link, the source for a reverse link) whose value
    -- is not found on the pointed side. protected_by names the enabled,
    -- validated FK that makes orphans impossible (no scan).
    create_table('EPF_LINK_STAT', q'[
        CREATE TABLE epf_link_stat (
            run_id             NUMBER         NOT NULL,
            link_id            NUMBER         NOT NULL,
            phase              VARCHAR2(20)   NOT NULL,
            pointing_table_id  NUMBER         NOT NULL,
            orphan_rows        NUMBER,
            protected_by       VARCHAR2(128),
            measured_at        TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            CONSTRAINT epf_link_stat_pk PRIMARY KEY (run_id, link_id, phase)
        )]');

    -- Checks of a run and their outcome (report).
    create_table('EPF_CHECK', q'[
        CREATE TABLE epf_check (
            run_id        NUMBER          NOT NULL,
            check_id      VARCHAR2(10)    NOT NULL,
            status        VARCHAR2(10)    NOT NULL,
            title         VARCHAR2(200)   NOT NULL,
            value         VARCHAR2(200),
            detail        VARCHAR2(4000),
            evaluated_at  TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL,
            CONSTRAINT epf_check_pk        PRIMARY KEY (run_id, check_id),
            CONSTRAINT epf_check_status_ck CHECK (status IN ('PASS', 'WARN', 'FAIL', 'SKIP'))
        )]');

    -- Segment sizes per phase.
    create_table('EPF_SEGMENT_SNAP', q'[
        CREATE TABLE epf_segment_snap (
            run_id           NUMBER         NOT NULL,
            phase            VARCHAR2(20)   NOT NULL,
            owner            VARCHAR2(128)  NOT NULL,
            segment_name     VARCHAR2(128)  NOT NULL,
            partition_name   VARCHAR2(128),
            segment_type     VARCHAR2(30),
            parent_owner     VARCHAR2(128),
            parent_table     VARCHAR2(128),
            tablespace_name  VARCHAR2(128),
            bytes            NUMBER,
            blocks           NUMBER,
            extents          NUMBER,
            module_code      VARCHAR2(30),
            captured_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
        )]');
    create_index('EPF_SEGMENT_SNAP_IX',
        'CREATE INDEX epf_segment_snap_ix ON epf_segment_snap (run_id, phase)');

    -- Datafile geometry per phase.
    create_table('EPF_FILE_SNAP', q'[
        CREATE TABLE epf_file_snap (
            run_id           NUMBER         NOT NULL,
            phase            VARCHAR2(20)   NOT NULL,
            tablespace_name  VARCHAR2(128)  NOT NULL,
            file_id          NUMBER         NOT NULL,
            file_name        VARCHAR2(513),
            bytes            NUMBER,
            hwm_bytes        NUMBER,
            free_bytes       NUMBER,
            autoextensible   VARCHAR2(3),
            increment_by     NUMBER,
            maxbytes         NUMBER,
            captured_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
        )]');
    create_index('EPF_FILE_SNAP_IX',
        'CREATE INDEX epf_file_snap_ix ON epf_file_snap (run_id, phase)');

    -- Space used inside segments per phase (DBMS_SPACE or estimate).
    create_table('EPF_SPACE_USAGE', q'[
        CREATE TABLE epf_space_usage (
            run_id           NUMBER         NOT NULL,
            phase            VARCHAR2(20)   NOT NULL,
            owner            VARCHAR2(128)  NOT NULL,
            segment_name     VARCHAR2(128)  NOT NULL,
            partition_name   VARCHAR2(128),
            segment_type     VARCHAR2(30),
            allocated_bytes  NUMBER,
            used_bytes       NUMBER,
            free_bytes       NUMBER,
            method           VARCHAR2(20),
            measured_at      TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL
        )]');
    create_index('EPF_SPACE_USAGE_IX',
        'CREATE INDEX epf_space_usage_ix ON epf_space_usage (run_id, phase)');

    -- Reclaim fingerprint: indexes, constraints, invalid objects, row counts,
    -- account status.
    create_table('EPF_OBJECT_BASELINE', q'[
        CREATE TABLE epf_object_baseline (
            run_id           NUMBER         NOT NULL,
            object_type      VARCHAR2(30)   NOT NULL,
            owner            VARCHAR2(128)  NOT NULL,
            name             VARCHAR2(128)  NOT NULL,
            table_name       VARCHAR2(128),
            tablespace_name  VARCHAR2(128),
            status           VARCHAR2(30),
            validated        VARCHAR2(20),
            degree           VARCHAR2(40),
            logging          VARCHAR2(10),
            row_count        NUMBER,
            detail           VARCHAR2(4000)
        )]');
    create_index('EPF_OBJECT_BASELINE_IX',
        'CREATE INDEX epf_object_baseline_ix ON epf_object_baseline (run_id, object_type)');

    -- Everything that lives in or points at a target tablespace.
    create_table('EPF_TS_INVENTORY', q'[
        CREATE TABLE epf_ts_inventory (
            run_id           NUMBER         NOT NULL,
            tablespace_name  VARCHAR2(128)  NOT NULL,
            kind             VARCHAR2(20)   NOT NULL,
            owner            VARCHAR2(128),
            object_name      VARCHAR2(128),
            sub_name         VARCHAR2(128),
            segment_type     VARCHAR2(30),
            bytes            NUMBER,
            handler          VARCHAR2(30),
            blocker_reason   VARCHAR2(400),
            CONSTRAINT epf_ts_inv_kind_ck CHECK (kind IN ('SEGMENT', 'SEGMENTLESS', 'DEFAULT_ATTR',
                                                          'USER_DEFAULT', 'QUOTA', 'DB_DEFAULT',
                                                          'RECYCLEBIN'))
        )]');
    create_index('EPF_TS_INVENTORY_IX',
        'CREATE INDEX epf_ts_inventory_ix ON epf_ts_inventory (run_id, tablespace_name)');

    -- Reclaim journal per movable unit.
    create_table('EPF_RECLAIM_OBJECT', q'[
        CREATE TABLE epf_reclaim_object (
            run_id       NUMBER         NOT NULL,
            owner        VARCHAR2(128)  NOT NULL,
            object_name  VARCHAR2(128)  NOT NULL,
            sub_name     VARCHAR2(128),
            unit_type    VARCHAR2(30)   NOT NULL,
            source_ts    VARCHAR2(128),
            target_ts    VARCHAR2(128),
            bytes        NUMBER,
            move_status  VARCHAR2(20)   DEFAULT 'PENDING' NOT NULL,
            attempts     NUMBER         DEFAULT 0 NOT NULL,
            last_ora     NUMBER,
            started_at   TIMESTAMP,
            ended_at     TIMESTAMP
        )]');
    create_index('EPF_RECLAIM_OBJECT_IX',
        'CREATE INDEX epf_reclaim_object_ix ON epf_reclaim_object (run_id, move_status)');

    -- Temporary supporting indexes created for a purge. owner is the index
    -- owner (the tool schema); table_owner.table_name is the indexed table.
    -- dropped_at is set when the index is dropped or could not be created.
    create_table('EPF_TEMP_INDEX', q'[
        CREATE TABLE epf_temp_index (
            run_id       NUMBER         NOT NULL,
            owner        VARCHAR2(128)  NOT NULL,
            index_name   VARCHAR2(128)  NOT NULL,
            table_owner  VARCHAR2(128),
            table_name   VARCHAR2(128)  NOT NULL,
            column_name  VARCHAR2(128)  NOT NULL,
            created_at   TIMESTAMP      DEFAULT SYSTIMESTAMP NOT NULL,
            dropped_at   TIMESTAMP,
            CONSTRAINT epf_temp_index_pk PRIMARY KEY (owner, index_name)
        )]');
    add_column('EPF_TEMP_INDEX', 'TABLE_OWNER', 'VARCHAR2(128)');

    -- LONG / LONG RAW columns found, decision and result.
    create_table('EPF_LONG_CONVERSION', q'[
        CREATE TABLE epf_long_conversion (
            run_id           NUMBER         NOT NULL,
            owner            VARCHAR2(128)  NOT NULL,
            table_name       VARCHAR2(128)  NOT NULL,
            column_name      VARCHAR2(128)  NOT NULL,
            tablespace_name  VARCHAR2(128),
            lob_tablespace   VARCHAR2(128),
            original_type    VARCHAR2(30)   NOT NULL,
            new_type         VARCHAR2(30)   NOT NULL,
            decision         VARCHAR2(10),
            row_count        NUMBER,
            bytes            NUMBER,
            dependents       VARCHAR2(400),
            status           VARCHAR2(20)   DEFAULT 'PENDING' NOT NULL,
            converted_at     TIMESTAMP,
            ora_code         NUMBER,
            message          VARCHAR2(4000),
            CONSTRAINT epf_long_conv_pk  PRIMARY KEY (run_id, owner, table_name, column_name),
            CONSTRAINT epf_long_conv_ck  CHECK (decision IN ('CONVERT', 'SKIP'))
        )]');

    -- Instance changes made by epf_tuning for the duration of a purge, with
    -- the original values needed to restore them (restored_at NULL while
    -- active). Kept outside history pruning: applied_run_id is not RUN_ID.
    create_table('EPF_INSTANCE_CHANGE', q'[
        CREATE TABLE epf_instance_change (
            change_id            NUMBER GENERATED ALWAYS AS IDENTITY NOT NULL,
            item                 VARCHAR2(30)   NOT NULL,
            target               VARCHAR2(513)  NOT NULL,
            file_id              NUMBER,
            original_value       NUMBER,
            original_autoextend  VARCHAR2(3),
            original_maxbytes    NUMBER,
            original_increment   NUMBER,
            applied_value        NUMBER,
            applied_at           TIMESTAMP      NOT NULL,
            restored_at          TIMESTAMP,
            applied_run_id       NUMBER,
            CONSTRAINT epf_instance_change_pk PRIMARY KEY (change_id),
            CONSTRAINT epf_instance_change_ck CHECK (item IN ('UNDO_RETENTION', 'UNDO_DATAFILE'))
        )]');

    -- Per root tree of a preflight: eligible roots and the redo and undo per
    -- root with their basis (measured by an earlier purge, or estimated).
    create_table('EPF_TREE_EST', q'[
        CREATE TABLE epf_tree_est (
            run_id      NUMBER          NOT NULL,
            table_id    NUMBER          NOT NULL,
            action      VARCHAR2(10)    NOT NULL,
            roots       NUMBER,
            redo_root   NUMBER,
            redo_basis  VARCHAR2(400),
            undo_root   NUMBER,
            undo_basis  VARCHAR2(400),
            undo_rate   NUMBER,
            CONSTRAINT epf_tree_est_pk PRIMARY KEY (run_id, table_id)
        )]');

    -- Roots before the cutoff of a preflight per month of their date (the
    -- largest purge that fits the archive space, smaller runs).
    create_table('EPF_ROOT_MONTH', q'[
        CREATE TABLE epf_root_month (
            run_id       NUMBER   NOT NULL,
            table_id     NUMBER   NOT NULL,
            month_start  DATE     NOT NULL,
            roots        NUMBER   NOT NULL,
            CONSTRAINT epf_root_month_pk PRIMARY KEY (run_id, table_id, month_start)
        )]');

    -- Roots before the cutoff of each retention option of a preflight (the
    -- requested retention and longer ones: retention table).
    create_table('EPF_RETENTION_OPTION', q'[
        CREATE TABLE epf_retention_option (
            run_id          NUMBER   NOT NULL,
            retention_days  NUMBER   NOT NULL,
            table_id        NUMBER   NOT NULL,
            cutoff_date     DATE     NOT NULL,
            roots           NUMBER   NOT NULL,
            CONSTRAINT epf_retention_option_pk PRIMARY KEY (run_id, retention_days, table_id)
        )]');

    -- Requirements of a purge measured by its preflight. status MET, NOT_MET
    -- or NOT_APPLICABLE; blocking Y when a purge cannot be expected to finish
    -- without it (N: it only slows the purge or leaves no way back).
    create_table('EPF_REQUIREMENT', q'[
        CREATE TABLE epf_requirement (
            run_id        NUMBER          NOT NULL,
            req_code      VARCHAR2(20)    NOT NULL,
            seq           NUMBER          NOT NULL,
            status        VARCHAR2(20)    NOT NULL,
            blocking      CHAR(1)         NOT NULL,
            title         VARCHAR2(200)   NOT NULL,
            why           VARCHAR2(1000),
            measured      VARCHAR2(2000),
            needed_bytes  NUMBER,
            room_bytes    NUMBER,
            met_by        VARCHAR2(30),
            CONSTRAINT epf_requirement_pk PRIMARY KEY (run_id, req_code),
            CONSTRAINT epf_requirement_ck CHECK (status IN ('MET', 'NOT_MET', 'NOT_APPLICABLE')
                                                 AND blocking IN ('Y', 'N'))
        )]');

    -- Ways to meet a requirement; met Y when the option meets it now.
    create_table('EPF_REQ_OPTION', q'[
        CREATE TABLE epf_req_option (
            run_id       NUMBER          NOT NULL,
            req_code     VARCHAR2(20)    NOT NULL,
            option_code  VARCHAR2(30)    NOT NULL,
            seq          NUMBER          NOT NULL,
            met          CHAR(1)         NOT NULL,
            title        VARCHAR2(200)   NOT NULL,
            detail       VARCHAR2(2000),
            CONSTRAINT epf_req_option_pk PRIMARY KEY (run_id, req_code, option_code),
            CONSTRAINT epf_req_option_ck CHECK (met IN ('Y', 'N'))
        )]');

    -- Forecast per module: by the preflight (eligible roots, estimates) and
    -- by a dry run (exact rows and roots after holding back, space freed).
    -- A purge report compares its result with the latest forecast.
    create_table('EPF_FORECAST', q'[
        CREATE TABLE epf_forecast (
            run_id          NUMBER          NOT NULL,
            origin          VARCHAR2(10)    NOT NULL,
            module_code     VARCHAR2(30)    NOT NULL,
            action          VARCHAR2(10),
            roots           NUMBER,
            row_count       NUMBER,
            batches         NUMBER,
            redo_bytes      NUMBER,
            undo_bytes      NUMBER,
            delete_seconds  NUMBER,
            freed_bytes     NUMBER,
            redo_basis      VARCHAR2(400),
            time_basis      VARCHAR2(400),
            CONSTRAINT epf_forecast_pk PRIMARY KEY (run_id, origin, module_code),
            CONSTRAINT epf_forecast_ck CHECK (origin IN ('PREFLIGHT', 'DRY_RUN'))
        )]');

    -- Accounts locked and sessions disconnected for the reclaim window.
    create_table('EPF_ACCOUNT_ACTION', q'[
        CREATE TABLE epf_account_action (
            run_id                 NUMBER         NOT NULL,
            username               VARCHAR2(128)  NOT NULL,
            original_status        VARCHAR2(32)   NOT NULL,
            locked_at              TIMESTAMP,
            unlocked_at            TIMESTAMP,
            sessions_disconnected  NUMBER         DEFAULT 0 NOT NULL,
            detail                 VARCHAR2(4000),
            CONSTRAINT epf_account_action_pk PRIMARY KEY (run_id, username)
        )]');
END;
/

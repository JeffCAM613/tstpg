CREATE OR REPLACE PACKAGE BODY epf_space AS

    PROCEDURE capture_segments(p_run_id IN NUMBER, p_phase IN VARCHAR2) IS
    BEGIN
        INSERT INTO epf_segment_snap (
            run_id, phase, owner, segment_name, partition_name, segment_type,
            parent_owner, parent_table, tablespace_name, bytes, blocks, extents, module_code
        )
        SELECT p_run_id, p_phase, s.owner, s.segment_name, s.partition_name, s.segment_type,
               m.parent_owner, m.parent_table, s.tablespace_name, s.bytes, s.blocks, s.extents, m.module_code
          FROM (SELECT e.owner AS seg_owner, e.table_name AS seg_name,
                       e.owner AS parent_owner, e.table_name AS parent_table, e.module_code
                  FROM epf_table e
                 WHERE e.active = 'Y'
                UNION ALL
                SELECT i.owner, i.index_name, e.owner, e.table_name, e.module_code
                  FROM epf_table e
                  JOIN dba_indexes i ON i.table_owner = e.owner AND i.table_name = e.table_name
                 WHERE e.active = 'Y'
                   AND i.index_type <> 'LOB'
                UNION ALL
                SELECT l.owner, l.segment_name, e.owner, e.table_name, e.module_code
                  FROM epf_table e
                  JOIN dba_lobs l ON l.owner = e.owner AND l.table_name = e.table_name
                 WHERE e.active = 'Y'
                UNION ALL
                SELECT l.owner, l.index_name, e.owner, e.table_name, e.module_code
                  FROM epf_table e
                  JOIN dba_lobs l ON l.owner = e.owner AND l.table_name = e.table_name
                 WHERE e.active = 'Y') m
          JOIN dba_segments s ON s.owner = m.seg_owner AND s.segment_name = m.seg_name;
    END capture_segments;

    PROCEDURE capture_files(p_run_id IN NUMBER, p_phase IN VARCHAR2) IS
    BEGIN
        INSERT INTO epf_file_snap (
            run_id, phase, tablespace_name, file_id, file_name, bytes, hwm_bytes, free_bytes,
            autoextensible, increment_by, maxbytes
        )
        SELECT p_run_id, p_phase, f.tablespace_name, f.file_id, f.file_name, f.bytes,
               (SELECT (MAX(x.block_id + x.blocks) - 1) * t.block_size
                  FROM dba_extents x
                 WHERE x.file_id = f.file_id),
               (SELECT SUM(fs.bytes) FROM dba_free_space fs WHERE fs.file_id = f.file_id),
               f.autoextensible, f.increment_by * t.block_size, f.maxbytes
          FROM dba_data_files f
          JOIN dba_tablespaces t ON t.tablespace_name = f.tablespace_name
         WHERE f.tablespace_name IN (SELECT DISTINCT ss.tablespace_name
                                       FROM epf_segment_snap ss
                                      WHERE ss.run_id = p_run_id AND ss.phase = p_phase
                                     UNION
                                     SELECT UPPER(p.value) FROM v$parameter p WHERE p.name = 'undo_tablespace');
    END capture_files;

    -- A BASICFILE LOB segment keeps the chunks of deleted or cleared values as
    -- used blocks: they are reused by new values of the same LOB column after
    -- the LOB retention, but DBMS_SPACE reports them as used. After a purge the
    -- use of such a segment is estimated from its BASELINE measurement times
    -- the share of the LOB data the purge left:
    --   deleting  rows not deleted / rows before
    --   clearing  1 - (values cleared / non-empty values of the eligible rows)
    --                 x (eligible rows / rows before)
    -- (LOB data assumed evenly spread over the rows). A lower measured value
    -- (after a shrink) is kept. Without a baseline or purge counts the
    -- measured value stands.
    PROCEDURE basicfile_estimate(p_run_id IN NUMBER, p_owner IN VARCHAR2, p_segment IN VARCHAR2,
                                 p_partition IN VARCHAR2, p_used IN OUT NUMBER, p_method IN OUT VARCHAR2) IS
        l_table     VARCHAR2(128);
        l_baseline  NUMBER;
        l_total     NUMBER;
        l_eligible  NUMBER;
        l_nonempty  NUMBER;
        l_processed NUMBER;
        l_action    VARCHAR2(10);
        l_left      NUMBER;
    BEGIN
        SELECT MAX(table_name) INTO l_table FROM dba_lobs WHERE owner = p_owner AND segment_name = p_segment;
        SELECT MAX(used_bytes)
          INTO l_baseline
          FROM epf_space_usage
         WHERE run_id = p_run_id AND phase = c_baseline AND owner = p_owner AND segment_name = p_segment
           AND NVL(partition_name, '-') = NVL(p_partition, '-');
        SELECT MAX(CASE WHEN st.phase = 'BEFORE' THEN st.total_rows END),
               MAX(CASE WHEN st.phase = 'BEFORE' THEN st.eligible_rows END),
               MAX(CASE WHEN st.phase = 'BEFORE' THEN st.nonempty_lob_rows END),
               MAX(CASE WHEN st.phase = 'AFTER' THEN st.processed_rows END),
               MAX(st.action)
          INTO l_total, l_eligible, l_nonempty, l_processed, l_action
          FROM epf_table_stat st
          JOIN epf_table e ON e.table_id = st.table_id
         WHERE st.run_id = p_run_id AND e.owner = p_owner AND e.table_name = l_table;
        IF l_baseline IS NULL OR l_processed IS NULL OR NVL(l_total, 0) = 0 THEN
            RETURN;
        END IF;
        IF l_action = 'CLEAR' THEN
            IF NVL(l_nonempty, 0) = 0 THEN
                RETURN;
            END IF;
            l_left := 1 - LEAST(l_processed / l_nonempty, 1) * NVL(l_eligible, 0) / l_total;
        ELSE
            l_left := 1 - l_processed / l_total;
        END IF;
        p_used   := LEAST(p_used, l_baseline * GREATEST(0, l_left));
        p_method := 'BASICFILE_EST';
    END basicfile_estimate;

    -- At a BASELINE, a BASICFILE LOB segment whose latest capture by another
    -- run is an estimate starts from that estimate plus what DBMS_SPACE
    -- reports more than then (new LOB data). Otherwise the chunks freed by
    -- the earlier purge, still reported as used, would count as freed again.
    -- A lower measured value (after a shrink) is kept.
    PROCEDURE basicfile_carry(p_run_id IN NUMBER, p_owner IN VARCHAR2, p_segment IN VARCHAR2,
                              p_partition IN VARCHAR2, p_used IN OUT NUMBER, p_method IN OUT VARCHAR2) IS
        l_method VARCHAR2(20);
        l_est    NUMBER;
        l_raw    NUMBER;
    BEGIN
        SELECT MAX(method) KEEP (DENSE_RANK LAST ORDER BY measured_at, run_id),
               MAX(used_bytes) KEEP (DENSE_RANK LAST ORDER BY measured_at, run_id),
               MAX(raw_used_bytes) KEEP (DENSE_RANK LAST ORDER BY measured_at, run_id)
          INTO l_method, l_est, l_raw
          FROM epf_space_usage
         WHERE run_id <> p_run_id AND owner = p_owner AND segment_name = p_segment
           AND NVL(partition_name, '-') = NVL(p_partition, '-');
        IF l_method = 'BASICFILE_EST' AND l_est IS NOT NULL AND l_raw IS NOT NULL THEN
            p_used   := LEAST(p_used, l_est + GREATEST(p_used - l_raw, 0));
            p_method := 'BASICFILE_EST';
        END IF;
    END basicfile_carry;

    PROCEDURE measure(p_run_id IN NUMBER, p_phase IN VARCHAR2, p_failed IN OUT PLS_INTEGER) IS
        l_type      VARCHAR2(30);
        l_method    VARCHAR2(20);
        l_used      NUMBER;
        l_raw       NUMBER;
        l_unf_b     NUMBER;
        l_unf       NUMBER;
        l_fs1_b     NUMBER;
        l_fs1       NUMBER;
        l_fs2_b     NUMBER;
        l_fs2       NUMBER;
        l_fs3_b     NUMBER;
        l_fs3       NUMBER;
        l_fs4_b     NUMBER;
        l_fs4       NUMBER;
        l_full_b    NUMBER;
        l_full      NUMBER;
        l_seg_b     NUMBER;
        l_seg       NUMBER;
        l_used_b    NUMBER;
        l_sf_used   NUMBER;
        l_exp_b     NUMBER;
        l_exp       NUMBER;
        l_unexp_b   NUMBER;
        l_unexp     NUMBER;
    BEGIN
        FOR s IN (SELECT ss.owner, ss.segment_name, ss.partition_name, ss.segment_type, ss.bytes,
                         t.segment_space_management AS ssm,
                         CASE ss.segment_type
                             WHEN 'LOBSEGMENT' THEN
                                 (SELECT MAX(l.securefile) FROM dba_lobs l
                                   WHERE l.owner = ss.owner AND l.segment_name = ss.segment_name)
                             WHEN 'LOB PARTITION' THEN
                                 (SELECT MAX(lp.securefile) FROM dba_lob_partitions lp
                                   WHERE lp.table_owner = ss.parent_owner AND lp.lob_name = ss.segment_name
                                     AND lp.lob_partition_name = ss.partition_name)
                         END AS securefile
                    FROM epf_segment_snap ss
                    JOIN dba_tablespaces t ON t.tablespace_name = ss.tablespace_name
                   WHERE ss.run_id = p_run_id
                     AND ss.phase = p_phase
                     AND ss.segment_type <> 'LOBINDEX'
                   ORDER BY ss.owner, ss.segment_name, ss.partition_name) LOOP
            l_type := CASE s.segment_type
                          WHEN 'LOBSEGMENT'   THEN 'LOB'
                          WHEN 'NESTED TABLE' THEN 'TABLE'
                          ELSE s.segment_type
                      END;
            l_used := NULL;
            l_raw  := NULL;
            BEGIN
                IF s.ssm = 'AUTO' AND s.securefile = 'YES' THEN
                    DBMS_SPACE.SPACE_USAGE(
                        segment_owner       => s.owner,
                        segment_name        => s.segment_name,
                        segment_type        => l_type,
                        segment_size_blocks => l_seg_b,
                        segment_size_bytes  => l_seg,
                        used_blocks         => l_used_b,
                        used_bytes          => l_sf_used,
                        expired_blocks      => l_exp_b,
                        expired_bytes       => l_exp,
                        unexpired_blocks    => l_unexp_b,
                        unexpired_bytes     => l_unexp,
                        partition_name      => s.partition_name);
                    l_method := 'SECUREFILE';
                    l_used   := l_sf_used;
                ELSIF s.ssm = 'AUTO' THEN
                    DBMS_SPACE.SPACE_USAGE(
                        segment_owner      => s.owner,
                        segment_name       => s.segment_name,
                        segment_type       => l_type,
                        unformatted_blocks => l_unf_b,
                        unformatted_bytes  => l_unf,
                        fs1_blocks         => l_fs1_b,
                        fs1_bytes          => l_fs1,
                        fs2_blocks         => l_fs2_b,
                        fs2_bytes          => l_fs2,
                        fs3_blocks         => l_fs3_b,
                        fs3_bytes          => l_fs3,
                        fs4_blocks         => l_fs4_b,
                        fs4_bytes          => l_fs4,
                        full_blocks        => l_full_b,
                        full_bytes         => l_full,
                        partition_name     => s.partition_name);
                    l_method := 'ASSM';
                    IF s.segment_type LIKE 'INDEX%' THEN
                        l_used := l_full;
                    ELSE
                        l_used := l_full + l_fs1 * 0.875 + l_fs2 * 0.625 + l_fs3 * 0.375 + l_fs4 * 0.125;
                    END IF;
                    l_raw := l_used;
                    IF s.securefile = 'NO' AND p_phase = c_baseline THEN
                        basicfile_carry(p_run_id, s.owner, s.segment_name, s.partition_name, l_used, l_method);
                    ELSIF s.securefile = 'NO' THEN
                        basicfile_estimate(p_run_id, s.owner, s.segment_name, s.partition_name, l_used, l_method);
                    END IF;
                ELSIF s.segment_type IN ('TABLE', 'NESTED TABLE') THEN
                    SELECT MAX(num_rows * avg_row_len)
                      INTO l_used
                      FROM dba_tables
                     WHERE owner = s.owner AND table_name = s.segment_name;
                    l_method := 'ESTIMATE';
                ELSE
                    l_method := 'UNSUPPORTED';
                END IF;

                INSERT INTO epf_space_usage (
                    run_id, phase, owner, segment_name, partition_name, segment_type,
                    allocated_bytes, used_bytes, free_bytes, method, raw_used_bytes
                ) VALUES (
                    p_run_id, p_phase, s.owner, s.segment_name, s.partition_name, s.segment_type,
                    s.bytes, ROUND(l_used), s.bytes - ROUND(l_used), l_method, ROUND(NVL(l_raw, l_used))
                );
            EXCEPTION
                WHEN OTHERS THEN
                    p_failed := p_failed + 1;
                    epf_log.event(epf_log.c_warn, 'SPACE_UNMEASURED',
                                  s.segment_type || ' not measured: ' || SQLERRM,
                                  p_object_owner => s.owner, p_object_name => s.segment_name,
                                  p_sub_name => s.partition_name, p_ora_code => ABS(SQLCODE),
                                  p_run_id => p_run_id);
            END;
        END LOOP;
    END measure;

    PROCEDURE capture(p_run_id IN NUMBER, p_phase IN VARCHAR2, p_failed OUT PLS_INTEGER) IS
        l_phase     VARCHAR2(20) := UPPER(p_phase);
        l_segments  NUMBER;
        l_allocated NUMBER;
        l_used      NUMBER;
        l_estimated NUMBER;
        l_lob_est   NUMBER;
        l_files     NUMBER;
        l_file_size NUMBER;
    BEGIN
        IF l_phase NOT IN (c_baseline, c_post_purge, c_post_compact, c_post_reclaim) THEN
            RAISE_APPLICATION_ERROR(-20140, 'Unknown space phase: ' || p_phase);
        END IF;
        p_failed := 0;

        DELETE FROM epf_space_usage WHERE run_id = p_run_id AND phase = l_phase;
        DELETE FROM epf_file_snap WHERE run_id = p_run_id AND phase = l_phase;
        DELETE FROM epf_segment_snap WHERE run_id = p_run_id AND phase = l_phase;
        capture_segments(p_run_id, l_phase);
        capture_files(p_run_id, l_phase);
        COMMIT;

        measure(p_run_id, l_phase, p_failed);
        COMMIT;

        SELECT COUNT(*), SUM(allocated_bytes), SUM(used_bytes),
               COUNT(CASE WHEN method IN ('ESTIMATE', 'UNSUPPORTED') THEN 1 END),
               COUNT(CASE WHEN method = 'BASICFILE_EST' THEN 1 END)
          INTO l_segments, l_allocated, l_used, l_estimated, l_lob_est
          FROM epf_space_usage
         WHERE run_id = p_run_id AND phase = l_phase;
        SELECT COUNT(*), SUM(bytes)
          INTO l_files, l_file_size
          FROM epf_file_snap
         WHERE run_id = p_run_id AND phase = l_phase;

        epf_log.event(
            p_severity   => CASE WHEN p_failed > 0 THEN epf_log.c_warn ELSE epf_log.c_ok END,
            p_event_code => 'SPACE_CAPTURED',
            p_message    => l_phase || ': ' || epf_util.fmt_int(l_segments) || ' segments, '
                            || epf_util.fmt_bytes(l_allocated) || ' allocated, '
                            || epf_util.fmt_bytes(l_used) || ' used inside; '
                            || l_files || ' datafiles, ' || epf_util.fmt_bytes(l_file_size)
                            || CASE WHEN l_estimated > 0 THEN '; ' || l_estimated || ' segments estimated or unsupported' END
                            || CASE WHEN l_lob_est > 0 AND l_phase = c_baseline
                                    THEN '; ' || l_lob_est || ' BASICFILE LOB segments carried over from an earlier estimate'
                                    WHEN l_lob_est > 0 THEN '; ' || l_lob_est || ' BASICFILE LOB segments scaled by rows' END
                            || CASE WHEN p_failed > 0 THEN '; ' || p_failed || ' segments not measured' END,
            p_bytes      => l_used,
            p_run_id     => p_run_id);
    END capture;

END epf_space;
/

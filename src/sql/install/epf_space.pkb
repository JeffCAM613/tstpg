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
                                      WHERE ss.run_id = p_run_id AND ss.phase = p_phase);
    END capture_files;

    PROCEDURE measure(p_run_id IN NUMBER, p_phase IN VARCHAR2, p_failed IN OUT PLS_INTEGER) IS
        l_type      VARCHAR2(30);
        l_method    VARCHAR2(20);
        l_used      NUMBER;
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
                    allocated_bytes, used_bytes, free_bytes, method
                ) VALUES (
                    p_run_id, p_phase, s.owner, s.segment_name, s.partition_name, s.segment_type,
                    s.bytes, ROUND(l_used), s.bytes - ROUND(l_used), l_method
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
        l_files     NUMBER;
        l_file_size NUMBER;
    BEGIN
        IF l_phase NOT IN (c_baseline, c_post_purge, c_post_reclaim) THEN
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
               COUNT(CASE WHEN method IN ('ESTIMATE', 'UNSUPPORTED') THEN 1 END)
          INTO l_segments, l_allocated, l_used, l_estimated
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
                            || CASE WHEN p_failed > 0 THEN '; ' || p_failed || ' segments not measured' END,
            p_bytes      => l_used,
            p_run_id     => p_run_id);
    END capture;

END epf_space;
/

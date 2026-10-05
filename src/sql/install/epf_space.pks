CREATE OR REPLACE PACKAGE epf_space AUTHID DEFINER AS
-- ============================================================================
-- EPF Data Purge - Space measurement
-- ============================================================================
-- Records, per run and phase, how much space the registry tables occupy and
-- how much of it is used inside their segments. A DELETE frees space inside
-- blocks without changing segment or file sizes; comparing used bytes
-- between BASELINE and POST_PURGE shows the space a purge made reusable.
--
-- Phases: BASELINE, POST_PURGE, POST_COMPACT, POST_RECLAIM.
-- ============================================================================

    c_baseline     CONSTANT VARCHAR2(20) := 'BASELINE';
    c_post_purge   CONSTANT VARCHAR2(20) := 'POST_PURGE';
    c_post_compact CONSTANT VARCHAR2(20) := 'POST_COMPACT';
    c_post_reclaim CONSTANT VARCHAR2(20) := 'POST_RECLAIM';

    -- Captures phase p_phase of run p_run_id, replacing an earlier capture of
    -- the same phase:
    --   EPF_SEGMENT_SNAP  every segment of the active registry tables: table,
    --                     indexes, LOB segments and LOB indexes, partitions
    --   EPF_FILE_SNAP     every datafile of the tablespaces holding them, and
    --                     of the undo tablespace (size, high-water mark, free
    --                     space, autoextend)
    --   EPF_SPACE_USAGE   space used inside each segment except LOB indexes:
    --                       ASSM        DBMS_SPACE.SPACE_USAGE, block fullness
    --                                   (table and BASICFILE LOB blocks count at
    --                                   the middle of their fullness band,
    --                                   blocks at least 75% free as empty;
    --                                   index blocks are full or free)
    --                       BASICFILE_EST  BASICFILE LOB segments after a
    --                                   purge: the chunks of deleted or cleared
    --                                   values stay "used" for DBMS_SPACE until
    --                                   new values reuse them, so the use is
    --                                   the BASELINE measurement times the share
    --                                   of the LOB data the purge left (rows not
    --                                   deleted; for clearing, the values not
    --                                   cleared); the measured value when lower.
    --                                   At a later BASELINE the segment starts
    --                                   from that estimate plus the growth of
    --                                   the measurement since, so the freed
    --                                   chunks are not counted twice
    --                       SECUREFILE  DBMS_SPACE.SPACE_USAGE, used bytes
    --                       ESTIMATE    manual segment space management tables:
    --                                   num_rows x avg_row_len from statistics
    --                       UNSUPPORTED other segments in manual segment space
    --                                   management (used bytes not recorded)
    --                     raw_used_bytes keeps what DBMS_SPACE reported, also
    --                     when used_bytes is an estimate
    -- p_failed returns the number of segments that could not be measured;
    -- each is reported as a SPACE_UNMEASURED warning. Emits SPACE_CAPTURED.
    -- ORA-20140 for an unknown phase.
    PROCEDURE capture(p_run_id IN NUMBER, p_phase IN VARCHAR2, p_failed OUT PLS_INTEGER);

END epf_space;
/

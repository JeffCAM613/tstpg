CREATE OR REPLACE PACKAGE epf_tuning AUTHID CURRENT_USER AS
-- ============================================================================
-- EPF Data Purge - Instance tuning for purges (opt-in)
-- ============================================================================
-- A purge writes about 1 KB of redo and about half as much undo per deleted
-- row. Two opt-in actions keep that from stalling the purge or growing the
-- disk footprint:
--   redo  enlarge_redo replaces undersized online redo log groups, so the
--         session does not wait on 'log file switch (checkpoint incomplete)'.
--         Permanent; reported.
--   undo  undo_apply lowers undo_retention (SCOPE=MEMORY) for the duration of
--         a purge, so committed undo is reused sooner instead of growing the
--         undo tablespace; the size and growth limit of the undo datafiles
--         are not changed. undo_restore puts back the recorded original
--         values. Every change is recorded in EPFPG.EPF_INSTANCE_CHANGE before
--         it is made, so the restore is exact even after an interrupted
--         session. While applied, long queries of other sessions can fail
--         with ORA-01555 (snapshot too old); the purge itself is not affected
--         (key snapshot). With autoextensible undo datafiles Oracle still
--         keeps undo for the longest running query, so the tablespace can
--         still grow when such queries run.
--
-- Invoker rights: call it as SYS (the DDL runs with the caller's rights).
-- Single-instance, non-CDB databases.
--
-- Error codes
--   ORA-20150  not SYS, multitenant or RAC database, or invalid arguments
--   ORA-20151  a new redo log group could not be added (groups added by the
--              call are dropped again)
--   ORA-20152  undo tablespace with RETENTION GUARANTEE (retention cannot be
--              lowered without failing transactions)
-- ============================================================================

    -- Ensures p_groups online redo log groups of at least p_size_mb:
    --   1. adds groups of p_size_mb (one member per member of the existing
    --      groups, in the same directory, named redo<group>[a-z].log;
    --      Oracle-managed names when db_create_online_log_dest_1 or
    --      db_create_file_dest is set; the disk group on ASM),
    --   2. switches logs and checkpoints until every smaller group is
    --      INACTIVE (and archived in ARCHIVELOG mode), then drops it; a group
    --      that stays in use is kept and reported,
    --   3. deletes the files of the dropped groups through a temporary
    --      directory object (file system only; a file that cannot be deleted
    --      is reported with its path).
    -- Prints the groups before and after and every action.
    PROCEDURE enlarge_redo(p_size_mb IN NUMBER DEFAULT 1024, p_groups IN NUMBER DEFAULT 4);

    -- Records, then sets undo_retention to setting undo_retention_s (SCOPE=
    -- MEMORY, so an instance restart also restores it) when it is lower than
    -- the current value. Does nothing when an unrestored undo change exists.
    -- ORA-20152 with RETENTION GUARANTEE.
    PROCEDURE undo_apply;

    -- Puts back every recorded, unrestored undo change (newest first):
    -- undo_retention, and the growth limit of an undo datafile when one is
    -- recorded. Marks each change restored. Does nothing when there is none.
    PROCEDURE undo_restore;

    -- Prints the undo tablespace, its files, undo_retention and the recorded
    -- changes that are still active.
    PROCEDURE undo_status;

END epf_tuning;
/

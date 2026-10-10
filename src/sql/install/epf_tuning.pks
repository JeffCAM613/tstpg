CREATE OR REPLACE PACKAGE epf_tuning AUTHID CURRENT_USER AS
-- ============================================================================
-- EPF Data Purge - Instance tuning for purges
-- ============================================================================
-- A purge writes about 1 KB of redo and about half as much undo per deleted
-- row. Two actions keep that from stalling the purge or growing the disk
-- footprint:
--   redo  (opt-in) enlarge_redo replaces undersized online redo log groups
--         for a purge, so the session does not wait on 'log file switch
--         (checkpoint incomplete)', and records them; redo_restore puts the
--         original groups back after the purge. set_redo sets the online
--         logs to a size the DBA chooses, kept after the call.
--   undo  (every purge) undo_apply lowers undo_retention (SCOPE=MEMORY) and limits the
--         growth of the undo datafiles for the duration of a purge, so
--         committed undo is reused instead of growing the undo tablespace.
--         With autoextensible undo datafiles Oracle keeps undo for the longest
--         running statement, and a purge is one long call, so a lower
--         undo_retention alone does not stop the growth (27.6 GB on a PAYMENTS
--         purge of 87 M rows); the growth limit does. The limit (undo_cap) is
--         the largest of the tablespace's current size, setting undo_cap_mb
--         and 4 x the undo of one batch; a batch commits, so only the running
--         batch needs undo that cannot be reused. undo_restore puts back the
--         recorded original values, then gives back what the undo datafiles
--         and the temporary tablespaces grew (size_giveback). Every change
--         is recorded in EPFPG.EPF_INSTANCE_CHANGE before it is made, so the
--         restore is exact even after an interrupted session. While applied,
--         long queries of other sessions can fail with ORA-01555 (snapshot
--         too old); the purge itself is not affected (key snapshot).
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
    -- Prints the groups before and after and every action. With p_run_id
    -- (a purge run whose preflight checked REDO_LOGS): nothing changes when
    -- one batch of that run fits in the smallest online log, and the groups
    -- are made large enough for one batch when it needs more than p_size_mb.
    -- Every group dropped (REDO_GROUP: number, thread, members, size) and
    -- added (REDO_ADDED) is recorded in EPFPG.EPF_INSTANCE_CHANGE first.
    PROCEDURE enlarge_redo(p_size_mb IN NUMBER DEFAULT 1024, p_groups IN NUMBER DEFAULT 4,
                           p_run_id IN NUMBER DEFAULT NULL);

    -- Puts back the online redo log groups enlarge_redo replaced:
    --   1. adds each recorded original group again, with its number, thread
    --      and size, its members under the same names on a file system
    --      (REUSE when a file is still there); Oracle names an Oracle-managed
    --      member again, and places an ASM member in the same disk group,
    --   2. switches logs and checkpoints until each group added for the purge
    --      is INACTIVE (and archived in ARCHIVELOG mode), drops it and deletes
    --      its files; a group that stays in use is kept, reported and left for
    --      the next call.
    -- Does nothing when nothing is recorded.
    PROCEDURE redo_restore;

    -- Sets the online redo logs to p_groups groups of p_size_mb, the DBA's
    -- choice, kept after the call (nothing is recorded to put back), such as
    -- the size they had before a tool replaced them:
    --   1. keeps up to p_groups groups that already have that size; adds the
    --      others under the lowest free group numbers (members as
    --      enlarge_redo names them, so group 1 is redo01.log; REUSE when such
    --      a file is still there),
    --   2. switches logs and checkpoints until each other group is INACTIVE
    --      (and archived in ARCHIVELOG mode), drops it and deletes its files;
    --      a group that stays in use is kept and reported.
    -- Nothing changes when the logs already are so. Refused while groups a
    -- purge replaced are not put back (redo_restore first).
    PROCEDURE set_redo(p_size_mb IN NUMBER, p_groups IN NUMBER);

    -- Growth limit of the undo tablespace during a purge in bytes: the largest
    -- of its current size, setting undo_cap_mb and 4 x p_batch_undo (the undo
    -- of one batch; NULL when unknown).
    FUNCTION undo_cap(p_batch_undo IN NUMBER) RETURN NUMBER;

    -- Records (the sizes of the undo datafiles and temporary tablespaces too,
    -- size_record), then
    --   sets undo_retention to setting undo_retention_s (SCOPE=MEMORY, so an
    --   instance restart also restores it) when it is lower than the current
    --   value, and
    --   limits the growth of the autoextensible undo datafiles to undo_cap
    --   (the room under the cap shared evenly between the files; a file is
    --   never limited below its current size).
    -- p_run_id / p_preflight_run_id: the purge run and the preflight run
    -- whose estimates size one batch (the batch size of the purge run, the
    -- largest undo per root of the preflight run); without them the limit is
    -- the larger of the current size and undo_cap_mb. Does nothing when an
    -- unrestored undo change exists. ORA-20152 with RETENTION GUARANTEE.
    PROCEDURE undo_apply(p_run_id IN NUMBER DEFAULT NULL, p_preflight_run_id IN NUMBER DEFAULT NULL);

    -- Puts back every recorded, unrestored undo change (newest first):
    -- undo_retention, and the growth limit of an undo datafile when one is
    -- recorded. Marks each change restored. Then gives back what the undo
    -- datafiles and temporary tablespaces grew (size_giveback).
    PROCEDURE undo_restore;

    -- Prints the undo tablespace, its files, undo_retention and the recorded
    -- changes that are still active.
    PROCEDURE undo_status;

    -- Records the size of each undo datafile (SIZE_UNDO, with p_undo) and of
    -- each temporary tablespace (SIZE_TEMP) before a purge or a reclaim
    -- (p_run_id); an open record of the same file or tablespace is kept, as
    -- it holds the size before.
    PROCEDURE size_record(p_run_id IN NUMBER, p_undo IN BOOLEAN);

    -- Gives back what the recorded undo datafiles and temporary tablespaces
    -- grew: an undo datafile is resized to its recorded size, or as near as
    -- the highest extent Oracle still holds there allows (Oracle releases
    -- undo extents on its own schedule, so right after a purge often little
    -- can be given back); a temporary tablespace is shrunk back to its
    -- recorded size (SHRINK SPACE KEEP). A record is closed once its file or
    -- tablespace is back at its size before; otherwise it stays open for the
    -- next call. Each change is reported.
    PROCEDURE size_giveback;

END epf_tuning;
/

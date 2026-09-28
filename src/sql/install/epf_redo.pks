CREATE OR REPLACE PACKAGE epf_redo AUTHID CURRENT_USER AS
-- ============================================================================
-- EPF Data Purge - Online redo log sizing (opt-in)
-- ============================================================================
-- Replaces undersized online redo log groups with larger ones. A purge
-- writes about 1 KB of redo per deleted row (close to 1 GB per batch on the
-- largest trees); with small online logs the session waits on 'log file
-- switch (checkpoint incomplete)' at every switch. The change is permanent
-- and reported; it is not reverted at the end of a run.
--
-- Invoker rights: call it as SYS (the DDL runs with the caller's rights).
-- Single-instance, non-CDB databases: in a multitenant database the online
-- redo logs belong to the CDB and are sized by the DBA in CDB$ROOT.
--
-- Error codes
--   ORA-20150  not SYS, multitenant or RAC database, or invalid arguments
--   ORA-20151  a new group could not be added (groups added by this call are
--              dropped again)
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
    -- Prints the groups before and after and every action; emits REDO_*
    -- events when the session is bound to a run.
    PROCEDURE enlarge(p_size_mb IN NUMBER DEFAULT 1024, p_groups IN NUMBER DEFAULT 4);

END epf_redo;
/

CREATE OR REPLACE PACKAGE epf_registry AUTHID DEFINER AS
-- ============================================================================
-- EPF Data Purge - Registry validation
-- ============================================================================
-- Checks the registry (EPF_TABLE, EPF_LINK) against the live database and
-- reports every finding as an event of the bound run.
--
-- Checks
--   REG_TABLE_MISSING        registry table not present (WARN, skipped by purge)
--   REG_COLUMN_MISSING       key, date, match or source column missing (ERROR)
--   REG_KEY_TYPE             key column not of type NUMBER (ERROR)
--   REG_KEY_UNIQUE           key column without a single-column unique index (ERROR)
--   REG_DATE_TYPE            date column not of type DATE or TIMESTAMP (ERROR)
--   REG_ROOT_INVALID         root without date column or not its own root (ERROR)
--   REG_DEPENDENT_UNLINKED   dependent table without any link (ERROR)
--   REG_SOURCE_KEY           link source without key column (ERROR)
--   REG_REVERSE_SOURCE       table reached through a reverse link (source column
--                            other than the source key) used as a link source (ERROR)
--   REG_LINK_TREE            link between two different root trees (ERROR)
--   REG_LINK_ORDER           dependent not processed before its source (ERROR)
--   REG_GRANT_MISSING        SELECT/DELETE/INDEX not granted to the tool schema (WARN)
--   REG_FK_ORDER             enabled FK whose child is processed after its parent (ERROR)
--   REG_FK_CROSS_TREE        enabled FK between two different root trees (ERROR)
--   REG_FK_SELF              self-referencing FK on a registry table (WARN)
--   REG_ROOT_KEY_FK          enabled FK into a root without key column (ERROR:
--                            such roots are purged by ROWID and cannot be held back)
--   REG_FK_EXTERNAL_CASCADE  FK from a non-registry table (any schema) with
--                            ON DELETE CASCADE / SET NULL into a registry table (ERROR)
--   REG_FK_EXTERNAL          FK from a non-registry table (any schema) into a
--                            registry table (WARN: roots whose rows it references
--                            are held back by the purge)
--   REG_FK_DISABLED          disabled FK into a registry table (INFO)
--   REG_SUMMARY              counts (OK or WARN)
-- ============================================================================

    PROCEDURE validate(p_errors OUT PLS_INTEGER, p_warnings OUT PLS_INTEGER);

END epf_registry;
/

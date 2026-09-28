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
--   REG_ROOT_INVALID         root without date column or not its own root (ERROR)
--   REG_DEPENDENT_UNLINKED   dependent table without any link (ERROR)
--   REG_LINK_TREE            link between two different root trees (ERROR)
--   REG_LINK_ORDER           dependent not processed before its source (ERROR)
--   REG_GRANT_MISSING        SELECT/DELETE not granted to the tool schema (WARN)
--   REG_FK_ORDER             enabled FK whose child is processed after its parent (ERROR)
--   REG_FK_CROSS_TREE        enabled FK between two different root trees (ERROR)
--   REG_FK_SELF              self-referencing FK on a registry table (WARN)
--   REG_FK_EXTERNAL_CASCADE  FK from a non-registry table (any schema) with
--                            ON DELETE CASCADE / SET NULL into a registry table (ERROR)
--   REG_FK_EXTERNAL          FK from a non-registry table (any schema) into a
--                            registry table (WARN: purge fails if it references
--                            an eligible row)
--   REG_FK_DISABLED          disabled FK into a registry table (INFO)
--   REG_SUMMARY              counts (OK or WARN)
-- ============================================================================

    PROCEDURE validate(p_errors OUT PLS_INTEGER, p_warnings OUT PLS_INTEGER);

END epf_registry;
/

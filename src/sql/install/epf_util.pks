CREATE OR REPLACE PACKAGE epf_util AUTHID DEFINER AS
-- ============================================================================
-- EPF Data Purge - Shared helpers
-- ============================================================================
-- Formatting, time arithmetic, settings access, dictionary lookups and
-- database environment facts used by every other package.
-- ============================================================================

    -- Current server time as TIMESTAMP (time zone of the database server).
    FUNCTION now_ts RETURN TIMESTAMP;

    -- Seconds between two timestamps (NULL if either is NULL).
    FUNCTION elapsed_s(p_from IN TIMESTAMP, p_to IN TIMESTAMP DEFAULT NULL) RETURN NUMBER;

    -- Display label of a run: R-000124.
    FUNCTION run_label(p_run_id IN NUMBER) RETURN VARCHAR2;

    -- 1234567 -> '1,234,567'.
    FUNCTION fmt_int(p_value IN NUMBER) RETURN VARCHAR2;

    -- Bytes -> '812 B', '4.2 KB', '15.0 MB', '118.0 GB', '1.2 TB'.
    FUNCTION fmt_bytes(p_bytes IN NUMBER) RETURN VARCHAR2;

    -- Seconds -> 'HH:MM:SS' (hours may exceed 99).
    FUNCTION fmt_duration(p_seconds IN NUMBER) RETURN VARCHAR2;

    -- Value of a setting from EPF_SETTING. Raises ORA-20100 for an unknown
    -- name and ORA-20101 when setting_num finds a non-numeric value.
    FUNCTION setting(p_name IN VARCHAR2) RETURN VARCHAR2;
    FUNCTION setting_num(p_name IN VARCHAR2) RETURN NUMBER;

    -- Quoted, validated "OWNER"."NAME" for dynamic SQL.
    FUNCTION qname(p_owner IN VARCHAR2, p_name IN VARCHAR2) RETURN VARCHAR2;

    -- Dictionary lookups (all schemas).
    FUNCTION table_exists(p_owner IN VARCHAR2, p_table IN VARCHAR2) RETURN BOOLEAN;
    FUNCTION column_exists(p_owner IN VARCHAR2, p_table IN VARCHAR2, p_column IN VARCHAR2) RETURN BOOLEAN;

    -- Comma-separated list -> trimmed, upper-case items; empty items dropped.
    FUNCTION split_list(p_list IN VARCHAR2) RETURN SYS.ODCIVARCHAR2LIST;

    -- Database environment.
    FUNCTION db_version RETURN VARCHAR2;
    FUNCTION is_enterprise RETURN BOOLEAN;
    FUNCTION container_name RETURN VARCHAR2;
    FUNCTION is_cdb_root RETURN BOOLEAN;

END epf_util;
/

# Change history

Newest first. Each entry: date, what changed, why, and how to test when relevant.

## 2026-09-28 - Phase 1: tool tablespace created by the installer

What changed
- `install.sql` takes one argument (the EPFPG password). It creates tablespace `EPFPG_DATA` when missing: one datafile (128 MB, autoextend 128 MB, maxsize unlimited) in the directory of the first datafile of the tablespace holding most of the OPPAYMENTS segments. Fallbacks: OP, OPREPORTS, their default tablespaces, the database default tablespace, SYSTEM. ASM: same disk group, Oracle-named file. File name `epfpg_data01.dbf` in the letter case of the reference file; a name already on disk is skipped (`02`, `03`, ...), an existing file is never reused. On re-run an existing `EPFPG_DATA` is reused after checking it is online, permanent and holds no segments of other owners.
- The installer prints the reference tablespace, the reason it was chosen and the reference datafile.
- `uninstall.sql` drops `EPFPG_DATA` with its datafiles after the user, only when no segment, segmentless object, partition default, recycle-bin object, user default or database default references it; otherwise it keeps it with a WARN.
- `environment.sql`: section 16 lists the datafiles of `EPFPG_DATA` and the owners of its segments.
- Plan: sections 3.4, 5, 7, 7.7 and 15 state that the application tablespace is detected from where OPPAYMENTS (then OP, OPREPORTS) segments live and is never assumed to be named DATA.

Why
- The tool's objects get a tablespace of their own that can never be a reclaim target, without asking the operator to choose one.
- Installations where the application data is not in a tablespace named DATA.

How to test (replaces step 1 of the phase 1 test)
1. `sqlplus -L "sys@<pdb_service> AS SYSDBA" @src/sql/install/install.sql <epfpg_password>`. Check the `reference tablespace` / `reference datafile` lines and the `created tablespace EPFPG_DATA, datafile ...` line. Run it a second time: it must print `present tablespace EPFPG_DATA` and succeed.
2. Steps 2-4 of the phase 1 test unchanged; `epf_environment.txt` now includes section 16.
3. Optional: `@src/sql/install/uninstall.sql` as SYS must end with `EPFPG_DATA and its datafiles removed.`; then install again.

## 2026-09-28 - Phase 1 (foundation)

Repository
- New implementation in `src/`; the previous implementation moved unchanged to `legacy/` (`legacy/bin`, `legacy/sql`, `legacy/config`) for comparison.
- `.gitattributes` (line endings per file type), `.gitignore` (run logs, local config, survey output).

Database objects (`src/sql/install/`)
- `install.sql` (SYS): checks (SYS, not CDB$ROOT, 12.2+, tool tablespace not used by OP/OPPAYMENTS/OPREPORTS), creates or updates user EPFPG, then tables, registry, grants, packages; fails if any EPFPG object is invalid.
- `uninstall.sql` (SYS): refuses while a run is active, while accounts locked by a reclaim are not restored, or while temporary purge indexes exist; then drops EPFPG.
- `tables.sql`: all tables of plan section 5 (idempotent).
- `registry_data.sql`: 3 modules, 27 tables, 23 links (today's scope and processing order), 16 settings. Settings keep operator values on upgrade.
- `grants.sql`: system privileges, direct SELECT on dictionary views, DBMS_LOCK, INHERIT PRIVILEGES ON USER SYS (warning only if refused), SELECT/DELETE/UPDATE on registry tables present.
- Packages: `epf_util` (formatting, settings, dictionary helpers), `epf_log` (events, steps, session tagging), `epf_control` (run lifecycle with an exclusive run lock, stop requests, parameter normalisation), `epf_registry` (registry validation, including FKs from any schema into purge tables).
- The run package is named `epf_control` because a package cannot share the name of table `EPF_RUN` in the same schema.

Entry scripts (`src/sql/run/`)
- `start_run.sql`: validates parameters, creates a run, prints `EPF_RUN_ID=<n>`.
- `preflight.sql`: registry validation (grows in phase 2). `NEW` runs it standalone and prints the events.

Verification (`src/tests/verify/`)
- `environment.sql`: read-only survey of the target database; writes `epf_environment.txt`.

How to test
1. `sqlplus -L "sys@<pdb_service> AS SYSDBA" @src/sql/install/install.sql <epfpg_password> <tool_tablespace>`
   (tool tablespace: e.g. USERS, as long as OP/OPPAYMENTS/OPREPORTS have no segments there). Run it a second time: it must succeed again (idempotent).
2. `sqlplus -L -S "epfpg/<password>@<pdb_service>" @src/sql/run/preflight.sql NEW`
3. `sqlplus -L "sys@<pdb_service> AS SYSDBA" @src/tests/verify/environment.sql`
4. Return: the console output of 1 (both runs) and 2, and the file `epf_environment.txt`.
5. Optional: `@src/sql/install/uninstall.sql` as SYS, then install again.

## 2026-09-28 - Plan draft 3

- Plan moved from `plan/PLAN.md` to `.local/PLAN.md`; this change log added.
- Layout: `src/` (new), `legacy/` (previous implementation, unchanged).
- Reclaim: REFERENCE_CHECK step before DROP_OLD; REVERT path when the check fails or Oracle refuses the drop (moves everything back, drops the empty clone).
- LONG conversion confirmation shows owner, column, source tablespace and target LOB tablespace per item.
- Phase 0 split: environment survey now; behavior spikes V1-V10 before phase 5.

## 2026-09-28 - Plan draft 2

- Decisions D1-D14 applied: EPFPG tool schema; indexes UNUSABLE + REBUILD; tablespace swap with all owners; bat + PowerShell 5.1; temporary purge indexes only; modes FULL / CLOB / LOGS / CLOB_N_LOGS; purge effect always measured, compaction opt-in; childless `file_dispatching` rows purged; always LOGGING; accounts locked and sessions disconnected at reclaim start after startup confirmation; clean CLI; SYS asked at startup when reclaim is selected; LONG columns converted with per-item approval.

## 2026-09-28 - Plan draft 1

- Assessment of the previous implementation (findings F/R/L/A/S/P) and target design.

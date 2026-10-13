# EPF Data Purge: scenarios

The tool as its user meets it, screen by screen: what is typed and what the tool answers, in the everyday cases and when something is not as it should be. For a discussion or a demonstration without a database: nothing here needs one.

This document is also available as a web page: [SCENARIOS.html](SCENARIOS.html).

## Contents

- [How to read the screens](#how-to-read-the-screens)
- [The scenarios at a glance](#the-scenarios-at-a-glance)
- [Part 1: the everyday path](#part-1-the-everyday-path)
- [Part 2: when something is not as it should be](#part-2-when-something-is-not-as-it-should-be)
- [Part 3: without questions](#part-3-without-questions)
- [Part 4: other things worth showing](#part-4-other-things-worth-showing)

## How to read the screens

- **The screens are the tool's own**, version 0.9.7: each scenario was played through the real program against a stand-in for the database. Nothing was run on a database for this document.
- **The figures are scripted**, from test runs on copies of real data: one database for the purge (DATA 41.7 GB), another for the reclaim (DATA 50.1 GB). The names are examples: the database is EPFDB.
- **What the user types** follows the colon of a line that starts with ` > `. `<Enter>` means Enter alone, which takes the default shown in brackets. Passwords are never shown on the real screen: here they are `********`.
- **Lines in brackets**, such as `[... as in scenario 1 ...]`, mark where a screen is shortened because an earlier scenario shows that part.
- **While rows are deleted** the real screen has one line per module, rewritten in place. Here that line is shown half way and at its end.
- **The times** on the right of a step and in the last sentence of a run are those of the replay, which answers in seconds. The times inside the figures (per module, per table) are from the test runs: that purge took 10 minutes in all, that reclaim 12 minutes.
- **Unless a scenario says otherwise**, the database is given on the command line and the passwords are in the environment, so the screens start after those questions. Scenario 2 shows them.

The commands and their options are in the [user guide](../README.md#parameters).

## The scenarios at a glance

| | Scenario | Command |
|---|---|---|
| [1](#1-the-menu-and-a-dry-run-of-a-purge) | The menu, and a dry run of a purge | `epf_purge.bat --tns EPFDB` |
| [2](#2-the-first-time-on-a-database-the-tool-installs-itself) | The first time on a database: the tool installs itself | `epf_purge.bat purge --dry-run --retention 365 --tns EPFDB` |
| [3](#3-by-command-with-no-option-every-question-of-a-purge) | By command, with no option: every question of a purge | `epf_purge.bat purge` |
| [4](#4-the-purge) | The purge | `epf_purge.bat purge --retention 365 --tns EPFDB` |
| [5](#5-a-dry-run-of-a-reclaim) | A dry run of a reclaim | `epf_purge.bat reclaim --dry-run --tns EPFDB` |
| [6](#6-the-reclaim) | The reclaim | `epf_purge.bat reclaim --tns EPFDB` |
| [7](#7-no-recent-backup-and-the-user-stops) | No recent backup, and the user stops | `epf_purge.bat purge --retention 365 --tns EPFDB` |
| [8](#8-no-recent-backup-and-the-user-goes-on) | No recent backup, and the user goes on | `epf_purge.bat purge --retention 365 --tns EPFDB` |
| [9](#9-not-enough-temporary-space) | Not enough temporary space | `epf_purge.bat purge --retention 365 --tns EPFDB` |
| [10](#10-the-user-does-not-type-yes) | The user does not type yes | `epf_purge.bat purge --retention 365 --tns EPFDB` |
| [11](#11-nothing-is-old-enough-any-more) | Nothing is old enough any more | `epf_purge.bat purge --retention 365 --tns EPFDB` |
| [12](#12-a-purge-is-stopped-while-it-deletes) | A purge is stopped while it deletes | `epf_purge.bat purge --non-interactive --retention 365 --tns EPFDB`, then `epf_purge.bat stop --tns EPFDB` |
| [13](#13-before-a-reclaim-dropped-objects-in-the-recycle-bin) | Before a reclaim: dropped objects in the recycle bin | `epf_purge.bat reclaim --tns EPFDB` |
| [14](#14-a-dry-run-in-one-command) | A dry run in one command | `epf_purge.bat purge --non-interactive --dry-run --retention 365 --tns EPFDB` |
| [15](#15-a-purge-in-one-command) | A purge in one command | `epf_purge.bat purge --non-interactive --retention 365 --tns EPFDB` |
| [16](#16-a-purge-that-does-not-start) | A purge that does not start | `epf_purge.bat purge --non-interactive --retention 365 --tns EPFDB` |
| [17](#17-a-purge-without-the-days-to-keep) | A purge without the days to keep | `epf_purge.bat purge --non-interactive --tns EPFDB` |
| [18](#18-a-reclaim-in-one-command) | A reclaim in one command | `epf_purge.bat reclaim --non-interactive --tns EPFDB` |
| [19](#19-after-an-update-of-the-tools-files) | After an update of the tool's files | `epf_purge.bat purge --dry-run --retention 365 --tns EPFDB` |
| [20](#20-not-everything-a-mode-and-some-modules) | Not everything: a mode and some modules | `epf_purge.bat purge --dry-run --retention 365 --mode CLOB_N_LOGS --tns EPFDB` |
| [21](#21-a-purge-that-empties-large-values) | A purge that empties large values | `epf_purge.bat purge --non-interactive --retention 365 --mode CLOB --depth BANK_STATEMENTS --tns EPFDB` |
| [22](#22-the-reclaim-typed-as-an-option-of-purge) | The reclaim typed as an option of purge | `epf_purge.bat purge --reclaim --dry-run --tns EPFDB` |
| [23](#23-removing-the-tool-from-the-database) | Removing the tool from the database | `epf_purge.bat uninstall --tns EPFDB` |

## Part 1: the everyday path

A dry run, the purge, then the reclaim, each with its questions.

### 1. The menu, and a dry run of a purge

Somebody runs the tool for the first time on a database where it is already installed, and wants to see what a purge would do. The command alone opens the menu.

```bat
src\bin\epf_purge.bat --tns EPFDB
```

**Typed:** `1` at the menu; `365` for the days to keep; Enter at the mode and at the depth (everything old, in every module); `Y` to go on although an optional requirement is not met; `N` to keep the tool in the database.

```text
 EPF Data Purge 0.9.7                                                       menu
 -------------------------------------------------------------------------------

 What do you want to do?
   1  Dry run of a purge     shows what a purge would delete; changes nothing
   2  Purge                  deletes old rows; a reclaim is needed afterwards to
                             free disk space
   3  Dry run of a reclaim   shows how much disk space a reclaim would give back;
                             changes nothing
   4  Reclaim                compacts the datafiles to free disk space; the
                             database must not be in use meanwhile
   5  Report of an earlier run
   6  Status: is anything left pending?
   7  Uninstall: remove the tool's objects from the database
   Q  Quit
 > Choice [1]: 1

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7

 -- Days of data to keep -------------------------------------------------------
   Rows older than that are purged. A number of days such as 365, or the day itself as YYYY-MM-DD:
   rows dated before it are purged.
 > Days of data to keep [30]: 365

 -- Mode: what is done to the rows dated before 13 October 2025 ----------------
   Mode             Tables   Size now   Frees (about)   What it does
   FULL                 25    22.0 GB          6.9 GB   deletes the rows, in the modules chosen next
   CLOB                  6    13.8 GB          1.6 GB   keeps the rows, empties their large values
   LOGS                  3     1.2 GB         24.6 MB   same as FULL with the module LOGS alone
   CLOB_N_LOGS           8    14.6 GB          1.6 GB   CLOB, and deletes the rows of module LOGS

   The tables, largest first. In brackets: the large values of a table (LOB columns: documents,
   messages), the part that CLOB empties.
   PAYMENTS         20 tables, 8.9 GB
       PAYMENT_ADDITIONAL_INFO               2.9 GB
       PAYMENT                               1.7 GB
       TRANSMISSION_EXECUTION_AUDIT          1.4 GB   [1.2 GB]
       PAYMENT_AUDIT                         1.2 GB
       FILE_INTEGRATION                    600.0 MB   [500.0 MB]
       BULK_PAYMENT                        400.0 MB
       IMPORT_AUDIT_MESSAGES               300.0 MB   [200.0 MB]
       13 smaller, 460.0 MB in all: INVOICE_ADDITIONAL_INFO, NOTIFICATION_EXECUTION,
         BULKPAYMENT_EXCEPTION, WORKFLOW_EXECUTION, APPROBATION_EXECUTION, OIDC_REQUEST_TOKEN,
         MANDATORY_SIGNERS, TRANSMISSION_EXCEPTION, BULK_SIGNATURE, TRANSMISSION_EXECUTION,
         BULK_PAYMENT_ADDITIONAL_INFO, INVOICE, IMPORT_AUDIT
   LOGS             3 tables, 1.2 GB
       AUDIT_TRAIL                         700.0 MB
       AUDIT_ARCHIVE                       500.0 MB   [450.0 MB]
       OP.SPEC_TRT_LOG                      60.0 MB
   BANK_STATEMENTS  2 tables, 11.9 GB
       DIRECTORY_DISPATCHING                 8.4 GB   [8.2 GB]
       FILE_DISPATCHING                      3.5 GB   [3.3 GB]

   Not in this database, and skipped: APPROBATION_EXECUTION_OPT, WORKFLOW_EXECUTION_OPT.
   Size now: the tables today, with their indexes and large values (the large values alone where
   they are emptied). Frees: that size by the share of top-level records dated before 13 October 2025; a
   rough estimate, which a dry run replaces by a count.
   17.6 GB of the application's 39.6 GB is in tables this tool does not purge.
 > Mode (FULL, CLOB, LOGS, CLOB_N_LOGS) [FULL]: <Enter>

 -- Depth: in which modules (mode FULL) ----------------------------------------
   Module           Tables   Size now   Frees (about)   What it holds
   ALL                  25    22.0 GB          6.9 GB   every module
   PAYMENTS             20     8.9 GB          6.5 GB   Bulk payments with all dependent records,
                                                        and file integrations
   LOGS                  3     1.2 GB         24.6 MB   Functional audit trail and technical logs
   BANK_STATEMENTS       2    11.9 GB        389.9 MB   Bank statement dispatching

   Several modules: their names separated by commas, such as PAYMENTS,LOGS.
 > Depth (ALL, or modules such as PAYMENTS,LOGS,BANK_STATEMENTS) [ALL]: <Enter>

 Dry run of a purge of everything dated before 13 October 2025. Nothing is changed.
 Run R-000040   C:\epf\logs\2026-10-13_185956_R-000040
 1 of 2  Checking the database (read-only)                         done    0:11
         note   2 of the tables this tool can purge are not in this database and are skipped:
                OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT

   Requirement                       Needed     Now
   Room for the archived logs        required   ok
       NOARCHIVELOG: redo is not archived (estimate 12.9 GB of redo)
   Undo space                        required   ok
       UNDOTBS1 610.0 MB, can grow to 32.0 GB; one batch needs about 89.8 MB; undo tuning keeps undo
       60 s and caps UNDOTBS1 at about 4.0 GB (without it undo_retention would keep about 6.5 GB)
   Temporary space                   required   ok
       about 7,200,000 keys, 1.1 GB; TEMP free 3.0 GB, can grow by 29.0 GB
   Room for the temporary indexes    optional   ok
       12 temporary indexes, about 1.4 GB; EPFPG_DATA free 100.0 MB, can grow by 31.9 GB
   Online redo logs                  optional   NOT MET
       smallest online log 150.0 MB; one batch writes about 179.6 MB
       What happens: Small online logs fill every few seconds and the purge waits on each switch.
       Slower, not a failure.
       What to do:   the tool can enlarge them for the purge: 4 logs of 1 GB replace the present
       ones while it runs (up to 4 GB more disk in the directory of the online logs), and the
       present ones are put back under the same names at its end. Needs SYS. A purge asks;
       --redo-logs says yes beforehand.
   Backup                            required   not needed
       dry run: nothing is deleted

   Only optional requirements are not met: the purge can run as things are.

 -- Requirements not met -------------------------------------------------------
   A purge asks whether to enlarge the online redo logs for its time (--redo-logs says yes
   beforehand).
 > Go on with the dry run (Y/N) [Y]: Y
   Batch size: 120 top-level rows per transaction, as the checks recommend.
 Run R-000041   C:\epf\logs\2026-10-13_190008_R-000041
 2 of 2  Counting what the purge would delete
         PAYMENTS                    18,218,547 rows      about 6.6 GB
         LOGS                           125,517 rows     about 21.0 MB
         BANK_STATEMENTS                935,130 rows    about 380.0 MB

 ===============================================================================
  A purge would delete 19,279,194 rows, about 7.0 GB, dated before 13 October 2025.
  It would take about 8 minutes of deleting, and would complete as things are.
 ===============================================================================
   What                  Rows to delete   Space freed (about)    Deleting
   PAYMENTS                  18,218,547                6.6 GB        7:40
   LOGS                         125,517               21.0 MB        0:04
   BANK_STATEMENTS              935,130              380.0 MB        0:33

   A purge compacts the tables it purged, so the database can use that space again. The disk gets it
   back with a reclaim: the datafiles keep their size until then.

   Disk used while the purge runs (given back at its end)
   What                Uses at most  Extra disk needed  Where
   Undo                      4.0 GB             3.4 GB  /u01/oradata/EPFDB/undotbs01.dbf
   Temporary space           1.1 GB                0 B  /u01/oradata/EPFDB/temp01.dbf
   Temporary indexes         1.4 GB             1.3 GB  /u01/oradata/EPFDB/epfpg_data01.dbf
   Online redo logs        450.0 MB                0 B  3 logs reused, the first:
                                                        /u01/oradata/EPFDB/redo01.log; a
                                                        purge can enlarge them for its time (4 x 1
                                                        GB, up to 4.0 GB more)
   In all                                       4.7 GB  of free disk space needed where these files
                                                        are
   Tablespace purged        41.7 GB               none  DATA: /u01/oradata/EPFDB/data.dbf;
                                                        its tables to purge take 22.0 GB
   Extra disk needed: what the file has to grow by, beyond its size today; 0 B when it has the room
   already.

   Other retentions, as examples of what else could be kept
     Days kept           Purges rows dated     Rows deleted         Space freed
     730 days kept       before 2024-10-13       15,604,000        about 5.7 GB
     365 days kept       before 2025-10-13       19,279,194        about 7.0 GB   (this dry run)
     270 days kept       before 2026-01-16       24,112,000        about 8.8 GB
     180 days kept       before 2026-04-16       41,870,000       about 15.2 GB
   Any number of days can be tried the same way: src\bin\epf_purge.bat purge --dry-run --retention
   DAYS.

  Good to know (1)
   - Undo kept within 4.0 GB by undo tuning; about a quarter of the time waiting for the 150.0 MB
     online logs

  Nothing was changed.
  Next     src\bin\epf_purge.bat purge --retention 365     the purge itself
  Report   C:\epf\logs\2026-10-13_190008_R-000041\report.html
  Files    C:\epf\logs\2026-10-13_190008_R-000041   (report.txt, console.log)

 -- The tool in the database ---------------------------------------------------
   The tool's own objects stay in the database for the next run: the account EPFPG and its
   tablespace EPFPG_DATA, with the history of the runs and what they measured. Removing them frees
   that space; the next run installs them again, and its estimates start from statistics. The
   reports on this machine stay.
 > Remove the tool from the database now (Y/N) [N]: N
   Kept.
```

What to notice:

- The run gets ready by itself (sqlplus, the database, the tool's objects) before it asks anything.
- Each question stands under a line with its name; the prompt is marked `>` and shows its default in brackets.
- The mode and the depth show what each choice works on in this database: the tables, their size, and a rough estimate of what it frees (6.9 GB here). The dry run then counts: 7.0 GB.
- The requirements are a table: required or optional, the state now, and for the one not met what happens and what to do.
- The result is one sentence, then the figures per module, the disk the purge uses while it runs (file by file), and other retentions as examples.
- Nothing was changed, and the last lines give the command of the purge itself.

### 2. The first time on a database: the tool installs itself

The same dry run on a database where the tool was never installed. The passwords are not in the environment, so they are asked for.

```bat
src\bin\epf_purge.bat purge --dry-run --retention 365 --tns EPFDB
```

**Typed:** Enter alone at the EPFPG password (the account does not exist yet); the SYS password; `Y` to install; the password to give the new account, twice.

```text
 EPF Data Purge 0.9.7                                             purge, dry run
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe

 -- The tool's own account (EPFPG) ---------------------------------------------
 > EPFPG password (Enter alone if the tool was never installed on this database): <Enter>

 -- SYS password ---------------------------------------------------------------
 > SYS password: ********
   Database           EPFDB: connected as SYS (EPFDB)
   Tool in database   not installed yet

 -- Install the tool -----------------------------------------------------------
   The tool keeps its own objects in the database: an account EPFPG and a tablespace EPFPG_DATA,
   with the history of its runs and what they measured. Installing them changes nothing else.
 > Install them now (Y/N) [Y]: Y

 -- Password of the new account ------------------------------------------------
 > Password to give the EPFPG account: ********
 > Password to give the EPFPG account (again): ********
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7 (installed now, 0:02)

   [... the dry run goes on with its questions, as in scenario 1 ...]
```

What to notice:

- Nothing is installed by hand: the run says what is missing, what it would create, and asks.
- Passwords are never shown on the real screen, and never placed on a command line.
- Without questions (`--non-interactive`) the same install is done without asking, with the passwords of the environment or the configuration file.

### 3. By command, with no option: every question of a purge

The command `purge` alone, with nothing in the configuration file. The tool asks for everything it needs, the database included.

```bat
src\bin\epf_purge.bat purge
```

**Typed:** The database; `365`; `FULL`; `ALL`; `Y` for a dry run.

```text
 EPF Data Purge 0.9.7                                                      purge
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe

 -- Database -------------------------------------------------------------------
 > Database (its alias in tnsnames.ora, or host:port/service): EPFDB
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7

 -- Days of data to keep -------------------------------------------------------
   Rows older than that are purged. A number of days such as 365, or the day itself as YYYY-MM-DD:
   rows dated before it are purged.
 > Days of data to keep [30]: 365

 -- Mode: what is done to the rows dated before 13 October 2025 ----------------
   Mode             Tables   Size now   Frees (about)   What it does
   FULL                 25    22.0 GB          6.9 GB   deletes the rows, in the modules chosen next
   CLOB                  6    13.8 GB          1.6 GB   keeps the rows, empties their large values
   LOGS                  3     1.2 GB         24.6 MB   same as FULL with the module LOGS alone
   CLOB_N_LOGS           8    14.6 GB          1.6 GB   CLOB, and deletes the rows of module LOGS

   [... the tables of each module and the notes on the figures, as in scenario 1 ...]

 > Mode (FULL, CLOB, LOGS, CLOB_N_LOGS) [FULL]: FULL

 -- Depth: in which modules (mode FULL) ----------------------------------------
   Module           Tables   Size now   Frees (about)   What it holds
   ALL                  25    22.0 GB          6.9 GB   every module
   PAYMENTS             20     8.9 GB          6.5 GB   Bulk payments with all dependent records,
                                                        and file integrations
   LOGS                  3     1.2 GB         24.6 MB   Functional audit trail and technical logs
   BANK_STATEMENTS       2    11.9 GB        389.9 MB   Bank statement dispatching

   Several modules: their names separated by commas, such as PAYMENTS,LOGS.
 > Depth (ALL, or modules such as PAYMENTS,LOGS,BANK_STATEMENTS) [ALL]: ALL

 -- Dry run --------------------------------------------------------------------
 > Dry run (simulation with the expected outcome, nothing is deleted) (Y/N) [N]: Y

   [... the dry run goes on as in scenario 1 ...]
```

What to notice:

- Every option that is given on the command line (or in the configuration file) removes its question.
- Only the batch size is never asked: it is what the checks recommend.

### 4. The purge

The dry run was read; now the rows are deleted. The online redo logs of this database are small, so the purge asks whether to enlarge them for its time.

```bat
src\bin\epf_purge.bat purge --retention 365 --tns EPFDB
```

**Typed:** Enter at the mode and the depth; `N` (not a dry run); `Y` to enlarge the online redo logs; `yes` to start; `N` to keep the tool.

```text
 EPF Data Purge 0.9.7                                                      purge
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7

 -- Mode: what is done to the rows dated before 13 October 2025 ----------------
   Mode             Tables   Size now   Frees (about)   What it does
   FULL                 25    22.0 GB          6.9 GB   deletes the rows, in the modules chosen next
   CLOB                  6    13.8 GB          1.6 GB   keeps the rows, empties their large values
   LOGS                  3     1.2 GB         24.6 MB   same as FULL with the module LOGS alone
   CLOB_N_LOGS           8    14.6 GB          1.6 GB   CLOB, and deletes the rows of module LOGS

   [... the tables of each module and the notes on the figures, as in scenario 1 ...]

 > Mode (FULL, CLOB, LOGS, CLOB_N_LOGS) [FULL]: <Enter>

 -- Depth: in which modules (mode FULL) ----------------------------------------
   Module           Tables   Size now   Frees (about)   What it holds
   ALL                  25    22.0 GB          6.9 GB   every module
   PAYMENTS             20     8.9 GB          6.5 GB   Bulk payments with all dependent records,
                                                        and file integrations
   LOGS                  3     1.2 GB         24.6 MB   Functional audit trail and technical logs
   BANK_STATEMENTS       2    11.9 GB        389.9 MB   Bank statement dispatching

   Several modules: their names separated by commas, such as PAYMENTS,LOGS.
 > Depth (ALL, or modules such as PAYMENTS,LOGS,BANK_STATEMENTS) [ALL]: <Enter>

 -- Dry run --------------------------------------------------------------------
 > Dry run (simulation with the expected outcome, nothing is deleted) (Y/N) [N]: N

 Purge of everything dated before 13 October 2025.
 Run R-000040   C:\epf\logs\2026-10-13_190134_R-000040
 1 of 5  Checking the database (read-only)                         done    0:11
         note   2 of the tables this tool can purge are not in this database and are skipped:
                OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT

   Requirement                       Needed     Now
   Room for the archived logs        required   ok
       NOARCHIVELOG: redo is not archived (estimate 12.9 GB of redo)
   Undo space                        required   ok
       UNDOTBS1 610.0 MB, can grow to 32.0 GB; one batch needs about 89.8 MB; undo tuning keeps undo
       60 s and caps UNDOTBS1 at about 4.0 GB (without it undo_retention would keep about 6.5 GB)
   Temporary space                   required   ok
       about 7,200,000 keys, 1.1 GB; TEMP free 3.0 GB, can grow by 29.0 GB
   Room for the temporary indexes    optional   ok
       12 temporary indexes, about 1.4 GB; EPFPG_DATA free 100.0 MB, can grow by 31.9 GB
   Online redo logs                  optional   NOT MET
       smallest online log 150.0 MB; one batch writes about 179.6 MB
       What happens: Small online logs fill every few seconds and the purge waits on each switch.
       Slower, not a failure.
       What to do:   the tool can enlarge them for the purge: 4 logs of 1 GB replace the present
       ones while it runs (up to 4 GB more disk in the directory of the online logs), and the
       present ones are put back under the same names at its end. Needs SYS. A purge asks;
       --redo-logs says yes beforehand.
   Backup                            required   ok
       last successful RMAN database backup: 2026-10-12 02:00

   Only optional requirements are not met: the purge can run as things are.

 -- Online redo logs -----------------------------------------------------------
   The tool can enlarge them for the purge: 4 logs of 1 GB replace the present ones while it runs
   (up to 4 GB more disk in their directory), and the present ones are put back under the same names
   at its end. Needs SYS.
 > Enlarge the online redo logs for this purge (Y/N) [Y]: Y
   The online redo logs will be 4 x 1 GB during the purge, then as they are now.
   Batch size: 860 top-level rows per transaction, as the checks recommend.

 A purge needs SYS: it keeps the undo tablespace from growing while rows are deleted.

 ===============================================================================
  Ready. This deletes everything dated before 13 October 2025: 197,409 top-level records, with the rows
  under them (a dry run counts those).
  About 8 minutes of deleting, then the purged tables are compacted. It cannot be undone.
 ===============================================================================
 > Type yes to start the purge: yes

 Run R-000041   C:\epf\logs\2026-10-13_190146_R-000041
 2 of 5  Preparing the database for the purge (SYS)                done    0:11
         online redo logs: 4 x 1 GB for the purge; the present ones are put back at its end
         undo kept 60 s and its tablespace under 4.0 GB while rows are deleted; put back at the end
 3 of 5  Deleting
         PAYMENTS         [##########..........]  50%   9,109,274 rows . 39,149 rows a second . 3:50 left
         PAYMENTS         [####################] 100%   18,218,547 rows              8:49
         LOGS             [##########..........]  50%   62,759 rows . 39,494 rows a second . 5:09 left
         LOGS             [####################] 100%   125,517 rows                 0:13
         BANK_STATEMENTS  [##########..........]  51%   478,439 rows . 26,475 rows a second . 1:43 left
         BANK_STATEMENTS  [####################] 100%   935,130 rows                 0:39
 4 of 5  Compacting the purged tables                              done    0:07
         9 tables compacted, 0 skipped
 5 of 5  Putting the database back as it was (SYS)                 done    0:00
         undo tablespace: settings as before
         online redo logs: as they were before the purge

 ===============================================================================
  DONE   19,279,194 rows deleted in 0:42. The checks passed, with 1 note.
 ===============================================================================
  7.0 GB was freed, and the purged tables were compacted: the database can use that space again. The
  disk does not have it back yet: the datafiles keep their size until a reclaim (the database must
  not be in use during a reclaim). To see how much a reclaim gives back:
      src\bin\epf_purge.bat reclaim --dry-run

  Good to know (2)
   - Some rows already had no parent row before the purge, and the purge added none (the report
     lists them under "Orphans on registry links"): 23 links (14 by FK, 9 scanned)
   - 2 of the tables this tool can purge are not in this database and are skipped:
     OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT
  Report   C:\epf\logs\2026-10-13_190146_R-000041\report.html
  Files    C:\epf\logs\2026-10-13_190146_R-000041   (report.txt, console.log)

 -- The tool in the database ---------------------------------------------------
   The tool's own objects stay in the database for the next run: the account EPFPG and its
   tablespace EPFPG_DATA, with the history of the runs and what they measured. Removing them frees
   that space; the next run installs them again, and its estimates start from statistics. The
   reports on this machine stay.
 > Remove the tool from the database now (Y/N) [N]: N
   Kept.
```

What to notice:

- Nothing is deleted before the typed `yes`. The sentence before it says what will be deleted, how long it takes, and that it cannot be undone.
- Five steps, named by what they do. Under "Deleting", one line per module with the progress, the rows, the speed and the time left (on a console that line is rewritten in place).
- Step 4 compacts the tables that were purged, so that the database can use the space of the deleted rows again. It is part of every purge: nothing asks for it.
- What the purge changed for its time (the undo settings, the online redo logs) is put back in step 5, and said.
- The end is one sentence, then what to know and what comes next: the space is free inside the tables, and a reclaim gives it back to the disk.
- "Good to know" keeps what is worth knowing, in plain words. With the larger logs the purge did not wait for them, so nothing is said about that; scenario 15 is the same purge without them.

### 5. A dry run of a reclaim

After the purge: how much disk space would a reclaim give back? No recent backup is recorded here, which for a reclaim is optional.

```bat
src\bin\epf_purge.bat reclaim --dry-run --tns EPFDB
```

**Typed:** `N` to keep the tool in the database.

```text
 EPF Data Purge 0.9.7                                           reclaim, dry run
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7

 A reclaim runs as SYS.

 Dry run of a reclaim: what it would give back to the disk. Nothing is changed.
 Run R-000040   C:\epf\logs\2026-10-13_190228_R-000040
 Measuring what a reclaim gives back (read-only)                   done    0:07

   Requirement                       Needed     Now
   Recycle bin empty                 required   ok
       none
   Room for the archived logs        required   not needed
       NOARCHIVELOG: no archived logs are written
   Temporary space                   required   ok
       largest rebuild OP.NDX_HIS_REG_WEB_POSFIN_DV (328.0 MB): needs about 492.0 MB; TEMP has 3.4
       GB free and can grow by 28.6 GB
   Backup                            optional   NOT MET
       no RMAN database backup recorded
       What happens: The reclaim changes no data, but it rewrites most of the tablespace; a backup
       from before is the way back from a media failure meanwhile. In NOARCHIVELOG mode only a
       backup restores the database.
       What to do:   take a backup first when the data matters: a reclaim changes no data, but it
       writes most of the tablespace again.
   Space quotas of the owners        required   ok
       every owner may use unlimited space in its tablespaces
   Scratch space                     optional   ok
       the reclaim takes up to 8.3 GB by itself; its datafile:
       /u01/oradata/EPFDB/epf_park_40.dbf; the largest table that moves: OP.HISTO_REGLEMENT,
       about 2.1 GB; all that moves: about 10.3 GB

   Only optional requirements are not met: the reclaim can run as things are.

 ===============================================================================
  A reclaim takes DATA from 50.1 GB to about 16.3 GB: 33.8 GB back to the disk.
 ===============================================================================
  The database must not be in use meanwhile: the application accounts KDCM, OP, OPPAYMENTS,
  OPREPORTS, SUPER are locked and their sessions disconnected until it ends.

   DATA              today  [##############################]  50.1 GB
                     after  [#########.....................]  about 16.3 GB
                     738 tables move, 1000 indexes are rebuilt, 2 segments stay where they are

   Disk used while the reclaim runs (removed at its end)
     Scratch space, up to 8.3 GB: /u01/oradata/EPFDB/epf_park_40.dbf (a file the tool
     creates and removes), for the tables that cannot move lower: they wait there and come back. The
     run takes only what it needs of it.
     No datafile grows above its size at the start.

  Nothing was changed.
  Next     src\bin\epf_purge.bat reclaim     the reclaim itself (it measures again, then asks)
  Report   C:\epf\logs\2026-10-13_190228_R-000040\report.html
  Files    C:\epf\logs\2026-10-13_190228_R-000040   (report.txt, console.log)

 -- The tool in the database ---------------------------------------------------
   The tool's own objects stay in the database for the next run: the account EPFPG and its
   tablespace EPFPG_DATA, with the history of the runs and what they measured. Removing them frees
   that space; the next run installs them again, and its estimates start from statistics. The
   reports on this machine stay.
 > Remove the tool from the database now (Y/N) [N]: N
   Kept.
```

What to notice:

- A reclaim asks nothing about what to do: it takes every tablespace that holds the application's data.
- The answer is the first sentence: from 50.1 GB to about 16.3 GB.
- It says which accounts are locked meanwhile, and the scratch space it takes (extra disk during the run), with the file it would create.

### 6. The reclaim

The application is stopped for the time of the reclaim. The reclaim measures again, shows the same screen as its dry run, and asks.

```bat
src\bin\epf_purge.bat reclaim --tns EPFDB
```

**Typed:** `yes` to start; `N` to keep the tool.

```text
 EPF Data Purge 0.9.7                                                    reclaim
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7

 A reclaim runs as SYS.

 Reclaim: compacting the datafiles to give disk space back.
 Run R-000040   C:\epf\logs\2026-10-13_190236_R-000040
 1 of 7  Measuring what a reclaim gives back (read-only)           done    0:07

   Requirement                       Needed     Now
   Recycle bin empty                 required   ok
       none
   Room for the archived logs        required   not needed
       NOARCHIVELOG: no archived logs are written
   Temporary space                   required   ok
       largest rebuild OP.NDX_HIS_REG_WEB_POSFIN_DV (328.0 MB): needs about 492.0 MB; TEMP has 3.4
       GB free and can grow by 28.6 GB
   Backup                            optional   ok
       latest RMAN database backup 2026-10-12 02:00
   Space quotas of the owners        required   ok
       every owner may use unlimited space in its tablespaces
   Scratch space                     optional   ok
       the reclaim takes up to 8.3 GB by itself; its datafile:
       /u01/oradata/EPFDB/epf_park_40.dbf; the largest table that moves: OP.HISTO_REGLEMENT,
       about 2.1 GB; all that moves: about 10.3 GB

   Every requirement is met: the reclaim can run as things are.

 ===============================================================================
  A reclaim takes DATA from 50.1 GB to about 16.3 GB: 33.8 GB back to the disk.
 ===============================================================================
  The database must not be in use meanwhile: the application accounts KDCM, OP, OPPAYMENTS,
  OPREPORTS, SUPER are locked and their sessions disconnected until it ends.

   DATA              today  [##############################]  50.1 GB
                     after  [#########.....................]  about 16.3 GB
                     738 tables move, 1000 indexes are rebuilt, 2 segments stay where they are

   Disk used while the reclaim runs (removed at its end)
     Scratch space, up to 8.3 GB: /u01/oradata/EPFDB/epf_park_40.dbf (a file the tool
     creates and removes), for the tables that cannot move lower: they wait there and come back. The
     run takes only what it needs of it.
     No datafile grows above its size at the start.

 > The application is not available until the reclaim ends. Type yes to start it: yes

 Run R-000041   C:\epf\logs\2026-10-13_190244_R-000041
 2 of 7  Measuring again, locking the application accounts         done    0:06
         5 accounts locked, 0 sessions disconnected
 3 of 7  Recording the state to compare afterwards                 done    0:02
         4,571 objects, 738 tables counted
         1000 indexes released
 4 of 7  Compacting the tables
         scratch space: epf_park_41.dbf, up to 8.3 GB; removed at the end
         data.dbf stops at 9.4 GB: its highest block belongs to OP.CM_SVC_STEP_EXECUTION (3.7 GB
         free below, which the 3.7 GB parked take when they come back: parking more would not make
         DATA smaller)
         DATA: 45 of 738 tables moved, 30 parked                          2:52
 5 of 7  Bringing back the tables set aside                        done    0:10
         30 parked tables moved back
 6 of 7  Rebuilding the indexes                                    done    0:02
         1000 indexes rebuilt
 7 of 7  Comparing with the state recorded, unlocking              done    0:07
         4,571 objects compared, 738 tables counted, 0 new invalid objects
         5 accounts restored

 ===============================================================================
  DONE   DATA went from 50.1 GB to 15.5 GB: 34.6 GB given back to the disk.
         0:55. The application accounts are unlocked. The checks passed, with 1 note.
 ===============================================================================
  Most held on disk: at most 50.1 GB during the run (its size at the start); 50.1 GB at the start,
  15.5 GB at the end.

  Good to know (2)
   - A tablespace ends above the size of its tables and indexes: DATA 15.5 GB vs 14.7 GB of segments
   - Within minutes Oracle adds about 5% of free space back to a datafile that can grow: expect it a
     little larger than above. Nothing to do.
  Report   C:\epf\logs\2026-10-13_190244_R-000041\report.html
  Files    C:\epf\logs\2026-10-13_190244_R-000041   (report.txt, console.log)

 -- The tool in the database ---------------------------------------------------
   The tool's own objects stay in the database for the next run: the account EPFPG and its
   tablespace EPFPG_DATA, with the history of the runs and what they measured. Removing them frees
   that space; the next run installs them again, and its estimates start from statistics. The
   reports on this machine stay.
 > Remove the tool from the database now (Y/N) [N]: N
   Kept.
```

What to notice:

- Seven steps: the measurement, the locking of the accounts, the state recorded, the compaction, the tables set aside brought back, the indexes rebuilt, the comparison and the unlocking.
- The end says what came back to the disk, that the accounts are unlocked, and that everything was compared with the state recorded at the start.
- The last note is there so that nobody is surprised: Oracle adds about 5% of free space back to a datafile that can grow.

## Part 2: when something is not as it should be

A required condition that is not met is a strong warning; going on is the user's choice, and the default answer is no.

### 7. No recent backup, and the user stops

The purge finds no RMAN backup of the last 24 hours. A backup is required: a purge cannot be undone.

```bat
src\bin\epf_purge.bat purge --retention 365 --tns EPFDB
```

**Typed:** As in scenario 4, then `N` for the online redo logs, `N` (no backup exists elsewhere), `N` (do not purge without one).

```text
   [... the questions on the mode, the depth and dry run, as in scenario 4 ...]

 Purge of everything dated before 13 October 2025.
 Run R-000040   C:\epf\logs\2026-10-13_190340_R-000040
 1 of 5  Checking the database (read-only)                         done    0:11
         note   2 of the tables this tool can purge are not in this database and are skipped:
                OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT

   Requirement                       Needed     Now
   [... the other requirements, as in scenario 4 ...]

   Backup                            required   NOT MET
       last successful RMAN database backup: none recorded
       What happens: A purge cannot be undone; a backup taken just before it is the only way back.
       What to do:   take an RMAN backup, then run again. When a backup exists that RMAN does not
       know (storage snapshot, export), or this database is a copy that can be lost, a purge asks
       and goes on (--backup confirmed, --backup none).

   Required and not met: Backup. A purge is not recommended as things are.

 -- Online redo logs -----------------------------------------------------------
   The tool can enlarge them for the purge: 4 logs of 1 GB replace the present ones while it runs
   (up to 4 GB more disk in their directory), and the present ones are put back under the same names
   at its end. Needs SYS.
 > Enlarge the online redo logs for this purge (Y/N) [Y]: N
   The online redo logs stay as they are: the purge waits for them at times.

 -- Backup ---------------------------------------------------------------------
   Backup: a purge cannot be undone; a backup taken just before it is the only way back.
 > Is there a backup of this database that RMAN does not know (storage snapshot, export) (Y/N) [N]: N
   Not recommended: without a backup, what the purge deletes cannot be brought back.
 > Purge without a backup (Y/N) [N]: N

 Stopped: take a backup, then run the purge again.
 Nothing was changed.
```

Exit code 3: stopped, or the answer was no.

What to notice:

- The table says why a backup matters and the ways out, before any question.
- Two questions, both with no as their default: is there a backup RMAN does not know, and if not, purge without one?
- Stopping changes nothing, and says what to do next.

### 8. No recent backup, and the user goes on

The same database. This time the user decides to purge without a backup: a test copy, for example.

```bat
src\bin\epf_purge.bat purge --retention 365 --tns EPFDB
```

**Typed:** `Y` for the online redo logs, `N` (no backup elsewhere), `Y` (purge without a backup), then `yes`.

```text
   [... as scenario 7 up to its questions ...]

 -- Online redo logs -----------------------------------------------------------
   The tool can enlarge them for the purge: 4 logs of 1 GB replace the present ones while it runs
   (up to 4 GB more disk in their directory), and the present ones are put back under the same names
   at its end. Needs SYS.
 > Enlarge the online redo logs for this purge (Y/N) [Y]: Y
   The online redo logs will be 4 x 1 GB during the purge, then as they are now.

 -- Backup ---------------------------------------------------------------------
   Backup: a purge cannot be undone; a backup taken just before it is the only way back.
 > Is there a backup of this database that RMAN does not know (storage snapshot, export) (Y/N) [N]: N
   Not recommended: without a backup, what the purge deletes cannot be brought back.
 > Purge without a backup (Y/N) [N]: Y
   Batch size: 860 top-level rows per transaction, as the checks recommend.
   Checked again with your answers: the purge can start.

 A purge needs SYS: it keeps the undo tablespace from growing while rows are deleted.

 ===============================================================================
  Ready. This deletes everything dated before 13 October 2025: 197,409 top-level records, with the rows
  under them (a dry run counts those).
  About 8 minutes of deleting, then the purged tables are compacted. It cannot be undone.
 ===============================================================================
 > Type yes to start the purge: yes

   [... the purge runs as in scenario 4 ...]
```

What to notice:

- The answers are checked again before anything starts: "Checked again with your answers: the purge can start."
- The typed `yes` is still asked for.
- Without questions, the same answers are options: `--redo-logs`, `--backup none` (or `--backup confirmed`).

### 9. Not enough temporary space

The temporary tablespace is too small for the purge and cannot grow. This is required, and no answer of the user can fix it.

```bat
src\bin\epf_purge.bat purge --retention 365 --tns EPFDB
```

**Typed:** As in scenario 4, then `N` at "Go on anyway".

```text
   [... the questions, as in scenario 4 ...]

 Purge of everything dated before 13 October 2025.
 Run R-000040   C:\epf\logs\2026-10-13_190446_R-000040
 1 of 5  Checking the database (read-only)                         done    0:11
         note   2 of the tables this tool can purge are not in this database and are skipped:
                OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT

   Requirement                       Needed     Now
   [... the requirements before, as in scenario 4 ...]

   Temporary space                   required   NOT MET
       about 7,200,000 keys, 1.1 GB; TEMP free 200.0 MB, can grow by 0 B
       What happens: The purge keeps the keys of the rows it will delete in a temporary table;
       without room in TEMP it stops before deleting anything.
       What to do:   let the temporary tablespace grow, or add a temporary file (the DBA), then run
       again.
   [... the other requirements are met ...]

   Required and not met: Temporary space. A purge is not recommended as things are.

 -- Temporary space ------------------------------------------------------------
   Not recommended: temporary space is required and not met. The purge keeps the keys of the rows it
   will delete in a temporary table; without room in TEMP it stops before deleting anything.
 > Go on anyway (Y/N) [N]: N

 Stopped: let the temporary tablespace grow, or add a temporary file (the DBA), then run again.
 Nothing was changed.
```

Exit code 3: stopped, or the answer was no.

What to notice:

- The table says what would happen (without room the purge stops before it deletes anything) and what to do (the DBA lets the temporary tablespace grow).
- The tool recommends against going on, and leaves the choice: `Y` would go on, after the same check again and the typed `yes`.

### 10. The user does not type yes

Everything is ready, and the user changes their mind at the last question.

```bat
src\bin\epf_purge.bat purge --retention 365 --tns EPFDB
```

**Typed:** `no` at "Type yes to start the purge".

```text
   [... the questions and the checks, as in scenario 4 ...]

 A purge needs SYS: it keeps the undo tablespace from growing while rows are deleted.

 ===============================================================================
  Ready. This deletes everything dated before 13 October 2025: 197,409 top-level records, with the rows
  under them (a dry run counts those).
  About 8 minutes of deleting, then the purged tables are compacted. It cannot be undone.
 ===============================================================================
 > Type yes to start the purge: no
 Stopped: you did not type yes. Nothing was changed.
```

Exit code 3: stopped, or the answer was no.

What to notice:

- Anything but `yes` stops there. Nothing was changed.

### 11. Nothing is old enough any more

The purge is run a second time with the same days to keep: the first one took everything that was old enough.

```bat
src\bin\epf_purge.bat purge --retention 365 --tns EPFDB
```

**Typed:** Enter at the mode and the depth; `N` (not a dry run); `yes`; `N` to keep the tool.

```text
   [... the questions, as in scenario 4 ...]

 Purge of everything dated before 13 October 2025.
 Run R-000040   C:\epf\logs\2026-10-13_190510_R-000040
 1 of 5  Checking the database (read-only)                         done    0:11
         note   2 of the tables this tool can purge are not in this database and are skipped:
                OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT

   Requirement                       Needed     Now
   [... the requirements, as in scenario 4, all met here ...]

   Every requirement is met: the purge can run as things are.
   Batch size: 120 top-level rows per transaction, as the checks recommend.

 A purge needs SYS: it keeps the undo tablespace from growing while rows are deleted.

 ===============================================================================
  Ready, but there is nothing to purge: no top-level record is dated before 13 October 2025. An earlier
  purge may have taken them. This run would delete nothing.
 ===============================================================================
 > Type yes to start the purge: yes

 Run R-000041   C:\epf\logs\2026-10-13_190522_R-000041
 2 of 5  Preparing the database for the purge (SYS)                done    0:11
         undo kept 60 s and its tablespace under 4.0 GB while rows are deleted; put back at the end
 3 of 5  Deleting
         PAYMENTS         [####################] 100%   0 rows                       0:06
         LOGS             [####################] 100%   0 rows                       0:01
         BANK_STATEMENTS  [####################] 100%   0 rows                       0:01
 4 of 5  Compacting the purged tables                              done    0:05
         25 tables compacted, 0 skipped
 5 of 5  Putting the database back as it was (SYS)                 done    0:00
         undo tablespace: settings as before

 ===============================================================================
  DONE   Nothing to purge: no row dated before 13 October 2025 was found (0:22). The checks passed, with
         1 note.
 ===============================================================================
  If an earlier purge deleted rows, the disk does not have their space back yet: the datafiles keep
  their size until a reclaim (the database must not be in use during a reclaim). To see how much a
  reclaim gives back:
      src\bin\epf_purge.bat reclaim --dry-run

  Good to know (2)
   - Some rows already had no parent row before the purge, and the purge added none (the report
     lists them under "Orphans on registry links"): 21 links (13 by FK, 8 scanned)
   - 2 of the tables this tool can purge are not in this database and are skipped:
     OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT
  Report   C:\epf\logs\2026-10-13_190522_R-000041\report.html
  Files    C:\epf\logs\2026-10-13_190522_R-000041   (report.txt, console.log)

 -- The tool in the database ---------------------------------------------------
   The tool's own objects stay in the database for the next run: the account EPFPG and its
   tablespace EPFPG_DATA, with the history of the runs and what they measured. Removing them frees
   that space; the next run installs them again, and its estimates start from statistics. The
   reports on this machine stay.
 > Remove the tool from the database now (Y/N) [N]: N
   Kept.
```

What to notice:

- The sentence before the typed `yes` says that nothing is old enough, so the run surprises nobody.
- The end says "Nothing to purge" in place of a count of zero, and what may still be worth doing: the space an earlier purge freed is still inside the tables, and a reclaim gives it back.
- The compaction still runs, and finds the tables an earlier purge emptied.

### 12. A purge is stopped while it deletes

A purge is running and has to give way: the quiet period is over. It is stopped from another window (Ctrl+C in its own window does the same).

```bat
src\bin\epf_purge.bat purge --non-interactive --retention 365 --tns EPFDB
src\bin\epf_purge.bat stop --tns EPFDB
```

**Typed:** Nothing: the first command runs without questions, the second is typed in another window while it deletes.

```text
   [... the checks, as in scenario 15 ...]

 2 of 5  Preparing the database for the purge (SYS)                done    0:00
         undo kept 60 s and its tablespace under 4.0 GB while rows are deleted; put back at the end
 3 of 5  Deleting
         PAYMENTS         [#######.............]  37%   6,783,502 rows . 39,149 rows a second . 4:49 left
         PAYMENTS         [##########..........]  50%   9,109,274 rows . 39,149 rows a second . 3:50 left
         Stop requested: the purge stops after batch 4,700 of PAYMENTS
         PAYMENTS         [##########..........]  50%   9,109,274 rows               4:40  stopped
         stopped after 0:13
 4 of 5  Compacting the purged tables                              not run
 5 of 5  Putting the database back as it was (SYS)                 done    0:00
         UNDOTBS1 not switched, nothing changed: 2 transactions of other sessions are open
         undo tablespace: settings as before

 ===============================================================================
  STOPPED   on request: 9,109,274 rows deleted so far, in 0:24. What was deleted stays deleted;
            nothing is half done.
 ===============================================================================
  The same command goes on from here.

  Good to know (3)
   - Some rows already had no parent row before the purge, and the purge added none (the report
     lists them under "Orphans on registry links"): 23 links (14 by FK, 9 scanned)
   - 2 of the tables this tool can purge are not in this database and are skipped:
     OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT
   - Time waiting for the online redo logs: log switches 00:02:05 of 00:08:24 in batches (25%),
     online logs 3 x 150.0 MB: larger online logs make fewer switches (--redo-logs)
  Report   C:\epf\logs\2026-10-13_190545_R-000040\report.html
  Files    C:\epf\logs\2026-10-13_190545_R-000040   (report.txt, console.log)
```

Exit code 3: stopped, or the answer was no.

What to notice:

- The purge ends its current batch, then stops: what was deleted stays deleted, nothing is half done.
- A purge that is stopped does not compact its tables: the run that carries on does.
- The database is still put back as it was (step 5). `epf_purge.bat status` says at any time whether a run left something pending.
- The same command goes on from there, another day.

### 13. Before a reclaim: dropped objects in the recycle bin

The tablespaces to compact hold objects that were dropped and can still be restored. The reclaim has to purge them first, and that cannot be undone, so it asks.

```bat
src\bin\epf_purge.bat reclaim --tns EPFDB
```

**Typed:** `N` at "Purge them and go on".

```text
   [... getting ready and the measurement, as in scenario 6 ...]

   Requirement                       Needed     Now
   Recycle bin empty                 required   NOT MET
       3 recycle-bin objects, 120.0 MB
       What happens: While the datafiles cannot grow, Oracle makes room for the moves by purging
       recycle-bin objects of the tablespace; they could then no longer be restored with FLASHBACK
       TABLE ... TO BEFORE DROP.
       What to do:   the DBA purges them (PURGE TABLESPACE name); or the reclaim purges them when
       you say so (--confirm RECYCLEBIN): FLASHBACK TABLE can then no longer restore them.
   [... the other requirements, as in scenario 6 ...]

   Required and not met: Recycle bin empty. A reclaim is not recommended as things are.

   [... what the reclaim gives back, as in scenario 6 ...]

 -- Recycle bin empty ----------------------------------------------------------
   Recycle bin: the reclaim purges the dropped objects of these tablespaces first.
   FLASHBACK TABLE ... TO BEFORE DROP can then no longer restore them.
 > Purge them and go on (Y/N) [N]: N

 Stopped: the DBA purges them (PURGE TABLESPACE name); or the reclaim purges them when you say so
          (--confirm RECYCLEBIN): FLASHBACK TABLE can then no longer restore them.
 Nothing was changed.
```

Exit code 3: stopped, or the answer was no.

What to notice:

- The question says what is lost by answering yes: FLASHBACK TABLE can then no longer restore those objects.
- Without questions the reclaim does not start in this state, unless the command says `--confirm RECYCLEBIN`.

## Part 3: without questions

With `--non-interactive` nothing is asked: the answers come from the options, the environment or the configuration file. This is the one command a scheduler can start; the tool schedules nothing itself.

### 14. A dry run in one command

The database is given, and the EPFPG password is in the environment (EPF_PASSWORD) or in the configuration file.

```bat
src\bin\epf_purge.bat purge --non-interactive --dry-run --retention 365 --tns EPFDB
```

**Typed:** Nothing.

```text
 EPF Data Purge 0.9.7                                             purge, dry run
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7

 Dry run of a purge of everything dated before 13 October 2025. Nothing is changed.
 Run R-000040   C:\epf\logs\2026-10-13_190617_R-000040
 1 of 2  Checking the database (read-only)                         done    0:09
         note   2 of the tables this tool can purge are not in this database and are skipped:
                OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT

   Requirement                       Needed     Now
   [... the requirements, as in scenario 1 ...]

   Only optional requirements are not met: the purge can run as things are.

 2 of 2  Counting what the purge would delete
         PAYMENTS                    18,218,547 rows      about 6.6 GB
         LOGS                           125,517 rows     about 21.0 MB
         BANK_STATEMENTS                935,130 rows    about 380.0 MB

 ===============================================================================
  A purge would delete 19,279,194 rows, about 7.0 GB, dated before 13 October 2025.
  It would take about 8 minutes of deleting, and would complete as things are.
 ===============================================================================
   What                  Rows to delete   Space freed (about)    Deleting
   PAYMENTS                  18,218,547                6.6 GB        7:40
   LOGS                         125,517               21.0 MB        0:04
   BANK_STATEMENTS              935,130              380.0 MB        0:33

   A purge compacts the tables it purged, so the database can use that space again. The disk gets it
   back with a reclaim: the datafiles keep their size until then.

   [... the disk used while the purge runs and the other retentions, as in scenario 1 ...]

  Good to know (1)
   - Undo kept within 4.0 GB by undo tuning; about a quarter of the time waiting for the 150.0 MB
     online logs

  Nothing was changed.
  Next     src\bin\epf_purge.bat purge --retention 365     the purge itself
  Report   C:\epf\logs\2026-10-13_190617_R-000040\report.html
  Files    C:\epf\logs\2026-10-13_190617_R-000040   (report.txt, console.log)
```

What to notice:

- The same screen as with questions, without the questions: no divider, no prompt.
- report.html is written in the run folder and not opened when nobody is at the console.

### 15. A purge in one command

The purge as a scheduler would start it. The days to keep must be given: a purge without questions deletes only what it is told to.

```bat
src\bin\epf_purge.bat purge --non-interactive --retention 365 --tns EPFDB
```

**Typed:** Nothing. No confirmation is asked either.

```text
 EPF Data Purge 0.9.7                                                      purge
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7

 Purge of everything dated before 13 October 2025.

 Run R-000040   C:\epf\logs\2026-10-13_190638_R-000040
 1 of 5  Checking the database (read-only)                         done    0:11
         note   2 of the tables this tool can purge are not in this database and are skipped:
                OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT

   Requirement                       Needed     Now
   [... the requirements, as in scenario 4 ...]

   Only optional requirements are not met: the purge can run as things are.

 2 of 5  Preparing the database for the purge (SYS)                done    0:00
         undo kept 60 s and its tablespace under 4.0 GB while rows are deleted; put back at the end
 3 of 5  Deleting
         PAYMENTS         [##########..........]  50%   9,109,274 rows . 39,149 rows a second . 3:50 left
         PAYMENTS         [####################] 100%   18,218,547 rows              8:49
         LOGS             [##########..........]  50%   62,759 rows . 39,494 rows a second . 5:09 left
         LOGS             [####################] 100%   125,517 rows                 0:13
         BANK_STATEMENTS  [##########..........]  51%   478,439 rows . 26,475 rows a second . 1:43 left
         BANK_STATEMENTS  [####################] 100%   935,130 rows                 0:39
 4 of 5  Compacting the purged tables                              done    0:07
         9 tables compacted, 0 skipped
 5 of 5  Putting the database back as it was (SYS)                 done    0:00
         undo tablespace: settings as before

 ===============================================================================
  DONE   19,279,194 rows deleted in 0:42. The checks passed, with 1 note.
 ===============================================================================
  7.0 GB was freed, and the purged tables were compacted: the database can use that space again. The
  disk does not have it back yet: the datafiles keep their size until a reclaim (the database must
  not be in use during a reclaim). To see how much a reclaim gives back:
      src\bin\epf_purge.bat reclaim --dry-run

  Good to know (3)
   - Some rows already had no parent row before the purge, and the purge added none (the report
     lists them under "Orphans on registry links"): 23 links (14 by FK, 9 scanned)
   - 2 of the tables this tool can purge are not in this database and are skipped:
     OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT
   - Time waiting for the online redo logs: log switches 00:02:05 of 00:08:24 in batches (25%),
     online logs 3 x 150.0 MB: larger online logs make fewer switches (--redo-logs)
  Report   C:\epf\logs\2026-10-13_190638_R-000040\report.html
  Files    C:\epf\logs\2026-10-13_190638_R-000040   (report.txt, console.log)
```

What to notice:

- The online redo logs are not enlarged here: without questions that takes `--redo-logs` (or REDO_LOGS=Y in the configuration file). The end says what the small logs cost.
- The exit code tells the scheduler how it ended: 0 done, 2 done with warnings, 1 failed or not started, 3 stopped.

### 16. A purge that does not start

The same command on a database without a recent backup. No option says what to do about it, so the purge does not start.

```bat
src\bin\epf_purge.bat purge --non-interactive --retention 365 --tns EPFDB
```

**Typed:** Nothing.

```text
 Purge of everything dated before 13 October 2025.

 Run R-000040   C:\epf\logs\2026-10-13_190721_R-000040
 1 of 5  Checking the database (read-only)                         done    0:09
         note   2 of the tables this tool can purge are not in this database and are skipped:
                OPPAYMENTS.APPROBATION_EXECUTION_OPT, OPPAYMENTS.WORKFLOW_EXECUTION_OPT

   Requirement                       Needed     Now
   [... the other requirements, as in scenario 4 ...]

   Backup                            required   NOT MET
       last successful RMAN database backup: none recorded
       What happens: A purge cannot be undone; a backup taken just before it is the only way back.
       What to do:   take an RMAN backup, then run again. When a backup exists that RMAN does not
       know (storage snapshot, export), or this database is a copy that can be lost, a purge asks
       and goes on (--backup confirmed, --backup none).

   Required and not met: Backup. A purge is not recommended as things are.

 The purge does not start: a required condition is not met. The way past each:
   BACKUP: take an RMAN backup; or add --backup confirmed (a backup exists that RMAN does not know) or --backup none (a copy that can be lost)

 ===============================================================================
  NOT STARTED   A required condition is not met (above). Nothing was changed.
 ===============================================================================
  Report   C:\epf\logs\2026-10-13_190721_R-000040\report.html
  Files    C:\epf\logs\2026-10-13_190721_R-000040   (report.txt, console.log)
```

Exit code 1: failed, or not started.

What to notice:

- Nothing is gone past without being told to: the run names the condition and the options that go past it.
- Nothing was changed, and the exit code is 1.

### 17. A purge without the days to keep

The command forgets `--retention`, and the configuration file has none.

```bat
src\bin\epf_purge.bat purge --non-interactive --tns EPFDB
```

**Typed:** Nothing.

```text
 EPF Data Purge 0.9.7                                                      purge
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7
 The days of data to keep are required with --non-interactive: --retention DAYS or --cutoff YYYY-MM-DD, or RETENTION_DAYS or CUTOFF in the configuration file.
```

Exit code 4: a mistake in the command; nothing was changed.

What to notice:

- A purge without questions never guesses how much to delete. No run is created.

### 18. A reclaim in one command

The reclaim as a scheduler would start it, with the SYS password in the environment or the configuration file. It still measures first.

```bat
src\bin\epf_purge.bat reclaim --non-interactive --tns EPFDB
```

**Typed:** Nothing.

```text
   [... getting ready, the measurement and what the reclaim gives back, as in scenario 6 ...]

  No question (--non-interactive or --yes): the reclaim starts.

 Run R-000041   C:\epf\logs\2026-10-13_190743_R-000041
 2 of 7  Measuring again, locking the application accounts         done    0:06
         5 accounts locked, 0 sessions disconnected
 3 of 7  Recording the state to compare afterwards                 done    0:02
         4,571 objects, 738 tables counted
         1000 indexes released
 4 of 7  Compacting the tables
         scratch space: epf_park_41.dbf, up to 8.3 GB; removed at the end
         data.dbf stops at 9.4 GB: its highest block belongs to OP.CM_SVC_STEP_EXECUTION (3.7 GB
         free below, which the 3.7 GB parked take when they come back: parking more would not make
         DATA smaller)
         DATA: 45 of 738 tables moved, 30 parked                          2:52
 5 of 7  Bringing back the tables set aside                        done    0:10
         30 parked tables moved back
 6 of 7  Rebuilding the indexes                                    done    0:02
         1000 indexes rebuilt
 7 of 7  Comparing with the state recorded, unlocking              done    0:07
         4,571 objects compared, 738 tables counted, 0 new invalid objects
         5 accounts restored

 ===============================================================================
  DONE   DATA went from 50.1 GB to 15.5 GB: 34.6 GB given back to the disk.
         0:55. The application accounts are unlocked. The checks passed, with 1 note.
 ===============================================================================
  Most held on disk: at most 50.1 GB during the run (its size at the start); 50.1 GB at the start,
  15.5 GB at the end.

  Good to know (2)
   - A tablespace ends above the size of its tables and indexes: DATA 15.5 GB vs 14.7 GB of segments
   - Within minutes Oracle adds about 5% of free space back to a datafile that can grow: expect it a
     little larger than above. Nothing to do.
  Report   C:\epf\logs\2026-10-13_190743_R-000041\report.html
  Files    C:\epf\logs\2026-10-13_190743_R-000041   (report.txt, console.log)
```

What to notice:

- Two runs: the measurement (read-only), then the reclaim itself.
- The application's accounts are locked from step 2 to step 7 only.

## Part 4: other things worth showing

### 19. After an update of the tool's files

The files of the tool were replaced by a newer version; the objects in the database are still the older one.

```bat
src\bin\epf_purge.bat purge --dry-run --retention 365 --tns EPFDB
```

**Typed:** `Y` to upgrade.

```text
 EPF Data Purge 0.9.7                                             purge, dry run
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.2; these scripts are version 0.9.7

 -- Version of the tool --------------------------------------------------------
 > Upgrade it now (SYS; the history of the runs is kept) (Y/N) [Y]: Y
   Tool in database   version 0.9.7 (upgraded now, 0:02)

   [... the dry run goes on as in scenario 1 ...]
```

What to notice:

- The history of the runs and the settings that were changed are kept. It needs the SYS password.

### 20. Not everything: a mode and some modules

The rows must stay, and only their large values (documents, messages) are emptied, while the logs are deleted: the mode CLOB_N_LOGS, given on the command line. Only the depth is asked.

```bat
src\bin\epf_purge.bat purge --dry-run --retention 365 --mode CLOB_N_LOGS --tns EPFDB
```

**Typed:** Enter at the depth.

```text
 -- Depth: in which modules (mode CLOB_N_LOGS) ---------------------------------
   Module           Tables   Size now   Frees (about)   What it holds
   ALL                   8    14.6 GB          1.6 GB   every module
   PAYMENTS              3     1.9 GB          1.2 GB   Bulk payments with all dependent records,
                                                        and file integrations
   LOGS                  3     1.2 GB         24.6 MB   always part of this mode: its rows are
                                                        deleted
   BANK_STATEMENTS       2    11.5 GB        376.8 MB   Bank statement dispatching

   [... the tables of each module, as in scenario 1 ...]

   Mode CLOB_N_LOGS: the tables counted are those with large values, and the sizes are those values.
   Several modules: their names separated by commas, such as PAYMENTS,LOGS.
 > Depth (ALL, or modules such as PAYMENTS,LOGS,BANK_STATEMENTS) [ALL]: <Enter>

   [... the dry run goes on ...]
```

What to notice:

- The figures follow the mode: here the tables counted are those with large values, and the sizes are those values.
- LOGS is a module, and also the name of the mode that deletes that module alone (FULL with the module LOGS).

### 21. A purge that empties large values

The mode CLOB on one module, without questions: the rows of BANK_STATEMENTS stay, and their large values are emptied.

```bat
src\bin\epf_purge.bat purge --non-interactive --retention 365 --mode CLOB --depth BANK_STATEMENTS --tns EPFDB
```

**Typed:** Nothing.

```text
 Purge of everything dated before 13 October 2025.
 Mode CLOB, modules BANK_STATEMENTS.

   [... the checks and the preparation, as in scenario 15 ...]

 3 of 5  Deleting
         BANK_STATEMENTS  [##########..........]  51%   21,440 LOB values . 1,072 LOB values a second . 0:19 left
         BANK_STATEMENTS  [####################] 100%   42,880 LOB values            0:44
 4 of 5  Compacting the purged tables                              done    0:03
         nothing to compact: no table has enough free space inside after this purge
 5 of 5  Putting the database back as it was (SYS)                 done    0:00
         undo tablespace created again to give its space back: UNDOTBS1 under the same names, 4.0 GB
           -> 610.0 MB

 ===============================================================================
  DONE   42,880 LOB values cleared in 0:18. The checks passed, with 1 note.
 ===============================================================================
```

What to notice:

- The line of the module counts large values (LOB values) in place of rows.
- Nothing is compacted: the compaction is for the tables whose rows were deleted.
- The last step says when the undo tablespace was created again to give its space back.

### 22. The reclaim typed as an option of purge

Somebody who knows the previous tool types the reclaim as an option of the purge, right after a purge.

```bat
src\bin\epf_purge.bat purge --reclaim --dry-run --tns EPFDB
```

**Typed:** Nothing until the end of the dry run.

```text
 --reclaim: the reclaim is a command of its own. This runs it, as this command does:
     src\bin\epf_purge.bat reclaim --dry-run

 EPF Data Purge 0.9.7                                           reclaim, dry run
 -------------------------------------------------------------------------------

 Getting ready
   sqlplus            C:\oracle\product\19.0.0\client_1\bin\sqlplus.exe
   Database           EPFDB: connected (EPFDB)
   Tool in database   version 0.9.7

 A reclaim runs as SYS.

 Dry run of a reclaim: what it would give back to the disk. Nothing is changed.

   [... the dry run of the reclaim goes on as in scenario 5 ...]
```

What to notice:

- The tool runs the reclaim, and says which command that is.
- Every command the tool shows can be typed as it is from where the user is: it begins with the path of the tool.
- With the options of a purge as well (`purge --retention 365 --reclaim`) it is refused, with the two commands to type: the purge and the reclaim are run one after the other, the purge in a quiet period, the reclaim with the application stopped.

### 23. Removing the tool from the database

The tool is no longer needed on this database.

```bat
src\bin\epf_purge.bat uninstall --tns EPFDB
```

**Typed:** `yes`.

```text
 EPF Data Purge 0.9.7                                                  uninstall
 -------------------------------------------------------------------------------

 -- Remove the tool ------------------------------------------------------------
   This removes the tool's own objects from the database: the account EPFPG and its tablespace
   EPFPG_DATA, with the history of the runs. The application's data is not touched, and the reports
   on this machine stay.
 > The EPFPG schema and the EPFPG_DATA tablespace will be removed. Type yes to proceed: yes

== EPF uninstall
  EPFPG removed.
== EPF uninstall: tool tablespace
  EPFPG_DATA and its datafiles removed.
```

What to notice:

- Only the tool's own account and tablespace go, with the history of the runs. The application's data is not touched, and the reports on the machine stay.

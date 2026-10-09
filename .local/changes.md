# Change history

Newest first. Each entry: date, what changed, why, and how to test when relevant.

## 2026-10-09 - Faster moves: a move's placement read from the inventory; a scratch size that fits (0.8.1)

Why: J4's console.log (16 lines, 19:15 to 19:20, sent by the user) shows where a move's time went on EPFPG784. Each UNIT_MOVED took 12 to 13 s for a table of OPPAYMENTS and 32 to 33 s for one of OP, and the MOVE_PLACEMENT after it came another 12 to 13 s or 32 to 33 s later. That second wait is the second unit_layout alone, so the first one takes the same, and the rest of the move (free_layout, the MOVE, refresh_item, the trim) about nothing. The cost goes with the owner: unit_layout's DBA_EXTENTS query, with `e.tablespace_name = p_ts` and the type and name joined into one string, reads every extent of that owner in DATA. refresh_item's query, by table names and a subquery on the tablespaces, ran in about a second in the same run (a park takes about 1 s with it). On TANM7883 all of it is fast (K5). And K5 stopped 0.5 GB above DATA's segments: the 2.2 GB table at the top did not fit in the scratch space, which K4 had sized for the largest table alone.

Changes (src/sql/install; tool version 0.8.1):
- tables.sql: EPF_TS_INVENTORY gets EXTENTS, MIN_EXTENT, MAX_EXTENT and LOW_BLOCK (add_column: an upgrade adds them).
- epf_reclaim: scan_ts (the assessment) and refresh_item (after each move, park and return of a unit) fill them: per segment and datafile, the extent count, the smallest and largest extent, the lowest block. unit_layout(p_ts, p_item) reads the unit's rows of the inventory instead of DBA_EXTENTS. MOVE_PLACEMENT keeps its text, so the digest reads it as before. A move now queries the dictionary as much as a park does.
- check_requirements: the scratch size suggested is the largest table that moves and half of all that moves, plus a tenth, rounded up to 256 MB (it was the largest plus a tenth). Its line names all that moves. For K5 about 8 GB instead of 2.5 GB. The scratch datafile only grows as far as the parked tables need, up to that size.
- park_unit: PARK_SKIPPED for want of scratch space gives the size that would have taken the table: `(--scratch NM would take it)`.
- README: run from a machine on the database's network, not through a VPN (set K from a server close to TANM7883: the suite in 39 min against 2 h 34 min, no dropped connection); the scratch suggestion explained. docs/README.html regenerated. PLAN.md 7.5.

Checked here: ASCII; every call of unit_layout changed; the wrapper still reads `--scratch NM` from the option. Not compiled here: no Oracle.

How to test: K7 and K8 on TANM7883 (status page): install 0.8.1, the labs with T18K (their placement lines in the digest as before), then DATA a second time with the size the dry run suggests (HISTO_REGLEMENT parked, R7 PASS expected). Set L shows the speed on EPFPG781.

## 2026-10-09 - K4 to K6 on TANM7883: DATA 18.0 to 9.9 GB in 5 min; a restore waits for a worker whose client is gone; K7 still to run

The digest of K6 (K3b's session, K4, K5):
- **K4** (R-000049, dry run, 34 s, PASS): DATA 18.0 GB in one datafile, its highest block at 17.1 GB, 15.9 GB of segments; 738 tables to move (15.4 GB, about 10.0 GB after), 175 indexes (450.5 MB); forecast 10.7 GB. INITIAL_OVERSIZED: 26 segments, 2.3 GB in all (OP.SPEC_TRT_LOG: INITIAL 936 MB for about nothing).
- **K5** (R-000050, `--scratch 3G`, PASS WITH WARNINGS, exit 2, 5 min 10 s): DATA 18.0 to 9.9 GB (8.1 GB given back) with 9.4 GB of segments, below the forecast; R1 to R6, R8 and R9 PASS. The compaction took 2 min 57 s: 49 tables moved, 13 parked (1.5 GB of the 3 GB), all returned, EPF_PARK_50 dropped; the index rebuilds about 20 s, the verify 39 s. R7 WARN, 0.5 GB above the segments: OP.HISTO_REGLEMENT (2.2 GB) came back to the top after each of its 3 moves, and PARK_SKIPPED: about 2.2 GB needed, 1.5 GB of the 3 GB left. The suggestion of K4 is the largest table plus a tenth (check_requirements), which leaves out what is parked before it.
- **Speed**: a small table moves in under a second (6 in 2 s, 10 in 8 s), a park takes about 1 s. J4 on EPFPG784, the same 0.8.0: about 45 s per small move (14 in 11 min 25 s), a park about 1 s. A park also runs the loop's free_bytes (DBA_FREE_SPACE), refresh_item (DBA_EXTENTS) and trim_ts; other_ts does nothing for a table whose segments are all in DATA. What only a move runs: unit_layout before and after it (DBA_EXTENTS, `e.tablespace_name = p_ts` where refresh_item has a subquery), free_layout (DBA_FREE_SPACE) and the move within DATA itself. One of these is slow on EPFPG784. console.log shows which: each UNIT_MOVED ends with its time (from the start of the move to the trim after it, the first unit_layout and free_layout included), and the MOVE_PLACEMENT after it comes once the second unit_layout is done. The digest folds these lines; the status page asks for J4's.
- **T18J's notes**: the restore waited for the worker whose client was gone (WORKER_RUNNING) and went on when its call ended; the path of 0.7.2, seen on Oracle for the first time. T18D and T18I: the worker session marked for kill (ORA-00031), ended soon after.
- T01 on TANM7883: OP 9,201 MB, OPPAYMENTS 7,056 MB, after 6 purges of the suite.

K7 (T18K) is still to run: the one test of a client lost as a whole while a table is parked. The run is left RUNNING, the next run marks it ABANDONED once its lock is free, and `reclaim --restore` brings the table back. T18J showed the wait for an orphan worker and J5 a later restore of parked tables; T18K covers the rest of that path.

Proposed next version: the slow part of a move made cheap (which one: J4's console.log), each move's event giving where its time went; the scratch suggestion covering what is parked before the largest table, and PARK_SKIPPED giving the size that would have taken the table. Then set L on EPFPG781. PLAN.md 12.7: the CLUBMED8 column.

How to test: K7 on TANM7883 (status page).

## 2026-10-09 - K3b on TANM7883: the lab tests pass; T18K after the digest (K7); set L planned on EPFPG781

K3b on TANM7883 (0.8.0, from the remote server; log `logs/tests/2026-10-09_075844_TANM7883`): `--only T18D,T18I,T18J,T18F`, 5 of 5 in 9 min after the pull, the same as the run before it. T18D and T18I pass with the kill check of 9171309. T18J passed in 6 min 59 s: the worker's sqlplus ended by the test, the restore in the same run, nothing left behind. T18K was not in the command. The same lab tests took 5 to 7 times as long on EPFPG784 from the test machine (T18D 6 min 32 s against 58 s): the lab holds the tool's own tables, so the difference is the connection, not the data.

T18K runs after K6's digest (K7 on the status page, with a digest of its own). A digest covers the latest test session and the wrapper runs started after it, so a test session started after K5 would leave K4 and K5 out of it; and while K5 runs, the lab's reclaim would be refused (another run holds the lock).

K4, the dry run on TANM7883, ran without `--verbose`; its output is still to be read (K6's digest includes it). K5 is running.

Set L (status page): set K's steps on EPFPG781, a fresh SONEPARUAT dump: the suite, a dry run, one reclaim with `--scratch`, the digest. No SONEPARUAT run has yet taken DATA to its segments in one reclaim (set I stopped at 14.2 GB, J4 lost its connection, R10 got there after earlier passes), and set L compares both sources on the same steps. After set K is read, and after the faster moves if K5 calls for them.

Test databases now: EPFPG781 and EPFPG782 hold fresh SONEPARUAT dumps, EPFPG783 is new and empty, EPFPG784 is being emptied; set D (ARCHIVELOG, optional) leaves EPFPG784 for another copy. PLAN.md 12.7: these states, set L, how a killed session ends and the lab timings per source.

How to test: K5, K6, then K7 on TANM7883; set L on EPFPG781 later.

## 2026-10-09 - Test databases by data source (PLAN.md 12.7)

Every set before K ran on dumps of SONEPARUAT (EPFPG781 to EPFPG784); TANM7883 (set K) holds a dump of CLUBMED8. PLAN.md 12.7 records which database holds which data, where the wrapper ran, and the main figures per source: the suite, a purge, the reclaims, the forecast against the result, the time per move. It is there to compare the tool on other clients' data; set K fills the CLUBMED8 column.

How to use: a new source adds a column, filled from the digests of its runs.

## 2026-10-09 - J6: why J4 could not restore itself; a session a run depends on keeps trying to connect

The digest of J6 (the labs of J2: 10 of 10; J3; J4; J5) with the error lines of a failed run:
- **What broke J4 (R-000051).** At about 20:49 on the database clock, 1 h 37 min into the run, the connection to EPFPG784 dropped: the monitor got ORA-03113, the worker's sqlplus ORA-03114. The worker's session ended with it: no event after 20:48:54, nothing put back, and J5 found no worker still running. The wrapper started the restore in the same run at once; its CONNECT failed (ORA-12545: target host or object does not exist). **A wrapper fault**: sqlplus prints the ready marker after a failed CONNECT too, so the session counted as ready, the script ran unconnected (SP2-0640, SP2-0670), and it was not tried again: "The restore did not finish either". About a minute later the report connected: a restore that kept trying would have put everything back in the same run.
- **The compaction itself worked.** Before the drop, DATA had gone from 14.2 GB to 2.2 GB, with 118 tables parked (2.9 GB of the 3.0 GB allowed) and the indexes released; after J5, 6.7 GB with 6.5 GB of segments (J3 forecast 8.4 GB). TRANSMISSION_EXECUTION_AUDIT, the table that held the top in set I: its LOB had an INITIAL of 2.0 GB; the move set it to 64 KB, and the table went from 2.2 GB to 192 KB (its copy still came back to the top, and was parked).
- **Why it ran so long.** Moving a small table took about 45 s (20 tables of 64 to 576 KB in 15 min, 20:24 to 20:39); parking one takes about 1 s. The cost is per move, not per byte: besides the MOVE, the queries of the move's description (where its segments lay before and after, the free space of the tablespace, MOVE_PLACEMENT) and the trim of the datafile after each move. To be measured on TANM7883 (K5) before changing it.

Change (src/bin/lib/epf.ps1, wrapper only):
- Start-Session: a CONNECT that printed an error before the ready marker no longer counts as ready. It is ended and tried again after 10, 20, then 30 s, while its patience lasts, unless the error is final (`$script:FinalConnectErrors`: ORA-01005, 01017, 01031, 01045, 12154, 12162, 28000, 28001, 28009, any SP2-); the warning of a password about to expire is no error. Each new attempt says why, in a line.
- Patience: `RECONNECT_S` (default 600, 60 to 86400; configuration key) for the sessions a run depends on: worker scripts, the restore in the same run, the SYS steps, the undo restore and the report (Invoke-SqlScript with a run state or `-Patient`), and the monitor attached again (Reset-Monitor: for RECONNECT_S, 5 attempts at least, pauses growing to 30 s). Other sessions: 60 s.
- Test-SessionFailure also counts ORA-03113, 03114, 03135, 12537, 12543, 12545, 12547 and 12560.
- The configuration example documents RECONNECT_S; PLAN.md 8.1.

Checked offline (the fake sqlplus, new: CONNECTs that fail with ORA-12545, a worker whose connection drops): two failed CONNECTs, then `status` works after 10 and 20 s; a wrong password fails at once, without a retry; a reclaim whose worker drops runs its restore in the same run once the connection works again. T00, T01, T06, T07; the 61 checks of the output.

How to test: K3b and K5 on TANM7883 run with it. A drop is not something a test causes; the next one on the test machine shows it.

## 2026-10-09 - Set K on TANM7883: 31 of 33; T18D and T18I's own kill check fixed (ORA-00031). J5 restored EPFPG784

Set K, the full suite on TANM7883 (a dump of another client) from a remote server close to the database, 0.8.0: 31 of 33 passed in 38 min 51 s (EPFPG784 took 2 h 34 min from the test machine, where each connection takes about 15 s). T08 passed there: the lighter output on a real run. The clone did not have T18J and T18K yet. T18D and T18I failed one check each, the same: "output contains KILLED|<sid>". Every other check passed (exit 1, "The worker session ended before the reclaim finished", the restore in the same run, R1 and R9, the lab as before, nothing pending), so the kill itself worked. The test's block printed KILLED only after `ALTER SYSTEM KILL SESSION ... IMMEDIATE` returned. On TANM7883 it returns ORA-00031 (session marked for kill: it ends soon after), the block stopped there, and SQL*Plus does not print the output of a block that failed. EPFPG784 never answered so. The tool's own disconnects already accept ORA-00030 and ORA-00031.

Change (src/tests/e2e/run_tests.ps1): Stop-WorkerSession, used by T18D and T18I. Each session's kill in its own block: KILLED, KILLED with "marked for kill" for ORA-00031 (noted), NOT_KILLED with the error otherwise. Checked: the PL/SQL text as sent; the suite parses.

J5 on EPFPG784, `reclaim --restore` (R-000052, 0.8.0 with the lighter output): PASS WITH WARNINGS in 11 min. The first SYS connection got no answer within 120 s (the network still drops); the second worked. 118 parked tables back from EPF_PARK_51 to DATA (the largest OP.HISTO_OPERATION 999 MB and OP.HISTO_REGLEMENT 942 MB, DATA growing by what each lacked), EPF_PARK_51 dropped, 972 indexes rebuilt in 6 min 49 s, the 6 accounts unlocked. R1, R6 and R9 PASS; the others skipped (restore only). DATA measured 1.7 GB at its start: J4 had compacted it that far, with the 118 tables parked and the indexes released, before the connection dropped. It ends at 6.7 GB with 6.5 GB of segments (14.2 GB before J4). The only warning: INDEXES_NEED_GROWTH, because the rebuilds needed room above the 1.7 GB the restore found.

How to test: set K, K3b on the status page: `run_tests.bat --only T18D,T18I,T18J,T18K,T18F` on TANM7883.

## 2026-10-09 - Tests T18J and T18K: a connection lost during a reclaim; TANM7883 from a remote server

Why: J4 failed when the network dropped. The suite only kills the worker's database session (T18C, T18D, T18I), never its connection, so the path of a worker whose client is gone while its call goes on (wait_for_workers, 0.7.2) had no test. The user asked for it, and runs a session on TANM7883 (a dump of another client: other data) from a remote server.

Changes (src/tests/e2e/run_tests.ps1):
- **T18J**: after the first move (TEST_PAUSE), the worker's sqlplus is ended on this machine (Stop-WorkerClient: its process id from V$SESSION.PROCESS of the SYS session with a run's client identifier). Its call goes on in the database. Required: exit 1, "The worker session ended before the reclaim finished", RECLAIM RESTORE, R1 and R9 PASS, the lab as before, nothing pending. Noted: WORKER_RUNNING and WORKER_ENDED (the restore waited for the call).
- **T18K**: with `--scratch 512M` and reclaim_test_park, while RT_TOP is parked, the whole wrapper is ended (Stop-WrapperTree: cmd, powershell, every sqlplus; Invoke-Process records the process it runs in `$script:CurrentPid`). Then `reclaim --restore` ends the lost run (ABANDONED; tried again after 30 s, up to 3 times, while the database still holds the run lock of the lost monitor). Required: exit 0 or 2, mode RESTORE, R1, R6 and R9 PASS or SKIP, the lab as before, nothing pending. Noted: WORKER_RUNNING, and UNIT_RETURNED (the restore moved RT_TOP back itself).
- A database that ends a session whose client is gone at once takes the other path: no wait, and the restore puts everything back itself. Hence the notes: the end state is required either way.
- PLAN.md: fault injection, the test table.

Checked offline: the suite parses under the T00 rules. Not run here: T18J and T18K need the lab on Oracle.

How to test: set K on the status page (the full suite on TANM7883 from the remote server). On EPFPG784 after J5: `run_tests.bat --only T18A,T18J,T18K,T18F`.

## 2026-10-09 - Set J on EPFPG784: J1 to J3 good; J4's reclaim of DATA failed when the network dropped; the digest shows why a run failed

J4 (R-000051, 0.8.0, `--scratch 3G`) ended FAILED after 01:40:16, the user reports through network instability. Its checks: R1 FAIL 0/972 indexes usable; R2-R5 not verified (the run ended before VERIFY); R6 FAIL (DATA's growth setting not restored, scratch tablespace EPF_PARK_51 not dropped); R8 FAIL 43 of 691 moved, 568 below where the datafile stopped, 80 still parked; R9 FAIL 6 accounts still locked (ANON_META, KDCM, OP, OPPAYMENTS, OPREPORTS, SUPER). So neither the restore path of the worker nor the wrapper's restore in the same run ran to its end. The worker's call may have gone on inside the database after its client was gone; `reclaim --restore` waits for such a worker (WORKER_RUNNING) and then restores: the parked tables come back to DATA, the indexes are rebuilt, the growth setting is restored, EPF_PARK_51 is dropped, the accounts are unlocked. 80 parked tables within 3 GB fits a DATA that the earlier reclaim left nearly full (14.2 GB, 13.1 GB of segments): almost nothing fits below the top, so the compaction parks it.

Change (src/tests/e2e/run_tests.ps1, digest): for a run that failed, the digest adds the wrapper's own lines up to the report (errors, lost connections, the monitor, the worker's early end and the restore in the same run: `$script:DigestTrouble`), and the ORA-, TNS- and SP2- lines of its sqlplus logs (8 per file at most, each once). A lost connection shows there, not in the events. Checked on a fake failed reclaim and a passing restore (digrepo3): the error lines for the first, none for the second; nothing from the report part.

How to test: `reclaim --restore` on EPFPG784, then the digest (status page, set J).

## 2026-10-09 - Output: a lighter view by default; --verbose shows everything (wrapper only; the database stays 0.8.0)

Why: the user found the output of a run too much to follow live. The details stay: with `--verbose`, and always in console.log.

Changes (src/bin/lib/epf.ps1):
- **`--verbose`** (or `VERBOSE=Y` in the configuration file) shows the output as before: every event but the detail events, a heartbeat line every 15 s, the whole report.
- **By default**, while a run is shown: the end of each step, progress (BATCH_PROGRESS), warnings, errors and the milestones of a run (`$script:MilestoneEvents`: scope, plan, requirements, forecast, module and purge end, the tuning changes, tablespaces assessed, accounts locked and unlocked, indexes released, parking and return, compaction end, where each datafile stopped, files resized, the reclaim result). Every other event, the start of each step among them, goes to console.log only.
- **A status line** at the bottom says what runs now: the database clock, the running step with its units done of those planned (the `ST|` lines of the poll, unused until now), the worker's wait, blocker and progress %. It is rewritten in place every 2 s, cleared before the next line and before a prompt, and never logged. When the output is not a console window (a file or a pipe), a line after 60 s without one replaces it. A statement suspended for space gets a line of its own (logged), at most once a minute.
- **At the end, a summary** instead of the whole report: the estimate (preflight) or the simulation and expected outcome (dry run); for a reclaim each tablespace in one line, and for an assessment the accounts a compaction locks; the requirements, each with what was measured, and why and how to meet the ones not met (not shown when a purge or compaction found them all met); the checks that did not pass, and P7 and R7, with their details, the others in one line; the verdict. It is built from the report's sections and EPF_ lines; report.txt and console.log have the whole report.
- **console.log is the same at both levels**: every line `--verbose` shows. The heartbeat lines are left out at both levels, as before.
- "(see the report above)" in three messages is now "(see above)".
- Help, README and docs/README.html, the configuration example (`VERBOSE`), PLAN.md (G8, 8.2, 8.3, D21).

Tests: the suite passes `--verbose` to every wrapper call (Invoke-Wrapper; `-Brief` leaves it out), so its checks and the digest see what they saw before. T08 now checks the default output of a preflight: the summary (ESTIMATE, REQUIREMENTS, its RESULT line, VERDICT), and none of ROOTS_ELIGIBLE, STEP_START, RETENTION OPTIONS, STEPS; its console.log has all of those and not the summary.

Checked offline: 61 checks of the summary, the events shown and the status text, on reports laid out as epf_report prints them. A dry run and a compaction replayed by the fake sqlplus at both levels: 87 and 55 lines on the console by default, 157 and 108 with `--verbose`, the same console.log at both levels. The status line in a real console window: rewritten in place, nothing left behind. T00, T01, T06, T07 and the new T08 against the fake.

How to test (set J on the status page): J2 includes T08; J3 and J4 run without `--verbose`. During J4, watch the bottom line and the SUMMARY at the end. The digest reads console.log as before.

## 2026-10-09 - README: how to use the tool; docs/README.html, its HTML version

Why: the README held a placeholder; the user asked for a guide to the tool and an HTML version of it.

Changes (documentation only):
- **README.md** rewritten for those who install and run the tool: what it does (modules, modes), requirements, install, configure (every key with its option), passwords (a PowerShell one-liner that keeps them off the command line), run it, purge (preflight, dry run, purge), large purges, reclaim (with `--scratch`), stop a run, runs, reports and logs (files, exit codes), status and recovery, settings, the SQL*Plus scripts, the command reference, the repository layout, testing (which warns that the suite changes the database).
- **docs/README.html**: the same guide as one self-contained page (nothing loaded from elsewhere, works offline): a contents sidebar that follows the reading, a Copy button on each command, tables as cards on a phone, dark mode, print styles.
- **.local/gen_readme_html.js** builds the page from README.md, which stays the source: change the README, then run `node .local\gen_readme_html.js`. It stops on non-ASCII and on a link to a section that does not exist (the README's contents list included).

Checked: headless Edge from 360 to 1370 px wide: no table or command wider than its frame, no sideways scroll; light and dark.

## 2026-10-08 - Reclaim: parking in a scratch tablespace (--scratch) replaces the 64 MB extents (0.8.0)

Why: I5 and I6 showed that Oracle chooses where the copy of a moved table goes, and that for a table like TRANSMISSION_EXECUTION_AUDIT (a BASICFILE LOB) it may start at the top of the file although there is free space below; nothing the tool does steers it. The user chose to allow temporary disk for such tables.

Changes (reclaim):
- **Parking.** With `reclaim --scratch SIZE` (or RECLAIM_SCRATCH in the configuration file), a table whose copy comes back to the top, or that still does not fit below after room making, is parked: every segment of it in the run's tablespaces moves to a scratch tablespace the run creates at the first parking (EPF_PARK_<run>: bigfile, the block size of its tablespace, next to that tablespace's first datafile, or OMF, or the ASM disk group; growing up to SIZE). The compaction goes on without it. The restore path's new first step RETURN_PARKED moves each segment back to the tablespace it came from: each first grows within its room by what the part lacks there, so the copy takes the free space the compaction left and the file grows only for the rest. Its indexes the move left unusable are rebuilt next; then the scratch tablespace is dropped with its datafile. Every exit path does this (failure, stop, lost session: RESTORE in the same run, or `reclaim --restore`).
- Recorded before it is made: the scratch tablespace (EPF_INSTANCE_CHANGE item RECLAIM_SCRATCH), each parked segment (new table EPF_RECLAIM_PARK: kind, LOB column, from and scratch tablespace, returned_at), the unit's status PARKED. The owner gets a quota on the scratch tablespace (removed before the drop). Parking is refused for an encrypted tablespace and beyond the space allowed (PARK_SKIPPED); a park that fails leaves the table where it was (PARK_FAILED). A table that cannot move back even after its datafiles grew stays parked and usable (RETURN_FAILED, an error); status lists it, and history pruning keeps its run.
- Without `--scratch`, nothing changes except the 64 MB extents: a table that comes back has room made for it once more and moves again only when it fits as it is, as before.
- **The 64 MB extents are gone** (c_chunk, c_large, large_plan, fresh_bytes, chunked): they relied on "lowest first", which I5 disproved, and they gave TRANSMISSION_EXECUTION_AUDIT's LOB index an INITIAL of 102.4 MB. An INITIAL left by them is now oversized like any other and set to 64 KB by the next move.
- Assessment: requirement SCRATCH (advice), with the space allowed, where the scratch datafile would go, the largest table that moves and a suggested size; the forecast counts the tables that do not fit as parked and coming back at the end; the ARCHIVE estimate adds the redo of parking (twice the space allowed at most). Candidates exclude EPF_PARK_* tablespaces.
- Report: the parameters show the scratch space; R6 fails for a scratch tablespace not dropped; R8 fails for a table still parked; TABLES lists parked tables first; status lists parked tables and scratch tablespaces left.
- Wrapper: `--scratch SIZE` (reclaim only; not with `--restore`), the run header and the review before a compaction show it; with prompts, the assessment's SCRATCH advice offers the suggested size; the Next line keeps it; help and the configuration example describe it. reclaim.sql takes the scratch size as a fourth argument.
- Tests only: setting reclaim_test_park (Y: the next compaction parks the first table it picks, then sets it back to N).

Tests: T07 has three more usage errors (`--scratch lots`, `--restore --scratch`, `preflight --scratch`). New T18H (lab 1 with `--scratch 512M` and reclaim_test_park: SCRATCH met in the dry run; RT_TOP parked, moved back, scratch tablespace dropped; R1-R4 and R9 PASS; the lab as before; nothing pending) and T18I (the worker session killed while RT_TOP is parked: the restore in the same run moves it back and drops the scratch tablespace). The digest keeps the parking events.

Checked offline: the package scans (declarations, order, private functions in SQL); the wrapper and the suite parse; T00, T01 and T07 with the fake sqlplus (0.8.0); the digest on a built set of logs. Not compiled here: T03 installs it.

How to test (set J on the status page): pull, install 0.8.0 on EPFPG784, run the labs with the two new tests, then one reclaim of EPFPG784's DATA with `--scratch 3G` (TRANSMISSION_EXECUTION_AUDIT still holds the top there), then the digest.

## 2026-10-08 - I6: a new table takes the lowest free space; there is no "last position" to reset

A test on EPFPG784 as SYS, with empty tables of its own (SYS.EPF_X_*, dropped at the end), in DATA's free space: all 1,742 MB of it from 12,078 MB up, since the index rebuilds after the compaction filled every gap below. (First try: ORA-00922, SEGMENT CREATION written after TABLESPACE in the script; nothing created.)
- A 64 MB table (P0) went to the lowest free space, 12,087 to 12,213 MB, in a 12 MB piece and 52 pieces of 1 MB.
- A table taking the 16 MB left there and 64 MB more (UP) went on to 12,288 and 12,496 MB. Both dropped.
- The next 64 MB table (M1) went back to exactly P0's pieces, below UP's: Oracle keeps no last position for a new table here.
- A table taking the free space from 12,288 MB to the end and 16 MB more (P1) started with the lowest free piece (12,179 MB) too. Its last 8 MB, more than Oracle could use of the free space, went to the end of the file, which grew by 100 MB through autoextend (14,635 MB, highest block still 14,535 MB; the next reclaim trims it).
- Moving the 64 MB table (M2) also took the lowest free space (12,179 MB, then 12,288 MB up).

So the reset proposed after I5 cannot work and is not needed for such tables. A new segment takes the lowest free space here, as the index rebuilds did. TRANSMISSION_EXECUTION_AUDIT's LOB is the exception: 3 of its 4 copies started high with free space below, for a reason these tests do not show, and its placement cannot be steered.

Next: a decision for the user. With temporary scratch space (about the size of the tables whose copy comes back, 2.1 GB on EPFPG784, confirmed by the DBA), such a table would wait in a scratch tablespace of the run while the rest is compacted, and come back last, filling the gaps left; the 64 MB extents would go. Without it, the reclaim stays best effort.

## 2026-10-08 - I5: Oracle's search for free space starts where it last allocated, not at the start of the file

What the read-only query of EPFPG784 showed (DATA as R-000038 left it):
- DATA is a bigfile tablespace (one datafile, 14,535 MB, 8 KB blocks, system-allocated extents, ASSM).
- TRANSMISSION_EXECUTION_AUDIT: its own segment is 64 KB; its LOB MESSAGE (BASICFILE) is 2,103 MB in 54 extents, INITIAL 2,048 MB as the last move set it.
- **The LOB's extents in the order Oracle allocated them:** 0 and 1 (64 MB each) at the very top of the file, 14,407 and 14,471 MB; 2 to 5 (8 MB) just below, 14,336 to 14,387 MB; then from 1,707 MB upward to 9,988 MB. The file is searched in stretches of 2 GB (pieces end and start exactly at multiples of 2,048 MB). In each stretch the copy takes the whole 64 MB holes first, lowest first, then every smaller piece left there, highest first, and then goes on to the next stretch. After the last stretch it goes on from the start of the file.
- So the copy started in the stretch where the last allocation had been, at the top. The free space below the top was enough; it was used only after the top.
- The LOB's index (SYS_IL...) took INITIAL 102.4 MB, 5 % of the LOB's INITIAL, in 10 extents around 10 GB.
- The 1 MB extents all start on whole MBs; the 64 MB extents too, but only 5 of 86 on a multiple of 64 MB. So the count of whole 64 MB stretches (fresh_bytes) was right; the order is what failed.
- The copies of the three tables moved to make room went to 68 MB (DIRECTORY_DISPATCHING, 64 KB), 10,433 MB (FILE_DISPATCHING, 64 KB) and 14,344 MB (PAYMENT_ADDITIONAL_INFO, 6 MB, in the top stretch).

This explains the instability seen since the first compactions: a copy lands where Oracle's search is, and the search moves up the file as copies are placed and goes back to the start only after the end of the file. Space freed below it (by the tables that made room) is not used before then.

Next: step I6 on the status page tests a reset on EPFPG784 with empty tables of its own (SYS.EPF_X_*): one table takes the free space from the search position to the end of the file and a little more, which can only come from the start of the file; once it is dropped, a table that moves should land near the start. If it does, the compaction makes that reset before each move: no extra disk. If not, a table that keeps coming back waits in a scratch tablespace and comes back last.

## 2026-10-08 - Set I on EPFPG784: the suite passed 31 of 31; one reclaim took DATA from 41.7 to 14.2 GB (R7 WARN)

What the runs showed (suite `logs/tests/2026-10-08_023528_EPFPG784`, then reclaim R-000038):
- **Suite:** 31 of 31 in 2 h 34 min, the stopped PAYMENTS purge and the four tests after it included: EPFPG784 had not been purged before. The digest had no T01 notes, since 610f2ca was not pushed yet.
- **Reclaim of DATA** (7 min 32 s, WARNING, exit 2): 41.7 GB to 14.2 GB, 27.5 GB given back, with 12.4 GB of segments. R7 WARN; R1 to R6, R8 (4 of 691 moved, 687 below where the datafile stopped) and R9 PASS. The warning is PUBLIC_DML: 15 grants to PUBLIC on the PowerBuilder catalog tables OP.PBCAT* (every account can write them; only the accounts listed are locked).
- **Where it stopped:** OPPAYMENTS.TRANSMISSION_EXECUTION_AUDIT (2.2 GB, 1.8 to 2.0 GB of it the LOB MESSAGE) held the top. It moved 4 times, its LOB with 64 MB extents, and its copy held the top again after 3 of them (FILE_DONE at reclaim_unit_moves):
  1. 39.7 to 30.8 GB: the copy took one stretch at 28.9 to 30.8 GB, in 36 extents, though the free space counted 11.2 GB in whole 64 MB stretches from 1.7 GB.
  2. After DIRECTORY_DISPATCHING (10.3 GB to 192 KB) made room: 30.8 to 23.1 GB, the copy at 68 MB to 14.4 GB in 130 extents. FILE_DISPATCHING (4.3 GB to 192 KB) then held the top and moved: 14.4 GB.
  3. After PAYMENT_ADDITIONAL_INFO (3.7 GB to 6 MB, its copy at 14.0 GB) made room, with 3.0 GB counted in whole 64 MB stretches for the 1.9 GB needed, the copy reached 14.4 GB again (72 extents), then 14.2 GB on the fourth move (65 extents).
- The extent counts changed from move to move for about the same INITIAL, so Oracle did not always give the LOB whole 64 MB extents. The digest does not show which segment of the copy (the table, the LOB, the LOB's index) holds the top, nor the order Oracle placed its extents in.
- The acceptance test of set I (R7 PASS in one pass) is not met. No error; nothing left pending.

Next: step I5 on the status page, a read-only query of EPFPG784 as the reclaim left it: the extents of that table's segments (and of the three tables that made room) in the order Oracle allocated them, what holds the top of data.dbf, and whether the extents of 1, 8 and 64 MB start on boundaries of their size. The fix depends on it.

## 2026-10-08 - A second suite run on EPFPG783 (20 of 31): the copy no longer held the application's data; T01 now says what a copy holds

What the run showed (log `logs/tests/2026-10-08_010517_EPFPG783`):
- The reclaim labs passed (T18A to T18D, T18F, T18G), and so did the installs, T09, T10B, T12B, T13B, T18 and T19.
- Every purge found nothing ("check.P1=SKIP|no purge"): T08 and T10 saw no eligible roots and no retention options, and T11 to T17 failed for it.
- T18E, the read-only assessment of the application tablespaces, found no tablespace: no segment of OP, OPPAYMENTS or OPREPORTS in any online application tablespace.
- A purge only deletes rows; it never drops a table or its storage. The tool truncates only its own work table, and nothing in the suite changes setting app_schemas or a tablespace's status. So the copy changed outside the tests between the two runs (refreshed or emptied for another use, as EPFPG782 was). The suite now runs on EPFPG784.

Change (suite only):
- T01 notes the application's data on the copy (MB per schema of OP, OPPAYMENTS, OPREPORTS, or a warning when there is none) and the purges this tool already ran on it (a warning: the purge tests may find little or nothing to purge, and T11 to T13 and T17 need a copy never purged).
- The digest shows T01's notes, and keeps the assessment's NO_TARGET event (no tablespace to reclaim, with the schemas it looked for).

Checked offline: T00 and T01 with the fake sqlplus; the digest on the two built sets of logs.

How to test: the next suite run. Its digest starts with T01's two notes.

## 2026-10-08 - Set I's suite on EPFPG783 (0.7.11): 26 of 31; every reclaim test passed

Run on EPFPG783, since EPFPG782 is in use on another project. EPFPG783 is not a fresh copy: the first end-to-end runs, sets C and E and the parity test purged it, and the suite enlarged its redo logs (permanent).
- Passed: every reclaim test (T18A to T18G: the labs, a stop, a lost session, the read-only assessment of the application tablespaces), the installs, the preflights and dry runs, T13B to T16 (LOGS in steps, LOGS with compaction, BANK_STATEMENTS LOB clearing and purge), the reports and T19.
- Failed: T11, and T12, T12B, T13 and T17 with it. T11 stops a PAYMENTS purge after its third batch and checks the wizard's offer to enlarge the redo logs ("Recommended batch size with 1 GB online logs", printed only when it offers that; "READY with these choices", only when the answers change something). On EPFPG783 the purge ended within its first batches (status SUCCESS, exit 0, its one-step plan done), so no stop was requested, and the logs were already 1 GB. T12, T12B, T13 and T17 work on the stopped run and its plan, which did not exist.
- Not a regression: epf_purge has not changed since set H passed these tests (0.7.1), the wrapper's display of BATCH_PROGRESS is unchanged, and the purges of T13B to T16 went through the same path. They run again on the next copy never purged.

Next: set I's I3, one reclaim of EPFPG783's DATA (purged, never compacted), judged by R7.

## 2026-10-07 - R11: 6 of 6 on 0.7.10; the growth for the index rebuilds is given back; the digest is brief for passing tests (0.7.11)

What R11 showed (6 of 6 passed):
- **Lab 1** (R-000183): to make room for RT_TOP (88 MB needed, 57.5 MB free), RT_IOT moved first: the smallest table whose estimate freed enough. It freed 21 MB, and RT_FAT followed. 344 to 255 MB as in R10, with 226.7 MB of segments.
- **Lab 2** (R-000185): EPF_RT2_DATA 88 to 44 MB and EPF_RT2_SIDE 56 to 26 MB, as in R10. EPF_RT2_INDX stayed at 16 MB (R10: 10.3 MB). It grew from 10.3 to 16 MB for its 6 index rebuilds, sized by their estimates (about 11 MB) plus the largest (8 MB, an INITIAL the rebuild resets), and the rebuilds took 1.5 MB. The final resize gives back only what lies more than reclaim_margin_mb above the highest extent.
- **The digest** was one paste of about 7,500 characters, most of it the moves of the two lab compactions, which passed.

Changes (0.7.11):
- After the index rebuilds, each tablespace grown for them is resized to the end of its highest extent: what the estimates asked beyond the rebuilds is given back.
- Digest: a run of a test that passed shows only its header, its checks, where each datafile stopped, the result per tablespace, a stop, and its warnings and errors. A failed test's runs and the runs after the session keep every key event. Growths of one datafile are folded only when they follow each other, with no resize down between them.

Checked offline: the package scans; T00 and T01 with the fake sqlplus (0.7.11); the wrapper checks (32); the digest on the two built sets of logs (2,500 and 2,700 characters).

Version 0.7.11: set I installs it (T03).

How to test (set I on the status page): the full suite on EPFPG782, then one reclaim of its DATA, then the digest. In the digest, T18G's EPF_RT2_INDX should end near 10 MB.

## 2026-10-07 - R10: DATA 11.1 to 7.6 GB with 7.5 GB of segments; room making takes the smallest table that frees enough; index rebuilds grow a datafile once; a shorter digest (0.7.10)

What R10 showed (6 of 6 passed; then the compaction of DATA, R-000176):
- **Lab 1** (R-000173): 344 to 255 MB with 249.8 MB of segments.
- **Lab 2** (R-000175): EPF_RT2_SIDE went from 56 to 26 MB with 21.3 MB of segments (R9: 42.9 MB). RT2_BLOB and RT2_IOT moved again, EPF_RT2_DATA growing 1 to 2 MB each time for their tables. EPF_RT2_DATA went from 88 to 44 MB. FILE_NO_GROWTH no longer fires there.
- **Probes:** G gave 2 x 64 MB in the fresh datafile, and H gave 2 x 64 MB in EPF_RT2_SIDE.
- **DATA** (R-000176, 54 min): 11.1 GB to 7.6 GB with 7.5 GB of segments (R7 PASS); 55 of 688 tables moved.
  - DIRECTORY_DISPATCHING moved first as usual (its estimate was below 640 MB) to 6.1-6.8 GB. Once the datafile had shrunk to it, it moved again with 64 MB extents, to 2.1-4.1 GB.
  - OP.HISTO_OPERATION (969 MB) ended at the top. It was moved to make room for AUDIT_ARCHIVE (448 KB) and came back. With 64 MB extents it took every whole stretch there was, the highest included, and came back again. The compaction stopped at 5.7 GB, and the index rebuilds took the datafile to 7.6 GB.
- **Two inefficiencies:**
  - The index rebuilds grew the datafile 250 times by about 1 MB each, one FILE_GROWN event each. Two indexes still did not fit (INDEXES_NEED_GROWTH: rebuilt after the growth settings were restored).
  - Room making took the table that frees the most: OP.HISTO_OPERATION (969 MB) for 448 KB of room. Later, 7 tables in a row added no whole 64 MB stretch for OP.HISTO_OPERATION (about 6 minutes).

Changes (0.7.10):
- **Index rebuilds:** before them, each tablespace of the run grows once by what its rebuilds need beyond its free space, plus the largest of them (free space is scattered), within its room. Each rebuild still grows its tablespace when it is short.
- **Room making for a given amount** (a table that does not fit; one that came back, as much as it needs once more) takes the smallest table that frees at least that much, else the one that frees the most.
- **Room making for 64 MB stretches** stops after three moves in a row that add none.
- **Digest:**
  - a run of FILE_GROWN events of one datafile is one line (count, first and last size);
  - a MAKING_ROOM said again is left out;
  - consecutive moves of small tables of one tablespace are one line with their count, their sizes, the room makers and INITIAL resets among them, and the tablespace's size before and after (small: below 64 MB and 2 % of the tablespace, and not moved again, back at the top, moved with 64 MB extents or after a growth);
  - a compaction that a passing test expected to stop at a requirement is left out, and so is RUN_END (the run's header line has it).
  - R10's digest, pasted in seven parts, would now be about 30 lines.

Checked offline: the package scans; T00 and T01 with the fake sqlplus (0.7.10); the wrapper checks (32); the digest on two built sets of logs (with R9's and R10's events): 34 lines and 2,500 characters, 28 lines and 3,100 characters.

Version 0.7.10: install again.

How to test (R11 on the status page): pull, install 0.7.10, run `--only T18A,T18B,T18F,T18G,T19` (6 passed; in T18B, RT_FAT still makes room for RT_TOP), then `--digest`. Each compaction's index rebuilds should show at most one FILE_GROWN line per datafile. DATA needs no further compaction (7.6 GB with 7.5 GB of segments); set I comes next.

## 2026-10-07 - Test digest: `run_tests.bat --digest`, what to send back instead of the logs

Why: what the tester pasted back was too long. The section of T18G alone exceeded 50,000 characters and had to be split: every LAB| state printed four times, the full console and report of every run, the manifests, every passing check. Most of it repeats what the run folders keep on disk.

Change (suite only, no database object; the tool version stays 0.7.9):
- `run_tests.bat --digest` reads the latest test session and the run folders in `logs\` started after it, needs no database and no configuration, and prints:
  - the summary of the session;
  - for the reclaim tests (T18*) and every test that failed: its notes and failed checks; for a failed test also the lines naming an error (ORA-, SP2-, PLS-, a warning or failure of the wrapper);
  - for each compaction of the session, each run of a failed test, and each run in `logs\` after the session (the reclaim of an application tablespace): one line from its manifest (action, mode, tablespaces, status, verdict, exit code, duration), its checks in one line (those that did not pass, and R7 and R8, with their detail; the others by code), and its key events from console.log, one line each: a move with where its copy went (UNIT_MOVED and MOVE_PLACEMENT merged and shortened), INITIAL resets, room making, where each datafile stopped, the result per tablespace, steps of 30 s or more, every warning and error; datafile paths without their directory. Of the moves, the first 10 and the last 40. Left out: the report tables (the events give the same), the 50 INITIAL_SEGMENT lines of an assessment, the PIN lines, probe notes A to F (settled, V14), and a failed test's own copies of the wrapper's events.
- It writes `logs\digest.txt` and copies it to the clipboard. On a test layout with a failed test, two lab runs and a DATA run of 80 moves: 84 lines, 8,300 characters (R9's section of T18G alone was above 50,000).
- The status page's steps ask for the digest instead of the collect commands. The snapshot of DATA those collected (with the EPFPG password) is no longer needed: MOVE_PLACEMENT gives where each copy went and the free space before it.

Checked offline: the digest of a built set of logs (a failed T18G, the lab's dry run and compaction, a DATA run after the session and one before it, which is left out); T00 and T01 with the fake sqlplus.

How to test: after R10's commands, run `.\src\tests\e2e\run_tests.bat --digest` and paste what it copies.

## 2026-10-07 - R9: lab 2 compacts fully; a moved table grows its other tablespaces again; a tablespace that cannot grow keeps its margin; probe G in a datafile of its own (0.7.9)

What R9's tests showed (5 passed, T18G failed on probe G only):
- **The compaction of lab 2 works.** All 5 tables moved (R8 "5 of 5 moved"), each kind of INITIAL was reset, and R1 to R9 passed. EPF_RT2_DATA went from 88 MB to 43 MB with 41 MB of segments, so no free space was left. EPF_RT2_INDX went from 16 MB to 10.3 MB.
- **EPF_RT2_SIDE stopped at 42.9 MB with 21.3 MB of segments.** RT2_BLOB's LOB held its top after the compaction of EPF_RT2_DATA had moved the table. Moving it again also writes its table into EPF_RT2_DATA, which had no free space left. A table that had moved already did not grow its other tablespaces, so the move failed with ORA-01658 (no room for the table's first extent in EPF_RT2_DATA) and the file was done.
- **Probe G** gave 3 extents (1 MB to 64 MB) for the INITIAL of 128 MB, where R8 gave 2 of 64 MB. The probe ran in EPF_RT2_SIDE as the compaction left it: autoextensible again, 20.7 MB free in holes, its datafile ending exactly at its last extent. What Oracle does there depends on that state, which is not the state during a compaction.

Changes (0.7.9):
- **A table that moved already grows its other tablespaces too** when they are short (within their room, never above their start size), as on its first move. Its segments there do not land in the tablespace being compacted. So a LOB tablespace compacted after the tablespace of its tables, which that compaction left full, can still have its segments moved lower. The other tablespace then ends larger by up to the size of those table segments.
- **A tablespace none of whose datafiles grows by itself keeps reclaim_margin_mb free.** The compaction trims each datafile to the end of its last extent, so such a tablespace would be left with no free space, and the application's next insert there would fail. At RESIZE its datafiles grow back by up to that margin, never above their size at the start of the run (R6). FILE_NO_GROWTH is now one warning per such tablespace that still has less than the margin. Before, it warned for every datafile that is not autoextensible, also where another datafile of the tablespace can grow.
- **Lab 2, probe G** runs in tablespace EPF_RT2_PRB, created for it: one 200 MB datafile, wholly free, that cannot grow, as during a compaction. T18G requires "2 extents: 2 x 64 MB" there. **Probe H** repeats the move in EPF_RT2_SIDE and is recorded only. Both report the extents by size, where they lie, and the size of the datafiles.

Checked offline: the package scans; T00 and T01 with the fake sqlplus (0.7.9); the wrapper checks (32).

Version 0.7.9: install again.

How to test (R10 on the status page): pull, install 0.7.9, run `--only T18A,T18B,T18F,T18G,T19` (6 passed; in T18G, R8 "5 of 5 moved", probe G "2 extents: 2 x 64 MB", and the note of probe H). EPF_RT2_SIDE should end lower than 42.9 MB, and EPF_RT2_DATA a little above 43 MB. Then compact DATA a fourth time, as in R9 (nothing changed for DATA since 0.7.8), and collect with R10's command.

## 2026-10-07 - R8: T18G failed on 0.7.7; a table too small for 64 MB extents moves as before, and the compaction trims to the end of the highest extent (0.7.8)

What R8's tests showed (5 passed, T18G failed):
- **Probe G passed.** A table moved with INITIAL 128 MB got 2 extents of 64 MB, which the 64 MB path relies on.
- **T18G failed.** RT2_IOT did not move (STAYED: below where both datafiles of EPF_RT2_DATA stopped), so its index kept INITIAL 8 MB and no INITIAL_RESET named it. R8 reported "4 of 5 moved".
  - EPF_RT2_SIDE (system-allocated, 52 MB): RT2_BLOB (about 4 MB) came back to the top after its move. 0.7.7 sent every table that came back to the 64 MB path, which needs a wholly free 64 MB stretch, and a 52 MB file never has one. The file was done at 42.7 MB with 20.8 MB free; 0.7.6 would have moved it again.
  - EPF_RT2_DATA (uniform 1 MB, two files): RT2_TOP's copy came back to the top of file 6 by taking its last free MB (47 to 48 MB). trim_ts resized a file to its highest block plus one block, rounded up to a MB. When the highest extent ends on a MB boundary, that keeps a free MB at the top of the file, and the next copy takes it (in a system-allocated file it is a partly used stretch, which Oracle fills first: SIDE stayed at 52 MB with its highest block at 51 MB). RT2_TOP also came out larger (16 to 22 MB), needed 23 MB with 21 MB free, and both files were done.
  - Why 0.7.6 passed: RT2_IOT moved as a room maker. Its overflow was then estimated below its INITIAL, which showed free space inside it on paper. 0.7.7 corrected that estimate.

Changes (0.7.8):
- **Extents of 64 MB only for segments large enough for them (chunked).** The INITIAL for that (the size rounded up to 64 MB) must not be oversized: at most a quarter above the size, so from about 51 MB. A table that came back with no segment that large moves as in 0.7.6: room is made for it, and it moves again when it fits in the free space (at most reclaim_unit_moves returns). The same rule applies to each LOB segment (was: 64 MB or more). The check against the whole 64 MB stretches counts only the segments that move that way (large_plan).
- **The compaction trims each datafile to the end of its highest extent** (FREEZE_FILES, after each move, other tablespaces of the run): no free space is left at the top for the next copy. The final RESIZE still adds reclaim_margin_mb, rounded up to a MB.
- **T18G** checks that every table of the lab moved (R8 "5 of 5 moved", V15).

Checked offline: the package scans; T00 and T01 with the fake sqlplus (0.7.8); the wrapper checks (32).

Version 0.7.8: install again.

How to test (R9 on the status page): pull, install 0.7.8, run `--only T18A,T18B,T18F,T18G,T19` (6 passed; in T18G, R8 "5 of 5 moved" and probe G ok). Then compact DATA a fourth time: DIRECTORY_DISPATCHING (688 MB) moves with 64 MB extents from its first move, and DATA should end well below 11.1 GB (its segments are 7.5 GB). Collect with R9's command.

## 2026-10-07 - R7's placement data: a copy fills partly used stretches first; tables that come back move with 64 MB extents (0.7.7)

What R7's collect showed:
- **AUDIT_ARCHIVE confirmed.** The dry run R-000084 listed it with INITIAL 783 MB and about 0 B needed. It also listed AUDIT_ARCHIVE_PK (152 MB) and 6 small segments, 950 MB in all. R-000085's rebuild reset the indexes. In R-000121 AUDIT_ARCHIVE moved first to make room, its INITIAL was reset, and it went from 783.2 MB to 256 KB.
- **The IOT overflow probe (A to F).** Every form recreated the overflow segment, and none changed its INITIAL: a MOVE ignores STORAGE for the overflow. The reclaim no longer asks for it, and plans the overflow's copy at its INITIAL; the assessment no longer lists it.
- **Where the copies of DIRECTORY_DISPATCHING went (MOVE_PLACEMENT):**
  - Move 1: the table was at 10.0-11.5 GB; its copy spread from 3.3 GB (the lowest free stretch) to 11.5 GB.
  - Move 2: the copy went entirely to 10.0-11.1 GB, the holes its first copy left, although 6.2 GB were free and the lowest stretch was at 3.7 GB.
  - Move 3: from 1.7 GB (the lowest) to 11.1 GB again.
  - Now: 16 x 64 KB at 10.0 GB, 64 x 1 MB at 10.1-11.1 GB, 76 x 8 MB from 1.7 to 11.35 GB. The free space (3.6 GB) lies between 6 and 10 GB, 3.3 GB of it in stretches of 64 MB or more.
- **Conclusion.** Oracle places the extents of a growing segment (64 KB, 1 MB, 8 MB) in partly used stretches first, wherever they are, and breaks a wholly free stretch, the lowest, only when there is none. Near the top, the table's own extents and the released indexes leave partly used stretches, so each copy comes back. An extent of 64 MB fits only a wholly free stretch, and Oracle takes the lowest.

Changes (0.7.7):
- **A table whose copy came back to the top moves again with extents of 64 MB:** STORAGE (INITIAL <its size rounded up to 64 MB>). Oracle creates a segment with such an INITIAL as extents of 64 MB (documented; verified by the lab's probe G). The tables with free space inside them move first, until whole 64 MB stretches cover it. Otherwise its datafile is done there: no more ordinary moves that come back.
- **A table of 640 MB or more moves that way from its first move**, since it wastes at most a tenth. When the 64 MB stretches are short, or the statement fails, it moves as usual.
- Only for system-allocated extents. With uniform extents there is no size to choose, and the behavior is as in 0.7.6.
- An INITIAL that is a table's size rounded up to whole 64 MB extents (at most a quarter more) is not reported as oversized.
- MOVE_PLACEMENT also gives the free space in whole 64 MB stretches.
- The assessment's INITIAL query now reads DBA_SEGMENTS for the run's tablespaces first. R7's assessment took 1 min 19 s instead of 20 s, and the join with the whole inventory is the likely cause.
- **Lab 2:**
  - Probe G: a heap table moved with INITIAL 128 MB must come out as 2 extents of 64 MB; T18G checks it.
  - T18G no longer expects the IOT overflow's INITIAL to be reset.

Checked offline:
- The package scans found a PL/SQL BOOLEAN inside an UPDATE, which Oracle 19c would not compile; it is fixed.
- T00 and T01 pass with the fake sqlplus (0.7.7), and the wrapper checks pass.

Version 0.7.7: install again.

How to test (R8 on the status page): pull, install 0.7.7, run `--only T18A,T18B,T18F,T18G,T19` (6 passed; T18G's probe G: 2 extents of 64 MB). Then compact DATA a fourth time. DIRECTORY_DISPATCHING (688 MB) moves with 64 MB extents from its first move: its MOVE_PLACEMENT line should show extents of 64 MB, low in the file, and DATA should end well below 11.1 GB, since its segments are 7.5 GB. Collect with R8's command.

## 2026-10-07 - R7: room making freed 2.8 GB inside DATA, but the table at the top still comes back to the top

R7 on EPFPG781 (0.7.6):
- The suite (`--only T18A,T18B,T18F,T18G,T19`) passed: 6 of 6. Both labs pass with the room making on a return to the top.
- The compaction R-000121, 9 min 28 s:
  - DATA 11.5 GB to 11.1 GB: 421 MB given back. R1-R6, R8 and R9 PASS; R7 and P5 WARN. 969 indexes released (3.0 GB) and rebuilt. Assessment 1 min 19 s (20 s in R6, same code).
  - The room making worked: OPPAYMENTS.PAYMENT moved first, from 2.1 GB to 3.0 MB. Three tables moved in all, and the segments of DATA went from 10.3 GB to 7.5 GB; 3.5 GB is free inside the file.
  - The file still stopped at OPPAYMENTS.DIRECTORY_DISPATCHING, "moved 3 times; its copy held the top again after 3 of them". R7: 11.1 GB for 7.5 GB of segments.

So the explanation of R6 does not hold, or not alone: after PAYMENT's 2.1 GB of large extents became free, the copy still went to the top. Oracle does not place a copy in the lowest free space that fits. Each of its moves gives back about 140 MB (R6 and R7 alike), as if each copy took the holes that the previous copy, or other segments, left near the top. About 3.5 GB is held by this one 688 MB table.

Next: the MOVE_PLACEMENT lines of R-000121 give where each copy went against the free space it had, and a read-only query gives the layout of DATA now (the extents of DIRECTORY_DISPATCHING, the 30 highest extents, the free space per GB of the file in stretches of 8 MB and 64 MB). The fix follows from them. Two candidates:
- Move a table that came back to the top with extents too large for the holes it left: STORAGE (INITIAL) at its size rounded up to 64 MB gives 64 MB extents, which only take 64 MB stretches.
- Hold it outside the tablespace while the file shrinks under it.

## 2026-10-07 - R6: a second compaction of DATA stops at its first table; room made when a copy comes back to the top (0.7.6)

R6 on EPFPG781 (0.7.5):
- The suite (`--only T18G,T19`) passed: 3 of 3. T18G now names the queue table as such.
- The dry run R-000084: DATA 11.9 GB, 10.5 GB of segments, forecast 7.0 GB; 12 tables with free space inside them would move first to make room. The only pins are OP.WEB_RAPPORT and OP.PLAN_TABLE (LONG), low in the file.
- The compaction R-000085, in 5 min 11 s:
  - DATA 11.9 GB to 11.5 GB: 443 MB given back. R1-R6, R8 and R9 PASS. 969 indexes released and rebuilt; 5 accounts locked 4.5 minutes, then restored.
  - R7 WARN: 11.5 GB for 10.3 GB of segments.
  - The file stopped at its first table. OPPAYMENTS.DIRECTORY_DISPATCHING moved 3 times, and each copy came back to the top: "moved 3 times; its copy held the top again after 3 of them". The 12 tables of the forecast never moved.

Why the copy comes back:
- With system-allocated extents, a segment grows in 64 KB, then 1 MB, then 8 MB extents. Set R's copy of DIRECTORY_DISPATCHING was exactly 688 MB = 16 x 64 KB + 63 x 1 MB + 78 x 8 MB.
- An 8 MB extent takes only a free stretch of 8 MB. Oracle does not use the smaller gaps for it (Jonathan Lewis, "Shrink Tablespace", 2014).
- The released indexes and the earlier moves leave mostly small gaps low in the file. So 4.6 GB free below the top did not take a 688 MB copy lower: its extents went to the 8 MB stretches near the top.
- The engine only moved tables with free space inside them first (room making) when the table at the top did not fit, counted in bytes; here it fitted.

Changes (0.7.6):
- **Room made when a copy comes back.** When the table at the top moved already and holds the top again, the tables with the most free space inside them move first, until the free space has grown by what the table needs; then it moves again. The segments those tables leave are 8 MB and 64 MB stretches, where such a copy can go. Each table moves at most once this way, and the limits stay: 3 returns to the top, 10 moves.
- **MOVE_PLACEMENT**, one line per move in console.log. It gives where the unit's segments were and where the copy went (size, extents and their sizes, lowest and highest position), and the free space before the move: in all, in stretches of 8 MB or more, and where the lowest of those starts. The next compaction shows where Oracle put each copy instead of my inferring it.

Checked offline: the package scans find nothing; T00 and T01 pass with the fake sqlplus (0.7.6); the wrapper checks pass (32).

Version 0.7.6: install again.

How to test (R7 on the status page): first collect R6's logs: the dry run, the compaction, and T18G's probe lines. Then pull, install 0.7.6, and run `--only T18A,T18B,T18F,T18G,T19` (6 passed) for the labs with the new room making. Then compact DATA a third time and collect: DIRECTORY_DISPATCHING is still at the top, so the run shows whether moving the tables with free space inside them first lets its copy go lower.

## 2026-10-07 - R5 suite on 0.7.4: 7 of 8; the queue table's reason and the IOT overflow's INITIAL (0.7.5)

R5's suite on EPFPG781 (`--only T18A,T18B,T18C,T18D,T18F,T18G,T19`): 7 of 8 passed.
- 0.7.4 compiled. The first lab passed unchanged on it: T18A to T18D, T18F and T19.
- T18G, the second lab, failed 2 of its checks. Everything else in it held on Oracle:
  - QUOTA was not met in the dry run while the owner was above its quota, and was met once it was raised.
  - The compaction moved tables across three tablespaces and two datafiles with uniform extents, the compressed table included.
  - INITIAL 64 KB was set for the table, the IOT's index, the SECUREFILE LOB (so Oracle creates a SECUREFILE segment with its INITIAL), the BASICFILE LOB and the rebuilt index.
  - R1-R4 and R9 PASS, the lab as before, the datafiles smaller.

The two failures:
- **The queue table's reason.** RT2_QT stayed where it was, but its reason was "object-type column": a queue table has a SYS.ANYDATA column (USER_PROP), and that check came first. Fix: a table an Oracle feature maintains is named as such first.
- **The IOT overflow kept its INITIAL of 8 MB.** The move's statement asked for it: INITIAL_RESET named "overflow 8 MB", so `OVERFLOW TABLESPACE ... STORAGE (INITIAL 65536)` was in it, and Oracle ran it without error. Two explanations fit: Oracle ignores STORAGE in the OVERFLOW part of a MOVE, or the overflow segment was not created again.
  - The engine now checks, after every move and rebuild, the INITIAL of each segment it asked 64 KB for. When Oracle kept one, it says so (event INITIAL_KEPT, and in the table's Detail) instead of implying it was set.
  - The second lab has a new mode PROBE, run by T18G after its compaction. It tries six forms of ALTER TABLE ... MOVE on a small IOT with INITIAL 4 MB on both segments. For each, it records whether the statement ran, whether the overflow segment was created again (its data object id), and the INITIAL of both segments before and after. The engine will use the form that works, if one does.
  - T18G now passes a segment that kept its INITIAL only when the run reported it (INITIAL_KEPT). It logs the probe's results as notes.

Checked offline: the package scans find nothing; T00 and T01 pass with the fake sqlplus (0.7.5); the wrapper checks pass (32).

Version 0.7.5: install again.

How to test: on EPFPG781, pull, then `src\bin\epf_purge.bat install --tns EPFPG781`, then `src\tests\e2e\run_tests.bat --only T18G,T19`. Expect 3 passed (T01 always runs); send the `note probe` lines of T18G. Then R5's dry run and compaction of DATA as before, if not run yet.

## 2026-10-07 - Reclaim hardened for other databases; second lab layout (0.7.4)

Why: every reclaim so far ran on one layout. That is EPFPG781 and a lab built like it: one bigfile tablespace, autoallocate extents, indexes and LOBs beside their tables. The next source is the same Oracle version and the same application (an older version, fewer tables), from another client whose DBA may have laid it out differently. I audited the whole reclaim engine for anything that worked only because of this layout and found six gaps. None of them occurred on EPFPG781.

Changes (engine, 0.7.4):
- **Space quotas: new requirement QUOTA, blocking.**
  - A move or a rebuild writes the segment again in the space quota of its owner, also when SYS runs it. An owner without a quota on the tablespace, or above it, is refused the space (ORA-01950, ORA-01536). A released index that cannot be rebuilt would stay unusable.
  - So the compaction does not start, and QUOTA cannot be confirmed with `--confirm`: the DBA gives the owner a quota (`ALTER USER <owner> QUOTA UNLIMITED ON <tablespace>`).
  - An owner with a limited quota and room is MET. A table larger than that room stays where it is (MOVE_NO_QUOTA, a warning like MOVE_NO_ROOM) instead of failing the run.
- **Queue tables, Oracle Text and spatial tables.**
  - These now stay where they are, with the reason, as the queue table itself already did: the tables Oracle keeps for a queue table (`AQ$_<queue table>_*`), the tables of an Oracle Text index (`DR$...`) and those of a spatial index (`MDRT_...$`).
  - Their indexes are left as found (not released). Before, they were moved and their indexes released like any other. Oracle maintains these objects and may refuse DDL on them, so the release step could have failed mid-run.
  - Whether an owner has queue tables or domain indexes at all is read once per run, so an application without them costs the assessment two queries per owner.
- **A LOB or IOT overflow segment in another tablespace of the run.** A move writes the table's segments again in every tablespace that holds them, but free space was checked only in the tablespace being compacted. Now, before a move, each other tablespace of the run that is short grows within its room (never above its size at the start), and it is resized down again after the move.
- **Several datafiles in one tablespace.** A copy that lands at the top of another datafile of the tablespace now counts as a return to the top (setting reclaim_unit_moves), as a copy at the top of the same file did.
- **INITIAL in the dry run.** The assessment lists the segments that move or are rebuilt with an INITIAL larger than they need: event INITIAL_OVERSIZED, with their count, the total and the five largest, and one INITIAL_SEGMENT line in console.log for each of the 50 largest. On EPFPG781 it should name OPPAYMENTS.AUDIT_ARCHIVE (INITIAL 783 MB), which confirms the cause found in set R without a separate query.
- **An index's INITIAL** is now judged by its optimizer statistics (leaf blocks) when no purge has measured it. Before, its estimate was its size, so an index whose INITIAL was its size at export was rebuilt at that size.
- **Grant:** EPFPG now gets DBA_SYS_PRIVS at install; QUOTA reads it. Without the grant the package would not compile.

Wrapper: when QUOTA is not met, the reclaim stops and says what the DBA does. The dry run's "Next" line no longer offers `--confirm` for it.

Second lab layout, src/tests/verify/reclaim_lab2.sql, with test T18G. Every new path, and the 0.7.3 paths that set R did not reach, now runs on Oracle before a new source does:
- EPF_RT2_DATA has two datafiles with uniform 1 MB extents; the second is not autoextensible. EPF_RT2_INDX holds the indexes (uniform 256 KB). EPF_RT2_SIDE holds the LOB segments and an IOT overflow (autoallocate).
- Low in the files are segments that stay: a LONG table, and a queue table with its internal tables.
- Each table that moves has an INITIAL larger than it needs, one of each kind: a compressed table (BASIC) with its primary key index, an IOT with its overflow, a SECUREFILE LOB (CACHE), and a BASICFILE LOB (PCTVERSION 0).
- The lab writes the space a purge would have measured in the LOB and overflow segments (EPF_SPACE_USAGE, run 0); the rows are removed with the lab.
- Its owner starts above its quota on EPF_RT2_DATA.
- T18G:
  - The dry run finds QUOTA not met and lists the oversized INITIALs. The LONG table and the queue table stay, and nothing changes.
  - The lab raises the quota, and the compaction runs: R1-R4 and R9 PASS; R5-R8 PASS or WARN.
  - Each kind of segment has its INITIAL reset, shown by the events and by the dictionary afterwards. The lab is as before (rows, indexes, LOB attributes, account, growth settings), the datafiles are smaller, and nothing is pending.
  - The lab removes itself. T18F removes both labs.

Checked offline:
- The package scans find nothing.
- Every dictionary view the reclaim package reads is granted; DBA_SYS_PRIVS was missing.
- T00 and T01 pass with the fake sqlplus (now 0.7.4).
- The wrapper checks pass: 29, of which 4 are new (QUOTA stops without a question).

Version 0.7.4: install again.

How to test (R5 on the status page): on EPFPG781, pull, then `src\bin\epf_purge.bat install --tns EPFPG781`, then `src\tests\e2e\run_tests.bat --only T18A,T18B,T18C,T18D,T18F,T18G,T19`. Expect 8 passed (T01 always runs). Then the dry run `src\bin\epf_purge.bat reclaim --tns EPFPG781 --dry-run --non-interactive`: INITIAL_OVERSIZED should name AUDIT_ARCHIVE, and QUOTA should be MET. Then the compaction, `src\bin\epf_purge.bat reclaim --tns EPFPG781 --non-interactive --yes`.

## 2026-10-07 - Set R: DATA 41.7 GB -> 11.9 GB; INITIAL, the move limit and the report's reason fixed (0.7.3)

Set R on EPFPG781 (0.7.2), the copy H5 purged. R0 (install 0.7.2, then T18C, T18D, T18F and T19) and R1 (the assessment: start 41.7 GB, forecast 8.9 GB) passed. R2, the compaction R-000059, took 6 min 25 s in all:
- DATA went from 41.7 GB to 11.9 GB: 29.8 GB given back, status COMPACTED, verdict PASS WITH WARNINGS.
- R1 969/969 indexes usable and identical (10.4 GB of indexes rebuilt as 3.2 GB); R2 2,553 constraints; R3 no new invalid object; R4 688/688 row counts; R5 717/717 table and LOB attributes; R6 never above the start size, autoextend YES (32 TB) before and after; R9 KDCM, OP, OPPAYMENTS, OPREPORTS and SUPER locked for 5.5 minutes and restored.
- Steps: assessment 23 s, baseline 10 s, release 9 s, compaction 37 s (6 tables moved), index rebuilds 4 min 26 s, verify 10 s.
- R7 WARN (11.9 GB for 10.5 GB of segments) and P5 WARN (PUBLIC_DML: 15 write grants to PUBLIC on tables in scope).

What the events and the dictionary showed:
- **AUDIT_ARCHIVE came back as 783 MB.** It had 0.3 MB of table and 3.2 MB of LOB, and the row counts did not change, yet the moved table segment is exactly 783 MB. A move or rebuild creates the segment again with its INITIAL storage, allocated at once. An import typically leaves the source size there.
  - Its estimate was 64 KB. The move fitted, but a table that comes back at its old size gives nothing back and needs room nobody planned for.
  - Fix: a move or rebuild sets INITIAL 64 KB on a segment whose INITIAL is larger than it needs (above its estimate and 1 MB). This applies to the table or IOT index, the overflow, each LOB segment, and each rebuilt index. Event INITIAL_RESET, and the table's Detail in TABLES says what it was.
  - The data and every compared attribute stay as they were; only the stored INITIAL changes.
- **The file stopped at the move limit, not at a pin.** DIRECTORY_DISPATCHING held the top again after its first move. Its second and third moves did leave the top: 21.8 -> 13.8 GB. It was back at the top only after three other tables had moved off it, and FILE_DONE stopped the file: "moved 3 times, still at the top". The limit counted every move.
  - Fix: `reclaim_unit_moves` (3) now counts only the moves that leave a table's copy at the top again; a table moves 10 times at most.
- **R7 blamed the wrong segment.** It named OP.WEB_RAPPORT, the LONG table that stays, which ends at 125.7 MB. R8 said "682 below a segment that stays".
  - Fix: where each datafile stopped and why is kept with its tablespace (new column EPF_RECLAIM_TS.stop_detail), shown under TABLESPACES as "stopped:", and used by R7.
  - Tables not reached now read "not moved: below where its datafile stopped (FILE_DONE)", and R8 "below where the datafile stopped".
- **PUBLIC_DML** now names the tables (up to 10) besides the count.
- Lab: RT_FAT is created with INITIAL 40 MB, more than it needs after the deletes; T18B asserts INITIAL_RESET for it.

Checked offline: the package scans find nothing (declarations, order, aggregates over aliases, private functions in SQL).

Version 0.7.3 (packages and a new column): install again.

How to test: on EPFPG781 as set R left it, install 0.7.3, then `run_tests.bat --only T18A,T18B,T18C,T18D,T18F,T19`. Then a second compaction of DATA, which is a compaction of an already compacted tablespace. DIRECTORY_DISPATCHING may move again, and at most the 1.4 GB of free space inside the file can come back. AUDIT_ARCHIVE, now at about 4.3 GB in the file, moves only if the compaction reaches it or uses it to make room; with its INITIAL of 783 MB it then shows INITIAL_RESET. The status page has it as R5.

## 2026-10-06 - H8 complete; a worker whose client is gone is waited for, or its sqlplus ended (0.7.2)

The rerun of T18A and T18B (`--only T18A,T18B,T18F,T19`) passed: 5 of 5, and no connection hung this time. With the first H8 run, all 10 tests of H8 passed on 0.7.1.
- R-000051 (T18A's assessment): PASS.
- R-000052 (T18B's first reclaim): refused by the recycle-bin requirement, FAILED, exit 1, nothing changed.
- R-000053 (T18B's compaction): SUCCESS, verdict PASS, exit 0. No warning: RT_TOP, which holds the top again after its move, no longer raises MOVE_NO_ROOM.

Why more before set R: the compaction and its restore path are one database call, several hours on DATA. If the network drops the worker's connection, the call goes on in the database until it ends. Many firewalls drop a connection idle for an hour, and a worker's connection is idle during its call. Two cases:
- The client is told (the connection is reset): sqlplus ends at once, and the wrapper ran its restore right away, beside the compaction still running in the database. The restore could unlock the accounts early, or mark an index rebuilt that a later move made unusable again.
- The client is not told: sqlplus waits forever, so the wrapper never ends the run.

Changes:
- Engine (0.7.2): a COMPACT or RESTORE run first waits while another reclaim session is still active in the database: SYS, module EPF, a run's client identifier, status ACTIVE.
  - Only a worker whose client is gone can be one: two runs cannot run together, and a killed session is not ACTIVE.
  - Event WORKER_RUNNING (WARN) when found, then every 10 minutes; WORKER_ENDED when it ends.
  - A stop request ends the wait with ORA-20162, before any change.
- Wrapper: once the worker of a run has been seen in the heartbeat, 300 polls in a row (about 10 minutes) without it, while its sqlplus still waits, mean that its database call has ended. The wrapper ends that sqlplus with a message, and the run goes on as for a worker that ended early: a reclaim restores in the same run, a purge ends FAILED with undo tuning restored.
- Offline, with the fake sqlplus extended: a worker that leaves the heartbeat while its sqlplus still waits is ended after the limit (3 polls in a test copy), and the run ends FAILED with exit 1. All earlier wrapper paths still pass (preflight questions, stopped preflight, connection retry, wizard purge). The engine scans find nothing.
- PLAN 7.8 and 8.1. The DBA can also keep such connections alive with `SQLNET.EXPIRE_TIME` in the server's sqlnet.ora.

Version 0.7.2: the engine changed, so install again.

Suite: T01 now also reads the installed tool version. When the session does not include T03 (the install), a version other than the scripts' fails T01, and the rest is skipped with the install command in the message. Found when R0 ran without its install: every wrapper command of T18C and T18D stopped with "The database has tool version 0.7.1 and these scripts are version 0.7.2" and "Aborted." (exit 3). Offline: the matching version passes; 0.7.1 fails T01 and skips the rest.

How to test: pull, install 0.7.2 on EPFPG781, then `run_tests.bat --only T18C,T18D,T18F,T19`. These are the compaction start, the stop, and the kill with its restore, all through the new wait. Pass: 5 passed. Then set R.

## 2026-10-06 - Set H, H7 and H8: 0.7.1 on Oracle; a connection that never completes is retried (wrapper and suite)

H7 passed: 0.7.1 installed on EPFPG781 (the changed reclaim package compiled without error), `backup_max_age_h` back to 24.

H8 (`--only T00,T10B,T18A,T18B,T18C,T18D,T18E,T18F,T19`): 8 of 10 passed.
- Confirmed on Oracle:
  - T10B: a preflight stopped at its questions ends STOPPED and closes its plan; the restore of `backup_max_age_h` is read back.
  - T18C: the compaction paused after the first move (TEST_PAUSE), and the stop arrived during the pause. The run ended STOPPED with R1-R4 and R9 PASS and the lab as before. The confirmed recycle-bin object was purged (RECYCLEBIN_PURGED).
  - T18D: the worker was killed during the pause and restored in the same run; `reclaim --restore` then found nothing.
  - T00, T18E, T18F, T19.
- T18A: the lab SETUP hung for its 30 minutes. The lab was never created, so T18A's assessment and T18B's compaction found no tablespace (ORA-20161). The rerun (`--only T18A,T18B,T18F,T19`) hung at the same place.
- The new hang report showed the cause. The SETUP's sqlplus process was running, but the database had no session from this machine: the query of the sessions of this machine and of the runs returned nothing. The report's own connection worked in 17 s.
  - The connection never completed. The cause lies in the network, the listener or the logon, not in the SQL.
  - T08's hang in H5 (no line before "Connected to") fits the same pattern.

Fix, in the wrapper and in the suite: a session is first sent only the CONNECT line and a PROMPT marker. sqlplus prints the marker once the CONNECT has finished, successful or not, and only then does the script, query or monitor command follow. Without the marker within `CONNECT_TIMEOUT_S` (default 120 s), the session is ended and started again, 3 attempts in all; nothing had been sent to it. After 3 attempts the step fails with "The database did not answer the connection ... (3 attempts of N s)".
- Wrapper: Start-Session, used by the connection test, by every script (Invoke-SqlScript) and by the monitor (Open-Monitor). Open-Run ends with a message when the monitor cannot connect, and Reset-Monitor counts it as a failed attempt. Configuration key `CONNECT_TIMEOUT_S` (10-3600).
- Suite: Invoke-Sql connects the same way, with `CONNECT_TIMEOUT_S` in test.conf, which it also passes to the wrapper. The hang report uses one attempt and adds the total of user sessions, the sessions of any sqlplus, and tnsping when the client has it. The lab SETUP is limited to 10 minutes; it takes under one.
- Offline, with the fake sqlplus extended so that the first CONNECT, or every CONNECT, hangs:
  - the wrapper retries after the limit and goes on, or stops after 3 attempts with the message and exit 1;
  - the suite's T01 retries after its limit and passes;
  - the three earlier wrapper paths and the wizard's purge still run end to end, and T00 passes on both scripts.

No database change: the installed 0.7.1 stays, so a pull is enough.

How to test: pull (no install), then `run_tests.bat --only T18A,T18B,T18F,T19`. Pass: 5 passed. If a connection hangs, the log shows `---- no answer to the connection within 120 s`, the report, then `---- connection attempt 2 of 3`, and the test goes on.

## 2026-10-06 - Set H, H5: 17 of 29 passed; every cause found and fixed (0.7.1)

H4 passed: other options with and without prompts, start over (`--new`), `plan --close`.

H5, the full suite on EPFPG781 (2:47:49): 17 passed, 12 failed. Each failure was traced in the log (`.local/h5.log`, the failed sections of test.log).

- **T08B, T11, T16 (then T12, T17, T18): a wrapper function lost in 0.6.0.**
  - `Get-BatchDefault` calls `Get-BatchForLog` when `--redo-logs` is chosen; 0.6.0 removed it together with `Use-SavedChoices`.
  - The preflight's batch-size question threw, and the run ended FAILED without an error event; its plan closed ("its preflight ... ended FAILED"). The exception text has no "error" in it, so it is not in the extract.
  - T12 (status STOPPED) needed T11's stop; T17 and T18 report the latest run, T16's failed preflight (exit 1).
  - Fix: the function is back. New test T00 parses the wrapper and the suite and fails on any command that is neither defined nor known to PowerShell; this was the only one.
  - Offline, with the fake sqlplus extended for the questions: the preflight with every requirement met asks only the batch size ("Recommended batch size with 1 GB online logs: 530"), saves the choices (choices.sql `40 200 Y Y NONE -`) and ends READY; the wizard's purge goes through CHOICES, REVIEW, REDO LOGS, PREFLIGHT with the choices, UNDO TUNING, PURGE and the restore.
- **T10B: a preflight stopped at its questions kept its plan.** It ended WARNING (exit 3), so its plan stayed READY. A preflight that does not end leaves no plan to follow (PLAN 6.10). Fix: it ends STOPPED, which closes the plan it made. Offline: finish.sql gets STOPPED, exit 3.
- **T10B left `backup_max_age_h` at 0 on EPFPG781.**
  - Its restore went to sqlplus as one line, `UPDATE ...; COMMIT; EXIT`. In PowerShell the comma binds tighter than `+`, so `"..." + $setting + "...", 'COMMIT;', 'EXIT'` is one string. sqlplus never ran the UPDATE, and the step passed on exit code 0. The reclaim reports of T18A-T18D show the effect ("an RMAN backup within 0 hours").
  - Fix: parentheses, and the value is read back and checked. T00 also fails on any `+` or `-` with a list on its right (none left).
  - EPFPG781 needs the setting back by hand: H7 in the status page.
- **T18A, T18B: recycle-bin objects not found.**
  - The requirement counted inventory rows marked RECYCLEBIN. DBA_EXTENTS does not list the segments of recycle-bin objects (DBA_FREE_SPACE counts them as free). The lab's dropped table, 10 MB, was missing from the inventory: the assessment's segments are 285.6 MB, the lab's DBA_SEGMENTS 295.6 MB.
  - So RECYCLEBIN was MET, and T18B's gate run compacted instead of stopping.
  - Fix: counted from DBA_RECYCLEBIN. With `--confirm RECYCLEBIN`, FREEZE_FILES now purges them (PURGE TABLESPACE, event RECYCLEBIN_PURGED) before the files stop growing. Oracle would purge them anyway once the files cannot grow, and a segment that DBA_EXTENTS does not show could keep a file from shrinking.
- **T18B, T18C, T18D: a table that had moved was reported as not moved, with a warning.**
  - Every compaction of the lab did the same. RT_FAT moved to make room (72 -> 14 MB). Then RT_TOP moved (80 -> 103 MB) and the file went from 342 to 260 MB.
  - RT_TOP's copy came out larger and took nearly all the free space below, so it held the top again. It was picked again (up to `reclaim_unit_moves` moves), did not fit (ORA-01652), and that failure overwrote MOVED with NO_ROOM. The result: R8 "1 of 6 moved ... RT_TOP no room", a MOVE_NO_ROOM warning, verdict PASS WITH WARNINGS, although the run did what it could.
  - Fix: a table that moved already moves again only when it fits in the free space as it is. The file does not grow for it: that room lies above it. Otherwise its file is done (FILE_DONE "moved; about ... needed to move it lower"). If such a move fails anyway, the table keeps MOVED, with the error in last_ora and MOVE_AGAIN_NOT_DONE (INFO; WARN for an error other than space).
- **A stop requested while tables moved to make room was honored only after the next move.** Found while reading the loop for T18C: after the room-making moves, the table at the top moved before the next stop check. In production that table can be large. Fix: a stop check right before every move.
- **T18C, T18D: the stop and the kill arrived after the run had ended.** The lab's compaction takes about 3 s. A stop through the wrapper took 32 s and the SYS kill 16 s (a connection takes about 15 s on this network). The stop ended with ORA-20124 "No run is active", and the kill found no session. Fix, for the tests only:
  - Setting `reclaim_test_pause_s` makes the next compaction pause after each table that moves (event TEST_PAUSE), until a stop is requested or the time is up.
  - The compaction sets it back to 0 when it reads it, and every install resets it.
  - T18C and T18D set 120 s, act on the TEST_PAUSE line, and check that the setting is back to 0.
- **T08 (30 min) and T18C's last lab check (15 min) hung without one line of output.**
  - T08's wrapper printed nothing, not even "Connected to": it hung in its first connection, the connection test, which had no time limit. The next test connected at once.
  - The lab check is a sqlplus SYS session that prints at the end of its block, so where it waited is unknown.
  - The cause is not in the log. The changes below make sure a hang cannot stay silent, and that the next one explains itself:
    - The wrapper's connection test now waits at most 120 s. Then it tries once more, then ends with exit 1 and "The database did not answer the connection".
    - On any timeout, the suite first logs the processes the step started, and what the database sessions of this machine and of the runs are doing (event, wait, blocker, SQL), from a separate SYS session.
    - The lab check now times out after 5 minutes (it takes seconds) and fails a check. It is then tried once more, so the comparisons after it still run.

Also seen, not a failure: T18D's lab check found the file at 268 MB, after the run ended it at 260 MB. That is one 8 MB extension (the file's NEXT) once autoextend was back on, not made by the tool; probably Oracle's space preallocation after the moves. R6 measures at the end of the run.

Checked offline: both scripts parse, and every command they call is defined. The PL/SQL scans of the engine found nothing: undeclared names, calls before definition, aggregates over aliases, private functions in SQL. The wrapper's unit checks pass (25, with three new ones for the batch size for 1 GB logs). The three wrapper paths above run end to end with the fake sqlplus.

Version 0.7.1: the engine, the settings and the wrapper changed; install again.

How to test: H7 and set R in the status page. On EPFPG781 as H5 left it, install 0.7.1 and set `backup_max_age_h` back to 24. Then run the tests that need no purge data: `run_tests.bat --only T00,T10B,T18A,T18B,T18C,T18D,T18E,T18F,T19`. The purge flows (T08, T08B, T11, T12, T16, T17, T18) need data: they run in the full suite on a refreshed copy after set R.

## 2026-10-06 - Set H, H1: first compile of 0.7.0 failed on EPF_RECLAIM; fixed

- H1 on EPFPG781: the tables, registry, settings and 92 grants installed; every package compiled except the body of EPF_RECLAIM.
  - The error: PLS-00103 at line 1451, `Encountered the symbol "CURSOR"`.
  - The cause: the shared fingerprint cursor `c_fingerprint` was declared between two procedures. In a package body every declaration must come before the first subprogram.
- Fix: the cursor moved to the package-level declarations, after the globals. Nothing else changed; still 0.7.0.
- A syntax error stops the compile before the semantic checks, so three more checks ran here on the three changed packages. Each first caught a planted error.
  - Every l_ and p_ name a subprogram uses is declared in it, and every named argument (`p_x =>`) is a parameter of some package.
  - No private subprogram is called before its definition.
  - No package-level declaration comes after the first subprogram, in any package.
  - Result: nothing found.

How to test: H1 again (`git pull`, then `src\bin\epf_purge.bat install --tns $db`). The install is safe to re-run. Pass if it ends with `EPFPG objects valid, tool version 0.7.0`.

H1 again: the body now parses, and the compile's semantic checks found one statement, in `report_ts` (the PIN events of the assessment).
- ORA-00935 `group function is nested too deeply` at `ORDER BY MAX(top_block)`. In ORDER BY, Oracle takes `top_block` as the select-list alias `MAX(top_block) AS top_block`, so the expression became MAX(MAX(...)). PLS-00364 on the loop variable followed from it.
- Fix: `ORDER BY top_block DESC, owner, object_name` (the alias).
- A scan of every package body for an aggregate in ORDER BY or HAVING over a name that is also a select-list alias found no other case.
- The compiler listed no other error in the body.

H2 passed (LOGS, retention 400, EPFPG781):
- R-000001 planned one step: 1,659,402 roots, 1.7 GB redo, NOARCHIVELOG.
- R-000002 with `--max-redo 300M` checked the same plan again (CHANGES SINCE: no change) and split it into 7 steps, 2018-06-01 to 2025-09-01, each at most 299.6 MB. The steps add up to the same roots and redo.
- P5 WARN only for UNDO_ESTIMATE (confirmed with `--confirm UNDO`).
- The last lines: R-000001 `Next    epf_purge.bat purge follows these choices (plan P-000001)`; R-000002 `Next    epf_purge.bat purge carries out step 1 of 7 of plan P-000001 (rows before 2018-06-01)`. The Choices line of R-000001 omits `batch 1000` (default batch, no option given); R-000002 takes it from the plan. Cosmetic.

H3 passed (menu):
- Rehearsal (menu 3): REVIEW `Plan          P-000001, rehearsal of step 1 of 7 (the plan ends with rows before 2025-09-01)`; report `This run: rehearsal of step 1, nothing changed`, plan still READY, 0 of 7 done.
- Step 1 (menu 1, R-000004): `PASS WITH WARNINGS (SUCCESS)`, exit 2; plan `IN_PROGRESS: 1 of 7 steps done, next: step 2, rows before 2021-09-01`; last line `Plan    P-000001: 1 of 7 steps done. Next: epf_purge.bat purge (step 2, rows before 2021-09-01)`.

## 2026-10-06 - Reclaim: compaction in place, with a hard limit on disk usage (0.7.0)

Why: a purge frees space inside the tables, but the datafiles keep their size. The reclaim gives that space back to the disk, keeps disk usage under control the whole time, and leaves every object as it found it.

Design decision: compaction in place replaces the tablespace swap of the plan (D3 revised; PLAN section 7).
- The swap, with the original file shrinking as the new one grows, was assessed. The original file can only shrink below the highest extent still in it. After years of growth, most segments have an extent near the top, so the two files together approach the original size plus all live data before the original shrinks. It also needs the drop, rename and path restore steps, each with its own failure modes.
- In place: the table holding the highest block of a datafile moves within its own tablespace into the free space below, the file is resized down to its new highest block, and so on down. A datafile never grows above its size at the start of the run (setting `reclaim_growth_mb`, default 0, allows a margin); there is no second tablespace, nothing to drop or rename.
- When the table at the top does not fit, tables with free space inside them (purged tables) move first: each lands compact and frees its old extents (MAKING_ROOM). Only then may the file grow within its limit.
- A segment that cannot move (LONG column, partitioned, cluster, queue or MV table, Oracle-maintained owner, recycle bin, disabled function-based index...) is a pin: the file cannot shrink below it, and the report names it with its position and reason.

Engine (new package `epf_reclaim`, invoker rights, run by SYS through `src/sql/run/reclaim.sql`):
- Modes ASSESS (a dry run: read-only), COMPACT, RESTORE.
- COMPACT steps:
  - PREPARE restores what earlier reclaims left: accounts, datafile growth settings.
  - ASSESS: inventory of every segment from DBA_EXTENTS, units (a table with its LOB segments and IOT overflow), indexes, pins, forecast per tablespace (a simulation of the loop), accounts in scope, requirements.
  - The requirements gate: RECYCLEBIN, ARCHIVE (ARCHIVELOG only), TEMP are blocking unless confirmed; BACKUP is advice. A gate not passed changes nothing.
  - LOCK_ACCOUNTS: the owners of the tables in scope, accounts with DML on them (directly or through roles), owners of foreign keys to them, sessions holding locks on them. Sessions are disconnected POST_TRANSACTION, then IMMEDIATE after `disconnect_timeout_s`.
  - BASELINE, once the accounts are locked (no write changes the counts after it): a fingerprint of indexes, constraints, tables, LOB columns, invalid objects and row counts, and the datafiles.
  - RELEASE_INDEXES (UNUSABLE drops the segment), FREEZE_FILES (autoextend off for every target tablespace, recorded first), COMPACT per tablespace.
  - Restore path, always: REBUILD_INDEXES while the datafiles are still frozen (within their room; an index that does not fit is rebuilt after the growth settings are restored, a warning), RESTORE_FILES, RESIZE (highest block plus `reclaim_margin_mb`), RECOMPILE, VERIFY (fingerprint and row counts again, before the accounts are unlocked), UNLOCK_ACCOUNTS.
- Every change is recorded before it is made: EPF_INSTANCE_CHANGE (RECLAIM_DATAFILE), EPF_ACCOUNT_ACTION, EPF_RECLAIM_OBJECT. A stop is honored between tables; units not reached are SKIPPED.
- RESTORE restores everything a reclaim left pending: indexes still released (adopted from the run that released them), datafile settings, accounts. The wrapper runs it in the same run when the worker session of a compaction ends without its end marker (killed, connection lost); `epf_purge.bat reclaim --restore` runs it in a new run.
- Indexes rebuild with resumable space allocation only after the growth settings are restored (a frozen file would make a resumable rebuild wait for nothing).

Report and checks (`epf_report`):
- RECLAIM reports: TABLESPACES (start, segments, tables, indexes, pins, forecast, end, peak, given back, status), TABLES, INDEXES, SEGMENTS THAT STAY, ACCOUNTS, DATAFILES, REQUIREMENTS. Machine line EPF_RECLAIM_TS; manifest keys reclaim_mode, tablespaces, tablespace.<name>.
- Checks R1-R9 replace the swap's: R1 indexes usable and identical, R2 constraints, R3 no new invalid objects, R4 row counts, R5 table and LOB attributes, R6 datafiles within their start size and growth settings restored, R7 efficiency, R8 tables moved, R9 accounts restored. An assessment skips them; a restore run checks R1, R6, R9.
- `status` shows datafile growth stopped by a reclaim, indexes released and still unusable, and accounts still locked, each with `reclaim --restore`. Undo tuning counts only UNDO items now.
- A requirement that is not blocking shows "(advice)" for a reclaim; NOT_APPLICABLE shows as NOT APPLICABLE (was NOT MEASURED).

Wrapper:
- New action `reclaim`, with `--tablespaces`, `--dry-run` (the assessment), `--restore`, `--confirm ARCHIVE,TEMP,RECYCLEBIN`, `--yes`, and config keys RECLAIM_TABLESPACES and RECLAIM_CONFIRM. SYS password required.
- With prompts: the assessment first (its report), a question for each blocking requirement not met, the review, then "type yes".
- Menu entry "Reclaim disk space". Help updated.
- `--reclaim`, `--resume` and `--long-conversion` are still refused, each with its reason.

Other:
- History pruning keeps the runs whose reclaim left something pending: an account still locked, a released index still unusable. Before, it would have removed their records after `history_retention_days`.
- Settings: `reclaim_growth_mb` 0, `reclaim_margin_mb` 64, `reclaim_unit_moves` 3, `reclaim_row_counts` Y. `parallel_min_mb` and `resize_every_mb` removed (swap only).
- Tables: new EPF_RECLAIM_TS; EPF_RECLAIM_OBJECT, EPF_TS_INVENTORY and EPF_OBJECT_BASELINE extended (detail_after); EPF_RUN gains reclaim_mode and reclaim_scope.
- Grants on DBA_ROLES, DBA_ROLE_PRIVS, DBA_OBJECT_TABLES, DBA_QUEUE_TABLES, DBA_MVIEWS, DBA_MVIEW_LOGS, DBA_FLASHBACK_ARCHIVE_TABLES. `epf_purge.archive_room` is public.
- uninstall refuses while released indexes are still unusable (-20906); its messages point to `reclaim --restore`.
- e2e suite:
  - T18A-T18F on a scratch tablespace (`src/tests/verify/reclaim_lab.sql`): the assessment changes nothing; the requirement gate; the compaction with room making and R1-R9; a stop; a killed worker session restored in the same run, then `reclaim --restore`; the assessment of the application tablespaces (read-only); cleanup.
  - T07: reclaim usage errors. T12: the new status wording.
  - T19: no account left locked and no released index left unusable.
- Checked here: every file is ASCII. Both PowerShell scripts parse. 22 offline checks of the wrapper's reclaim functions pass (options, tablespace lists, machine lines, confirmations, report sections). A scan of the three changed packages finds no package-private function and no BOOLEAN in a SQL statement. The SQL is not compiled here: T03 and T04 compile it.

How to test (set R, on a refreshed copy; see the status page):
- R1: `.\src\tests\e2e\run_tests.bat --only T03,T04,T07,T18A,T18B,T18C,T18D,T18E,T18F,T19` (T01 runs too). It compiles 0.7.0, then runs the lab tests: all pass.
- R2: on the purged copy (after the full suite or the set R1 purges), `epf_purge.bat reclaim --dry-run`: read the TABLESPACES forecast, the pins and the accounts.
- R3: `epf_purge.bat reclaim` (prompts): the assessment, the questions, type yes. Then the report: R1-R9, datafiles start vs end, and `status` shows nothing pending.

## 2026-10-05 - Plan of smaller runs and its lifecycle (0.6.0, D19/D20 round 2)

Why: in ARCHIVELOG a purge whose redo does not fit the archive space cannot run at once. The preflight now plans it in smaller runs, and the purges carry out the plan step by step with the choices of its preflight.

- Every preflight records the plan of its scope (mode, depth, cutoff) in EPF_PLAN and EPF_PLAN_STEP (new step PLAN, after UNDO).
  - One run, or several when the archive space (ARCHIVELOG, ARCHIVE not confirmed) or the new `--max-redo SIZE` (such as 500M or 20G) cannot take the redo at once.
  - Steps follow the months of the root dates, older data first, with roots, rows, redo, archive need and deleting time per step. A month alone above the limit is a step of its own (`fits N`); the last step ends at the requested cutoff.
  - ARCHIVE counts as met (SMALLER_RUNS) when the plan has several runs that each fit.
- `purge` without `--retention`, `--cutoff`, `--mode` or `--depth` carries out the next step of the open plan with its choices; `--dry-run` rehearses it.
  - A step is DONE when its purge ends SUCCESS or WARNING with P1 PASS; the plan is DONE after its last step. A stopped or failed step stays to do.
  - The purge reuses the root counts of the plan's preflight only while they are valid (same cutoff, within `preflight_valid_h`, nothing purged since), so a later step counts again.
- Lifecycle, at most one open plan (READY or IN_PROGRESS):
  - a run with other options replaces a READY plan;
  - while a plan is IN_PROGRESS, a purge with other options is refused: exit 4 non-interactive, the wizard asks (continue, start over, cancel); `start_run` refuses it too (ORA-20128);
  - `--new` starts over: the open plan is closed, its done steps stay done;
  - `plan` shows the open plan (or the latest), `plan --close` closes it (`--yes` with `--non-interactive`);
  - a preflight of the same scope checks the plan again: done steps stay, the rest is planned anew, and CHANGES SINCE lists what moved since the previous check;
  - a preflight of another scope while a plan is in progress plans nothing and says so (PLAN_KEPT);
  - a preflight that ends STOPPED or FAILED leaves no plan to follow: the plan it made is closed, and a plan it checked again keeps its previous check;
  - the run that closes a plan (start over, or a purge or preflight of another scope replacing it) says so in a PLAN event, with how far the plan had got.
- Wizard: the menu shows the open plan and offers continue, check again, rehearse the next step and start over.
  - Before a step it checks the plan again (a preflight with the plan's choices, counting anew) when the last check found requirements not met, is older than `preflight_valid_h` (8 h), or `--max-redo` changes.
  - Without a plan, Purge runs the preflight first; it plans, and the purge carries out step 1.
  - The wizard connects as EPFPG before the menu, to show the plan. A failed connection still shows the menu (Install).
- Reports and run folder:
  - PLAN section in preflight and purge reports: the steps with their estimates and state, and the next command;
  - machine lines EPF_PLAN, EPF_PLAN_STEP and EPF_PLAN_KEPT;
  - manifest keys plan, plan_status, plan_steps, plan_done, plan_next, plan_step and max_redo;
  - `plan.txt` and `requirements.txt`;
  - `status` shows the open plan.
- Removed: `saved.sql` and `epf_control.print_saved_choices`. The plan replaces the saved choices, which no longer expire after 8 h.
- e2e suite:
  - new T13B: LOGS at twice the suite's retention, the plan split with `--max-redo` at 60% of its redo, step 1, other options refused, a dry run of step 2, `plan`, `plan --close`;
  - plan checks in T08B, T10B (the stopped preflight's plan is CLOSED), T11, T12B and T13 (the plan is DONE);
  - usage errors for `--new`, `--close` and `--max-redo` in T07.
- Checked here: both scripts parse; 41 unit checks of the wrapper's plan helpers pass (sizes, plan lines, scope matching, report sections, choices). The SQL is not compiled here: T03 and T04 compile it.

How to test (set H, on a refreshed copy; see the status page):
- H1, by hand, LOGS only:
  - `epf_purge.bat preflight --mode LOGS --retention 400 --backup none --confirm UNDO`: a plan of one step; note its Redo (est.).
  - The same command with `--max-redo` at about half of that redo (such as 300M): the plan is checked again and split into several steps, `plan.txt` in the run folder.
  - `epf_purge.bat` (menu): the plan is shown. 3 rehearses step 1; 1 carries it out; `plan` shows 1 step done.
  - `epf_purge.bat purge --mode FULL`: the question continue, start over, cancel (S).
  - Menu 4 starts over; `plan --close` closes the new plan.
- H2: the full suite, `.\src\tests\e2e\run_tests.bat`: 23 tests pass. T13B notes the redo estimate and months of its plan.

## 2026-10-05 - Set F: the full suite on EPFPG781 (0.5.4), 21 of 22; T08 assertion fixed, rerun passed

- 21 passed, 1 failed, in 1:16:06. 0.5.4 compiled (T03, T04) and every purge, stop, wizard and report test passed:
  - the graceful stop with batches limited by rows (T11);
  - the PAYMENTS purge to the end with its forecast against result (T13);
  - compaction (T14), LOB clearing (T15) and the menu wizard (T16).
- T08 failed on its own check, not on the tool.
  - Every preflight ends with a line ` Choices <choices> (saved with R-...)` (since 0.5.1).
  - T08 checked that a non-interactive preflight shows no questions with `Assert-NoMatch ' CHOICES '`. PowerShell's `-match` ignores case, so the Choices line matched.
  - T08B, T10B and T11 used the same pattern positively and passed on the Choices line too, so they did not prove the questions section was there.
- Fix: the four checks use the section header exactly, case-sensitive: `(?m-i)^ CHOICES +HH:MM:SS` (`$script:ChoicesSection`). Checked against sample lines: it matches the section, not the Choices line or the CHOICES step of the report.

How to test: `.\src\tests\e2e\run_tests.bat --only T08,T08B,T10B` (T01 runs too; about 10 minutes on the purged copy): 4 passed. T11 uses the same check and needs data to purge: the next full run covers it.

Rerun (F4) with the fix: T01, T08, T08B and T10B passed. T08B and T10B found the questions section itself this time.

Forecast against result in T13 (PAYMENTS, retention 30, 87,728,675 rows). The dry run R-000010 took its costs from the first batches of the T11 purge, which the suite stops after 3 progress lines.

| Measure | Forecast | Actual | Error |
|---|---|---|---|
| Rows | 87,728,675 | 87,728,675 | 0% |
| Redo | 64,914,525,874 | 66,164,520,896 | -1.9% |
| Undo | 32,510,348,226 | 33,499,216,076 | -3.0% |
| Deleting time (s) | 1,264 | 1,312 | -3.7% |
| Space freed | 17,383,983,090 | 17,313,281,186 | +0.4% |

A few measured batches forecast the whole purge within 4%. The redo per row, 754 B, is set G's 753 B on another instance, at batches limited to about 200,000 rows.

## 2026-10-05 - Measuring lighter, no redo log warning when the logs are to be enlarged (0.5.4)

- The batches read the session's redo and undo once after each statement, with both statistics in one V$MYSTAT query.
  - 0.5.3 read them four times per statement.
  - In set G, LOGS took 32 s in both steps against 25 and 26 s in set E. Its 1,543 to 1,590 batches of 530 rows run 2 statements each, so the reads weigh most there.
  - BATCH_PROGRESS counts the redo of a batch up to its last statement. Its commit is counted with the next reading.
- REDO_LOGS check: with redo log sizing planned (`--redo-logs`), each batch is compared with the 1 GB logs the purge will use.
  - Set G's dry run warned that a batch fills more than one of the 150 MB logs (REDO_ESTIMATE, REDO_SUMMARY), so a dry run ended PASS WITH WARNINGS for logs that the purge replaces first.
  - The recommended batch size is then for 1 GB logs, as the wrapper's question already offers.

How to test: set F (the full suite) on EPFPG781 installs 0.5.4.
- In T08B (preflight with `--redo-logs`), REDO_SUMMARY says `the size planned for the purge`.
- In the next two-step set, a dry run with `--redo-logs` on 150 MB logs ends PASS (P5 PASS), and LOGS deletes in about 25 s again.

## 2026-10-05 - Set G on EPFPG782 (0.5.3, batch 530): first purge within +-25%, second within +-11%

Same data and commands as set E, on a refreshed EPFPG782. All four steps passed.
- G1: 0.5.3 installed and compiled.
- G2, step 1 at 2023-09-28: dry run R-000001, then purge R-000002, PASS WITH WARNINGS (the AUDIT_TRAIL orphans, as before).
  - Parameters: `batch 530 (at most 200,000 rows)`.
  - PAYMENTS ran 493 batches: 479 of bulk payments, about 177K rows each, and 14 of file integrations. Set E ran 248 batches of 341K rows.
  - R-000001 was the first run on the copy, so the forecast came from statistics and the assumed speed. PAYMENTS 00:28:16 = 84,663,379 rows / 50,000 rows/s + 493 batches x 6 ms.
- G3, step 2 at 2025-10-01: dry run R-000003, then purge R-000021, PASS.
  - The dry run said `Redo and undo per row, measured by R-000002`. LOGS adds `1 table estimated from optimizer statistics`, which is SPEC_TRT_LOG with no rows in step 1.
  - Its deleting time was `measured per tree by R-000002`.
  - The run number went from R-000003 to R-000021: Oracle hands out identity values 20 at a time and its cache was lost between the two runs (an instance restart or memory pressure). No run is missing.
- FORECAST AND RESULT, set G (set E):

  | Step | Module | Rows | Redo | Undo | Deleting time | Space freed |
  |---|---|---|---|---|---|---|
  | 1 | PAYMENTS | 0.0% | +25.4% (+89.5%) | +23.9% (+73.7%) | +15.5% (+161.8%) | +0.7% (+6.8%) |
  | 1 | LOGS | 0.0% | -17.6% (+37.2%) | -3.2% (+45.2%) | -19.2% (+90.0%) | -5.4% (+1.6%) |
  | 1 | BANK_STATEMENTS | 0.0% | +1.8% (+69.6%) | -24.7% (+12.9%) | -18.8% (+255.3%) | +0.1% (+2.4%) |
  | 2 | PAYMENTS | 0.0% | -1.5% (+8.3%) | -1.0% (+5.4%) | +10.8% (+29.9%) | +5.3% (+89.0%) |
  | 2 | LOGS | 0.0% | -8.7% (-8.6%) | -5.3% (-5.3%) | +2.5% (-2.7%) | +0.3% (+13.3%) |
  | 2 | BANK_STATEMENTS | 0.0% | -9.4% (-11.2%) | -10.6% (-11.9%) | +26.3% (+42.6%) | 0.0% (+55.2%) |

  In step 1, LOGS and BANK_STATEMENTS came out as recomputed from set E. PAYMENTS redo came out +25% instead of the recomputed +14%, because the smaller batches lowered the actual redo.
  The step 2 BANK_STATEMENTS time is 4 s forecast against 3 s.
  Space freed is now within +-6% in both steps: emptied blocks count as empty. Used after in step 2: PAYMENTS 103.5 MB, BANK_STATEMENTS 272 KB. Set E showed 1.0 GB and 344 MB.
- Smaller batches, PAYMENTS step 1, same rows:

  | | Set E: 248 batches, 341K rows | Set G: 493 batches, 177K rows | Change |
  |---|---|---|---|
  | Redo | 65.5 GB, 830 B per row | 59.4 GB, 753 B per row | -9% |
  | Undo | 32.1 GB | 30.1 GB | -6% |
  | Deleting time | 26:57, 19.1 us per row | 24:28, 17.3 us per row | -9% |

  - Redo per row has matched across instances at the same batch size before (parity on EPFPG781: 832 B; set E on EPFPG783: 831 B), so the redo drop comes from the batch size.
  - The time comparison is less clean. LOGS and BANK_STATEMENTS kept their batches and still took longer here: 32 s against 25 s, and 97 s against 70 s.
  - The key snapshot of PAYMENTS took 57 s in the dry run and 76 s in the purge, against 48 s and 45 s in set E. Weighing the 123,745 bulk payments into batches costs those 10 to 30 s.
- Redo per row by table (EPF_TABLE_REDO lines).
  - The measured cost carries over between old and recent data. Step 2 against step 1:
    - PAYMENT_ADDITIONAL_INFO 624 B against 620 B;
    - PAYMENT_AUDIT 864 B against 860 B;
    - PAYMENT 1,565 B against 1,527 B;
    - AUDIT_TRAIL +9%, DIRECTORY_DISPATCHING +11%, TRANSMISSION_EXECUTION_AUDIT -14%;
    - only BULK_PAYMENT_ADDITIONAL_INFO moved a lot: 995 B against 610 B.

    So the forecast after a first purge, which uses these measurements per table, is reliable.
  - Against the statistics estimate, step 1:
    - the two large child tables cost less than estimated: PAYMENT_ADDITIONAL_INFO 620 B against 778 B, PAYMENT_AUDIT 860 B against 1,252 B. They hold about 10 and 5 rows per payment, so the rows of one payment share blocks and are deleted together;
    - most other tables cost 10 to 45% more, for example PAYMENT 1,527 B against 1,213 B, AUDIT_TRAIL 1,337 B against 1,102 B and WORKFLOW_EXECUTION 751 B against 540 B.
  - Fitting the estimate to the dictionary figures (G4: row length, indexes, key lengths, LOB columns, temporary indexes) still leaves +-15 to 40% per table. I tried linear fits on row length, index count and key length, with and without a flag for many rows per parent. The statistics cannot see how the rows to delete sit in the blocks.
    - Counting the temporary indexes would add 0.3% to the PAYMENTS total. Of the 12, only 6 are on columns with values, and those tables are small.
    - The module totals are what the requirements and the outcome use: within +-25%. The largest module, PAYMENTS, comes out high (on the safe side).
  - Undo per redo by table ranges from 0.43 (AUDIT_TRAIL) to 0.70 (DIRECTORY_DISPATCHING). The single share of 0.5 left BANK_STATEMENTS undo at -25% in step 1. Step 2 uses the per-table measurement: -11%.
- Possible next step: reference costs per registry table from these measurements, scaled to the statistics of the database.
  - These copies would then be forecast exactly by construction. That cannot be checked before a different database purges.
  - Not built.

## 2026-10-05 - First-purge estimate calibrated, deleting time per row, batches limited by rows, emptied blocks counted as free (0.5.3)

Built from the set E measurements (entry below). Set G tested it (entry above).

- Redo per row from optimizer statistics (`row_redo_estimate`):
  - now 1.2 R + 180 B, plus 1.2 K + 162 B per index (R = avg_row_len, K = key length);
  - was 2 R + 300 B, plus 2 K + 270 B per index;
  - the factor 0.6 comes from set E, where the measured redo was 0.53 (PAYMENTS), 0.59 (BANK_STATEMENTS) and 0.73 (LOGS) times the old estimate.
- Undo estimated as 0.5 times the redo, up from 0.45. Set E measured 0.49, 0.68 and 0.43 (0.50 overall).
- Recomputed for set E step 1:

  | Module | Redo | Undo |
  |---|---|---|
  | PAYMENTS | +14% | +16% |
  | LOGS | -18% | -3% |
  | BANK_STATEMENTS | +2% | -25% |

- Deleting time is now rows divided by rows per second, no longer redo divided by a redo rate, so a wrong redo estimate no longer distorts it. Rows per second come from, in order:
  - the latest purge of the same tree;
  - else the latest purge on the database, all trees together;
  - else the new setting `delete_rows_s` (50,000) plus 6 ms per batch.

  `delete_rows_s` replaces `redo_rate_mb_s`. Set E measured 52,300 rows/s (PAYMENTS) and 54,800 rows/s (BANK_STATEMENTS). LOGS, at 530 rows per batch, spent about 6 ms per batch.
- Recomputed for set E, time error (was):

  | Module | Step 1, assumed speed | Step 2, measured per tree |
  |---|---|---|
  | PAYMENTS | +5% (+162%) | +33% (+30%) |
  | LOGS | +2% (+90%) | -1% (-3%) |
  | BANK_STATEMENTS | +13% (+255%) | -12% (+43%) |

- The preflight forecast takes its deleting time from rows per root: from the latest purge of the tree, else from statistics (`EPF_TREE_EST.rows_root`).
- Batches limited by rows. A new setting, `batch_rows_max` (200,000), is recorded with each run in `EPF_RUN.batch_rows`.
  - A batch holds at most the batch size in roots and about 200,000 rows.
  - Rows of a bulk payment = its keys in each table with keys (payments, import audits, workflow executions, invoices) times that table's rows per key from statistics. On the set E data that is about 675 rows for an old bulk payment, against 684 measured.
  - A root above the limit gets a batch of its own. Grouped roots stay together.
  - Trees without link sources with keys below the root use the same rows per root for every root: LOGS and BANK_STATEMENTS keep 530 roots per batch.
  - Why: set E step 1 ran 341K rows per batch at 830 B and 19.1 us per row. Step 2 ran 158K rows per batch at 766 B and 14.3 us per row. Set B, at 683K rows per batch, cost 1,098 B and 29.6 us per row.
  - On the step 1 data PAYMENTS goes from 248 batches to about 450.
  - The preflight's batch redo and undo (REDO_LOGS, UNDO) use the batch limited by rows.
- Redo and undo are now measured per table:
  - stored in `EPF_TABLE_STAT.redo_bytes` and `undo_bytes` after the purge, with the statistics estimate per row in `est_redo_row` before it;
  - REDO AND UNDO lists each table with rows, redo per row, undo per row and the estimate per row, plus machine lines `EPF_TABLE_REDO|run|table|rows|redo|undo|estimate`;
  - the dry run uses a table's own measurement when a purge processed at least 1,000 of its rows, else its tree's, else statistics;
  - purpose: calibrate the statistics formula per table from the next purges.
- Space: blocks at least 75% free (ASSM FS4) now count as empty; before, they counted as 12.5% used.
  - In set E step 2 the space forecast was +89% for PAYMENTS and +55% for BANK_STATEMENTS. Emptied blocks still counted 12.5% used: DIRECTORY_DISPATCHING showed 320.5 MB used after its last row was deleted, AUDIT_TRAIL 15.8 MB with 90 rows left.
  - Table space figures are lower than in earlier versions, by up to an eighth of the emptied blocks.
- Report:
  - each SIMULATION and ESTIMATE basis line names its modules when the modules differ (set E printed two "Redo and undo per row" lines without saying which was LOGS);
  - Parameters shows `batch 530 (at most 200,000 rows)`;
  - KEYS_SNAPSHOT shows the batch limits;
  - `EPF_ADVICE|UNDO_MAX_BATCH` comes from the largest undo per root.
- Faster measuring: the session statistics are read by their statistic number, looked up once.

How to test: set G on EPFPG782, refreshed: the same data as set E's EPFPG783, on the same server. The parity purge on EPFPG781 and set E on EPFPG783 wrote the same redo per row at batch 530 (832 and 831 B), so the instances compare. It runs the same two steps as set E, with batch 530, `--redo-logs --undo-tuning --backup none`. In G2 the dry run must say `estimated from optimizer statistics` (no earlier purge on the copy).
- G1: pull and install. Pass if `EPFPG objects valid, tool version 0.5.3`.
- G2, step 1 at 2023-09-28, dry run then purge. Pass if:
  - KEYS_SNAPSHOT shows about 450 PAYMENTS batches of up to 530 roots and about 200,000 rows;
  - FORECAST AND RESULT shows rows at 0.0%, redo and undo within about +-30%, deleting time within about +-30% and space freed within about +-10%.

  Also compare the purge's PAYMENTS redo per row and time per row with set E step 1 (830 B, 19.1 us). REDO AND UNDO lists every table.
- G3, step 2 at 2025-10-01, dry run then purge. Pass if:
  - the dry run says `per row, measured by R-...` (now per table);
  - FORECAST AND RESULT shows rows at 0.0%, redo and undo within about +-15%, deleting time within about +-35% and space freed within about +-15%. Set E had +89% and +55% space for PAYMENTS and BANK_STATEMENTS.
- G4: collect the 4 reports into `.local\test.log`.

## 2026-10-05 - Set E on EPFPG783 (0.5.2, batch 530): per-row forecast and LOB space carry-over verified

Step 2 (E3), cutoff 2025-10-01:
- Dry run R-000061 (1:33), then purge R-000062 (4:29): PASS. P4 passes this time, because the purge deleted the AUDIT_TRAIL rows with the old orphans.
- The dry run used `Redo and undo per row, measured by R-000042` (the step 1 purge) and a redo rate of 42.3 MB/s, also measured by R-000042.
- FORECAST AND RESULT:

  | Module | Rows | Redo | Undo | Deleting time | Space freed |
  |---|---|---|---|---|---|
  | PAYMENTS | 0.0% | +8.3% | +5.4% | +29.9% | +89.0% |
  | LOGS | 0.0% | -8.6% | -5.3% | -2.7% | +13.3% |
  | BANK_STATEMENTS | 0.0% | -11.2% | -11.9% | +42.6% | +55.2% |

  Set B's step 2, measured per bulk payment, was +122% for PAYMENTS redo.
- LOB space carried over:
  - used before was 3.3 GB, equal to what step 1 left (set B: 16.2 GB);
  - the report says `Used before includes 6 BASICFILE LOB segments carried over`;
  - freed 1.8 GB.
- Space freed was forecast too high because emptied blocks count as 12.5% used (ASSM FS4 band midpoint). For example:
  - DIRECTORY_DISPATCHING: 320.5 MB used after, with no rows left;
  - PAYMENT_ADDITIONAL_INFO: 529.6 MB used after, with 83,926 of 3.7M rows left.

  The forecast takes used before times the eligible share, so it counts that floor as freed. Fixed in 0.5.3.
- The dry run printed two basis lines, `per row, measured by R-000042` and `...; other trees estimated from optimizer statistics`. The second was LOGS: OP.SPEC_TRT_LOG had no rows before step 1's cutoff, so step 1 did not measure it. The report did not say which module each line was for; 0.5.3 names them.
- Per row, PAYMENTS:
  - step 2 wrote 766 B of redo and took 14.3 us per row, at 158K rows per batch;
  - step 1 wrote 830 B and took 19.1 us per row, at 341K rows per batch.

Step 1 (E2), cutoff 2023-09-28:
- Dry run R-000041 passed, and the purge passed with warnings.
- FORECAST AND RESULT, first purge on this database (estimates from statistics, per row):

  | Module | Rows | Redo | Undo | Deleting time | Space freed |
  |---|---|---|---|---|---|
  | PAYMENTS | 0.0% | +89.5% | +73.7% | +161.8% | +6.8% |
  | LOGS | 0.0% | +37.2% | +45.2% | +90.0% | +1.6% |
  | BANK_STATEMENTS | 0.0% | +69.6% | +12.9% | +255.3% | +2.4% |

- Transaction size confirmed. Set B step 1 and set E step 1 purged the same 84,663,379 PAYMENTS rows on copies of the same data:

  | Batch | Redo | Undo | Deleting time |
  |---|---|---|---|
  | 1000 (set B) | 86.5 GB | 39.3 GB | 41:46 |
  | 530 (set E) | 65.5 GB | 32.1 GB | 26:57 |

  Batch 530 used 24% less redo, 18% less undo, and took 35% less time. Per row that is 831 B of redo, the same as the parity purge (832 B) and set B step 2 (842 B).
- The redo error rose from +35% to +89.5% because the actual redo fell; the estimate barely moved (116.7 GB per root, 124.1 GB per row).
- Statistics estimate against measured redo per row:
  - PAYMENTS: 1,574 B against 831 B;
  - BANK_STATEMENTS: 2,044 B against 1,204 B;
  - LOGS: 1.84 KB against 1.31 KB.

  The assumed redo rate is 30 MB/s; this purge wrote about 41 MB/s.
- Calibrating the statistics estimate and the time forecast on these measurements, and limiting batches by rows: built in 0.5.3 (entry above).

## 2026-10-03 - Set B on EPFPG782: dry-run accuracy; per-row forecast and LOB space fix (0.5.2)

Set B (EPFPG782, 0.5.1, batch 1000, `--redo-logs --undo-tuning --backup none`)
- Step 1, cutoff 2023-09-28, the first purge on the database:
  - dry run R-000001 (3:58);
  - purge R-000002 (48:24): PASS WITH WARNINGS. The only warning is P4: AUDIT_TRAIL orphans that existed before the purge (1,195,572, then 800,823).
- Step 2, cutoff 2025-10-01: dry run R-000003 (1:24), then purge R-000004 (4:53), PASS.
- Forecast against result (FORECAST AND RESULT):

  | Step | Module | Rows | Redo | Undo | Deleting time | Space freed |
  |---|---|---|---|---|---|---|
  | 1 (statistics) | PAYMENTS | 0.0% | +34.8% | +33.5% | +58.9% | +6.8% |
  | 1 | LOGS | 0.0% | +37.8% | +45.5% | +112.7% | +1.6% |
  | 1 | BANK_STATEMENTS | 0.0% | +68.9% | +12.4% | +243.6% | +2.4% |
  | 2 (measured by step 1) | PAYMENTS | 0.0% | +121.6% | +105.4% | +174.5% | not valid (LOB space) |
  | 2 | LOGS | 0.0% | -8.9% | -5.4% | +31.2% | +13.3% |
  | 2 | BANK_STATEMENTS | 0.0% | +40.6% | +39.3% | +78.4% | not valid (LOB space) |

- Expected outcome: WOULD COMPLETE both times, and both purges completed.
- Why step 2 was further off than step 1:
  - the cost was measured per bulk payment;
  - the older bulk payments of step 1 carry 684 rows each, the recent ones of step 2 carry 402;
  - per row the redo moved much less: 1,098 B against 842 B.
- Space:
  - step 2's baseline took Oracle's raw figure for the 6 BASICFILE LOB segments (DIRECTORY_DISPATCHING, FILE_DISPATCHING, TRANSMISSION_EXECUTION_AUDIT), which still counts the space step 1 freed: 16.2 GB used before step 2, against 3.3 GB after step 1;
  - step 2 reported 14.8 GB freed, about 1.9 GB in reality;
  - its space forecast matched only because it started from the same inflated figure.
- Transaction size, redo per row of the BULK_PAYMENT tree:
  - step 1: 1,098 B, at 683K rows per batch;
  - step 2: 842 B, at 390K rows per batch;
  - parity purge (batch 530): 832 B, at 347K rows per batch.

  Time per row was 29.6, 17.9 and 19.5 microseconds. Batches above about 400K rows cost about 30% more redo and 50% more time per row.

Changes (0.5.2, with the set C report fixes)
- Dry-run forecast per row:
  - the rows the dry run counts in the tables of each tree, times the redo and undo per row measured by the latest purge of that tree (TREE_REDO and TREE_UNDO over the rows that purge processed);
  - without a measurement: each table's rows times its estimate per row from optimizer statistics.
- Recomputed on set B's numbers, step 2 would have been:
  - PAYMENTS: redo +30.4% (was +121.6%), undo +20.8% (was +105.4%), deleting time +61% (was +175%);
  - BANK_STATEMENTS: redo -11.0% (was +40.6%), undo -11.8% (was +39.3%);
  - LOGS: unchanged (one row per root).
- A dry run's RETENTION OPTIONS scale the dry run's own forecast, redo included, so the requested row matches SIMULATION.
- BASICFILE LOB space is carried over:
  - EPF_SPACE_USAGE.RAW_USED_BYTES keeps DBMS_SPACE's figure;
  - at a BASELINE, a BASICFILE LOB segment whose latest capture by another run was an estimate starts from that estimate, plus the growth of the raw figure since;
  - the report notes the carried segments, and P7 counts each estimated segment once.
- Not changed:
  - the preflight's estimate is still per root, since it has no counts per table;
  - the statistics estimate for a first purge stays 35-70% high (safe, but stricter than needed for the archive requirement).

Proposal, not built: limit batches by rows (about 400K) as well as by roots. Old, heavy bulk payments would then run in smaller transactions, which costs about 30% less redo and about a third less time.

Not yet run: written without a database.

## 2026-10-03 - 0.5.1 test round: set C on EPFPG783 passed; report fixes (0.5.2)

Set C (EPFPG783, 0.5.1)
- C1: the install of 0.5.1 compiled.
- C2: `S` at the first question stopped the preflight (exit 3).
- C3 (R-000023, again R-000026):
  - questions UNDO, BACKUP and REDO_LOGS, then the batch size (530 for 1 GB logs);
  - the check with the answers took about 1 s, with no table scan; result READY 6 of 6;
  - the screen kept the steps, the warnings and the report.
- C4: the wizard offered the choices saved with R-000026, the review showed them, and `no` aborted. No run was created.
- C5 (R-000027, dry run without prompts):
  - it followed the choices of R-000026 and reused its root counts (preflight in 1 s);
  - SIMULATION: 96,163,037 rows, the same as the parity purge R-000002 on the same data; nothing held back; READY; WOULD COMPLETE;
  - space freed: 31.6 GB forecast against 30.2 GB measured by R-000002 (+4.6%);
  - first-purge estimates as in S2: redo 140.9 GB, deleting time 1:20:11 at the assumed 30 MB/s.
- Commands with `--non-interactive` read the passwords from EPF_PASSWORD and EPF_SYS_PASSWORD. The checklist now has a line that sets both from masked prompts, and the wrapper no longer passes these variables on to its sqlplus sessions (a4afeb5).

Fixes (0.5.2)
- Triggers in the simulation:
  - for a deleting purge, the simulation notes listed the tables' UPDATE triggers;
  - they now list the triggers the purge fires: DELETE triggers for deleting modules, and UPDATE triggers on the tables whose LOB values a clearing module clears;
  - past 5 triggers the line ends with "and N more";
  - on EPFPG783 a FULL purge fires none.
- SPACE INSIDE SEGMENTS: in a dry run, the module totals showed used after equal to used before and 0 B freed. They now show `-`, like the table lines.
- A dry run reported "Undo tuning not applied ... may grow during the purge". It now says that a dry run writes no undo, and whether undo tuning is planned.
- UNDO requirement with undo tuning planned or active: the line now says undo tuning keeps undo 60 s and caps the tablespace; the undo_retention figure appears as "without it".

Finding: each new sqlplus session takes about 15 s to connect from the test machine. It shows even for the session that only reads the advice, so it is the connection, not the tool's work; a wizard purge opens 6 to 8 such sessions. To measure it, with the password line set: `Measure-Command { src\bin\epf_purge.bat status --tns EPFPG783 --non-interactive }` (two sessions). The tool could later run its short queries in the monitor session, which stays connected.

## 2026-10-02 - Preflight asks for the choices and saves them; the purge follows them (0.5.1)

Why: the preflight only reported the requirements. The operator expected it to ask how to meet each one, and the purge to follow the answers (plan 6.10).

Preflight
- Without `--non-interactive`, after the checks, the preflight asks one question per requirement not met. Blocking requirements come first, then the ones that only slow the purge. Each question shows what was measured:
  - ARCHIVE: the DBA confirms the room; purge older data first (stops with the `--cutoff` that fits); or stop;
  - UNDO: undo tuning (default); accept the growth (the DBA confirms); or stop;
  - TEMP: the DBA confirms; or stop (default);
  - BACKUP: made another way; purge without a backup; or stop (default);
  - INDEX_SPACE: continue (slower); or stop;
  - REDO_LOGS: enlarge to 4 x 1 GB when the purge starts (default); or leave them.
- Then it asks the batch size: the recommendation for 1 GB logs when they will be enlarged, capped by undo.
- The answers are saved with the preflight run (`epf_control.set_choices`). The requirements and the forecast are checked again without a table scan (`epf_purge.recheck`, step and event CHOICES). If something is still not met, it offers to answer again.
- `S` stops at any question: nothing is saved, exit code 3.
- At the end: the saved choices, and the next command (`purge` of the same scope, or `--dry-run` first).

Purge
- A purge or dry run looks up the latest preflight of its scope (same mode, depth and cutoff, within `preflight_valid_h`, 8 h) (`saved.sql`).
- If that preflight is READY, the purge follows its choices. The wizard asks once, "Use the choices saved with R-...?", instead of running a new preflight; a run without prompts uses them and says so.
- Command-line values win over saved ones. Undo tuning, redo log sizing and confirmations add up.
- The purge's own preflight reuses that preflight's root counts unless a purge has processed batches since; then it counts again.
- The wizard without saved choices runs the preflight with its questions, then the purge. The old separate redo, undo, backup and batch questions are gone.
- `--redo-logs` now also works with `preflight` and `--dry-run`, as planned (EPF_RUN.WITH_REDO_LOGS). The requirement REDO_LOGS then counts 1 GB logs.

Output
- The console no longer shows the EPF_ machine lines of the report, or the INFO detail events: IDX_MISSING, REDO_ESTIMATE, UNDO_ESTIMATE, TABLE_ELIGIBLE, TEMP_INDEX_CREATED, TEMP_INDEX_DROPPED. `console.log` and `report.txt` keep everything.

Tests (22): T08B, new, is an interactive preflight with options (the only question is the batch size, answered 200), then a dry run that follows the saved choices. T10B also checks that `S` stops the preflight's questions with exit code 3. T11 checks the wizard's CHOICES section. T08 checks that no machine lines reach the console.

Not yet run: written without a database.

## 2026-10-02 - 0.5.0 test round: end-to-end suite on EPFPG781 (set A), 21/21 passed

- 21 passed, 0 failed, in 1:22:52.
- T10B: the purge R-000004 was refused (NOT READY: UNDO, BACKUP). It ended FAILED with REQUIREMENTS_NOT_MET, and no batch ran.
- T11:
  - the wizard's preflight, with `--undo-tuning --backup none`, was READY except REDO_LOGS (slower only);
  - after the redo log sizing, the purge's own preflight was READY 6 of 6;
  - the root counts were reused, and the stop was honoured.
- T13 against the dry run R-000007 (T12B). The redo and undo per root were measured by the three batches of T11:
  - rows: exact;
  - redo: 68.7 GB forecast, 67.6 GB actual (+1.6%);
  - undo: 33.3 GB forecast, 33.2 GB actual (+0.2%);
  - deleting time: 34:49 forecast, 28:22 actual (+22.7%). The rate came from the three batches of T11 only;
  - space freed inside the tables: 16.2 GB forecast, 15.2 GB actual (+6.7%).
- T14 (`--confirm UNDO`), T15 and T16 passed. Undo growth limits were restored after every run.

## 2026-10-02 - 0.5.0 test round: install check on EPFPG783 (S1, S2)

- S1: the 0.5.0 install compiled; the wrapper connects and reports tool version 0.5.0.
- S2: preflight with `--cutoff 2025-10-01` (R-000001, 56 s, PASS WITH WARNINGS, exit 2):
  - ESTIMATE, RETENTION OPTIONS and REQUIREMENTS are in the report;
  - RESULT NOT READY: UNDO and BACKUP are blocking, REDO_LOGS is slower only;
  - ARCHIVE is met by NOARCHIVELOG; TEMP and INDEX_SPACE are met.
- EPFPG783 after its refresh: 3 online logs of 150 MB, UNDOTBS1 620 MB (can grow to 32 GB), no RMAN backup recorded, empty tool schema (first run R-000001).
- The first-purge estimates (optimizer statistics), against what R-000002 measured on the same data in the parity run:
  - redo per bulk payment 988.6 KB against 531 KB (+86%); PAYMENTS redo 130.4 GB against 70.1 GB;
  - undo per bulk payment 444.9 KB against about 261 KB (34.4 GB over 138,295) (+71%);
  - PAYMENTS deleting time 1:14:11 at the assumed 30 MB/s against 29:22 measured (the parity run wrote about 40 MB/s).

  The statistics-based estimate and the `redo_rate_mb_s` default are to be calibrated after set B, which compares a first purge with a measured one.

## 2026-10-02 - Requirements, simulation, forecast against result (D19, D20 round 1; 0.5.0)

Why: a purge must not fill the archive destination or the undo tablespace part way (plan 6.10), and the dry run must say what the purge will do, so its accuracy can be checked against real purges.

Requirements (preflight step REQUIREMENTS, report section REQUIREMENTS)
- Six requirements, each with its reason, what was measured, the ways to meet it, and which one meets it now: ARCHIVE, UNDO, TEMP, INDEX_SPACE, REDO_LOGS, BACKUP. ARCHIVE, UNDO, TEMP and BACKUP are blocking. The section ends with RESULT READY or NOT READY.
- A purge that deletes does not start while a blocking requirement of its own preflight is not met:
  - the wrapper names the requirements;
  - the purge step records REQUIREMENTS_NOT_MET;
  - the run ends FAILED (exit 1) and nothing is changed.
- Choices, on the command line or in the configuration file:
  - `--backup confirmed|none` (BACKUP), for when no RMAN database backup newer than `backup_max_age_h` (24) is found;
  - `--confirm ARCHIVE,UNDO,TEMP` (CONFIRM): the DBA confirms these are handled although the preflight finds them not met, for example an archive directory whose free space the database cannot read;
  - `--undo-tuning` now also works with `preflight` and `--dry-run`: the requirements are checked as if undo tuning were applied, and nothing is changed;
  - `--cutoff YYYY-MM-DD` (CUTOFF) instead of `--retention`, so a purge on a later day keeps the cutoff of its dry run.
- Wizard, after its preflight:
  - the backup question when no recent backup is found (stop, made another way, or none);
  - for ARCHIVE, UNDO or TEMP not met: stop here, or the DBA confirms;
  - the batch size offered is capped so that the undo tablespace holds 4 batches.
- Every purge runs its own preflight with its choices, also after the wizard. After the wizard it reuses the root counts of the wizard's preflight (same cutoff, mode and depth, within `preflight_valid_h`, 8 hours), so the root tables are not scanned twice.
- Undo tuning is sized from the purge run's own preflight.

Simulation and forecast
- Dry run report:
  - SIMULATION per module: exact rows, roots, batches, redo, undo, deleting time, space freed;
  - held-back roots, enabled triggers, application sessions now;
  - RETENTION OPTIONS: the requested retention and 1.5, 2 and 3 times it, each with roots, rows, redo, archive space needed, space freed, and whether it fits;
  - REQUIREMENTS;
  - EXPECTED: WOULD COMPLETE (time, space), WOULD FAIL (where and why, for example the batch at which the archive space runs out), or MAY FAIL.
- Preflight report: an ESTIMATE per module, RETENTION OPTIONS and REQUIREMENTS.
- Purge report, FORECAST AND RESULT per module:
  - it compares the forecast with the actual rows, redo, undo, deleting time and space freed, with the error in percent;
  - the forecast comes from the latest dry run with the same cutoff and mode and no purge of the module since, otherwise from the purge's own preflight.
- Deleting time uses the redo rate measured by the latest purge on the database (else `redo_rate_mb_s`, 30).

Other
- New settings:
  - `archive_margin_pct` 20;
  - `backup_max_age_h` 24;
  - `redo_rate_mb_s` 30;
  - `preflight_valid_h` 8.
- New grants:
  - V$ARCHIVE_DEST, V$RECOVERY_FILE_DEST, V$ASM_DISKGROUP, V$RMAN_BACKUP_JOB_DETAILS;
  - DBA_TEMP_FREE_SPACE, DBA_TEMP_FILES, DBA_TRIGGERS.
- New tables: EPF_TREE_EST, EPF_ROOT_MONTH, EPF_RETENTION_OPTION, EPF_REQUIREMENT, EPF_REQ_OPTION, EPF_FORECAST.
- New EPF_RUN columns: BACKUP_CHOICE, CONFIRMED_REQS.
- manifest.txt gains these keys:
  - `cutoff`, `backup`, `confirmed`;
  - `req.<requirement>`, `requirements_ready`;
  - `expected`, `forecast.<module>.<measure>`.
- Advice lines: READY, REQ, UNDO_MAX_BATCH.
- Not in this round (round 2): the plan of smaller runs, choices stored with the preflight, plan lifecycle and menu.

End-to-end suite (21 tests)
- T07: new usage errors (retention with cutoff, bad cutoff date, bad backup choice, `--confirm BACKUP`).
- T08 and T10: requirements, estimate, retention options, simulation, expected outcome.
- T10B, new: with `backup_max_age_h` set to 0 for the test, a LOGS purge without `--backup` is refused (exit 1, REQUIREMENTS_NOT_MET, no batch). The setting is put back afterwards.
- T11 and T16: `--backup none`. T11 also checks that the purge reused the wizard's root counts.
- T12B, new: a PAYMENTS dry run with T13's batch size.
- T13 compares its result with that dry run:
  - rows must match exactly (check);
  - redo, undo, deleting time and space freed are logged as `forecast accuracy` lines with their error.
- T14: `--backup none --confirm UNDO` (no undo tuning).
- T15: `--backup none`.
- T18: the READY and REQ advice lines.

Not yet run: written without a database. The new PL/SQL compiles for the first time at install (T03 and T04 would show compile errors).

How to test
1. Refresh EPFPG781, pull, and run `run_tests.bat`. T03 installs 0.5.0.
2. Send the digest. These PowerShell commands write `logs\review.txt` from the latest test session and copy it to the clipboard:
   ```
   $log = Get-ChildItem logs\tests -Directory | Sort-Object Name | Select-Object -Last 1 | ForEach-Object { Join-Path $_.FullName 'test.log' }
   Select-String -Path $log -Pattern '^====|^----|FAILED|forecast accuracy|  note |^ RESULT' | ForEach-Object { $_.Line } | Set-Content logs\review.txt
   Get-Content logs\review.txt | Set-Clipboard
   ```
3. Optional: run `epf_purge.bat preflight --retention 366` and read REQUIREMENTS and RETENTION OPTIONS in the report.

## 2026-10-02 - Parity with the previous tool: EXPLAINED (D8 only)

Results (FULL, depth ALL, cutoff 2025-10-01; copies refreshed from the same source)
- Previous tool on EPFPG782 (`legacy_purge.sql 366`, after `06_optimize_db.sql`, `08_undo_tune.sql`, `06b_create_purge_indexes.sql`): 29:04, no errors, 96,157,615 rows.
- This tool on EPFPG781 (R-000002, `--redo-logs --undo-tuning`, batch 530): verdict PASS, 96,163,037 rows, 30.2 GB freed inside segments (31.6 -> 1.4 GB).
- Timing, this tool against the previous tool:
  - batch loops: PAYMENTS 29:22 against 26:52, LOGS 1:00 against 0:37, BANK_STATEMENTS 1:23 against 1:33;
  - all steps: 35:11 against 29:03 for `run_purge`, without each tool's preparation;
  - about 3.5 minutes of the difference is measurement: key snapshot 1:47, counts before and after 1:20, space 0:13;
  - about 2.5 minutes is the batch size: 530 bulk payments per batch (284 batches) against 1,000 (139). The first purge on the database estimated about 1 MB of redo per root; 531 KB were measured, so the next recommendation for 1 GB logs is about 980.
- `compare.ps1 -Mode FULL`: starting data identical. The remaining rows are the same, count and key checksum, in 26 of the 27 tables. FILE_DISPATCHING differs by the 5,422 files without directory rows that this tool deletes and the previous tool keeps (D8). No row held back (D16), no row deleted through ON DELETE CASCADE, no foreign key blocking the previous tool. Both tools used cutoff 2025-10-01.
- The class counts before the purge matched the previous tool's own per-table counts exactly, including PAYMENT_AUDIT by bulk payment (15,368,660) and by payment (10,784,182). The snapshot models its rules.
- Previous tool, findings for the record:
  - its run summary reports 96,114,901 rows: it counts FILE_INTEGRATION, SPEC_TRT_LOG and the bulk payment batches twice and leaves out FILE_DISPATCHING; its per-table lines are right;
  - its space snapshot falls back to `user_segments` without the DBA view grants its wrapper gives when it has the SYS password.
- Phase 2 exit criterion (parity with the previous tool) met for FULL. CLOB_ONLY and CLOB_N_LOGS not run; the expected difference there is D8.
- PAYMENT_AUDIT in LOB clearing: the previous tool clears it by bulk payment only, while it deletes it by bulk payment and by payment. The 10.8 M rows reached through the payment only would keep their LOB values with it. No reason for the asymmetry in its code; this tool treats both links the same in both modes. PAYMENT_AUDIT has no LOB column (`dba_lobs`, EPFPG782), so the difference cannot occur on this schema.

## 2026-10-02 - Plan: requirements, purge plan and simulation (D19, D20)

- Design only (plan 6.10, D19, D20); to be built after the parity results are reviewed.
- Why: the PAYMENTS purge of EPFPG782 wrote 70.1 GB of redo and 34.4 GB of undo for 90.5 M rows. Without archiving this costs I/O only. A database in ARCHIVELOG mode would keep about that much in archived logs and stop if the archive destination fills (ORA-00257).
- Decided with the user:
  - six requirements, each with its reason and ways to meet it;
  - choices and a plan of smaller runs (retention steps, older data first, and modules), stored with the preflight run in the database;
  - `purge` follows the latest preflight of the last 8 hours, applies its choices (batch size, redo log sizing, undo tuning) and measures the space requirements again at start;
  - the backup requirement can be met by a detected RMAN backup, a confirmed backup made another way, or a confirmed purge without a backup;
  - the dry run becomes a simulation with a retention table and a predicted outcome;
  - no option based on archived logs being removed while the purge runs;
  - the tool never changes the log mode;
  - plan lifecycle: one plan per database; the latest preflight decides; start over at any time (completed steps stay done, the new preflight measures what is left); check again with the saved choices in one question; an expired plan is re-checked rather than refused; the main menu shows the plan and offers continue, check again, rehearse, start over.

## 2026-10-02 - Parity check: runner fix

- `legacy_purge.sql`, first run on EPFPG782: SQL*Plus did not find `@@../../../legacy/sql/0x_*.sql`, so nothing was installed. The check still reported the package valid, because it only looked for compilation errors. `run_purge` then failed with PLS-00201, and nothing was purged.
- The install scripts are now called relative to the top folder (`@legacy/sql/...`), where the runner is started from (as the spool path already required). The check requires both the package and the package body, and both VALID.

## 2026-10-01 - Parity check: running the previous tool without its wrapper

Results (EPFPG782 previous tool, EPFPG781 this tool, cutoff 2025-10-01)
- `compare.ps1 -Before`: READY. Both copies start identical, and both tools select the same rows in every table except the D8 files (5,422 FILE_DISPATCHING rows without directory rows). No rows go through ON DELETE CASCADE, and no foreign key will stop the previous tool.
- The snapshot ran without errors on both copies, about 4 minutes each.
- `legacy/bin/epf_purge.bat` cannot run a purge:
  - The block that asks for the TNS name, password and retention is missing. The mode, depth and batch prompts sit inside the reclaim-only branch, so a purge run asks for nothing and connects as `oppayments/@<tns>` with an empty password (sqlplus prints its usage).
  - A config file is read only with `--config <path>`.
  - `wmic` no longer exists on recent Windows 11, so the timestamp is empty and the log file name contains a colon.

Changes
- `src/tests/parity/legacy_purge.sql <retention> [mode [depth [batch]]]` (as OPPAYMENTS): runs the previous tool's purge the way its wrapper does, without the wrapper. It installs `legacy/sql` 01-03 (statement errors do not stop it, as in the wrapper), stops if `EPF_PURGE_PKG` has compilation errors, calls `run_purge` with the wrapper's arguments and prints the elapsed time and the errors the run logged. Output in `logs/parity/legacy_purge.txt`.
- The wrapper's optional steps around the purge end with EXIT, so they run as separate commands in the wrapper's order:
  - as SYS: `06_optimize_db.sql` (redo logs 4 x 1 GB, OPPAYMENTS statistics), then `utility/08_undo_tune.sql` (undo_retention 60 s, undo datafiles limited to 8 GB, not reverted by the wrapper);
  - as OPPAYMENTS: `06b_create_purge_indexes.sql` (temporary FK indexes), the purge, then `06c_drop_purge_indexes.sql`;
  - as SYS: `ALTER SYSTEM SET undo_retention = 900`.
- `legacy/` is left as it is (reference).

How to test (EPFPG782, previous tool; from the top folder)
1. `sqlplus -L "sys@EPFPG782 AS SYSDBA" @legacy\sql\06_optimize_db.sql`, then `exit` once it prints "Database optimization complete".
2. `sqlplus -L "sys@EPFPG782 AS SYSDBA" @legacy\sql\utility\08_undo_tune.sql`
3. `sqlplus -L "oppayments@EPFPG782" @legacy\sql\06b_create_purge_indexes.sql`
4. `sqlplus -L "oppayments@EPFPG782" @src\tests\parity\legacy_purge.sql 365`
5. `sqlplus -L "oppayments@EPFPG782" @legacy\sql\06c_drop_purge_indexes.sql`
6. `sqlplus -L "sys@EPFPG782 AS SYSDBA"`, then `ALTER SYSTEM SET undo_retention = 900;` and `exit`.

## 2026-10-01 - Parity check against the previous tool

Closes the open exit criterion of phase 2 (parity with the previous tool), row by row, on two copies of the same database (plan 12.6).

- `src/tests/parity/parity.sql` (SYS, read-only; steps in `parity_step.sql`): for the 27 tables of the previous tool, every row is classed by four flags and counted with a checksum of its key (primary key, otherwise unique key, otherwise every column that is not a LOB or LONG) per class:
  - D: the previous tool deletes it. Its rules, transcribed from `legacy/sql/03_epf_purge_pkg_body.sql`: bulk payments by value date and their 20 dependent tables (payment_audit by bulk payment and by payment), file_integration by integration date, audit_trail by timestamp with the audit_archive rows it references, spec_trt_log by date, file_dispatching by reception date only when it has directory rows, with those rows.
  - X: deleted through an ON DELETE CASCADE foreign key from a D row (NOTIFICATION_EXECUTION.IMPORT_AUDIT_FK).
  - N: this tool selects it (registry links, before holding back).
  - C: the previous tool clears its LOB values in CLOB_ONLY and CLOB_N_LOGS (payment_audit by bulk payment only).
  - Scope CLOB also records the non-empty LOB values per column and class.
- The snapshot also records every enabled foreign key into the 27 tables. When kept rows reference D rows, the count is reported: the previous tool's delete fails with ORA-02292 there, and the module stops.
- It records the last runs of both tools as well: `OPPAYMENTS.EPF_PURGE_LOG` with its errors, and `EPFPG.EPF_RUN` with the held rows.
- `src/tests/parity/compare.ps1` reads the four snapshots. It checks:
  - both copies started identical (every class, count and checksum), and both purges used the snapshot cutoff;
  - the previous tool deleted or cleared exactly what its rules select, or the rows it left are listed with its errors;
  - this tool kept every row it does not select.

  Every difference between the two results is classified: D8, D16 (held back, cascade rows of kept roots), PAYMENT_AUDIT (LOB clearing through the payment). Anything else fails.
- `compare.ps1 -Before` reads only the two BEFORE snapshots, before any purge is started. It checks that both copies start identical and lists, per table, what each tool will change. It also lists the expected differences, the rule differences and the foreign keys that will stop the previous tool. Exit 0 READY, 1 INVALID or rule differences.
- Checked locally with synthetic snapshots: identical results (exit 0), explained differences (exit 2), a kept row deleted (exit 1), different starting data (exit 1), LOB clearing with the PAYMENT_AUDIT and D8 differences (exit 2), CLOB mode on snapshots without LOB values (refused). The SQL has not run on a database yet.

How to test (EPFPG783 for the previous tool, EPFPG782 for this tool, both refreshed from the same source; both purges on the same day with the same retention, so cutoff = that day minus the retention)
1. In the tool folder: `sqlplus -L "sys@EPFPG783 AS SYSDBA" @src\tests\parity\parity.sql LEGACY_BEFORE <cutoff>` and `sqlplus -L "sys@EPFPG782 AS SYSDBA" @src\tests\parity\parity.sql NEW_BEFORE <cutoff>` (two windows can run at once). Do not run the end-to-end suite on these copies: it purges them.
1b. `powershell -NoProfile -ExecutionPolicy Bypass -File src\tests\parity\compare.ps1 -Mode FULL -Before`: purge only on RESULT READY; send `logs\parity\parity_before_report.txt`.
2. Previous tool on EPFPG783: `legacy\bin\epf_purge.bat --tns EPFPG783 --user oppayments --retention <days> --depth ALL --mode FULL`, without reclaim. This tool on EPFPG782: `src\bin\epf_purge.bat install --tns EPFPG782`, then `src\bin\epf_purge.bat purge --tns EPFPG782 --retention <days> --depth ALL --mode FULL --redo-logs --undo-tuning`.
3. `parity.sql LEGACY_AFTER <cutoff>` on EPFPG783 and `parity.sql NEW_AFTER <cutoff>` on EPFPG782.
4. `powershell -NoProfile -ExecutionPolicy Bypass -File src\tests\parity\compare.ps1 -Mode FULL`; send `logs\parity\parity_report.txt`.

## 2026-09-30 - End-to-end run on EPFPG781 (0.4.4): 19/19 passed

Results (EPFPG781 as the 0.4.3 run left it: PAYMENTS untouched, LOGS purged, BANK_STATEMENTS LOB values cleared; RETENTION_DAYS=365; 01:01:21; log kept on the test machine only, `logs/tests/2026-09-30_172149_EPFPG781/`)
- All 19 tests passed, no check failed. Every wrapper step ended with no sqlplus session left running (0 ended); T16 completed in 00:04:08.
- Undo growth cap: at T05 UNDOTBS1 was 3,435 MB with a growth limit of 32,768 MB. T11 and T13 set the cap to 4,096 MB (setting `undo_cap_mb`; 4 x the undo of one batch was 920 MB and 540 MB) and limited the datafile 32,768 -> 4,096 MB. The PAYMENTS purge to the end (R-000015: 87,309,042 rows, 275/275 batches in 00:26:44, 67.6 GB redo, 33.2 GB undo, verdict PASS) completed within the cap: UNDOTBS1 3,435 -> 4,096 MB (27.6 GB on EPFPG783 without the cap, 00:27:07). T16 (BANK_STATEMENTS full purge, R-000019: 3,980,655 rows, 1.6 GB undo) ran with the cap at the current size (4,096 MB, no growth left) and completed. After every run the growth limit was back at 32,768 MB (T12, T13, T19) and undo_retention at 900 s.
- The stopped run (R-000014, after batch 9 of 284, 1.2 GB undo) and the dry run (T10, work keys in TEMP) did not grow the undo tablespace.
- Undo per batch: the preflight before any measured purge estimated 230 MB (measured: 1.2 GB / 9 batches, about 136 MB); after that run 135 MB (measured in R-000015: 33.2 GB / 275, about 124 MB).
- T14 (LOGS) and T15 (BANK_STATEMENTS clearing) had nothing to process (0 rows; 0 LOB values in 199 batches): the 0.4.3 run had purged them (1,659,623 rows; 2,426,081 LOB values), and their code is unchanged in 0.4.4.
- Space used inside segments: PAYMENTS 28.9 -> 13.7 GB, BANK_STATEMENTS 15.5 -> 3.2 GB.

## 2026-09-30 - End-to-end run on EPFPG781 (0.4.3): undo apply error, hang at T16; fixes (0.4.4)

Results (EPFPG781, fresh copy, RETENTION_DAYS=365; partial log `logs/tests/2026-09-30_143658_EPFPG781/`)
- T01-T10, T14, T15 passed (install, redo logs 3 x 150 MB -> 4 x 1 GB, preflights with UNDO_CAP for the planned undo tuning, dry run, LOGS with compaction, BANK_STATEMENTS clearing).
- T11, T13: `undo.sql APPLY` failed with ORA-00923 in `epf_tuning` (line 309): the new growth-limit query used the reserved word INCREMENT as a column alias; the SQL of an invoker-rights package is checked when it runs, not at install. The failure path worked: no datafile had been changed, the purge was not started, undo_retention was restored, the runs ended FAILED with their reports. T12 failed as a consequence (no stopped run). PAYMENTS was not purged.
- T16: after the wizard's preflight (R-000009) and the confirmation, the new monitor session did not answer `begin_run.sql` within 120 s (cause not visible in the log: the session's output and database state were not captured). The wrapper stopped with an error but left that sqlplus running; it held the output pipe of the wrapper, so the test suite waited indefinitely.

Changes
- `epf_tuning`: alias `incr_bytes` (all SQL searched for reserved words used as aliases; this was the only one).
- Wrapper: every sqlplus it starts is registered and ended when the wrapper exits, on every exit path; when `begin_run` does not answer, the monitor session is ended, the message includes what the session printed, `status` is shown, and the exit code is 1.
- `epf_report.print_status` (`status`): lists the other sessions of the tool schema with status, wait event, seconds, blocking session (user, machine, program) and SQL_ID, so a stuck monitor or worker shows why.
- Test suite: once a process has exited its output is read for 15 more seconds at most; sqlplus processes left behind by a step (parent ended) are ended and fail the step ("no sqlplus session left running by the wrapper"); only T01 runs whatever the selection (T03 no longer runs with `--only`); T14 checks that the COMPACT step ran (nothing to compact on data an earlier run compacted).
- Checked locally: a `begin_run` that never answers (stand-in for sqlplus) now ends in 2 minutes with the diagnosis, exit 1, no sqlplus left, and the suite continues.
- Tool version 0.4.4.

How to test
1. EPFPG781 as it is (PAYMENTS untouched, LOGS purged, BANK_STATEMENTS LOB values cleared) or a fresh copy: `git pull`, `src\tests\e2e\run_tests.bat`.

## 2026-09-30 - Second end-to-end run on EPFPG783: 19/19 passed; review fixes (0.4.3)

Results (EPFPG783, 0.4.2, RETENTION_DAYS=365; log `logs/tests/2026-09-29_205549_EPFPG783/`, 01:06:04)
- All 19 tests passed: install (wrapper and install.sql), wrapper basics and usage errors, preflights, dry run, PAYMENTS through the wizard with redo sizing (3 x 150 MB -> 4 x 1 GB), undo tuning and a graceful stop after batch 9 (R-000025, exit 3, 12 temporary indexes dropped, undo restored), PAYMENTS to the end (R-000026: 87,309,042 rows in 00:27:07, 53,662 rows/s, 67.6 GB redo, 33.2 GB undo, used inside segments 31.2 -> 16.0 GB), LOGS with compaction (R-000027: 1.66 M rows in 00:00:43, 1.2 GB returned, verdict PASS), BANK_STATEMENTS clearing (R-000028: 2,426,081 LOB values) and full purge through the menu wizard (R-000030: 3,980,655 rows, verdict PASS), reports, final state clean.
- Live view: heartbeat lines showed wait events, blocking background processes (CKPT, LGWR, DBWn) and longops progress; pre-existing orphans are INFO.

Findings
- Undo: with undo tuning (undo_retention 60 s) UNDOTBS1 still grew 450 MB -> 2.1 GB (dry run: 5.5 M work keys) -> 5.2 GB (stopped run) -> 27.6 GB (PAYMENTS), and an autoextended datafile does not shrink. With autoextensible undo Oracle tunes retention to the longest running statement, and the purge is one PL/SQL call of about 30 minutes, so lowering undo_retention alone does not stop the growth. On EPFPG782 the 0.2.2 tuning also capped the datafile growth (8 GB) and the file stayed at 8 GB. Open decision (growth cap).
- BASICFILE estimate for clearing runs: DIRECTORY_DISPATCHING read 3.9 GB used after all its non-empty LOB values were cleared: the estimate scaled by rows, and 1.55 M of its 3.78 M rows had no LOB value.
- Measurements reused across kinds of purge: the wizard offered batch 30,000 for the BANK_STATEMENTS full purge from the redo measured by the clearing run.
- A stopped run logged a WARN TABLE_RESULT for every table with residual rows (17 in R-000025), counted in P5 although P1 and P2 already report the residual.
- Console clocks: section headers showed this machine's time (21:00), events the database time (15:00).
- A full purge after a clearing run of the same rows counts the cleared BASICFILE LOB space again (its baseline reads it as used); only when both run on the same rows.

Changes
- `epf_space`: BASICFILE estimate for clearing runs uses the values cleared out of the non-empty values of the eligible rows (R-000028 would read about 0 GB of LOB data left instead of 3.3 GB).
- `epf_purge`: redo and undo per root are taken only from earlier purges that did the same (deleting or clearing); TABLE_RESULT is a WARN for residual rows only when the module processed every batch (INFO after a stop or a failure).
- Wrapper: section headers use the database clock (the connection test reads it); the run header shows the offset when the clocks differ.
- Report: the BASICFILE note names the share of LOB data left.
- `EPF_WORK_KEY` becomes a global temporary table (ON COMMIT PRESERVE ROWS) and the purge session sets `temp_undo_enabled`: the key snapshot (5.5 M keys for PAYMENTS) writes no redo and no longer grows the undo tablespace, also in dry runs; it uses the temporary tablespace instead. Install replaces a permanent EPF_WORK_KEY (transient data only). Decided 2026-09-30.
- Undo tuning limits undo growth again (D18 revised, decided 2026-09-30, 4 GB): `epf_tuning.undo_apply(run_id, preflight_run_id)` also sets the growth limit (MAXSIZE) of the autoextensible undo datafiles to `undo_cap`: the largest of the undo tablespace's current size, setting `undo_cap_mb` (4096, new) and 4 x the undo of one batch; the limit is recorded in EPF_INSTANCE_CHANGE (UNDO_DATAFILE) before it is set and `undo_restore` puts it back. No file is resized. `run/undo.sql APPLY [run_id [preflight_run_id]]` (optional arguments). `EPF_RUN.with_undo_tuning` (new column; `start_run` parameter; `begin_run.sql` 9th argument, passed by the wrapper): the preflight of such a run reports the limit (`UNDO_CAP`) instead of a growth warning. The undo tablespace's datafiles are part of the report's DATAFILES section (size before and after), and the report shows the undo tuning the purge ran with.
- Test suite: T05 records the undo datafiles' growth limits; T12, T13 and T19 check they are back; T11 and T13 check the limit was applied; T13 checks the undo tablespace stayed within the larger of its size and 4 GB; any `Enter value for` prompt fails a step.
- Tool version 0.4.3.

How to test (a refreshed test database with unpurged data)
1. `src\tests\e2e\run_tests.bat`.
2. In the log: T11/T13 `UNDO_CAP` and `UNDO_GROWTH_LIMITED` in the undo tuning section, `UNDO_GROWTH_RESTORED` in the restore; T13 check "undo tablespace ... within ... MB"; T12/T13/T19 "original growth limit"; the purge report's DATAFILES section with the undo datafile; the dry run (T10) without undo growth (work keys in TEMP).

## 2026-09-29 - First end-to-end run on EPFPG783; fixes (0.4.2)

Results (EPFPG783, fresh copy of the same data as EPFPG782; RETENTION_DAYS=365; log `logs/tests/2026-09-29_193038_EPFPG783/test.log`)
- 10 passed, 9 failed. Install through the wrapper (new tablespace, user, 23 tables) and again with `install.sql`, undo restore, wrapper basics, usage errors (exit 4, no run created), `preflight.sql NEW`, reports, `status.sql`, final state: as expected.
- T08, T10-T16: every run through the wrapper failed at `begin_run.sql`: PLS-00103, the variable `l_run_id` was declared after the local function `arg` (PL/SQL requires variables before subprograms, also in anonymous blocks). `start_run.sql` had the same order. Run scripts are compiled only when they run, so neither install nor the stand-in for sqlplus could show it. No purge ran; the data of EPFPG783 is unchanged.
- T12 failed as a consequence (no stopped run); T18 skipped `advice.sql` (no preflight run from T08).
- T04 failed on the test itself: the installer prints `present  tablespace` (two spaces).
- Preflight on the fresh data (T09): all modules eligible (138,296 bulk payments, 1.7 M audit trail rows, 198,890 bank statement files); redo WARN with 3 x 150 MB logs (recommended batch 100); undo estimated 58.7 GB for PAYMENTS but no warning, because nothing was measured on this database yet (no rate).
- Output: sqlplus replaced runs of spaces with tabs (`SET TAB` defaults to ON); `UNDO_NOTHING_TO_RESTORE` was cut to 22 characters; `status` showed verdict `-` for a `preflight.sql NEW` run.
- Every sqlplus connection from the test machine took 13-15 s.

Changes
- `run/begin_run.sql`, `run/start_run.sql`: variable declared before the local function.
- Every entry script, `install.sql`, `uninstall.sql`, `environment.sql`: `SET TAB OFF`.
- `epf_purge` preflight: without a measured undo rate (first purge of a tree on the database) the undo kept by retention can be up to the undo of all eligible roots; UNDO_ESTIMATE warns ("may grow") when that exceeds the undo tablespace and undo tuning is not applied, so the wizard offers undo tuning on a first purge too.
- `run/preflight.sql NEW`: the run is ended with `epf_report.close_run` (checks and verdict recorded, as for wrapper runs).
- `epf_tuning`: event codes are padded, never cut.
- Wrapper: a run that cannot be created exits 1 unless the database refused it with one of the tool's own errors (ORA-20xxx: parameters, another active run), which stays 4.
- Test suite T04: pattern `present\s+tablespace`.
- Tool version 0.4.2.

How to test
1. `git pull`, then `src\tests\e2e\run_tests.bat` again on EPFPG783 (T03 upgrades it to 0.4.2; its data is untouched).
2. Return the new `test.log`.

## 2026-09-29 - End-to-end test suite; UTF-8 console fix

Changes
- `src/tests/e2e/run_tests.bat` + `run_tests.ps1` (new): runs tests T01-T19 (plan 12.5) against one test database without further input and writes `logs\tests\<timestamp>_<db>\test.log` with every command, output, exit code, run manifest, check and a summary. Safety: refuses to start unless `DESTRUCTIVE_OK=YES`, and T01 stops everything when the database name is not `EXPECTED_DB`, when it is a CDB or has more than one instance. `test.conf.example` documents the settings; `test.conf` is git-ignored.
- Wrapper (fix): with a UTF-8 console (code page 65001) .NET began the standard input of every sqlplus session with a byte order mark, so sqlplus would have rejected the CONNECT line of every session (not visible in the earlier checks because the stand-in for sqlplus ignored it). The wrapper now keeps UTF-8 input without the mark. Found by the suite: piped wizard answers arrived as `?30`.
- Checked locally: the whole suite against a stand-in for sqlplus that rejects a byte order mark, answers the precheck queries and keeps run state (stop, dry run, clearing and compaction events); all steps behave as intended, and no password appears in any output file.

How to test
1. Refresh a test database (not yet purged at 30 days), set `src\tests\e2e\test.conf`, run `src\tests\e2e\run_tests.bat`.
2. Return `test.log` from the session folder.

## 2026-09-29 - Phase 3 test results (EPFPG782), fixes (0.4.1)

Results (EPFPG782, 0.4.0)
- `install.sql`: EPF_TABLE_STAT.ACTION added, EPF_LINK_STAT and EPF_CHECK created, 78 grants, all objects valid. PASS.
- `undo.sql STATUS / RESTORE / STATUS`: the tuning applied by 0.2.2 (undo_retention 60 s, undotbs01 limit 8192 MB) restored to 900 s and 32768 MB; no active change left. PASS.
- `report.sql 2` (R-000002, PAYMENTS, 0.2.2): report printed, verdict PASS; P4 0 links (not counted by 0.2.x), Action column empty (not recorded by 0.2.x). OIDC_REQUEST_TOKEN appeared twice in the pasted results while P1 counts 22 tables; the query cannot return a table twice (one registry row, one stat row per phase), so this is taken as a copy artifact, to be checked in a saved report.
- `preflight.sql NEW` (R-000021): REDO_ESTIMATE and UNDO_ESTIMATE measured by R-000002. PASS, with one false warning: UNDO_ESTIMATE WARN for BULK_PAYMENT although PAYMENTS had 0 eligible roots (all purged), and the recommended batch size (740) came from that tree.
- `purge.sql NEW 30 LOGS LOGS - N Y` (R-000022, real purge with compaction): 1,722,146 rows in 00:00:48 (35,000 rows/s); residual 0; compaction of AUDIT_ARCHIVE, AUDIT_TRAIL and SPEC_TRT_LOG returned 1.2 GB to the tablespace (free 2.1 -> 3.3 GB). Verdict PASS WITH WARNINGS only because 1,195,572 AUDIT_TRAIL rows pointed at no AUDIT_ARCHIVE row before the purge (LINK_ORPHANS WARN, phase BEFORE); none after.
- `purge.sql NEW 30 BANK_STATEMENTS FULL 100 N N` (R-000023, undo tuning applied beforehand): 3,980,655 rows in 00:01:35 (1,989 batches); verdict PASS. Too fast to test the stop request. Space: 14.7 GB used before, 12.2 GB after although both tables are empty; to be diagnosed (LOB segments of deleted rows still counted as used).
- `status.sql`: severity PROGRESS ran into the event code (`PROGRESSBATCH_PROGRESS`).
- Words joined in the pasted output (`scansthis`, `0-`, `00`) are line wraps of the terminal when copying, not in the output.

Changes
- `epf_purge` preflight: REDO_ESTIMATE and UNDO_ESTIMATE skip trees with no eligible roots ("No rows before the cutoff"), a batch counts at most the eligible roots, and the undo kept by retention is at most the undo of all eligible roots (also shown). A module with nothing to purge no longer warns or lowers the recommended batch size.
- `epf_purge` orphans: LINK_ORPHANS is INFO before the purge and for orphans that were already there, WARN only for orphans the purge added (P4 still fails on those). Orphans in the application data no longer make P5 a warning.
- `epf_report`: column helpers never cut a value and always keep one space between columns; table column 45 characters (OPPAYMENTS.TRANSMISSION_EXECUTION_AUDIT has 39), Held 10, Orphans 12, status event columns 9 and 24.
- Wrapper: Ctrl+C requests a graceful stop also with `--non-interactive` when the console input is a keyboard (before: it ended the wrapper and left the worker running).
- Space diagnosis (per segment, R-000022 and R-000023): the LOB segments of DIRECTORY_DISPATCHING (7,986 MB) and FILE_DISPATCHING (4,254 MB) are BASICFILE (RETENTION 900) and read 7,947 MB and 4,189 MB used before and after the purge that emptied both tables; the table and index segments dropped as expected. `epf_space`: after a purge a BASICFILE LOB segment's use is the BASELINE measurement scaled by the share of rows the purge did not process (method `BASICFILE_EST`, the measured value when lower); `SPACE_CAPTURED` and P7 name these segments; the space section of the report explains them. R-000023 would read used 14.7 GB -> about 0.3 GB instead of 12.2 GB.
- Wizard: when the redo log sizing is chosen, the default batch size is computed for the new 1 GB logs from the largest redo per root (`EPF_ADVICE|REDO_PER_ROOT`), not from the current small logs (on 3 x 150 MB logs the recommendation is 100, with 1 GB about 530 for bulk payments).
- Tool version 0.4.1.

How to test (wrapper, new instance EPFPG783, from the Windows clone)
1. `epf_purge.bat install --tns <783>`: tool version 0.4.1. Optional: `environment.sql` survey of the new instance.
2. `--help`, `status` (no run recorded), `stop` (no active run: exit 1).
3. `preflight`: live events, report, run folder; exit 0 or 2.
4. `purge --depth PAYMENTS --undo-tuning` through the wizard: preflight run, redo sizing question (accept), batch size default for 1 GB logs, SYS password, review, `yes`; Ctrl+C after a few batches: STOPPED, undo restored, exit 3.
5. `status` after the stop.
6. Non-interactive rerun of PAYMENTS to the end with `--yes --undo-tuning` (passwords from EPF_PASSWORD / EPF_SYS_PASSWORD): in-run preflight, purge, restore, report; exit 0 or 2.
7. Wizard purge of LOGS,BANK_STATEMENTS: report shows the BASICFILE note, P7 names the scaled LOB segments.
8. Dry run with retention 1 (P1-P4, P6, P8 SKIP); `report` latest and by run id.
9. Usage errors: exit 4.
Return: console output, exit codes, `manifest.txt` and `report.txt` of each run folder.

## 2026-09-28 - Phases 3 and 4: report, compaction, wrapper (0.4.0)

Open questions answered with the plan defaults (to confirm)
- Compaction is delivered (opt-in, purge-only runs, default No).
- Rows not attached to any bulk payment (7,038 payments, 4,093 import audits and their children on EPFPG782) are kept, as today; they count as retained rows.

Phase 3 - report and compaction
- `epf_report` (new package): `evaluate` writes checks P1-P8 into the new table `EPF_CHECK` and derives the verdict (FAIL / PASS WITH WARNINGS / PASS, exit 1 / 2 / 0; 3 when the run was stopped); `close_run` evaluates and ends the run with the verdict; `print_report` prints header, steps, purge results per table, held roots, space inside segments per table, datafiles, redo and undo, checks, verdict and the machine-readable lines `EPF_CHECK|...`, `EPF_STEP|...`, `EPF_VERDICT|...`; `print_advice` (wizard) and `print_status`. A run ended FAILED fails P5 even without an ERROR event (a step outside the database failed, or the worker session ended).
- Orphans: after the purge (and before, for comparison) every registry link is checked for rows on the pointing side whose value no longer exists on the pointed side (new table `EPF_LINK_STAT`; `EPF_TABLE_STAT.orphan_rows`; `LINK_ORPHANS` WARN). A link protected by an enabled, validated FK is not scanned. P4 fails on new orphans only.
- Compaction (6.7): step `COMPACT` and `SPACE_POST_COMPACT` (phase `POST_COMPACT`). `start_run` accepts `with_compact = Y` for a PURGE that is not a dry run and does not reclaim. Events `COMPACTED` (bytes returned), `COMPACT_SKIPPED` (reason), `COMPACT_FAILED`, `ROW_MOVEMENT_KEPT`; check P8.
- `EPF_TABLE_STAT.action` (DELETE / CLEAR) so the report distinguishes residual rows from residual LOB values.
- `run/report.sql <run_id|LATEST>` (new). `run/purge.sql` takes a 7th argument `<compact>`; with NEW it ends the run with the report's verdict and prints the report (exit code = verdict). `run/preflight.sql` exits 2 when it finds warnings only (was 0).
- `install.sql` compiles `epf_report`; tool version 0.4.0.

Phase 4 - wrapper
- `src/bin/epf_purge.bat` (launcher) and `src/bin/lib/epf.ps1` (Windows PowerShell 5.1): actions purge, preflight, report, status, stop, install, uninstall and the wizard; options and exit codes as in plan 10.1; configuration file `src/config/epf_purge.conf` (example `epf_purge.conf.example`).
- Passwords: environment (`EPF_PASSWORD`, `EPF_SYS_PASSWORD`), configuration file or masked prompt; kept as SecureString; written only to sqlplus stdin (`CONNECT user/"pw"@tns`); never on a command line.
- One run = one monitor session (holds the run lock: `begin_run.sql`, then `poll.sql` every 2 s, `finish.sql` at the end; restarted and re-attached with `attach.sql` when a poll does not answer within 60 s) and one-shot worker sessions (`preflight.sql`, `purge.sql`, `report.sql`, SYS `redo_logs.sql` / `undo.sql`). `epf_log.poll` prints events, running steps, the worker's heartbeat (wait event, blocker, SQL_ID, longops, resumable suspension) and the run status.
- Live view: one line per event with `[ OK ]`, `[INFO]`, `[WARN]`, `[FAIL]`; heartbeat line `..` after 15 s without an event (console only unless it reports a suspension). Ctrl+C requests a graceful stop (`stop.sql`) instead of ending the wrapper.
- Wizard purge flow: connection, retention, mode, depth, dry run, compaction; a read-only PREFLIGHT run with these parameters; `advice.sql` findings drive the redo sizing and undo tuning questions and the batch size default (the recommendation); SYS password only when a SYS step was chosen; review; typed `yes` for a purge that deletes. The PURGE run refers to that preflight instead of repeating it. Undo tuning applied by the wrapper is restored in a `finally` block on every exit path.
- Run folder `logs/<yyyy-MM-dd_HHmmss>_R-<id>/`: `console.log`, `report.txt`, `manifest.txt` (parameters, step statuses, checks, verdict, exit code), `sqlplus_*.log` (raw worker output).
- `run/begin_run.sql`, `attach.sql`, `poll.sql`, `finish.sql` (monitor session; no EXIT), `advice.sql`, `status.sql`, `stop.sql <run_id|ACTIVE>` (new).
- Checked locally: PowerShell parser, ASCII only, and end-to-end runs of the wizard, non-interactive purge, failure paths and exit codes against a stand-in for sqlplus (no database here).
- Plan: 4.1, 6.7, 6.9, 8.1, 9.2, 9.3, 10.1, 10.2, 10.3, 13 (preflight errors exit 1, not 3).

How to test (EPFPG782)
SQL level, on the database machine:
1. If not done yet: `undo.sql RESTORE` as SYS (undo tuning from the PAYMENTS run is still active).
2. `git pull`, `install.sql`: tool version 0.4.0, `created  table EPF_LINK_STAT` and `EPF_CHECK`, all objects valid.
3. `report.sql LATEST` and `report.sql 2` (the PAYMENTS run R-000002): the report prints; P4 shows 0 links for runs of 0.2.x (orphans were not counted then).
4. `purge.sql NEW 30 LOGS LOGS - Y N` (dry run): report at the end, P1-P4, P6, P8 SKIP; exit 0 or 2 (`echo $?`).
5. `purge.sql NEW 30 LOGS LOGS - N Y` (LOGS purge with compaction): steps COMPACT and SPACE_POST_COMPACT, events COMPACTED / COMPACT_SKIPPED, P4 links counted, P8 with the bytes returned.
6. Stop: start `purge.sql NEW 30 BANK_STATEMENTS FULL 100 N N` in one session; once batches run, `stop.sql ACTIVE` from a second session; the first stops after its current batch and ends STOPPED (P1 WARN, exit 3). `status.sql` shows the run. Step 9 purges the rest.
Wrapper, on a Windows machine with sqlplus and a TNS alias for the PDB:
7. `src\bin\epf_purge.bat --help`; `src\bin\epf_purge.bat status --tns <alias>` (password prompt).
8. `src\bin\epf_purge.bat preflight --tns <alias>`: live events, report, run folder with `console.log`, `report.txt`, `manifest.txt`.
9. `src\bin\epf_purge.bat` (wizard) -> 1 Purge, BANK_STATEMENTS, FULL, dry run N, compact Y: preflight run, redo/undo questions if the findings call for them, batch size default = recommendation, review, `yes`. Watch the live view; `echo %ERRORLEVEL%` afterwards.
10. Ctrl+C during a purge run from the wrapper: `Stop requested`, run ends STOPPED, exit 3.
11. Return: console output of each step, and `manifest.txt` + `report.txt` of the wrapper runs.

## 2026-09-28 - Phase 2: undo retention only, output fixes

Results (EPFPG782, 0.2.2)
- `install.sql`: EPF_INSTANCE_CHANGE created, EPF_REDO dropped, all objects valid. PASS.
- `preflight.sql NEW`: 12 temporary indexes planned (10 FK columns, TRANSMISSION_EXECUTION_AUDIT link, NOTIFICATION_EXECUTION and TRANSMISSION_EXECUTION FK columns), 2 small tables scanned per batch. Redo estimate for BULK_PAYMENT 988.6 KB per root (measured on EPFPG781: about 930 KB); recommended batch size 100 with 3 x 150 MB logs (WARN). UNDOTBS1 450 MB, can grow to 32 GB, undo_retention 900 s, tuned up to 2,427 s in the last 24 hours. PASS.
- `redo_logs.sql 1024 4`: groups 4-7 of 1024 MB added, groups 1-3 dropped and their files removed. PASS.
- `undo.sql APPLY` (0.2.2): undo_retention 900 -> 60 s, undotbs01.dbf growth limit 32768 -> 8192 MB. PASS.
- `purge.sql NEW 30 PAYMENTS FULL 1000 N` (R-000002, undo tuning active, 4 x 1 GB redo logs): SUCCESS in 00:46:47. PROCESS_BATCHES 151 batches in 00:44:26 (about 19 s per bulk-payment batch, 34,000 rows/s; R-000008 without the FK indexes and with 150 MB logs: about 62 s per batch; previous tool: about 2 hours). 90,522,793 rows deleted; deleted = eligible and residual 0 for every table; retained rows unchanged. 12 temporary indexes created in 3 s and dropped. Redo 92.6 GB (701.8 KB per bulk payment, estimate was 988.6 KB), undo 42.1 GB (318.8 KB per bulk payment, 16.2 MB/s, 45% of redo). Used space inside segments 31.6 -> 17.8 GB.

Decision
- D18 revised: undo tuning lowers undo_retention only; the undo datafiles' size and growth limit are left unchanged.

Changes
- `epf_tuning.undo_apply`: undo_retention only. `undo_restore` still puts back any recorded datafile growth limit (the one applied on EPFPG782 by 0.2.2).
- `registry_data.sql`: setting `undo_max_mb` removed; settings no longer listed are deleted on install. Tool version 0.2.3.
- `epf_util.fmt_bytes`: values below 1 KB are rounded (an undo estimate printed 36 decimals).
- Run scripts: LINESIZE 32767, so long event lines are no longer wrapped (words were joined at the wrap point).
- `epf_purge`: an index need that is both a link column and an FK column names both in its detail.

How to test
1. After the PAYMENTS run: `undo.sql RESTORE` as SYS (restores undo_retention 900 s and the 32768 MB growth limit).
2. `git pull`, `install.sql`: tool version 0.2.3.
3. `undo.sql APPLY`: only UNDO_RETENTION_SET; `undo.sql STATUS` shows the datafile limit unchanged. Then `undo.sql RESTORE`.
4. `preflight.sql NEW`: REDO_ESTIMATE and UNDO_ESTIMATE measured by the PAYMENTS run; no wrapped lines.

## 2026-09-28 - Phase 2: undo tuning (D18), compile fix

Results
- EPFPG782 install of 64ae529: EPF_PURGE body did not compile (PLS-00103 at the index-needs types: PL/SQL requires every type declaration of a package body before its first subprogram). The types moved to the top of the body.

Decision
- D18: keep the previous tool's undo handling as an opt-in for the duration of a purge (undo_retention 60 s, undo datafiles capped at 8 GB) and restore the original values afterwards.

Changes
- `epf_redo` renamed `epf_tuning` (instance tuning for purges): `enlarge_redo` (as before), `undo_apply`, `undo_restore`, `undo_status`. Undo changes are recorded in the new table `EPF_INSTANCE_CHANGE` before they are made (retention SCOPE=MEMORY; datafile MAXSIZE never below the current size; refused with RETENTION GUARANTEE); restore puts back the recorded values.
- `run/undo.sql` (new): `APPLY | RESTORE | STATUS`. `run/redo_logs.sql` calls `epf_tuning.enlarge_redo`.
- `epf_purge`: undo measured per root tree (`TREE_UNDO`, with elapsed time) and per batch; preflight step `UNDO` (undo size and limit, retention, active tuning, `UNDO_ESTIMATE` per tree with undo per batch and the undo kept at the measured rate; WARN when the tablespace would grow without tuning or a batch needs more than half of it); `UNDO_TUNING` at the start and end of a run.
- `install.sql`: tool packages not delivered by this version are dropped (removes `EPF_REDO`). `uninstall.sql` refuses while undo tuning is active.
- Settings `undo_retention_s` (60), `undo_max_mb` (8192); grant on V_$UNDOSTAT; tool version 0.2.2.
- Plan: 3 (principle 9), 4.1, 6.9, 10.3, 15 (D5, D18).

## 2026-09-28 - Phase 2: redo logs (D17), redo measurement, batch size recommendation

Findings
- EPFPG781 has 3 online redo log groups of 150 MB; the PAYMENTS purge writes about 930 MB of redo per batch of 1,000 bulk payments, so each batch switches logs about six times and the session waits on `log file switch (checkpoint incomplete)`. The previous tool's optimize option replaced the logs with 4 x 1 GB.
- An external review of R-000008 counted PAYMENT_AUDIT rows as roots ("26,153 batches, 18 days"); the module has 151 batches. Redo per deleted row (about 1.1 KB) is normal for deletes that maintain several indexes.

Decision
- D17: redo log sizing becomes an opt-in, permanent, reported action (D5 revised).

Changes
- `epf_redo` (new, invoker rights, run as SYS): `enlarge(size_mb, groups)` adds groups (same directories and multiplexing, or Oracle-managed), switches and checkpoints until the smaller groups are inactive (archived in ARCHIVELOG), drops them and deletes their files through a temporary directory object. Non-CDB single instance only.
- `run/redo_logs.sql` (new): `<size_mb|-> <groups|->`, default 1024 MB x 4.
- `epf_purge`: redo measured per root tree (`TREE_REDO`), per batch in progress events, per module in `MODULE_END`; preflight step `REDO_LOGS` (`REDO_LOGS`, `REDO_ESTIMATE` per tree, `REDO_SUMMARY` with the recommended batch size; WARN when a batch exceeds a whole online log).
- `grants.sql`: SELECT on V_$LOG, V_$LOGFILE, V_$LOG_HISTORY, V_$MYSTAT, V_$STATNAME; EXECUTE on UTL_FILE. Tool version 0.2.1.
- Plan: 3 (principle 9), 4.1, 6.8, 10.3, 15 (D5, D17).

How to test (covers the FK index fix below as well)
1. Stop R-000008 (`EXEC epfpg.epf_control.request_stop(8)` as EPFPG) or recreate the instance.
2. `git pull`; `install.sql` as SYS: packages valid, tool version 0.2.1.
3. `preflight.sql NEW`: IDX_MISSING lists the FK columns; REDO_LOGS shows 3 x 150 MB; REDO_ESTIMATE per tree (estimated); REDO_SUMMARY WARN with the recommended batch size.
4. `redo_logs.sql 1024 4` as SYS: groups before/after, 4 x 1024 MB, old files removed.
5. `preflight.sql NEW` again: REDO_LOGS 4 x 1 GB; recommended batch size.
6. Purges (fresh instance: dry run, LOGS, BANK_STATEMENTS first; same instance: PAYMENTS only). PAYMENTS shows TEMP_INDEX_CREATED for the FK columns, redo per batch in BATCH_PROGRESS, TREE_REDO; then `preflight.sql NEW` shows the measured redo per root.

## 2026-09-28 - Phase 2: real runs and FK index fix

Results (EPFPG781, retention 30, batch 1000)
- LOGS (R-000005): SUCCESS in 00:01:36; AUDIT_TRAIL 1,658,823, AUDIT_ARCHIVE 252, SPEC_TRT_LOG 63,071 deleted, residual 0; about 24,000 rows/s.
- BANK_STATEMENTS CLOB (R-000006): SUCCESS in 00:03:27; 198,889 + 2,227,192 LOB values to clear; used space inside segments 31.4 -> 29.3 GB.
- BANK_STATEMENTS FULL (R-000007): SUCCESS in 00:01:35; FILE_DISPATCHING 198,890 (childless rows included) and DIRECTORY_DISPATCHING 3,781,765 deleted, residual 0; about 44,000 rows/s.
- PAYMENTS FULL (R-000008): about 3 minutes per batch of 1,000 bulk payments (151 batches), CPU-bound with heavy reads; roughly 1 GB of redo per batch. Stop requested.

Cause
- Deleting a parent row makes Oracle look for child rows through each FK; when the FK columns are not indexed it scans the child table once per deleted parent row. `bulk_payment_additional_info.bulk_payment_id` (46 MB) was not indexed and was skipped by the 64 MB threshold, so each batch scanned it about 1,000 times. The threshold only considered the engine's own per-batch lookups.
- Confirmed from V$SQL after 47-48 batches (per batch): DELETE BULK_PAYMENT 25.6 s and 5.9 M buffer gets for 1,000 rows (1,000 full scans of the 5,900-block child table); DELETE PAYMENT_ADDITIONAL_INFO 19 s for 534,000 rows (disk-bound, same work as the previous tool); DELETE PAYMENT 8 s, inflated by unindexed BULKPAYMENT_EXCEPTION and INVOICE. Unindexed FK columns into purge tables: BULK_PAYMENT_ADDITIONAL_INFO, BULK_SIGNATURE, MANDATORY_SIGNERS, OIDC_REQUEST_TOKEN, TRANSMISSION_EXCEPTION (BULK_PAYMENT_ID); BULKPAYMENT_EXCEPTION, INVOICE (PAYMENT_ID); INVOICE_ADDITIONAL_INFO (INVOICE_ID); NOTIFICATION_EXECUTION (IMPORT_AUDIT_ID, TRANSMISSION_EXECUTION_ID); TRANSMISSION_EXECUTION (TRANSMISSION_EXCEPTION_ID).
- Redo per deleted row is the same as with the previous tool and is not the cause.
- Copy-and-truncate for high-eligibility tables was considered and rejected: monthly purges keep most rows, so DELETE is the path that must be fast.

Fix (`epf_purge`)
- Supporting indexes also cover the columns of every enabled FK into a table the module deletes from, whatever the table size (composite FKs supported; an existing index whose leading columns are the FK columns counts). Child tables outside the registry cannot be indexed: WARN `IDX_MISSING` in preflight, `FK_UNINDEXED` in the purge.
- Preflight `SUPPORTING_INDEXES` lists link and FK columns per module.

How to test
1. Stop R-000008 if still running: as EPFPG, `EXEC epfpg.epf_control.request_stop(8)`; it ends STOPPED after the current batch.
2. `git pull`, re-run `install.sql` as SYS.
3. `preflight.sql NEW`: IDX_MISSING lines now include FK columns (at least BULK_PAYMENT_ADDITIONAL_INFO.BULK_PAYMENT_ID).
4. `purge.sql NEW 30 PAYMENTS FULL 1000 N`: TEMP_INDEX_CREATED for the FK columns; compare batch pace with R-000008.

## 2026-09-28 - Phase 2: dry run results

- `purge.sql NEW 30 ALL FULL 1000 Y` (R-000004): SUCCESS in 00:03:50. Baseline 96 segments, 33.0 GB allocated, 31.6 GB used. Snapshot: BULK_PAYMENT 138,296 roots in 139 batches with 5,543,406 derived keys; FILE_INTEGRATION 11,794 (ROWID, 12 batches); AUDIT_TRAIL 1,658,823 (1,659 batches); SPEC_TRT_LOG 63,071 (ROWID, 64 batches); FILE_DISPATCHING 198,890 (199 batches). No held roots, no shared batches, no held AUDIT_ARCHIVE rows.
- Rows not reachable from any root stay (same as the previous tool): PAYMENT 7,038, PAYMENT_ADDITIONAL_INFO 83,926, WORKFLOW_EXECUTION 7,027, APPROBATION_EXECUTION 3,453, IMPORT_AUDIT 4,093, IMPORT_AUDIT_MESSAGES 57,644, NOTIFICATION_EXECUTION 7,918, PAYMENT_AUDIT 13,949. Open scope question for later: whether rows without a bulk payment should be purged by their own date.

## 2026-09-28 - Phase 2: batch numbering fix

Results so far (EPFPG781)
- `install.sql` upgrade: columns, indexes and EPF_HELD_ROOT added; CREATE/DROP ANY INDEX revoked; all packages valid, tool version 0.2.0. PASS.
- `preflight.sql NEW` (R-000002): registry 0 errors / 0 warnings; 13/24 link columns indexed, 1 temporary index planned (TRANSMISSION_EXECUTION_AUDIT.BULK_PAYMENT_ID, 445 MB), 10 small tables scanned; every root row is older than the 30-day cutoff (BULK_PAYMENT 138,296, FILE_INTEGRATION 11,794, AUDIT_TRAIL 1,658,823, SPEC_TRT_LOG 63,071, FILE_DISPATCHING 198,890). PASS.
- Dry run `purge.sql NEW 30 ALL FULL 1000 Y`: did not finish. The batch-numbering MERGE joined EPF_WORK_KEY to itself on group_key (no index), so every root rescanned all roots of its table; with 1.66 M AUDIT_TRAIL roots this never completes. Cancelled; nothing in the application schemas was changed.

Fix (`epf_purge`)
- Batch numbers are assigned in the root snapshot INSERT (`ROW_NUMBER` in key order); the MERGE is removed.
- Roots grouped because their trees reference each other are moved to the batch of the group's smallest key, updated by root key (index).
- EPF_WORK_KEY statistics are gathered after each tree's snapshot, before the held-back and grouping queries run.

How to test
1. `git pull`, re-run `install.sql` as SYS (packages only change).
2. Repeat the dry runs of the phase 2 test (FULL, then CLOB). Expected duration: minutes, mostly the exact counts of the largest tables (PAYMENT_ADDITIONAL_INFO 57 M rows, PAYMENT_AUDIT 25 M rows).

## 2026-09-28 - Phase 2 (purge engine)

Decision
- D16: kept rows that reference rows being purged are protected by holding back the referenced root (plan 6.1.1).

Database objects (`src/sql/install/`)
- `epf_purge` (new): registry-driven purge. Key snapshot with derived keys per root; held-back roots through every enabled FK (any schema) and held rows through reverse links (shared `audit_archive`); roots that reference each other share a batch; modes FULL / CLOB / LOGS / CLOB_N_LOGS; one transaction per batch, leaves first; failing batch rolled back, module stops, other modules continue; stop requests between batches; progress events; counts BEFORE / AFTER per table; temporary supporting indexes; `preflight` for the read-only checks.
- `epf_space` (new): segment, datafile and in-segment snapshots (DBMS_SPACE.SPACE_USAGE for ASSM and SECUREFILE, statistics estimate for manual segment space management).
- `epf_registry`: checks REG_KEY_TYPE, REG_KEY_UNIQUE, REG_DATE_TYPE, REG_SOURCE_KEY, REG_REVERSE_SOURCE, REG_ROOT_KEY_FK; grant check includes INDEX.
- `epf_log`: `current_step`, `step_skip_pending`.
- `epf_control`: `start_run` refuses `with_compact = Y` (compaction comes with phase 3).
- `tables.sql`: column-level upgrade (`add_column`); `EPF_WORK_KEY.root_key/group_key` and two indexes; `EPF_HELD_ROOT`; `EPF_TABLE_STAT.held_rows`; `EPF_TEMP_INDEX.table_owner`.
- `grants.sql`: `INDEX` on registry tables and `EXECUTE` on `DBMS_SPACE`; `CREATE ANY INDEX` / `DROP ANY INDEX` revoked (temporary indexes are created in EPFPG's own schema and tablespace); `SELECT` on tables outside the registry with an FK into it.
- `registry_data.sql`: setting `temp_index_min_mb` (64); tool version 0.2.0.
- `uninstall.sql`: no longer refuses because of temporary indexes (EPFPG owns them; they go with the user).

Entry scripts (`src/sql/run/`)
- `purge.sql` (new): `<run_id> - - - - -` or `NEW <retention> <depth> <mode> <batch_size> <dry_run>`.
- `preflight.sql`: calls `epf_purge.preflight` (registry, supporting indexes, eligible roots).

Plan: 3.4 (privileges), 5 (tables), 6.1 / 6.1.1 (snapshot, held back), 6.4 (temporary indexes in EPFPG_DATA, no date-column indexes), 6.7 and 13 (compaction in phase 3), 15 (D16).

How to test
1. `git pull`, then `sqlplus -L "sys@<pdb_service> AS SYSDBA" @src/sql/install/install.sql <epfpg_password>` (upgrade). Expected: added columns and indexes, `created table EPF_HELD_ROOT`, `revoke CREATE ANY INDEX` / `DROP ANY INDEX`, `EPFPG objects valid, tool version 0.2.0`. If a package does not compile, the errors are listed just above.
2. `sqlplus -L -S "epfpg/<password>@<pdb_service>" @src/sql/run/preflight.sql NEW`. Expected: PURGE_SCOPE, REG_SUMMARY, IDX_MISSING lines, IDX_SUMMARY, one ROOTS_ELIGIBLE per root table.
3. Dry run, FULL: `sqlplus -L -S "epfpg/<password>@<pdb_service>" @src/sql/run/purge.sql NEW 30 ALL FULL 1000 Y`. Expected: SPACE_CAPTURED BASELINE, KEYS_SNAPSHOT per root, ROOTS_HELD / ROWS_HELD if any, TABLE_ELIGIBLE for 27 tables, MODULE_END per module, PURGE_END. Changes nothing in the application schemas.
4. Dry run, CLOB: same with `CLOB` instead of `FULL`: TABLE_ELIGIBLE shows non-empty LOB values.
5. Only on a test copy of the database (NOARCHIVELOG: take a backup or export first): a real purge, smallest module first, e.g. `purge.sql NEW 30 - LOGS 1000 N`, then `purge.sql NEW 30 BANK_STATEMENTS FULL 1000 N`, then `purge.sql NEW 30 ALL FULL 1000 N`. Expected: TEMP_INDEX_CREATED/DROPPED, BATCH_PROGRESS, TABLE_RESULT with residual eligible 0, SPACE_CAPTURED POST_PURGE.
6. Return the console output of each step.

## 2026-09-28 - Phase 1 test results and survey review

Results (database EPFPG781, 19c EE 19.24, non-CDB)
- `install.sql`, first run: reference tablespace DATA (largest share of OPPAYMENTS segments), `EPFPG_DATA` created at `/files2/oradata19/EPFPG781/epfpg_data01.dbf`; user, 18 tables, registry (27 tables, 23 links), 72 grants, packages valid. PASS.
- `install.sql`, second run: tablespace, tables and user reused, same result. PASS (idempotent).
- `preflight.sql NEW`: run R-000001, 27/27 tables present, 22 FKs into registry tables, all covered by the processing order, 0 errors, 0 warnings. PASS.
- `environment.sql`: reviewed; the facts and their design consequences are in plan section 12.4.
- Not yet run: `uninstall.sql` followed by a new install.

Changes
- `environment.sql` section 14 lists the previous tool's objects by exact name. The `EPF%` prefix matched the application's own packages in OPPAYMENTS (EPF_BIND, EPF_CONTEXT, ...), which are not tool objects.
- Plan: 7.3 (IOT primary key index moved with the table, never UNUSABLE), 12.4 (target environment), 14 (previous tool objects identified by exact name only).
- Decision D15 (plan 7.6, 15): the reclaim locks and disconnects owners of objects in the target tablespaces plus accounts with INSERT/UPDATE/DELETE on those objects (direct or through a role) or sessions using them, each listed with the reason at startup.

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

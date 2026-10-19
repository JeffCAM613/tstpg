# EPF Data Purge: tests

The tests of the tool, for the people who develop it. This folder is not part of a release: `tools\make_release.bat` builds the copy a client receives without it.

```text
e2e\       the end-to-end test suite (run_tests.bat) and its configuration example
verify\    the reclaim labs and the survey of a test database, which the suite runs
parity\    the parity check against the previous tool (legacy\)
sim\       the simulator of the screens as they were designed (epf_sim.bat)
```

## The end-to-end test suite

The end-to-end test suite runs every feature against a test database, and changes it: it purges every module, clears LOB values, compacts tables, enlarges the online redo logs during the purges (put back after each) and changes undo_retention during them. Its reclaim tests work on tablespaces they create and remove. Run it only on a copy that can be discarded.

1. Copy `src\tests\e2e\test.conf.example` to `src\tests\e2e\test.conf`, and set TNS, EXPECTED_DB and DESTRUCTIVE_OK=YES.
2. Run `src\tests\e2e\run_tests.bat` for the whole suite (about 3 hours), or a part of it, such as `src\tests\e2e\run_tests.bat --only T18A,T18B`.
3. `src\tests\e2e\run_tests.bat --digest` writes a short summary of the last test session and of the runs after it to `logs\digest.txt` and copies it to the clipboard: each run with its checks, every step with its duration, key events (a large move with the time it took), restore lines and summary, and the time of the runs in all. With the SYS password at hand (EPF_SYS_PASSWORD, or SYS_PASSWORD in test.conf) it adds the database as it is now: how the instance started, the tool installed and whether its objects are valid, the online logs, and every datafile and temporary file with its size, the free space inside it and the step it grows by.
4. `src\tests\e2e\run_tests.bat --sys redo_logs.sql SET 200 3` runs a SYS script of `src\sql\run` (`redo_logs.sql`, `undo.sql`) on the test database of test.conf with the arguments that follow, as typed in SQL*Plus, after checking the database name. Its output is shown and kept in `logs\sys\`, and the digest lists what the script did. Test steps use it in place of SQL*Plus by hand, so that the digest carries them too.
5. `src\tests\sim\epf_sim.bat` plays the screens and questions of a purge and a reclaim with scripted figures, as they were designed before the tool followed them: it connects to nothing and needs no database. `epf_sim.bat --help` lists what it takes; `--sim` chooses the state the database is found in (a requirement not met, the tool not installed, a run that fails). It writes a sample `report.html` under `logs\sim\`.

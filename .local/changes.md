# Change history

Newest first. Each entry: date, what changed, why, and how to test when relevant.

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

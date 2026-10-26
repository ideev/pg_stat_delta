# Index sampler: checking the supplied full-join query

The current pg_stat_user_indexes_delta adopts the proposed compact result, flat
snapshots, FULL OUTER JOIN by indexrelid, and schema/table/index ordering. It stays
in extension version 0.1.0. The supplied counter-only reset logic is corrected.

## Reset findings

A separately named copy of the supplied query was exercised against two relevant
integration cases. Both returned ok when reset was expected:

- Resetting an index whose scan counters were still zero.
- Resetting a previously scanned index and then doing enough scans to exceed all
  three old counter values before the second snapshot.

Counter decreases can identify a discontinuity, but monotonic values do not prove
that a reset did not occur. The corrected implementation retains the database
reset timestamp internally, read once per snapshot. PostgreSQL 17 index resets
update that marker. Its change conservatively invalidates every index's deltas
in the sample, since it cannot identify which object was reset.

Another issue is independent per-counter masking: the proposed status may say
reset while nondecreasing counters still return numbers. The corrected function
sets **all three cumulative deltas to NULL** whenever the marker changes, any
counter decreases, or one snapshot row is missing. Status is ok/reset/missing;
reset indicates an unreliable sample and does not prove a particular cause.

The final last_idx_scan timestamp remains available from the second row. A missing
second row yields NULL; a missing first row can still have a last-scan timestamp.

## Implementation and execution ordering

The first snapshot selects identity fields and three counters, without the
last-scan timestamp; the second includes that timestamp too. All fields are
native scalar types. A flat measured subquery computes the reset classification
once per row. OFFSET 0 prevents it being expanded into each output CASE without
creating another materialized snapshot. There is no WindowAgg or composite row.

EXPLAIN VERBOSE on PostgreSQL 17.11 showed the statistics getters only in the root
Nested Loop projection of each snapshot. The clear CTE is among its relational
inputs (possibly nested within joins). Thus the verified plans consume the clear
row before projecting the getters. This source view has no index aggregation
like the table-statistics view; the table sampler's explicit pre-scan OFFSET
barrier is not copied mechanically. CROSS JOIN textual order is not a general
SQL side-effect-order guarantee; plans and concurrent tests must be rechecked
when changing the source/query shape or PostgreSQL version.

Timing aggregates consume entire snapshots and return one timing row, including
an empty index set. The second clear depends on sleep. FULL OUTER JOIN uses
indexrelid, not relid: multiple indexes on the same table remain independent.

## Validation

The corrected implementation passed:

- Plain, bitmap and index-only scans, with distinct tuple-fetch semantics.
- Concurrent plain scans in none/cache/snapshot modes after cached reads.
- Explicit index/database resets and reset followed by counter catch-up.
- Creation/rename visibility, dropped-index counter disappearance, independent
  indexes of the same table, repeated calls and invalid intervals.
- Default/explicit 0.1.0 installation, empty index sets and a non-superuser call
  after extension schema relocation.
- Two additional join configurations: hash joins disabled with collapse limits
  of one; and merge/nested-loop/materialization preferences disabled. JIT is
  disabled for the deliberately penalized paths. Required nodes can still be used.
- The actual SQL with controlled snapshots: missing-before/after, only one counter
  decreasing while the others increase, and multiple indexes sharing one relid.
  All invalid deltas must be NULL, with correct second-snapshot timestamp behavior.

The two database-reset columns are removed from the public return type, as in the
supplied signature. This requires recreating the development extension rather
than CREATE OR REPLACE FUNCTION; see README for the no-CASCADE instructions.

## Local performance comparison

PostgreSQL 17.11, Debian 13, default 4 MB work_mem. Compared the previous query,
the supplied proposal and the corrected query on the same disposable catalog:
100 and then 1,000 empty user tables, each with a primary-key index and text/TOAST
storage. Exactly one user index per table is returned. Sleep was zero; each query
had two warmups and seven measured EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT
JSON) runs, rotating variant order.

| Indexes | Query | Median execution | Range | Median planning | Estimated total cost |
| --- | --- | --- | --- | --- | --- |
| 100 | Previous | 1.995 ms | 1.420–2.551 ms | 2.089 ms | 158.75 |
| 100 | Proposed | 1.717 ms | 1.304–2.429 ms | 1.805 ms | 156.48 |
| 100 | Corrected | 1.637 ms | 1.362–2.364 ms | 2.243 ms | 157.57 |
| 1,000 | Previous | 13.278 ms | 12.282–14.412 ms | 2.159 ms | 883.54 |
| 1,000 | Proposed | 12.505 ms | 10.972–13.177 ms | 2.229 ms | 873.63 |
| 1,000 | Corrected | 10.800 ms | 10.135–13.165 ms | 2.175 ms | 874.72 |

The corrected median at 1,000 indexes was about 19% lower than the previous
implementation. Timing ranges overlap; these results do not establish a universal
speedup or show that reset checks themselves improve execution time. The new
public result is also narrower (13 columns rather than 15), so this is a comparison
of complete implementations rather than a controlled join-algorithm experiment.

The previous query had one WindowAgg; neither full-join query did. All three had
one in-memory sort. At 1,000 rows sort space fell from 595 kB to 298 kB. Final-run
shared hits were 6,349/6,345/6,346; there were no shared reads or temporary writes.
These are instrumented internal-query execution times, not CPU measurements.
Client transfer, function-wrapper overhead and intentional waiting are excluded.
The benchmark used empty relations, not a production scan workload.

Inspect the current inner query with:

```sh
python3 tests/explain_statistics.py --view indexes
```

Use --source to inspect an earlier per-function SQL file and repeat measurements
against representative catalogs before drawing broader conclusions.

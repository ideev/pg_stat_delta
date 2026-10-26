# Index block-I/O sampler: full-join validation

pg_statio_user_indexes_delta now uses flat native snapshots and FULL OUTER JOIN
by indexrelid. This completes the flat/full-join baseline for all five functions,
in extension version 0.1.0. The compact public result follows the supplied
signature, without the two database-reset timestamp columns.

## Delta validity

The proposal correctly classifies missing rows, database reset-marker changes,
and decreasing block counters. Its output CASE expressions, however, do not use
that classification: nondecreasing counters can return zero or positive deltas
even when status is reset or counter_decreased.

A separately named copy of the proposal failed an explicit reset/catch-up test.
After resetting a warmed index, scanning it to establish a baseline, resetting
again and executing five range scans, it returned 0 instead of NULL for a read
delta on a row marked reset. The hit delta can also be a plausible but invalid
number after renewed activity.

The corrected query computes a single per-row status and exposes **both deltas
only when status is ok**. All other statuses invalidate both, even if one counter
is unchanged or zero. Source zeros remain zero for valid samples; NULL and missing
rows are not replaced with fabricated zero activity.

The database marker remains internal, read once per snapshot. PostgreSQL 17
index/table/function resets can change it; conservative invalidation therefore
applies across the database. Decreasing counters without a marker change produce
counter_decreased, not a claimed explanation of the discontinuity.

## Query and ordering

Both snapshots contain the view's five identity fields and two block counters,
without composite records or JSON. Timing aggregates fully consume each snapshot
and yield exactly one timing row, including for an empty index set. The second
clear depends on sleep.

EXPLAIN VERBOSE on PostgreSQL 17.11 showed statistics getters only in the root
Nested Loop projection of each snapshot. The clear CTE is a relational input
below that projection, so the verified plans consume clearing before evaluating
the getters. As for the index-statistics sampler, this view does not have the
index aggregation that required a pre-scan OFFSET barrier in the table samplers.
CROSS JOIN textual order alone is not a general SQL side-effect-order guarantee;
recheck plans and concurrent tests on query-shape or PostgreSQL changes.

The measured subquery calculates status and differences once per row. OFFSET 0
prevents inlining and duplicate validity calculations without another materialized
snapshot. There is no WindowAgg. Final ordering is by schema, table and index.
Index identity, not table relid or names, is used for matching.

## Validation

Twelve relevant checks passed across the corrected index-I/O/installation runs:

- Index hits in none/cache/snapshot modes and indexes sharing one table.
- Index/database resets, and reset followed by enough work to recover counters.
- Create/rename/drop visibility, user-only scope, repeated calls, invalid intervals.
- Two alternate join configurations: hash joins disabled with collapse limits of
  one; separately merge/nested-loop/materialization preferences disabled. JIT is
  disabled for the deliberately penalized paths.
- Actual SQL with controlled snapshots: multiple indexes on the same relid,
  missing-before/after, only one counter decreasing, unchanged zero counters,
  and a reset marker change despite unchanged/increasing counters. Both deltas
  must be NULL for every invalid case.
- Fresh/default/explicit 0.1.0 installation, an empty index set and a non-superuser
  call after extension schema relocation.

The optional private-cluster cold-buffer check passed with 3 index block reads
and 0 index buffer hits after its own clean restart. It does not restart existing
servers or clear the OS cache, and does not prove physical device reads.

### Cache-priming test correction

During this review the existing cache tests were strengthened. Their old
count(*) prefix could avoid evaluating statistics getters entirely. EXPLAIN
VERBOSE confirmed no pg_stat_get_* expressions for count(*) on all five source
views, but did show them for sums of selected counters.

Prefixes now read actual counters: xact_commit, n_tup_ins, idx_scan,
heap_blks_hit and idx_blks_hit, respectively. Both the three-cache-mode methods
and alternate-plan methods were rerun for all five functions with these prefixes.
The replacement makes the claimed preexisting cache state meaningful. It does
not change application SQL or affect the performance comparison below.

## Local comparison

PostgreSQL 17.11, Debian 13, default 4 MB work_mem. The catalog had 100 and then
1,000 empty user tables, each with a primary-key index and text/TOAST storage.
Each query had two warmups and seven EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT
JSON) measurements with rotating order and zero sleep. Functional and cold-buffer
tests finished before this comparison ran.

| Indexes | Query | Median execution | Range | Median planning | Estimated total cost |
| --- | --- | --- | --- | --- | --- |
| 100 | Previous | 1.622 ms | 1.514–2.754 ms | 1.908 ms | 158.74 |
| 100 | Proposed | 1.598 ms | 1.463–2.342 ms | 2.151 ms | 157.36 |
| 100 | Corrected | 1.561 ms | 1.260–1.619 ms | 1.943 ms | 157.36 |
| 1,000 | Previous | 11.055 ms | 9.040–12.051 ms | 1.744 ms | 883.52 |
| 1,000 | Proposed | 10.056 ms | 8.522–11.240 ms | 2.046 ms | 873.44 |
| 1,000 | Corrected | 9.743 ms | 8.790–11.676 ms | 1.972 ms | 873.44 |

The corrected median at 1,000 indexes was about 12% lower than the previous
implementation. Ranges overlap; this is a local observation, not a reliable
production speedup or evidence that reset checks themselves accelerate SQL.
The result also narrowed from 13 to 11 columns, so this compares whole query
implementations rather than an isolated join algorithm.

The previous plan had one WindowAgg; the full-join plans have none. All have one
in-memory sort, whose purpose changes from window ordering to final output
ordering. At 1,000 rows sort space fell from 564 kB to 282 kB. This does not mean
total memory halved: hash joins and other nodes consume memory too. Final-run
shared hits were 6,349/6,346/6,346; no shared reads or temporary writes occurred.
These are instrumented internal-query times, not CPU measurements. They exclude
client transfer, function-wrapper overhead and intentional waiting.

Inspect the current query with:

```sh
python3 tests/explain_statistics.py --view statio_user_indexes
```

The helper accepts --source for an earlier SQL revision. Recreate the development
extension without CASCADE to apply the changed return type; CREATE OR REPLACE
FUNCTION cannot change the old returned row type in place. See README.

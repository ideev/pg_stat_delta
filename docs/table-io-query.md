# Table block-I/O sampler: validating the full join

pg_statio_user_tables_delta now uses flat native snapshots and FULL OUTER JOIN by
relid, with the supplied compact signature and schema/table ordering. It remains
part of extension version 0.1.0. The database reset timestamps remain internal;
they are no longer returned as two extra columns.

## Correctness finding

The supplied query already detects a changed database reset marker. However, its
eight output CASE expressions check only whether each counter is nondecreasing.
A row can therefore have status reset and still return zero or positive deltas.
After reset/catch-up those differences are not valid interval activity.

A separately named copy of the proposal failed the existing table-reset check:
one delta was 0 where an invalid sample required NULL. The tested index-reset
case passed, illustrating why checking one counter is insufficient.

The corrected query computes one per-row status and returns all eight cumulative
deltas only when it is ok. Missing rows, changed reset markers, or any decreased
component invalidate the whole row. Status values remain exactly the supplied
ok/reset/counter_decreased/missing. NULL source components stay NULL, while valid
unchanged counters remain zero. A counter decrease alone does not establish the
cause; index removal can decrease a table's aggregate index counters too.

The PostgreSQL 17 reset marker is read once per snapshot. Table/index/function
resets can change it; conservative invalidation applies across all sampled tables.
No attempt is made to infer reset validity from monotonic counters alone.

## Ordering and query structure

This source view aggregates index/TOAST statistics. As with the table-statistics
sampler, each flat read retains a zero OFFSET whose InitPlan consumes the clear
CTE before entering the source view. A textual CROSS JOIN alone is not used as a
general ordering guarantee for source aggregates. The reason is commented next
to both OFFSET clauses. Sleep remains dependent on complete first-snapshot
consumption, and timing aggregates return one row even for an empty user set.

The measured CTE now passes raw counter endpoints to status-ok CASE expressions;
invalid rows never perform subtraction. OFFSET 0 was removed: it does not
guarantee a single status evaluation in all plans. See the
[current uniform policy](uniform-snapshots.md). The measurements below record
the earlier corrected full-join implementation.

## Validation

The corrected function passed thirteen relevant checks across the runs:

- Nine table-I/O tests: heap hits in none/cache/snapshot modes; index and TOAST
  activity; table/index/database resets; reset followed by renewed index activity;
  catalog rename/create/drop behavior; user-only scope, repeated calls and input
  validation. A test method can contain multiple related cases.
- Fresh/default/explicit 0.1.0 installation and a non-superuser call after schema
  relocation.
- Cached reads with two alternative join configurations (hash joins disabled
  with collapse limits of one; separately merge/nested-loop/materialization
  preferences disabled). JIT is disabled for deliberately penalized paths.
- Actual SQL against controlled snapshots: missing-before/after, unavailable
  index/TOAST components, valid zeros, a single decreasing component while
  another grows, and changed reset markers with nondecreasing/zero values.

The controlled test requires every invalid delta to be NULL, rather than checking
only the status or only one field. No source component is replaced with zero.

The optional private-cluster check also passed. After cleanly restarting only its
own temporary cluster it observed 5 heap block reads, 3 table-index reads, 41 TOAST
heap reads and 2 TOAST-index reads. The existing cluster and OS cache were not
restarted/cleared. These are PostgreSQL block reads, not proof of device I/O.

## Performance comparison

PostgreSQL 17.11, Debian 13, default 4 MB work_mem. The comparison used the same
catalog for all three queries: 100 and then 1,000 empty user tables, each with a
primary-key index and text/TOAST storage. Sleep was zero. Each query had two
warmups and seven EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) measurements,
rotating query order. The reported repeat was run after functional and cold-buffer
checks had finished, to avoid overlapping those workloads.

| Tables | Query | Median execution | Range | Median planning | Estimated total cost |
| --- | --- | --- | --- | --- | --- |
| 100 | Previous | 2.854 ms | 2.386–4.018 ms | 2.181 ms | 3288.41 |
| 100 | Proposed | 2.603 ms | 2.252–3.232 ms | 1.955 ms | 3289.22 |
| 100 | Corrected | 2.694 ms | 2.299–3.386 ms | 2.224 ms | 3286.20 |
| 1,000 | Previous | 23.159 ms | 20.576–26.420 ms | 1.915 ms | 21553.88 |
| 1,000 | Proposed | 22.265 ms | 20.308–25.020 ms | 2.086 ms | 21554.47 |
| 1,000 | Corrected | 22.856 ms | 19.760–31.195 ms | 2.079 ms | 21536.66 |

There is no convincing runtime improvement in this repeat: the corrected median
at 1,000 rows is only about 1.3% lower and the ranges substantially overlap. Do not
interpret this as a reliable speedup. The original proposal's invalid-delta issue
still prevents adopting it unchanged, regardless of its timings.

The previous plan had one WindowAgg, while both new plans have none. Each query
has one sort, but its purpose changes from window ordering to the final output
ordering. At 1,000 rows sort space fell from 533 kB to 267 kB, using in-memory
quicksort. This does not establish that total process memory halved: hash joins
and other nodes consume memory too. Final-run shared hits were 18,255/18,252/18,252;
there were no shared reads or temporary writes. The result is narrower (15 fields
rather than 17). This compares complete implementations, not just join algorithms.

These are instrumented internal-query execution times, not CPU measurements or
production guarantees. They exclude intentional sleep, client transfer and the
PL/pgSQL wrapper. Catalog shape, load, statistics mode and caches affect results.

Inspect the current internal query with:

```sh
python3 tests/explain_statistics.py --view statio_user_tables
```

The helper accepts --source for a saved earlier per-function SQL revision. Recreate
the development extension, without CASCADE, to load the changed return type as
documented in README; CREATE OR REPLACE FUNCTION cannot change the old row type.

# Database sampler: flat snapshots and a full join

The database function now follows the supplied FULL OUTER JOIN implementation.
This comparison concerns only the database sampler. A subsequent table-sampler
revision is described in table-query.md. All functions remain version 0.1.0.

## Query changes

- Snapshots contain flat pg_stat_database columns, rather than a composite row.
- FULL OUTER JOIN matches by datid and retains an unmatched snapshot row.
- UNION ALL, lag(), WindowAgg and the window sort are removed. The final ORDER BY
  datid remains, so the default measured plan still has one sort.
- Both cache-clear CTEs are joined to their reads. first_time and second_time
  retain aggregates, which consume the snapshots and yield a single timing row.
- The reset condition is a direct comparison of stats_reset. Equal NULL markers
  are accepted. The missing status prevents subtraction, even when both reset markers are NULL.

## Execution-order checks

All snapshots now use a zero OFFSET InitPlan to consume the corresponding clear
CTE before entering the source scan. This replaces the earlier CROSS JOIN
implementation whose observed PostgreSQL 17.11 projection order was suitable but
was source/plan-specific. Every delta now uses a named status guard, including
the connection-count difference. Invalid rows retain start/end gauges but return
NULL for num_backends_delta. See [current uniform policy](uniform-snapshots.md).
The runtime comparison below records the earlier full-join revision.

Concurrent tests exercised cached reads in none, cache and snapshot modes, as
well as these additional configurations (with JIT disabled for the deliberately
penalized join paths):

- Hash joins disabled, join_collapse_limit=1, from_collapse_limit=1.
- Merge joins, nested loops and optional materialization disabled. Required
  executor nodes may still be used when PostgreSQL has no alternative.

The tests prepopulate the transaction's statistics cache, generate committed
transactions while sampling sleeps, and check that the second snapshot sees
them. Reset handling and repeated calls in one transaction are also checked.
These results validate the supported PostgreSQL 17.11 implementation; execution
plans should be rechecked when changing the query shape or PostgreSQL version.

## Returned row type

The public result now has four additional fields:

- session_time_delta: cumulative session time, milliseconds.
- active_time_delta: cumulative active time, milliseconds.
- idle_in_transaction_time_delta: cumulative idle-in-transaction time, milliseconds.
- sessions_delta: newly established sessions.

These are source statistics, subject to publication delays and state transitions;
they are not continuous timers or counts of currently connected backends. A
client-side pause inside a transaction, followed by active work and disconnect,
is used to test publication of all four counters. These fields are tested on
PostgreSQL 17, not claimed to have been introduced in that version.

stats_reset_start and stats_reset_end are removed from the returned columns.
The markers remain internal to reset validation. Status is ok, reset or missing.
The last case is defensive: an ordinary call still holds one MVCC catalog
snapshot and cannot promise to discover newly created databases during sleep.

Controlled-snapshot tests execute the actual query with known rows to cover
missing-before, missing-after, changed reset markers, matching NULL reset markers,
and the datid=0 shared-object row. All cumulative deltas must be NULL for missing
or reset rows; valid rows return the expected differences.

Because the return type changes, CREATE OR REPLACE FUNCTION cannot reload the
old signature in place. Recreate the development extension without CASCADE as
documented in README; dependent callers and custom grants need attention.

## Local comparison

Compared the preceding committed implementation (56f0b44) with the new query on
PostgreSQL 17.11, Debian 13. The source had four rows: three databases and the
shared-object row. Intentional sleep was zero. Each variant had two warmup runs
and twenty measured EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, FORMAT JSON) executions;
execution order alternated between the variants.

| Metric | Previous query | New query |
| --- | --- | --- |
| Median instrumented execution | 0.4085 ms | 0.3370 ms |
| Execution range | 0.301–0.806 ms | 0.280–0.656 ms |
| Median planning | 0.8060 ms | 0.7415 ms |
| Estimated total cost | 3.29 | 3.48 |
| WindowAgg nodes | 1 | 0 |
| Sort nodes | 2 | 1 |
| Full join | None | Hash Full Join |
| Shared buffer hits, final run | 8 | 5 |
| Shared reads / temporary writes | 0 / 0 | 0 / 0 |

The measured median improved by about 18% on this small catalog, despite a higher
estimated cost and four more returned metrics. The time ranges overlap. This is
not a CPU measurement, a large-catalog scaling test, or evidence of a universal
speedup. Client transfer, wrapper overhead and intentional waiting are excluded.
Planner cost alone would not have predicted the observed result.

Inspect either internal query, rather than an outer PL/pgSQL Function Scan:

```sh
git show 56f0b44:sql/pg_stat_database_delta.sql > /tmp/database-before.sql
python3 tests/explain_statistics.py --view database --source /tmp/database-before.sql
python3 tests/explain_statistics.py --view database
```

Use representative catalogs and repeat measurements before extending conclusions
to a different workload or server. The new query is the database sampler baseline;
any future simplification must preserve the cache and timing semantics above.

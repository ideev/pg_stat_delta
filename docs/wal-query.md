# WAL query baseline

`pg_stat_wal_delta` is part of version 0.1.0 and follows the native flat-snapshot
approach. PostgreSQL 17.11's pg_stat_wal returns one cluster-wide record from
pg_stat_get_wal(). Two materialized snapshots and timing aggregates explicitly
consume each read around the sleep. There is no catalog identity to match, so a
singleton CROSS JOIN replaces the object samplers' FULL OUTER JOIN; no sort or
window operation is needed. Work and snapshot size do not grow with object count.

## Cache ordering

A plain CROSS JOIN with a clear CTE does not guarantee that a Function Scan's
statistics getter starts after cache clearing. Both snapshot reads use:

```sql
OFFSET (SELECT count(*) - 1 FROM initial_clear)
```

The clear returns exactly one row, giving a zero offset. PostgreSQL evaluates this
Limit InitPlan before entering the underlying Function Scan. The second barrier
uses second_clear, whose dependency executes the wait first. Inline comments
explain the otherwise non-obvious expressions. PostgreSQL 17.11 EXPLAIN ANALYZE
confirmed two Limit/InitPlan dependencies, two single-call Function Scans, no Sort
and no WindowAgg. Recheck ordering on PostgreSQL/query changes.

The flat measured subquery names the status and raw start/end values. An ordinary
subquery or CTE does not guarantee a single status calculation; PostgreSQL may
expand its expression into output CASEs. The unnecessary OFFSET 0 was removed.
Every subtraction stays inside CASE WHEN status is ok. Statistics remain native;
wal_bytes is numeric, not bigint. No per-database reset getter or persistent
storage is involved. See [uniform policy](uniform-snapshots.md).

## Validity and tests

Compare source stats_reset before counter values. A marker change means reset,
even with nondecreasing counters. With unchanged markers any decrease means
counter_decreased. All eight deltas are NULL for either invalid status; NULL reset
markers compare with IS DISTINCT FROM. The actual source always has one row,
so there is no missing-object status.

Tests on PostgreSQL 17.11 exercise concurrent WAL-producing inserts after the
sampler enters PgSleep, preexisting counter caches in none/cache/snapshot modes,
alternate join settings, and pg_stat_reset_shared('wal') followed by activity.
Controlled snapshots extracted from the actual query cover each of eight
counters decreasing, reset with increasing counters, and exact numeric byte
values beyond bigint. Installation tests include the sixth extension member in
public and another schema. Reset tests require a disposable cluster because WAL
statistics are shared across databases.

Inspect the internal query with `python3 tests/explain_statistics.py --view wal`.
Zero sleep isolates query overhead for plan inspection; no before/after speedup
is claimed for this new function. Buffer-cache state, publication delays,
track_wal_io_timing and wal_sync_method affect interpretation as documented in
README. No rate conversion, LSN arithmetic or physical-device accounting is added.

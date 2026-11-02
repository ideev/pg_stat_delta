# SLRU query baseline

pg_stat_slru_delta belongs to version 0.1.0. It samples the PG17 cluster-wide
pg_stat_slru view, matching by source name text with FULL OUTER JOIN. Seven native
bigint differences are returned: blks_zeroed, blks_hit, blks_read, blks_written,
blks_exists, flushes and truncates, each suffixed _delta.

## Query and reset semantics

The source calls pg_stat_get_slru() in FROM. Each flat materialized snapshot uses
the common zero-OFFSET clear InitPlan before entering this Function Scan. Timing
aggregates consume complete snapshots around sleep. A regular measured CTE names
status and raw endpoints; subtraction is guarded by status='ok', and no extra
classification materialization or OFFSET 0 is used. Final ordering is by name.
There is no JSON, persistent storage, or hard-coded list of cache names.

Each source row has its own stats_reset. Changed marker, decreased counter and
missing name classify reset, counter_decreased and missing respectively. All
seven deltas are NULL for an invalid row. Matching NULL markers are accepted.
A reset of one cache must not invalidate unrelated caches; no database or global
marker is substituted. pg_stat_reset_slru('transaction') resets that PG17 cache,
whereas NULL resets all caches.

Existence checks, cache hits, reads, writes, flushes and truncations are distinct
SLRU events. They are not ordinary relation-buffer counters, physical disk I/O
or interchangeable counts to sum as bytes. A flush count is not a device-fsync
count. Source reads may be served by the OS cache. Publication is asynchronous;
clearing local caches cannot force other processes to report.

## Validation

Six new integration methods cover actual XID-assigning committed transactions
and positive transaction-cache hits in none/cache/snapshot, alternate plans,
per-name reset followed by work, global reset, repeated calls, invalid arguments,
exact name matching, missing sides, all seven individual decreases, matching NULL
markers and resets whose new counters caught up. Cache priming reads SUM(blks_hit).
The common invalid-arithmetic fixture proves invalid bigint differences cannot
overflow. Installation and ordinary-role/schema tests include this new member.

## Plan and overhead

Use `python3 tests/explain_statistics.py --view slru` for actual zero-sleep SQL.
Snapshot size follows source cache names rather than database/table/process count;
only PostgreSQL 17.11 is verified. Local measurements follow, without a claimed
speedup over an earlier function.

PostgreSQL 17.11 / Debian 13, local test server after the functional suite. Four
warmups preceded twenty measured internal-query EXPLAIN (ANALYZE, VERBOSE,
BUFFERS, TIMING OFF) runs at each tested size, all with zero intentional sleep.

| Returned rows | Median execution ms | Range ms | Median planning ms | Final sort KB | Shared hits |
| ---: | ---: | --- | ---: | ---: | ---: |
| 8 | 0.2955 | 0.243–0.435 | 0.4825 | 25 | 3 |

Both snapshot nodes had Limit/InitPlan dependencies executing cache clearing
before source scanning. No WindowAgg was present. The checkpointer plan has no
sort; row-set samplers retain final ordering. Final plans recorded no shared
reads or temporary writes. Buffer counters do not account for statistics-memory
access; sort space is not total process memory.

These are local instrumented elapsed times, not CPU measurements. They exclude
client round trips, the PL/pgSQL wrapper and the requested wait; ranges overlap
and no universal speedup is claimed. Recheck plans/concurrent tests on PostgreSQL
or query changes. All 102 integration methods passed on PostgreSQL 17.11 in
179.824 seconds. The private primary/standby recovery and restartpoint checks
passed separately.

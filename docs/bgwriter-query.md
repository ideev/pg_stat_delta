# Background-writer query baseline

pg_stat_bgwriter_delta is part of version 0.1.0. On PostgreSQL 17.11 the source
contains exactly three bigint counters and stats_reset: buffers_clean,
maxwritten_clean and buffers_alloc. Checkpoint statistics moved to
pg_stat_checkpointer in PostgreSQL 17, so this function does not reproduce the
older pg_stat_bgwriter layout or claim compatibility with it.

## Query and units

Two flat materialized snapshots read the one cluster-wide source row. Each uses
OFFSET (SELECT count(*) - 1 FROM its_clear_CTE), a zero-offset InitPlan consumed
before source getters. The second clear consumes sleep, whose input is the
aggregate fully consuming the first snapshot. Timing aggregates return exactly
one row. A singleton CROSS JOIN needs no identity matching, final sort, or
additional materialized classification set. All source fields are required.
There is no JSON, persistent storage, new configuration setting or forced I/O.

The source stats_reset is internal. A changed marker yields reset; any decreased
counter with unchanged markers yields counter_decreased. Either invalidates all
three deltas. A regular naming subquery does not promise single evaluation of
status. Every subtraction stays inside CASE WHEN status = 'ok', so even invalid
bigint endpoints whose difference would overflow are harmless. Matching NULL
reset markers are accepted. A singleton source has no missing-object status.

buffers_clean counts background-writer buffer writes, not all cluster writes.
maxwritten_clean counts cleaning scans stopped at the writer limit, not buffers,
errors or milliseconds. buffers_alloc counts shared-buffer allocations; this is
not an exact device-read count, a growing-memory gauge, or a write count. Do not
sum these different event counts as total I/O. No derived byte totals are added.

## Publication and reset behavior

The bgwriter shared reset marker, not a per-database marker, validates snapshots.
pg_stat_reset_shared('bgwriter') resets this set. Database, WAL and I/O resets
alone leave its validity intact. A marker change invalidates all counters even
if new activity already caught up.

Statistics publication is asynchronous. A client pg_stat_force_next_flush()
cannot force bgwriter to report: it is a separate process with its own cycle and
idle/hibernation behavior. An initial 1.5-second concurrent-allocation test
observed zero allocation delta; a 3-second sampling window passed cache-mode and
alternate-plan tests. This is a test allowance, not a universal publication-delay
bound or a changed default interval. The public default remains five seconds.
The function does not alter writer settings or force a checkpoint.

## Validation

Seven new integration methods exercise real allocations in none/cache/snapshot
modes after priming buffers_alloc, explicit bgwriter reset followed by work,
unrelated resets, repeated transaction calls, alternate plans, invalid arguments,
zero counters, exact bigint precision above 2^53, matching NULL markers,
reset/catch-up and each counter decreasing. The common invalid-subtraction test
now includes the ninth query. Installation checks and ordinary-role/schema tests
include all nine functions, still in version 0.1.0.

The optional tests/check_bgwriter_workload.py creates a private Unix-socket-only
PostgreSQL cluster with shared_buffers=1MB, bgwriter_delay=10ms,
bgwriter_lru_maxpages=1 and bgwriter_lru_multiplier=10. A paced insertion workload
exceeds its buffer pool, generating actual writer activity. One observed
three-second sample returned buffers_clean_delta=93, maxwritten_clean_delta=93
and buffers_alloc_delta=960. These are workload-specific counts, not prescribed
expected values. The helper requires all three to be positive, cleans up its own
cluster, and never changes an existing server. It does not clear the OS cache or
claim to measure physical-device writes.

## Plan and overhead

Inspect the actual internal zero-sleep SQL using
`python3 tests/explain_statistics.py --view bgwriter`. This avoids mistaking an
outer PL/pgSQL Function Scan for the underlying query. Local measurements follow;
no speedup over an earlier implementation is claimed for this new function.

PostgreSQL 17.11 / Debian 13, one source row, idle local test cluster after the
functional suite. Forty EXPLAIN (ANALYZE, VERBOSE, BUFFERS, TIMING OFF) runs
followed four warmups, all with zero intentional sleep. Median internal-query
execution was 0.129 ms (0.113–0.497 ms); median planning was 0.2185 ms. These
exclude client round trips, the PL/pgSQL wrapper and the requested wait, and do
not measure CPU time or establish a production performance bound.

Both snapshot nodes were Limit nodes with pre-scan InitPlans. There was no Sort
or WindowAgg. The last plan recorded no shared-buffer hits, reads or temporary
writes; this does not imply no shared-statistics-memory access or zero CPU use.
The snapshot size is one row and does not grow with database/table/process count.
Recheck plans and concurrent tests on PostgreSQL/query changes.

The complete 84-method suite passed in 148.580 seconds on PostgreSQL 17.11,
including nine-function installation and ordinary-role/schema checks. The
private-cluster real writer/limit test passed separately.

# Cluster I/O query baseline

pg_stat_io_delta belongs to version 0.1.0. Its tested source is PostgreSQL 17.11's
pg_stat_io, which calls the set-returning pg_stat_get_io(). This view reports
cluster-wide aggregates, not per-PID or per-database counters. Joining snapshots
requires the complete (backend_type, object, context) text key. Controlled tests
vary each dimension independently to detect accidental cross-matching.

## Ordering and native data

Each flat snapshot retains every source column: three key columns, the operation
size, thirteen cumulative metrics and the reset marker. There is no JSON,
composite-record conversion, persistent storage, or extra materialized result
set. The common first/second snapshot materialization and timing aggregates
consume reads around the sampling wait.

Both snapshots use OFFSET (SELECT count(*) - 1 FROM their_clear_CTE). Each clear
returns exactly one row, making the offset zero. Its Limit InitPlan executes
before entering the Function Scan, so the second read waits and clears before
fetching I/O statistics. A plain CROSS JOIN with a clear CTE would not establish
that order. The reason is commented beside each OFFSET.

A normal measured CTE names the status and counter endpoints; it does not promise
one-time status evaluation. Every subtraction is inside CASE WHEN status = 'ok'.
No OFFSET 0 or additional materialized classification set is introduced. FULL
OUTER JOIN preserves missing keys; final sorting orders the three dimensions.

op_bytes is bigint metadata, not a cumulative metric. The result uses its second
value, falling back to the first only when unavailable. In the tested PG17 source
it is the build's fixed operation size. No byte totals are derived, and buffer
hits/reuse are not interpreted as additional read operations.

## Reset and NULL semantics

A missing side takes priority, followed by a changed source stats_reset, followed
by any decreasing cumulative metric. These yield missing, reset and
counter_decreased respectively. Every invalid row returns NULL for all thirteen
deltas, including unchanged metrics. Matching NULL markers are accepted and
unsupported source counters remain NULL. The marker is internal.

The source's shared I/O reset marker is used, not the current database marker.
pg_stat_reset_shared('io') affects the whole cluster. A reset followed by new
activity is still invalid even if every counter already caught up.

Timing deltas are milliseconds and depend on track_io_timing in the workers doing
the I/O. Source statistics publication is asynchronous; clearing a local cache
cannot force another worker to publish. Counts are PostgreSQL operations, not
physical-device requests. PG17 pg_stat_io omits WAL and temporary sort/hash spill
file I/O, among other coverage limits; temporary relations are a separate source
object category. Other PostgreSQL layouts have not been verified.

## Validation

Seven new integration methods cover actual normal-relation updates and temporary
relations, none/cache/snapshot priming by SUM(hits), alternate plans, shared I/O
reset followed by work, repeated transaction calls, invalid intervals, exact
key matching, missing rows, all thirteen metrics decreasing separately, matching
NULL markers, reset/catch-up, and unsupported NULL metrics. The common invalid
arithmetic test now includes this seventh query and proves invalid raw bigint
endpoints cannot cause subtraction overflow.

Installation checks include the seventh extension member, default/explicit
version 0.1.0, another schema and removal. The invoker/schema test calls the new
function as an ordinary role with an empty caller search_path.

The optional cold-buffer script restarts only its own private temporary cluster
before sampling this function. With track_io_timing enabled in the workload,
the additional phase observed 68 reads and 0.344 ms read time. The earlier
relation/TOAST/index block-read checks also passed. No existing server or OS cache
is cleared; these are PostgreSQL reads, not claims of physical device access.

## Plan and overhead

Use `python3 tests/explain_statistics.py --view io` to inspect the actual internal
query with zero sleep instead of an outer PL/pgSQL Function Scan. Plan and local
measurements for this implementation are recorded below; no previous-version
speedup is claimed for a new function.

PostgreSQL 17.11 / Debian 13, 35 source buckets, idle local test cluster after the
functional suite. Thirty EXPLAIN (ANALYZE, VERBOSE, BUFFERS, TIMING OFF) runs
followed four warmups with zero intentional sleep. Median internal-query execution
was 0.5415 ms (0.461–0.935 ms); median planning was 0.7995 ms. These exclude client
round trips, the PL/pgSQL wrapper and the requested wait, and do not measure CPU
consumption or establish a production bound.

Both snapshot nodes were Limit nodes with pre-scan InitPlans. Exactly two
pg_stat_get_io Function Scans were present. The final quicksort used 31 KB; the
last plan recorded three shared-buffer hits, no shared reads and no temporary
writes. Hash joining also uses memory, so sort space is not a total-memory figure.
The row set is bounded by the source's backend/object/context combinations,
rather than the number of databases, tables or client processes. Recheck plans on
PostgreSQL/source changes. No speedup comparison is claimed.

The complete 67-method integration suite passed in 112.174 seconds. The extended
ordinary-role/schema test was also rerun successfully after adding both WAL and
cluster I/O calls; the optional private-cluster cold checks passed separately.

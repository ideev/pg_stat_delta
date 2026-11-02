# Checkpointer query baseline

pg_stat_checkpointer_delta is part of version 0.1.0 and targets the PostgreSQL 17
source. Its singleton row contains six bigint counts and two double-precision
millisecond times: num_timed, num_requested, restartpoints_timed,
restartpoints_req, restartpoints_done, write_time, sync_time and buffers_written.
Checkpoint/restartpoint statistics are not part of PG17 pg_stat_bgwriter.

## Query and semantics

Two flat materialized snapshots read only the complete source's required fields.
Each has a zero-OFFSET InitPlan consuming its clear CTE before evaluating source
getters. Timing aggregates fully consume snapshots around the requested wait.
A singleton CROSS JOIN needs no identity match or final sort. A regular measured
CTE names status/endpoints without promising a single status evaluation. Every
subtraction remains inside CASE WHEN status = 'ok'; invalid bigint differences
are never evaluated. There is no JSON or extra materialized classification set.

The source stats_reset is compared internally. A changed marker yields reset,
a decreased count/time yields counter_decreased; all eight deltas are NULL for
either invalid status. Matching NULL markers are valid. No missing status is
needed for a singleton. Reset via pg_stat_reset_shared('checkpointer'), not the
bgwriter or database marker, controls validity.

Requested restartpoints can be skipped when no suitable safe checkpoint record
has become available; requests and performed restartpoints must not be equated.
A primary normally has no restartpoints. Writing time includes checkpoint pacing,
not just device activity. Counts/times are asynchronous published statistics,
not exact physical-device operations. The function never requests a checkpoint.

## Validation

Six new integration methods (including shared checks) cover real requested
checkpoints after dirtying a table in all three statistics cache modes, alternate
plans, own and unrelated resets, repeated calls, invalid arguments, zero deltas,
each of eight metrics decreasing and marker change with increasing counters.
The common invalid-subtraction fixture also covers this query.

The optional private primary/standby helper replays a fresh primary checkpoint,
then requests a standby restartpoint during sampling. It observed one requested
and one performed restartpoint with status ok. It uses only private Unix sockets
and removes its servers; no existing server is reconfigured. Installation and
ordinary-role/schema tests now cover all twelve extension functions.

## Plan and overhead

Use `python3 tests/explain_statistics.py --view checkpointer` to inspect actual
zero-sleep SQL rather than the outer PL/pgSQL Function Scan. Local measurements
follow; no previous-version speedup is claimed for this new function.

PostgreSQL 17.11 / Debian 13, local test server after the functional suite. Four
warmups preceded twenty measured internal-query EXPLAIN (ANALYZE, VERBOSE,
BUFFERS, TIMING OFF) runs at each tested size, all with zero intentional sleep.

| Returned rows | Median execution ms | Range ms | Median planning ms | Final sort KB | Shared hits |
| ---: | ---: | --- | ---: | ---: | ---: |
| 1 | 0.1930 | 0.158–0.707 | 0.4110 | 0 | 0 |

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

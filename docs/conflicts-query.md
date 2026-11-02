# Recovery-conflict query baseline

pg_stat_database_conflicts_delta belongs to version 0.1.0. It reads six PG17
bigint counters from pg_stat_database_conflicts: confl_tablespace, confl_lock,
confl_snapshot, confl_bufferpin, confl_deadlock and confl_active_logicalslot.
The result adds _delta suffixes, datid/datname and common timing/status fields.

## Query and validity

Flat snapshots are matched by datid with FULL OUTER JOIN and ordered by OID.
Each read uses the common pre-scan zero-OFFSET clear InitPlan. Timing aggregates
consume complete reads around sleep; the measured CTE names status/endpoints
without extra materialization. Every subtraction stays inside its status-ok CASE.
There is no JSON, persistent storage or extra statistics-view join.

The source has no reset timestamp. Each snapshot adds just
pg_stat_get_db_stat_reset_time(d.datid) AS stats_reset, reading one corresponding
marker per database row. Markers stay internal. A changed marker yields reset,
any counter decrease yields counter_decreased, and a missing side yields missing.
All six deltas are NULL for any invalid status, including otherwise nondecreasing
metrics. Matching NULL markers are accepted. PG17 individual relation/function
resets can advance a database marker and conservatively invalidate conflict rows.

These counters concern standby recovery cancellations, not ordinary lock waits,
primary deadlocks or application errors. Positive primary transaction activity
does not imply conflicts; a primary normally reports zero. The source includes
pg_database catalog rows, not the datid=0 shared-object row. OID matching survives
renames; one statement retains its catalog MVCC snapshot, so missing is defensive
and does not promise live discovery of newly created databases. Source
publication is asynchronous; the sampler cannot force other backends to publish.

## Validation

Six new integration methods cover primary zero deltas in all three cache modes,
per-database reset and unaffected other databases, repeated calls, alternate
plans, invalid arguments, exact OID pairing, missing sides, every individual
counter decreasing, matching NULL markers and reset/catch-up. Cache priming uses
SUM(confl_lock). Invalid bigint arithmetic is covered by the common fixture.
Installation and ordinary-role/schema checks include all twelve functions.

The optional tests/check_recovery_conflicts.py creates a private primary and a
physical streaming standby using pg_basebackup. Both bind private Unix sockets
only. A standby transaction holds an AccessShareLock while primary ALTER TABLE
replays an exclusive lock. A short standby delay cancels the lock holder; each
of none/cache/snapshot samples observed confl_lock_delta=1, status ok. The helper
asserts the locker was actually canceled due to recovery, not merely disconnected.
It also verifies a requested/performed restartpoint after replaying a fresh
checkpoint. Both servers are stopped and removed; existing servers are untouched.

This is a real recovery-lock test, not a demonstration of every conflict cause.
The other five deltas and missing/reset semantics are exercised with controlled
snapshots extracted from the actual SQL. No claim is made that all conflict types
were induced in recovery.

## Plan and overhead

Use `python3 tests/explain_statistics.py --view database_conflicts`. The optional
zero-sleep measurements inspect internal SQL rather than the outer PL/pgSQL node;
local results follow, without a previous-version speedup claim.

PostgreSQL 17.11 / Debian 13, local test server after the functional suite. Four
warmups preceded twenty measured internal-query EXPLAIN (ANALYZE, VERBOSE,
BUFFERS, TIMING OFF) runs at each tested size, all with zero intentional sleep.

| Returned rows | Median execution ms | Range ms | Median planning ms | Final sort KB | Shared hits |
| ---: | ---: | --- | ---: | ---: | ---: |
| 3 | 0.2515 | 0.226–0.474 | 0.5870 | 25 | 5 |
| 23 | 0.3470 | 0.296–0.757 | 0.6405 | 28 | 5 |

The larger case temporarily created twenty databases with TEMPLATE template0 and
removed them afterward. These are actual catalog/view scans, not substituted
VALUES rows. Only two sizes were measured; no production scaling bound follows.

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

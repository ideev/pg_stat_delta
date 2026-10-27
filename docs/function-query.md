# User-function query baseline

pg_stat_user_functions_delta is part of version 0.1.0. It reads two flat snapshots
of pg_stat_user_functions in the current database, matching funcid rather than
schema/name because overloaded functions share names. Only the six required
source fields are read: OID, schema, name, calls, total_time and self_time.

## Query ordering and validity

Both snapshot CTEs use OFFSET (SELECT count(*) - 1 FROM their_clear_CTE). The
clear CTE returns one row, giving a zero OFFSET whose InitPlan runs before
entering the source scan. This matters for getters in the source view's WHERE
clause as well as its output. The timing aggregates consume complete snapshots,
return one row even for empty sets, and establish the dependency around sleep.
There is no JSON, extra materialized classification set or persistent storage.

A regular measured CTE names status and raw endpoints; it does not guarantee a
single classification evaluation. FULL OUTER JOIN preserves either missing side.
Each subtraction occurs only inside CASE WHEN status = 'ok'. Invalid rows never
subtract counters and cannot trigger a discarded bigint overflow. Sorting by
schema, name and funcid gives deterministic order for overloaded functions.

Source function statistics do not expose a per-function reset timestamp. The
current database reset marker is therefore read internally once per snapshot.
PostgreSQL 17 single-function resets advance that marker, even if subsequent
calls already overtook the first counts. A changed marker conservatively marks
all present pairs reset. Any decrease in calls, total_time or self_time also
marks reset. Missing/reset rows return NULL for every delta. The source marker
is not added to the public row type.

## Tracking and source membership

The sampler does not modify track_functions. It must be enabled in executing
workload sessions (pl or all, according to the language). SQL inlining can avoid
separate function execution/tracking even with all. Existing recorded rows can
remain visible after disabling tracking; newly untracked calls do not increment
them. Do not interpret no rows or zero calls as proof that no functions ran.

Unlike ordinary catalog creation, first statistics publication can make an
already-existing function appear only in the second read: its getter changes
from NULL to a recorded count and the source view includes it. This yields
missing, not a difference from an invented zero. Catalog names still obey one
statement's MVCC snapshot, so a rename during sleep is reflected on the next call.
No additional schema filter beyond the actual source view is imposed.

Times are milliseconds of elapsed execution. total_time includes nested tracked
calls; self_time excludes them. Inclusive times cannot be summed as server CPU
time. Publication is asynchronous and may include complete calls that began
before sampling. Clearing the cache does not force worker publication. Tracking
the PL/pgSQL sampler can itself add published activity on later measurements.

## Validation

Ten new test methods cover actual PL/pgSQL calls with exact counts in all three
cache modes, prefilled caches using SUM(calls), overloaded names, nested timing,
disabled tracking, inlined SQL with track_functions=all, newly published function
statistics, a single-function reset followed by 30 new calls, database reset,
alternate plans, catalog rename, repeated transaction calls, invalid inputs and
controlled missing/decreasing rows. The overflow regression includes the eighth
query. Installation and ordinary-role/schema relocation tests include all eight
extension members, still only version 0.1.0.

## Plan and overhead

Inspect the internal query using `python3 tests/explain_statistics.py --view functions`.
It executes zero-sleep sampling SQL rather than an outer PL/pgSQL Function Scan.
Local plan and scaling measurements are recorded below; no prior-function
speedup is claimed for this new sampler.

PostgreSQL 17.11 / Debian 13, an isolated disposable database, with 0, 100 and
1,000 tracked PL/pgSQL functions. At each size four warmups preceded ten measured
EXPLAIN (ANALYZE, VERBOSE, BUFFERS, TIMING OFF) executions of the internal query
with zero sleep. Each generated function was called and its backend's statistics
published before measurements. The measurement sessions used track_functions=none.

| Tracked rows | Median execution ms | Range ms | Median planning ms | Final sort KB | Shared hits |
| ---: | ---: | --- | ---: | ---: | ---: |
| 0 | 1.1080 | 0.756–2.714 | 1.1410 | 25 | 205 |
| 100 | 1.7490 | 1.244–6.903 | 1.7270 | 45 | 209 |
| 1000 | 6.6215 | 5.090–16.936 | 1.3500 | 228 | 253 |

All tested snapshot nodes were Limit nodes with pre-scan clear InitPlans. There
was no WindowAgg, shared read or temporary write in the measured final plans.
The final sort is not total process memory: snapshots and joining use memory too.
Source evaluation also scans function catalogs and checks for existing statistics,
so an empty returned set still has overhead; workload depends on both catalog
size and tracked rows. The actual empty-source call returned zero rows while
still honoring a 0.05-second sampling wait.

These local instrumented elapsed times exclude client round trips, the PL/pgSQL
wrapper and intentional sleep. They are not CPU measurements or production
bounds. Ranges were broad; no speedup or precise scaling factor is claimed for
this new function. Recheck plans and concurrent tests on PostgreSQL/query changes.

All 77 integration methods passed on PostgreSQL 17.11 in 127.687 seconds, including
the extended eight-function installation and ordinary-role/schema checks.

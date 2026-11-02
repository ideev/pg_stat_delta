# Statement query baseline

pg_stat_statements_delta is part of pg_stat_delta 0.1.0 and supports the tested
PostgreSQL 17.11 / pg_stat_statements SQL extension version 1.11. It is optional:
core installation and all thirteen other functions work without it. Absence,
missing preload and unsupported SQL versions produce clear errors rather than
silently returning misleading deltas. No monitored server configuration changes
or automatic extension upgrades are performed.

## Dependency, scope and permissions

The PL/pgSQL wrapper validates the interval, looks up the extension namespace/
version, and uses format('%I', namespace) for the native sampling query. The
interval is a bound EXECUTE parameter. This is one sampling SQL query after the
small catalog lookup, not one separately executed SQL statement per snapshot.
It keeps SECURITY INVOKER and search_path=pg_catalog,pg_temp; untrusted search
paths cannot redirect the source to a caller's similarly named table. Quoted
non-public schemas and relocation of either extension are tested.

The getter returns shared entries across databases, not just the installation
database. The complete key is (userid, dbid, toplevel, queryid). Different users,
databases, nested/top-level statements must not cross-match. NULL query IDs hidden
by source privileges are omitted before matching, whereas query ID zero remains
eligible. Source rights are not bypassed; ordinary roles see identifiable own
entries, pg_read_all_stats permits the broader source view. Missing schema USAGE
or revoked getter EXECUTE remains a normal permission error. The function does
not grant privileges or introduce a mandatory extension dependency.

## Snapshots and counters

The source view is a wrapper around pg_stat_statements(true). The first scan uses
the same extension-owned getter with showtext=false and retains only keys,
stats_since and 34 additive counters. The second uses true and retains the
representative query text too. This avoids loading the query-text file twice;
it does not avoid scanning shared counter entries twice. Both native snapshots
are materialized and have pre-scan zero-OFFSET clear InitPlans. Aggregates consume
the snapshots around the sampling sleep. There is no JSON, text serialization of
statistics, persistent snapshot table or per-row SQL invocation.

pg_stat_statements is not the core stats_fetch_consistency cache. Its getter
reads extension state; the common clear dependency preserves ordering but does
not synchronize running statements or force them to finish. Plans can become
visible before calls complete, while completed calls can include execution
started before the interval. Monitoring queries can appear in the source too.

Counters cover plans/total_plan_time, calls/total_exec_time/rows, shared/local/
temporary blocks, corresponding read/write times, WAL counts/numeric bytes, and
JIT generation/inlining/optimization/emission/deformation counts/times. Every
float time is cumulative milliseconds; no CPU usage or rates are inferred.
Planning, I/O timing and JIT settings control whether relevant fields accrue.
Planning disabled in workers is tested to yield calls without plan increments.
Min/max/mean/stddev and minmax_stats_since are deliberately excluded.

## Reset, eviction and incomplete pairs

Each pair compares its own stats_since. A changed marker means reset, covering
selective/full resets and eviction/recreation of a key, even after new counts
caught up. Any additive counter decreasing without that marker change means
counter_decreased. Min/max-only resets leave additive validity intact. A regular
database statistics reset is unrelated to this extension's per-entry marker.
There is no need to scan pg_stat_statements_info for a global reset/deallocation
flag; that could invalidate unaffected entries and miss selective details.

A missing side yields missing. All 34 deltas are NULL for every invalid row;
all subtractions are inside status-ok CASEs. No zero baseline is invented for a
new statement, and disappeared entries have NULL query because no first-snapshot
text is retained. Query text is representative/normalized according to the
source, not necessarily the interval's exact SQL or parameters. Query hashes have
the source's collision/lifetime/upgrade limits and are not permanent identities.
Matching NULL reset markers are handled explicitly in controlled fixtures.

## Classifier cost

Unlike small classifiers in other functions, checking 34 metrics is expensive
when expanded into 34 output CASEs. measured AS MATERIALIZED computes status once
and retains native endpoints for final guarded subtraction. An ordinary CTE or
OFFSET 0 must not be presented as guaranteeing this behavior. This adds a third
materialized row set and can spill; it is a measured tradeoff, not an assumed
optimization. Two alternatives are retained in the benchmark: wide NOT
MATERIALIZED (repeated checks), and a narrow materialized classifier followed by
two extra joins back to snapshots. The extra joins avoided the observed wide
classifier spill but were slower in the measured workloads.

## Functional tests

The default core suite installs fourteen functions without pg_stat_statements
and verifies its optional dependency error while all other samplers remain usable.
Its installation/removal/schema checks still require only version 0.1.0.

The dedicated helper creates a private Unix-socket-only server. It first verifies
installed-but-not-preloaded failure, then restarts only that server with pg_stat_
statements preloaded, track=all, track_planning=on, max=100 and query IDs enabled.
The source is in schema "statement stats" and the sampler in diagnostics. It does
not restart or modify the main development server.

Nineteen dedicated test methods cover exact calls/plans/rows in none/cache/
snapshot, positive DML WAL metrics, nested statements, complete composite keys,
user/database separation, invoker privacy with an empty caller search_path,
pg_read_all_stats, selective/full/minmax-only resets, eviction/reentry after
exceeding max=100, new/disappeared entries, repeated calls, empty snapshots that
still sleep, alternate plans, planning disabled, unrelated database reset,
relocated schemas and unsupported version 1.10. The helper separately verifies
installed-but-not-preloaded failure. Controlled SQL
fixtures exercise all 34 individual decreases, key collisions across dimensions,
hidden NULL keys, matching NULL markers, invalid bigint arithmetic, and numeric
WAL bytes beyond bigint precision. No permissions are granted by the sampler.

```sh
python3 tests/check_statements_workload.py --pg-bindir /path/to/postgresql/17/bin
python3 tests/check_statements_workload.py --pg-bindir /path/to/postgresql/17/bin --benchmark-only
python3 tests/explain_statistics.py --view statements
```

The benchmark mode is also a fresh disposable server, raises only its own max
to 10,000, and disables utility tracking for the measurement workload. It resets
only private counters, never a monitored server. See measurements below.

## Local comparative measurements

PostgreSQL 17.11 / pg_stat_statements 1.11, fresh private cluster, short generated
SELECT queries over a 1,000-column one-row table. Distinct referenced columns and
operators create distinct query IDs without relying on literal values. Source
counts were 0, 103, 1,003 and 5,003; the latter counts include three tracked
PL/pgSQL generator/control statements. Query text was short; large text payloads
were not benchmarked.

For each size, four warmup runs preceded ten measured internal EXPLAIN (ANALYZE,
VERBOSE, BUFFERS, TIMING OFF) runs per variant with alternating forward/reverse execution order and
zero sleep. Utility tracking was off; measurement sessions disabled statement
tracking. The max setting was 10,000 to avoid eviction during these comparisons.
The selected variant was compared with a wide inlined classifier and a compact
materialized key/status set requiring two additional joins back to snapshots.

| Source rows | Chosen wide materialized median ms | Inlined median ms | Compact/extra joins median ms |
| ---: | ---: | ---: | ---: |
| 0 | 0.4770 | 1.0600 | 0.5045 |
| 103 | 1.7425 | 3.4520 | 3.0370 |
| 1003 | 12.4425 | 27.3880 | 28.0020 |
| 5003 | 56.9030 | 123.9155 | 139.1305 |

| Rows | Chosen range ms | Inlined range ms | Compact range ms |
| ---: | --- | --- | --- |
| 0 | 0.370–1.257 | 0.735–1.595 | 0.377–1.059 |
| 103 | 1.378–5.051 | 3.211–4.258 | 2.384–4.730 |
| 1003 | 10.808–15.645 | 23.861–31.400 | 24.658–33.778 |
| 5003 | 52.012–131.414 | 111.563–135.640 | 127.833–204.774 |

The chosen 5,003-row plan reported **401 temporary written blocks** at the default
work_mem; both alternatives reported zero in these runs. This materialization
was retained for lower observed median execution time, not because its memory/
I/O cost is free. It is not a universal optimization or a production memory bound.
At 1,003 rows the chosen/inlined/compact median planning times were
0.7470, 2.4475, 0.8395 ms respectively.

All variants retained two Limit/InitPlan snapshot-clear dependencies and exactly
two pg_stat_statements Function Scans. Merge-join input sorts and final sorting
were present; compact classification added joins/sorts rather than avoiding the
work of matching. Selected 5,003-row sort sizes were 2,147 / 1,756 / 2,030 KB;
these exclude tuplestores and are not total memory use. Shared-buffer counters
were zero, but that does not include shared-statistics memory or query-text file
I/O. No source text/state serialization was introduced.

These are instrumented elapsed execution/planning measurements, not CPU
measurements. Client transport, the PL/pgSQL wrapper, namespace/version catalog
lookup, format/EXECUTE overhead and the intentional wait are excluded. Some time
ranges overlap and the measurements do not establish a universal speedup; long
query texts, more entries, work_mem and concurrency can change the tradeoff.

The core 109-method suite passed on the main non-preloaded test server in
190.139 seconds, including optional-dependency installation checks. Dedicated
functional tests also passed: all 19 methods completed in 28.601 seconds, plus
the expected installed-but-not-preloaded failure check in the helper.

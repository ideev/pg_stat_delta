# Development principles

## Monitoring overhead

Correctness is mandatory. Among correct implementations, minimizing the impact
on the monitored PostgreSQL server takes priority over convenience, abstraction,
feature breadth, and implementation uniformity. A performance diagnostic must
not become a source of performance problems.

For every statistics function or query change:

- Read only the statistics and columns required for the result. Avoid redundant
  scans, repeated calculations, unnecessary sorting and materialization.
- Keep statistics in native PostgreSQL types. Avoid JSON/text serialization and
  deserialization unless required by the public interface.
- Prefer a single efficient SQL query when it preserves measurement semantics.
  Establish execution dependencies explicitly where snapshot ordering matters;
  do not rely on incidental UNION ALL or FROM execution order. Retain only the
  materialization needed for correctness or demonstrated efficiency.
- Preserve cache invalidation, reset detection, identity matching, and documented
  snapshot semantics when optimizing. Verify them with meaningful concurrent
  tests; a cheaper plan does not justify incorrect deltas.
- Evaluate CPU, memory, buffer activity, and scaling with the number of monitored
  objects. Use comparable EXPLAIN plans and representative execution measurements
  for substantive performance changes. Separate intentional sampling sleep from
  query overhead, and account for EXPLAIN ANALYZE instrumentation overhead.
- Treat planner cost as an estimate, not a CPU or elapsed-time measurement. Do not
  infer a speedup from cost alone, sum unrelated plan costs as proof of overhead,
  or benchmark only an outer Function Scan that hides the underlying SQL.
- When reporting an optimization, state what was measured, the PostgreSQL version,
  workload and limitations. Do not claim measured improvements without evidence.

Cache-invalidation tests must prime caches by reading an actual counter, such as
sum(idx_blks_hit), inside the sampling transaction. count(*) over a statistics
view can be reduced to a catalog-only plan and does not establish cached stats.

## Statistics query baselines

All fourteen samplers use the same pre-scan cache-clear dependency in both
first_snapshot and second_snapshot:

```sql
OFFSET (SELECT count(*) - 1 FROM initial_clear)
-- Use second_clear for the second snapshot.
```

Each clear CTE returns one row, so the offset is zero. Its InitPlan consumes
clearing (and, on the second read, the preceding wait) before starting the scan.
Retain this dependency for every source view, even where a particular flat
CROSS JOIN plan happened to project getters after clearing. Recheck actual plans
and concurrent tests on PostgreSQL/query changes.

Calculate every public *_delta only inside CASE WHEN status = 'ok' THEN
end_value - start_value END. Keep raw start/end values until this final CASE:
invalid rows must not perform subtraction, which can overflow bigint even when
the result would later be discarded. This includes num_backends_delta; its
start/end gauges remain available on invalid rows. Do not claim that ordinary
CTEs or OFFSET 0 guarantee a single status evaluation: verify actual plans.
Avoid extra per-object materialization solely to share a cheap status check.

The seven object samplers use flat snapshots and FULL OUTER JOIN by object OID.
The database sampler compares source stats_reset. The four relation samplers
read the database reset marker internally once per snapshot. A marker change
invalidates all deltas, even if activity has already caught up. Table/index
statistics classify decreases as reset; block-I/O samplers use counter_decreased.
All invalid statuses, including missing, invalidate every delta together.

The WAL sampler reads one cluster-wide row from pg_stat_wal. Keep wal_bytes in
native numeric and use the source reset marker. Any decrease or reset invalidates
all eight deltas. No identity join or sort is needed.

The cluster I/O sampler joins the complete (backend_type, object, context) key
from pg_stat_io. Use its own stats_reset marker, preserve unsupported NULL
metrics, and keep op_bytes as a size, not a delta or cumulative count. Any invalid
status invalidates all thirteen deltas. This PG17 view does not cover all server
I/O (notably WAL and temporary spill files). See docs/io-query.md.

The function sampler joins pg_stat_user_functions by funcid, not function name
(overloads share names). Retain the internal database reset-marker check: PG17
single-function resets advance that marker. All three deltas are NULL for missing
or reset, including caught-up counters. First statistics publication may create
a missing row even without catalog DDL. Never set track_functions inside the
sampler; workload sessions control tracking, and SQL inlining can bypass it.
Times are milliseconds, not CPU time. See docs/function-query.md.

The PostgreSQL 17 bgwriter sampler is a singleton with three bigint counters,
not the pre-17 checkpoint/backends layout. Use its own stats_reset marker and
invalidate all three deltas on reset or decrease. It needs no identity join or
sort. Bgwriter publication is independent of client forced flushes: allow enough
time in concurrent tests, and test real writer/limit activity only in a private
cluster where buffer/writer settings may safely be changed. See docs/bgwriter-query.md.

The checkpointer sampler is one PG17 cluster-wide row with six bigint counters
and two millisecond timing counters. Use its own reset marker; never request a
checkpoint from the sampler. SLRU pairs rows by name and uses each row's own
stats_reset, so a targeted reset must not invalidate unrelated caches. Conflicts
pair by database OID and add only pg_stat_get_db_stat_reset_time(datid) per source
row: that view lacks a reset marker. Its counters concern recovery cancellations,
not primary lock waits. All three use counter_decreased for non-marker decreases
and invalidate every delta of an invalid row. Verify real recovery conflicts and
restartpoints using only the private primary/standby helper. See the new
checkpointer, SLRU and conflicts query documents.

The archiver sampler is a singleton with two bigint deltas and four last-event
fields from the second snapshot, suffixed _end. Keep the first snapshot limited
to counters/reset marker. A reset or decrease invalidates both deltas but does
not discard final event state. End timestamps can predate sampling, and failure
counts can include retries for one filename. Never enable archiving, switch WAL
or invoke archive commands from the sampler; real archive tests use only the
private-cluster helper. See docs/archiver-query.md.

The statement sampler is an optional pg_stat_statements 1.11 dependency; do not
make the whole extension require it or alter the monitored server's preload or
tracking settings. Resolve/quote its extension namespace and bind the interval;
keep SECURITY INVOKER and fixed search_path. Pair userid/dbid/toplevel/queryid,
omit hidden NULL query IDs, preserve numeric WAL bytes and use per-entry
stats_since (not database/global/minmax markers). Missing/reset/decreased rows
invalidate all 34 additive deltas. Fetch text only on the second read through
the source getter's showtext argument; no extrema/mean/stddev differences.
Its expensive 34-metric classifier is deliberately materialized: measurements
beat repeated evaluation or extra joins, but 5,000 entries spilled at default
work_mem. Preserve/report that CPU/memory/I/O tradeoff and benchmark substantive
changes. Dedicated tests use only a private preloaded cluster. See
docs/statements-query.md.

See docs/uniform-snapshots.md for the current query policy and measurements.
The per-function query documents retain earlier implementation comparisons.

## Query clarity

Keep monitoring queries as clear and direct as possible without sacrificing
correctness or the monitoring-overhead priority above. Remove redundant
expressions and execution dependencies rather than keeping unexplained tricks.
When a necessary technique has non-obvious behavior (for example, a materialized
CTE dependency, an OFFSET barrier, or cache invalidation ordering), explain its
purpose and required execution semantics in a comment at that exact location.
Comments must explain why the technique is needed, not just restate the SQL.

## Extension version during development

Keep every function in the single extension version 0.1.0 until the user requests
otherwise. Do not introduce a version or upgrade script for each new function.
Edit the named per-function SQL sources and build the complete 0.1.0 installation
script with make. Keep that tracked script synchronized for direct review.

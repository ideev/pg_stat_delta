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

The current pg_stat_database_delta baseline uses flat materialized snapshots
and FULL OUTER JOIN. Compare future changes against this implementation and
measure actual execution, not just planner cost. Preserve the verified placement
of cache clearing before statistics getter evaluation; recheck plans and
concurrent cache-mode tests when changing this query shape or PostgreSQL version.
See docs/database-query.md for the analysis and measurements.

The table sampler also uses flat snapshots and FULL OUTER JOIN, with explicit
cache-clear OFFSET dependencies because its source view contains aggregates.
Retain database reset-marker validation and whole-row invalidation of all nine
cumulative deltas. Scan-counter decreases alone do not detect every reset.
See docs/table-query.md for the tested compact API and performance comparison.

The index sampler now also uses flat snapshots and FULL OUTER JOIN. Keep its
internal database reset-marker check and invalidate all three cumulative deltas
for missing/reset rows, including resets whose counters caught up. The marker
is not part of its compact public result. See docs/index-query.md.

The table block-I/O sampler also uses flat snapshots and FULL OUTER JOIN.
Retain its pre-scan cache-clear dependency for the aggregate source view. Its
reset marker is internal; all eight deltas must be NULL for reset,
counter_decreased or missing, even if individual counters are nondecreasing.
See docs/table-io-query.md for the regression and comparison.

The index block-I/O sampler completes the flat-snapshot/FULL OUTER JOIN baseline
for all five functions. Keep its database reset marker internal and return both
block-counter deltas as NULL for every non-ok status. Verify cache ordering and
independence of indexes sharing one relid. See docs/index-io-query.md.

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

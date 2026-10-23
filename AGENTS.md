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

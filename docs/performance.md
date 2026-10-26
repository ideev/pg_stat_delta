# Query plans and performance evidence

All five functions in version 0.1.0 now use flat native snapshots and FULL OUTER
JOIN. The comparisons below evaluate complete implementations, including compact
result changes and correctness fixes, not isolated join algorithms.

## Current comparisons

| Function | Tested catalog | Previous median | Current median | Analysis |
| --- | --- | --- | --- | --- |
| `pg_stat_database_delta` | 4 statistics rows | 0.4085 ms | 0.3370 ms | [Database](database-query.md) |
| `pg_stat_user_tables_delta` | 1,000 user tables | 17.773 ms | 13.504 ms | [Tables](table-query.md) |
| `pg_stat_user_indexes_delta` | 1,000 user indexes | 13.278 ms | 10.800 ms | [Indexes](index-query.md) |
| `pg_statio_user_tables_delta` | 1,000 user tables | 23.159 ms | 22.856 ms | [Table I/O](table-io-query.md) |
| `pg_statio_user_indexes_delta` | 1,000 user indexes | 11.055 ms | 9.743 ms | [Index I/O](index-io-query.md) |

These are local PostgreSQL 17.11 / Debian 13 instrumented internal-query execution
medians with zero intentional sleep. Time ranges overlap; the table-I/O repeat
in particular provides no convincing runtime improvement. Different rows are
from separate experiments and must not be used to rank functions or extrapolate
production overhead. Each analysis records catalogs, warmups, repetitions,
planning times, estimated cost, range and correctness findings.

The window nodes are gone. Sort memory fell in the measured catalogs, but all
queries still sort for final output order, and hash joins consume memory too.
No result establishes a universal speedup or a total-memory bound. Planner cost
alone is not a runtime measurement; execution time is not a CPU measurement.
Intentional waits, client transfer and the PL/pgSQL wrapper are excluded.

## Inspect the internal SQL

Use a representative disposable database and standard PGHOST, PGPORT, PGDATABASE
and PGUSER settings, optionally PSQL to select a client:

```sh
python3 tests/explain_statistics.py --view database
python3 tests/explain_statistics.py --view tables
python3 tests/explain_statistics.py --view indexes
python3 tests/explain_statistics.py --view statio_user_tables
python3 tests/explain_statistics.py --view statio_user_indexes
```

The helper extracts the selected function's RETURN QUERY and runs EXPLAIN
(ANALYZE, BUFFERS, TIMING OFF) with zero sleep. It executes statistics reads and
clears the connection's statistics cache. It reveals the real SQL plan instead
of the outer PL/pgSQL Function Scan. Zero wait is for overhead inspection, not
useful sampling.

To inspect a saved earlier per-function definition, add --source:

```sh
python3 tests/explain_statistics.py --view indexes --source /tmp/index-before.sql
```

Verify snapshot/cancellation/reset semantics under concurrent activity before
accepting a cheaper plan. Warm up, rotate comparison order, repeat measurements,
and separate other workloads from timing runs. Use meaningful source-counter
reads such as sum(idx_scan) when testing preexisting statistics caches; count(*)
can avoid getter evaluation entirely. Recheck on PostgreSQL or query changes.

## Cold-buffer behavior

The optional tests/check_statio_cold.py creates a private Unix-socket-only cluster,
prepares heap/index/TOAST data, and cleanly restarts only that cluster. It verifies
positive table/index block-read deltas and cleans up the server and data. Existing
servers and the OS cache are untouched. This demonstrates PostgreSQL block reads,
not physical device I/O or latency. See README for the invocation.

Earlier window-based measurements are preserved separately in
[performance-history.md](performance-history.md). They include different catalog
shapes and repetition counts and should not be treated as current baselines.

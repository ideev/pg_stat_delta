# Inspecting monitoring overhead

Run against a representative **disposable** database with PostgreSQL 17 and the
usual PGHOST, PGPORT, PGDATABASE and PGUSER variables:

```sh
python3 tests/explain_statistics.py
```

Set PSQL to select a particular client binary. The script extracts the actual
sampling SQL from `sql/pg_stat_user_tables_delta.sql` and runs EXPLAIN (ANALYZE, BUFFERS, TIMING
OFF) with zero sleep. It inspects the internal query, rather than the outer
PL/pgSQL Function Scan. It executes statistics reads and clears this connection's
statistics cache. Zero sleep is for overhead inspection, not useful sampling.

The query reads pg_stat_user_tables twice, stores native records, and sorts the
two snapshots once for the window function. Cache-clear dependencies and full
first-snapshot consumption are explicit. There is no final output sort. A small
OFFSET 0 barrier keeps the reset/decrease classification from being expanded and
recomputed for every output counter, without another materialized snapshot.

## Local measurement, PostgreSQL 17.11

Measured in the development Debian 13 container against an otherwise empty
database with 100 and then 1,000 empty, unindexed user tables. Default work_mem
was 4 MB. Each size had one warmup and three measured EXPLAIN ANALYZE executions,
TIMING OFF and zero sleep. This measures instrumented execution time, not CPU
usage, function-call overhead, client transfer, or intentional waiting.

| Tables / output rows | Median execution | Window sort memory | Shared buffer hits | Shared reads / temp writes |
| --- | --- | --- | --- | --- |
| 100 | 1.848 ms | 85 kB | 45 | 0 / 0 |
| 1,000 | 11.665 ms | 658 kB | 83 | 0 / 0 |

The corresponding three times were 1.888/1.848/1.730 ms and
11.940/11.665/11.364 ms. Sorts used in-memory quicksort. Planner time for the last
runs was 2.209 ms and 1.590 ms, respectively. Buffer metrics do not account for
all shared-memory statistics access or process memory.

These measurements preceded removal of the redundant `n * 0` sleep-argument
expression. Rerun the script for current timings. They are small synthetic
measurements, not a production performance guarantee.
Indexed/partitioned tables, larger catalogs, other cache modes, work_mem limits,
concurrent activity, and server load can change the plan and overhead. Snapshot
storage and sorting scale with relation count and may spill at larger sizes.
Use representative catalogs and repeated measurements when changing this query.

## Index sampler, PostgreSQL 17.11

Use the same helper with `--view indexes` to inspect the actual index SQL:

```sh
python3 tests/explain_statistics.py --view indexes
```

A separate synthetic run used 100 and then 1,000 empty tables, each with one
primary-key index. As above, zero sleep, default 4 MB work_mem, one warmup and
three measured EXPLAIN ANALYZE executions with TIMING OFF were used. This run
measured the current index function, without the redundant sleep arithmetic.

| Indexes / output rows | Median execution | Window sort memory | Shared buffer hits | Shared reads / temp writes |
| --- | --- | --- | --- | --- |
| 100 | 1.543 ms | 79 kB | 653 | 0 / 0 |
| 1,000 | 10.268 ms | 595 kB | 6,171 | 0 / 0 |

The three times were 1.543/1.703/1.299 ms and 17.711/10.268/9.522 ms. Last-run
planning times were 1.583 ms and 1.473 ms. Both sizes used one in-memory quicksort.
These are instrumented internal-query execution times, not CPU measurements or
production guarantees. The test did not exercise index scans in the workload;
functional tests separately check plain, bitmap and index-only activity. The
larger time variation illustrates why these small measurements should not be
used to claim a general speedup or a production overhead bound.

## User-table I/O sampler, PostgreSQL 17.11

```sh
python3 tests/explain_statistics.py --view statio_user_tables
```

A separate synthetic run used 100 and then 1,000 empty user tables, each with one
primary-key index and a text column (and therefore an associated TOAST relation).
Only user-table rows are returned. Settings were again default 4 MB work_mem,
zero sleep, one warmup and three EXPLAIN ANALYZE executions with TIMING OFF.

| User tables / output rows | Median execution | Window sort memory | Shared buffer hits | Shared reads / temp writes |
| --- | --- | --- | --- | --- |
| 100 | 2.579 ms | 73 kB | 1,455 | 0 / 0 |
| 1,000 | 27.520 ms | 533 kB | 18,255 | 0 / 0 |

The three times were 2.579/2.411/2.768 ms and 27.520/25.245/35.939 ms. Last-run
planning times were 2.423 ms and 2.047 ms. Both used in-memory quicksort. The
source view also collects index and TOAST statistics, so these catalogs differ
from the previous experiments; these figures are not a controlled comparison
between functions. All the measurement limits above apply.

Separately, `tests/check_statio_cold.py` validated actual read-counter changes on
a private PostgreSQL 17.11 cluster after its own clean restart. A sequential scan
produced 5 heap block reads; an indexed range scan produced 1 heap and 3 index
block reads; reading external TOAST values produced 41 TOAST heap and 2 TOAST
index block reads. These checks validate counter behavior, not device latency or
a production performance bound. The OS cache was not cleared.

## User-index I/O sampler, PostgreSQL 17.11

```sh
python3 tests/explain_statistics.py --view statio_user_indexes
```

Measured on 100 and then 1,000 empty user tables, each with one primary-key index,
using zero sleep, default 4 MB work_mem, one warmup and three EXPLAIN ANALYZE
executions with TIMING OFF. The native index records include only the source
view's identity fields and two block counters. There is one window sort and no
explicit final sort or extra per-index query.

| Indexes / output rows | Median execution | Window sort memory | Shared buffer hits | Shared reads / temp writes |
| --- | --- | --- | --- | --- |
| 100 | 1.527 ms | 76 kB | 653 | 0 / 0 |
| 1,000 | 9.624 ms | 564 kB | 6,171 | 0 / 0 |

The three times were 1.255/1.527/1.561 ms and 8.534/9.624/10.400 ms. Last-run
planning times were 1.826 ms and 2.347 ms; sorts used in-memory quicksort. These
instrumented internal-query measurements are not CPU measurements, a controlled
comparison with another function, or production guarantees. Catalog size, access
methods, cache state and load can affect cost and execution time.

The optional private-cluster cold-buffer check also sampled
`pg_statio_user_indexes_delta` after a clean restart and read an indexed range.
It observed 3 index block reads (and 0 index buffer hits), while leaving existing
servers and the operating system cache untouched.

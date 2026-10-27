# Uniform snapshot ordering and delta guards

All eight version-0.1.0 functions now use the same explicit ordering dependency in
first_snapshot and second_snapshot:

```sql
OFFSET (SELECT count(*) - 1 FROM initial_clear)
-- second_snapshot uses second_clear instead.
```

Each materialized clear CTE returns one row, so the offset is zero. PostgreSQL's
Limit node evaluates this InitPlan before scanning its child. The second clear
consumes waited, which depends on the aggregate consuming the complete first
snapshot. Clearing therefore precedes statistics getter evaluation, including
getters in source-view aggregates or Function Scans. No snapshot relies on
CROSS JOIN execution order to establish clearing.

Five samplers still match object IDs with FULL OUTER JOIN. WAL remains a
singleton CROSS JOIN. No new sort, window function or materialized object set is
introduced. The snapshots and timing aggregates retain their existing roles.

Every returned *_delta uses a status-ok CASE, with the subtraction inside that
CASE. Raw endpoints are carried to the final projection rather than subtracting
in a prior CTE and only then discarding invalid results. This also prevents
bigint overflow on invalid rows. Missing/reset/decreased rows retain their
existing status classification, but all their deltas are NULL together.

This rule now includes num_backends_delta. num_backends_start and
num_backends_end remain available where their snapshots exist; the signed
difference is NULL on reset/missing. On ok rows a falling connection count still
produces a valid negative difference. The public row types have not changed;
CREATE OR REPLACE FUNCTION can apply these body-only changes. Version stays 0.1.0.

An ordinary naming CTE does not guarantee a single status evaluation. The former
OFFSET 0 expressions and comments claiming that guarantee were removed. Plans may
expand the status expression into each CASE; this is accepted without adding
another materialized set of all monitored objects. The prior WAL comparison
confirmed expansion even with OFFSET 0.

## Validation

The preceding six-function integration suite passed all 60 methods on PostgreSQL
17.11 (100.363 seconds). The current eight-function suite adds I/O and function tests and has
77 methods; see [I/O query](io-query.md) and [function query](function-query.md). The controlled-snapshot
regression now executes all eight actual SQL queries with invalid statuses and raw
bigint endpoints whose difference would overflow. Every delta must return NULL
without evaluating that subtraction. Database missing/reset fixtures now also
assert num_backends_delta is NULL. Concurrent tests cover none/cache/snapshot
caching, resets and catch-up, alternate plans, repeated transactions, DDL, empty
object sets, and installation/schema relocation.

## Local plan and runtime comparison

Measurements and verification results for the preceding six-function revision
are recorded below. The new I/O sampler is measured in [io-query.md](io-query.md). Earlier per-function performance documents retain their historical
comparisons; their medians are not measurements of this revision.

PostgreSQL 17.11 / Debian 13, isolated disposable database with 1,000 empty user
tables, each with a primary-key index and text/TOAST storage. The comparison
executes the actual internal SQL with zero sleep, using EXPLAIN (ANALYZE, VERBOSE,
BUFFERS, TIMING OFF). Four warmups precede ten measured runs per query, alternating
before/after order. Database sampling returned five rows including the temporary
benchmark database; WAL returned one row. Other samplers returned 1,000 rows.

| Function | Before median ms | After median ms | Before range ms | After range ms |
| --- | ---: | ---: | --- | --- |
| `pg_stat_database_delta` | 0.3730 | 0.4435 | 0.285–0.627 | 0.334–1.655 |
| `pg_stat_user_indexes_delta` | 9.2770 | 9.4345 | 8.678–10.167 | 8.453–10.775 |
| `pg_stat_user_tables_delta` | 10.4805 | 11.0490 | 9.166–14.655 | 10.115–17.013 |
| `pg_stat_wal_delta` | 0.1575 | 0.1885 | 0.148–0.175 | 0.165–0.275 |
| `pg_statio_user_indexes_delta` | 8.4945 | 8.7550 | 7.730–10.048 | 8.173–9.268 |
| `pg_statio_user_tables_delta` | 19.4530 | 19.4585 | 18.540–22.887 | 19.178–25.866 |

All twelve after-snapshot plans have a Limit node with a pre-scan InitPlan (two
per function). No extra sort or WindowAgg was introduced. Per-function final sort
space was unchanged: database 26 KB, table statistics 314 KB, index statistics
298 KB, table I/O 267 KB, index I/O 282 KB; WAL has no sort. Shared buffer hits
were unchanged within each before/after pair (5, 346, 6,346, 18,252, 6,346 and 0
for database, tables, indexes, table I/O, index I/O and WAL respectively). There
were no shared reads or temporary writes in these measured plans.

Medians increased slightly for most queries, and all observed time ranges overlap.
No speedup is claimed. These are local instrumented execution measurements, not
CPU measurements or a production bound; client round trips, the PL/pgSQL wrapper
and intentional sleep are excluded. They do not quantify total process memory.
The changes establish uniform explicit cache ordering and guarded subtraction;
the earlier full-join performance tables are retained as historical evidence.

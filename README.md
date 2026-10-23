# pg_stat_delta

On-demand PostgreSQL statistics deltas, without snapshot tables or background
workers. Version 0.1.0 provides `pg_stat_database_delta`,
`pg_stat_user_tables_delta`, `pg_stat_user_indexes_delta`,
`pg_statio_user_tables_delta`, and `pg_statio_user_indexes_delta`.
Each accepts `seconds numeric DEFAULT 5`.
Implemented in PL/pgSQL; currently tested on **PostgreSQL 17.11**.

## Design priority

Correctness is mandatory. Among correct implementations, minimizing CPU, memory,
I/O and other overhead on the monitored server takes priority over convenience
and additional features. Queries should read only necessary statistics and avoid
redundant work and serialization. Keep queries as clear as possible; explain
necessary non-obvious techniques with comments at their point of use, and remove
redundant expressions or dependencies. A single SQL query is preferred when it retains
correct snapshot ordering and measurement semantics.

Performance changes should be assessed with comparable plans and representative
execution measurements, separating sampling sleep from actual query overhead.
Planner costs alone do not establish a runtime improvement. See [AGENTS.md](AGENTS.md)
for the development rules.

## Install

Install PostgreSQL, its client and server development package (PGXS), and make.
For example, on Debian with PostgreSQL 17: `postgresql-17`,
`postgresql-client-17`, `postgresql-server-dev-17`, and `make`.
No C compilation or external extension dependency is required.

```sh
make PG_CONFIG=/path/to/pg_config
make install PG_CONFIG=/path/to/pg_config
```

The installation step requires write access to the server's extension directory.
Then, as a database administrator:

```sql
CREATE EXTENSION pg_stat_delta;
SELECT * FROM pg_stat_database_delta();       -- wait approximately five seconds
SELECT * FROM pg_stat_database_delta(1.5);    -- fractional seconds are supported
```

During development all functions remain in **version 0.1.0**. New functions do
not introduce additional extension versions or upgrade scripts. The complete
`sql/pg_stat_delta--0.1.0.sql` is built from the five named per-function SQL source
files and kept in the repository for direct review. Run make after editing a
function; make install also rebuilds the installation script when necessary.

Installing files does not refresh functions in an existing database, and
`CREATE EXTENSION IF NOT EXISTS` does not reload them. To load a changed 0.1.0 in a
**disposable development database**, recreate the extension after make install:

```sql
DROP EXTENSION pg_stat_delta;
CREATE EXTENSION pg_stat_delta;
```

This uses no CASCADE: dependent objects must be handled explicitly. It removes
and recreates the extension's functions, so custom grants must be reapplied.

All functions run with the caller's privileges, without privilege escalation.
The extension can be installed into another schema with `CREATE EXTENSION ... SCHEMA ...`.
Calls require schema USAGE and function EXECUTE (the latter is granted to PUBLIC
by PostgreSQL by default; administrators can revoke it).

## Database statistics

Each call uses one SQL query: two materialized statistics snapshots are combined
with `UNION ALL`, then `lag()` computes the preceding values per database OID.
Rows stay in PostgreSQL's native record format; there is no JSON serialization.
Materialized CTE dependencies enforce complete first read → sleep → cache clear
→ second read, independently of the execution order of UNION ALL branches.
`OFFSET` subqueries force cache clearing before each statistics scan. No
persistent objects are created per measurement.

Rows are matched by `datid`, including PostgreSQL's shared-object row (`datid=0`,
NULL database name).

| Columns | Meaning |
| --- | --- |
| `datid`, `datname` | Database OID and name visible at the start of the query |
| `sampled_at_start`, `sampled_at_end` | Wall-clock timestamps immediately after each snapshot read |
| `elapsed_seconds` | Actual elapsed seconds between those timestamps |
| `status` | `ok` or `reset` |
| `stats_reset_start`, `stats_reset_end` | Reset timestamps from both snapshots |
| `num_backends_start`, `num_backends_end`, `num_backends_delta` | Connection counts and their signed difference |
| `xact_commit_delta`, `xact_rollback_delta` | Transaction counter deltas |
| `blks_read_delta`, `blks_hit_delta` | Block counter deltas |
| `tup_returned_delta`, `tup_fetched_delta`, `tup_inserted_delta`, `tup_updated_delta`, `tup_deleted_delta` | Tuple counter deltas |
| `temp_files_delta`, `temp_bytes_delta`, `deadlocks_delta` | Temporary-file and deadlock counter deltas |
| `blk_read_time_delta`, `blk_write_time_delta` | I/O time deltas in milliseconds; depend on `track_io_timing` |

For `reset`, **all cumulative counter deltas are NULL**. Connection measurements
remain available. A changed `stats_reset` identifies a reset; unchanged NULL
reset timestamps are accepted.

Calculate rates explicitly using actual duration, for example:

```sql
SELECT datname, status, xact_commit_delta,
       xact_commit_delta / NULLIF(elapsed_seconds, 0) AS commits_per_second
FROM pg_stat_database_delta(2);
```

NULL, negative, NaN and infinite intervals are rejected. Zero is allowed for an
immediate comparison, though it is rarely useful. Waiting occupies the calling
connection; normal query cancellation and `statement_timeout` apply.

## User-table statistics

```sql
SELECT schemaname, relname, status,
       seq_scan_delta, idx_scan_delta,
       n_tup_ins_delta, n_tup_upd_delta, n_tup_del_delta
FROM pg_stat_user_tables_delta(2)
ORDER BY schemaname, relname;
```

The function samples `pg_stat_user_tables` in the **current database**. It uses the
same single-query, native-record, `UNION ALL` / `lag()` approach, matching by `relid`.
No JSON, dynamic SQL, per-table queries, or snapshot tables are used. It returns
all user-table rows, including unchanged ones. An outer WHERE filters the result,
not the sampling work. No output ordering is promised; add ORDER BY if needed.

| Columns | Meaning |
| --- | --- |
| `relid`, `schemaname`, `relname` | Identity and names from the statement's catalog snapshot |
| `sampled_at_start`, `sampled_at_end`, `elapsed_seconds` | Same timing semantics as the database function |
| `status` | `ok` (no discontinuity detected), `reset`, or `counter_decreased` |
| `database_stats_reset_start`, `database_stats_reset_end` | Current database reset timestamps, read once per snapshot |
| `seq_scan_delta`, `seq_tup_read_delta` | Sequential scan counters |
| `idx_scan_delta`, `idx_tup_fetch_delta` | Index scan counters; NULL is preserved for tables without indexes |
| `n_tup_ins_delta`, `n_tup_upd_delta`, `n_tup_del_delta` | Tuple modification counters |
| `n_tup_hot_upd_delta`, `n_tup_newpage_upd_delta` | HOT and new-page update counters; subsets of updates, not additional operations |
| `vacuum_count_delta`, `autovacuum_count_delta`, `analyze_count_delta`, `autoanalyze_count_delta` | Maintenance operation counters |
| `n_live_tup_*`, `n_dead_tup_*` | Estimated live/dead tuple counts: `_start`, `_end`, and signed `_delta` |
| `n_mod_since_analyze_*`, `n_ins_since_vacuum_*` | Counts since maintenance: `_start`, `_end`, and signed `_delta` |
| `last_seq_scan_end`, `last_idx_scan_end`, `last_vacuum_end`, `last_autovacuum_end`, `last_analyze_end`, `last_autoanalyze_end` | Last-event timestamps in the second snapshot; never subtracted |

A changed database reset timestamp produces `reset`. In PostgreSQL 17,
`pg_stat_reset_single_table_counters()` also changes that timestamp, so even a
reset followed by counters catching up is detected. This database-wide marker
cannot identify the affected table: a table (or function) reset conservatively
invalidates **every table's** cumulative deltas in that sample. There is no
per-table reset timestamp in this view.

If any available cumulative counter decreases without a changed reset marker,
status is `counter_decreased` (for example, a dropped table's statistics can
vanish while its catalog row is still visible). For either invalid status, all
cumulative deltas are NULL. A decrease is evidence of a discontinuity, not proof
of its cause. `ok` does not certify that no concurrent DDL or statistics changes
occurred; statistics across objects are not atomic.

State estimates and counts since maintenance retain their raw before/after
values and signed differences, even for invalid samples. They are **not event
rates**: ANALYZE, VACUUM, TRUNCATE and resets can change or reduce them. Scan and
tuple counters describe PostgreSQL's published physical activity, not necessarily
committed logical changes or a sum over an inheritance/partition hierarchy.
The function preserves the source view's relation types and per-relation scope.
`track_counts` and statistics publication affect what is observable.

As with the database function, creation, rename and drop during the wait do not
refresh the statement's catalog snapshot. New tables appear on the next call;
renamed tables retain their initial names; dropped tables may retain a row with
invalid deltas. No attempt is made to lock user tables or prevent DDL.

Plan inspection and a small scaling measurement are documented in
[docs/performance.md](docs/performance.md).

## User-index statistics

```sql
SELECT schemaname, relname, indexrelname, status,
       idx_scan_delta, idx_tup_read_delta, idx_tup_fetch_delta
FROM pg_stat_user_indexes_delta(2)
ORDER BY schemaname, relname, indexrelname;
```

The source is `pg_stat_user_indexes` in the current database. The function reads
that view twice, retains native records and matches snapshots by **indexrelid**,
not index name or table OID. This keeps different indexes on the same table
separate. There is one window sort and no final output sort, JSON conversion,
per-index query, or persistent snapshot. An outer WHERE filters output, not the
two statistics scans. Idle indexes are included.

| Columns | Meaning |
| --- | --- |
| `relid`, `indexrelid` | Table and index OIDs |
| `schemaname`, `relname`, `indexrelname` | Names from the statement's catalog snapshot |
| `sampled_at_start`, `sampled_at_end`, `elapsed_seconds` | Same actual timing semantics as other samplers |
| `status`, `database_stats_reset_start`, `database_stats_reset_end` | Same conservative reset/decrease handling as the table sampler |
| `idx_scan_delta` | Change in index scans/searches, not a count of SQL queries |
| `idx_tup_read_delta` | Change in index entries returned by scans |
| `idx_tup_fetch_delta` | Change in live table rows fetched by simple index scans using this index |
| `last_idx_scan_end` | Last scan timestamp in the second snapshot, not a timestamp difference |

Counter interpretation matters:

- Bitmap scans increase `idx_tup_read`, but do not charge heap fetches to an
  individual index's `idx_tup_fetch`. Several indexes can contribute to one bitmap.
- Index-only scans can avoid heap fetches when the visibility map permits;
  therefore `idx_tup_read_delta` may be positive while `idx_tup_fetch_delta` is zero.
- Index entries can refer to dead/invisible tuples; not every returned index
  entry produces a live fetched row.
- A query may perform multiple index searches, and the planner itself can probe
  an index for boundary values when estimating selectivity. These counters do
  not describe only the executor nodes visible in EXPLAIN.
- These are scan/tuple counters, not disk I/O or a measure of index usefulness.
  The function does not calculate sizes or join unrelated I/O views.

A changed database reset marker returns `reset` for every index. In PostgreSQL
17, `pg_stat_reset_single_table_counters(index_oid)` can reset index statistics
and also changes that database marker. Any decreased cumulative counter without
a changed marker gives `counter_decreased`; all three cumulative deltas are NULL
for either invalid status. The last scan timestamp remains the raw second value.

Catalog snapshot and publication limitations also apply here. New/rebuilt indexes
with new OIDs may appear only on the next call; renames retain the original names;
a dropped index can retain a catalog row while its counters disappear. An `ok`
status is not proof that no concurrent DDL occurred. Scope and index eligibility
are exactly those of the source view; there is no hierarchy aggregation.

## User-table block I/O statistics

```sql
SELECT schemaname, relname, status,
       heap_blks_read_delta, heap_blks_hit_delta,
       idx_blks_read_delta, idx_blks_hit_delta,
       toast_blks_read_delta, toast_blks_hit_delta,
       tidx_blks_read_delta, tidx_blks_hit_delta
FROM pg_statio_user_tables_delta(2)
ORDER BY schemaname, relname;
```

The source is **pg_statio_user_tables**, in the current database. System and
TOAST relations are excluded as separate rows, exactly as in that view; each
user table still has its own index and TOAST counters. Snapshots are matched by
`relid`, with the same explicit ordering, native records, window-based deltas,
conservative reset handling, and catalog/publication limitations as other samplers.
There is no JSON, per-table query, write, or explicit final sort. An outer WHERE
only filters output, not sampling work. Unchanged user tables are included.

| Columns | Meaning |
| --- | --- |
| `relid`, `schemaname`, `relname` | Table identity and names in the catalog snapshot |
| `sampled_at_start`, `sampled_at_end`, `elapsed_seconds` | Actual timing, as in other samplers |
| `status`, `database_stats_reset_start`, `database_stats_reset_end` | `ok`, `reset`, or `counter_decreased`, with the database reset marker |
| `heap_blks_read_delta`, `heap_blks_hit_delta` | Table heap block reads and buffer hits |
| `idx_blks_read_delta`, `idx_blks_hit_delta` | Block reads and hits summed over the table's indexes |
| `toast_blks_read_delta`, `toast_blks_hit_delta` | Associated TOAST heap reads and hits |
| `tidx_blks_read_delta`, `tidx_blks_hit_delta` | Associated TOAST index reads and hits |

All eight counters are bigint differences. NULL is preserved for unavailable
components (for example, no index or no TOAST). A reset marker change, including
an index/table reset in PostgreSQL 17, invalidates all cumulative deltas. Any
decreasing component without a marker change yields `counter_decreased` and also
makes all eight deltas NULL. Aggregated index counters can decrease when indexes
are dropped or replaced; these statuses do not identify the particular cause.

`*_blks_read` counts PostgreSQL block reads, **not necessarily physical device
reads**: the operating system may serve a read from its cache. `*_blks_hit` counts
PostgreSQL buffer hits, not OS cache hits. These counters contain no write counts,
I/O latency or bytes. The function does not assume a block size or calculate a
cache-hit percentage. Statistics publication, concurrent DDL and `track_counts`
apply as for the source view; `ok` means no discontinuity was detected.

For optional cold-shared-buffer validation, run as a regular, non-root user:

```sh
python3 tests/check_statio_cold.py --pg-bindir /usr/lib/postgresql/17/bin
```

This creates a private temporary cluster, prepares heap/index/TOAST data, restarts
only that cluster to clear shared buffers, and verifies positive block-read
deltas. It cleans up its server and data; existing servers are untouched. It does
not clear the operating system cache or claim to measure physical device reads.

## User-index block I/O statistics

```sql
SELECT schemaname, relname, indexrelname, status,
       idx_blks_read_delta, idx_blks_hit_delta
FROM pg_statio_user_indexes_delta(2)
ORDER BY schemaname, relname, indexrelname;
```

`pg_statio_user_indexes_delta` samples **pg_statio_user_indexes** in the current
database. It returns one row per index, matching snapshots by `indexrelid`, with
`relid`, `schemaname`, `relname`, and `indexrelname` for identification. System
and TOAST indexes are excluded according to the source view. No index sizes,
heap I/O, extra statistics views or per-index queries are added.

`idx_blks_read_delta` and `idx_blks_hit_delta` are bigint differences of the source
counters: block reads and PostgreSQL buffer-cache hits for that particular index.
As with the table I/O sampler, reads are **not necessarily physical disk reads**.
The counters contain no write counts or latency. Even an index unused by an
executor can receive I/O from planner metadata probes; a zero-query workload
for that index does not guarantee zero index I/O.

The result also includes `sampled_at_start`, `sampled_at_end`, `elapsed_seconds`,
`status`, `database_stats_reset_start` and `database_stats_reset_end`. A changed
reset marker produces `reset`; a decreased counter produces `counter_decreased`.
Both deltas are NULL for either invalid status. PostgreSQL 17 index/table resets
update the database marker and conservatively invalidate all indexes' deltas.

The same cache-clear dependencies, single-query UNION ALL / lag approach,
catalog snapshot and publication limitations apply. There is no JSON conversion
or explicit final sort. Indexes created or replaced with new OIDs during the wait
appear on the next call; renames retain their initial names; dropped indexes can
retain a catalog row with vanished counters. Unchanged indexes are returned too,
and an outer WHERE does not reduce sampling work. Add ORDER BY if needed.

The optional private-cluster check above now also verifies positive per-index
block-read deltas after a second clean restart of that temporary cluster.

## Measurement limits

* Counters represent statistics **published** by other backends. Publication can
  lag activity; short intervals can miss work or include earlier work published
  during the interval. No cross-backend flush is forced by this function.
* One SQL statement retains one MVCC catalog snapshot. A database created during
  the wait is absent from this call; a renamed database retains its initial name;
  a dropped database retains its catalog row, although its statistics may vanish.
  A reset timestamp change invalidates its deltas, but this is not a reliable
  database-lifecycle detector. The next call sees the updated catalog.
* PostgreSQL does not provide a globally atomic snapshot of all database counters.
  Reading each snapshot takes time. The reported duration excludes the first
  read and includes the second; wall-clock adjustments can affect it.
* Statistics cache invalidation affects subsequent statistics reads in the same
  transaction. The function deliberately clears an existing cached snapshot.
* Measurement and other diagnostic connections can contribute to the statistics.
* Only the listed counters are included. Other PostgreSQL versions and
  statement deltas are unverified.

## Integration tests

Tests require Python 3, `psql`, and a running PostgreSQL 17 server. Use a
**disposable test database and cluster**: tests reset database statistics, create
and drop databases, tables and a role, and temporarily move the extension between schemas.
Tests require the current 0.1.0 files and all five functions loaded in the
selected test database.
The connection needs administrative privileges. No Python packages are required.

```sh
PGHOST=/path/to/socket PGPORT=5432 PGDATABASE=delta_test PGUSER=test_admin \
  python3 tests/integration.py
```

Set `PSQL` if the client is not on PATH. The suite checks input validation,
concurrent committed and rolled-back transactions in all three statistics cache
modes, repeated calls inside one transaction, reset handling, catalog snapshot
visibility during database/table DDL, and non-superuser calls after schema relocation.
Table tests cover DML, index scans, maintenance gauges, and table resets even when
counters catch up. Index tests cover plain, bitmap, and index-only scans, resets,
DDL visibility and repeated calls. I/O tests cover heap, index and TOAST buffer
hits, NULL components, user-only scope, resets, DDL and cache modes. Index I/O
tests also distinguish indexes of the same table. Installation tests verify that
only 0.1.0 is available, both default and explicit version selection install all
five extension members, and extension removal cleans up those functions. These
checks include another schema and empty user-table/index sets in a separate
disposable database. Sampling tests wait until the measurement connection enters
`pg_sleep` before generating activity.

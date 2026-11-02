# pg_stat_delta

On-demand PostgreSQL statistics deltas, without snapshot tables or background
workers. Version 0.1.0 provides `pg_stat_database_delta`,
`pg_stat_user_tables_delta`, `pg_stat_user_indexes_delta`,
`pg_statio_user_tables_delta`, `pg_statio_user_indexes_delta`, `pg_stat_wal_delta`,
`pg_stat_io_delta`, `pg_stat_user_functions_delta`, `pg_stat_bgwriter_delta`,
`pg_stat_checkpointer_delta`, `pg_stat_slru_delta`, `pg_stat_database_conflicts_delta`,
and `pg_stat_archiver_delta`.
Each accepts `i_delta_seconds numeric DEFAULT 5`.
Implemented in PL/pgSQL; currently tested on **PostgreSQL 17.11**.

## Functions and shared behavior

| Function | Source | Snapshot key |
| --- | --- | --- |
| `pg_stat_database_delta` | `pg_stat_database` | `datid` |
| `pg_stat_user_tables_delta` | `pg_stat_user_tables` | `relid` |
| `pg_stat_user_indexes_delta` | `pg_stat_user_indexes` | `indexrelid` |
| `pg_statio_user_tables_delta` | `pg_statio_user_tables` | `relid` |
| `pg_statio_user_indexes_delta` | `pg_statio_user_indexes` | `indexrelid` |
| `pg_stat_wal_delta` | `pg_stat_wal` | One cluster-wide row |
| `pg_stat_io_delta` | `pg_stat_io` | `(backend_type, object, context)` |
| `pg_stat_user_functions_delta` | `pg_stat_user_functions` | `funcid` |
| `pg_stat_bgwriter_delta` | `pg_stat_bgwriter` | One cluster-wide row |
| `pg_stat_checkpointer_delta` | `pg_stat_checkpointer` | One cluster-wide row |
| `pg_stat_slru_delta` | `pg_stat_slru` | `name` |
| `pg_stat_database_conflicts_delta` | `pg_stat_database_conflicts` | `datid` |
| `pg_stat_archiver_delta` | `pg_stat_archiver` | One cluster-wide row |

Each call reads two flat snapshots in one SQL query, waits between them, clears
the statistics cache for each read, and matches object rows with FULL OUTER JOIN.
WAL, background-writer, checkpointer and archiver sampling use singleton CROSS JOINs. All functions return `sampled_at_start`, `sampled_at_end`, `elapsed_seconds` and
`status`. Cumulative differences use `_delta`; state estimates and last-event
timestamps are separate values. Database scope includes its shared-object row;
the four relation samplers and function sampler follow their source views in the
current database.

| Status | Meaning | Availability |
| --- | --- | --- |
| `ok` | No discontinuity detected; source NULLs remain NULL | All functions |
| `reset` | A reset marker changed; table/index/function statistics also use this for counter decreases | All functions |
| `counter_decreased` | A counter decreased without a changed reset marker | Relation I/O, WAL, cluster I/O, bgwriter, checkpointer, SLRU, conflicts and archiver |
| `missing` | An identity exists in only one sampled row set | Row-set samplers, including `pg_stat_io_delta` |

**Every delta is NULL for a non-ok row**, including `num_backends_delta`.
Connection start/end counts, table state estimates and last-event times can remain
available where a snapshot exists. All thirteen functions clear caches before each
snapshot using `OFFSET (SELECT count(*) - 1 FROM initial_clear)` and the matching
`second_clear` dependency. Each subtraction occurs inside `CASE WHEN status =
'ok' THEN end_value - start_value END`; invalid rows never subtract counters.
See [uniform query policy](docs/uniform-snapshots.md).
A valid zero means no published counter change; NULL means unavailable or invalid,
not zero activity. `ok` does not certify an atomic measurement or absence of DDL.
The single statement retains its MVCC catalog snapshot, so `missing` is defensive
and does not promise live discovery of newly created objects during the wait.

PostgreSQL 17's `stats_fetch_consistency` controls transaction-local statistics
caching, independently of the data buffer cache:

| Mode | Statistics reads within the transaction |
| --- | --- |
| `none` | Read currently published values without retaining a statistics cache |
| `cache` (default) | Cache an object's statistics on first access |
| `snapshot` | Cache a statistics snapshot on first access |

`pg_stat_clear_snapshot()` discards this cached state. It does not force other
backends to publish pending counters. Short intervals can therefore miss recent
work or include earlier work published during measurement. The actual elapsed
seconds can exceed the requested wait; callers can cancel or use statement_timeout.

The current implementation/plan comparisons are indexed in
[docs/performance.md](docs/performance.md).

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
`sql/pg_stat_delta--0.1.0.sql` is built from the thirteen named per-function SQL source
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

The database function uses one SQL query with two materialized, **flat**
`pg_stat_database` snapshots, matched by `FULL OUTER JOIN`. This is the baseline
for further database-query optimization. It avoids composite-record field access,
`UNION ALL` and window functions. The table and index samplers also use full joins,
as described below.
The seven object samplers use flat snapshots and FULL OUTER JOIN. All thirteen
samplers, including WAL, retain explicit pre-scan cache-clear OFFSET barriers.

`pg_stat_clear_snapshot()` runs for each read through the singleton clear CTE,
consumed by the snapshot OFFSET InitPlan before entering the source scan.
Aggregates in `first_time` and `second_time` fully consume their respective
snapshots and yield one timing row. The second clear depends on the sleep.
The final join preserves a row even if only one snapshot contains its OID.
Native scalar types are retained throughout, without JSON or persistent tables.
The result is ordered by database OID.

Rows are matched by `datid`, including PostgreSQL's shared-object row (`datid=0`,
NULL database name).

| Columns | Meaning |
| --- | --- |
| `datid`, `datname` | Database OID and name visible at the start of the query |
| `sampled_at_start`, `sampled_at_end` | Wall-clock timestamps immediately after each snapshot read |
| `elapsed_seconds` | Actual elapsed seconds between those timestamps |
| `status` | `ok`, `reset`, or `missing` |
| `num_backends_start`, `num_backends_end`, `num_backends_delta` | Connection counts and their signed difference |
| `xact_commit_delta`, `xact_rollback_delta` | Transaction counter deltas |
| `blks_read_delta`, `blks_hit_delta` | Block counter deltas |
| `tup_returned_delta`, `tup_fetched_delta`, `tup_inserted_delta`, `tup_updated_delta`, `tup_deleted_delta` | Tuple counter deltas |
| `temp_files_delta`, `temp_bytes_delta`, `deadlocks_delta` | Temporary-file and deadlock counter deltas |
| `blk_read_time_delta`, `blk_write_time_delta` | I/O time deltas in milliseconds; depend on `track_io_timing` |
| `session_time_delta`, `active_time_delta`, `idle_in_transaction_time_delta` | Published session, active, and idle-in-transaction time deltas in milliseconds |
| `sessions_delta` | Change in established sessions, not the instantaneous connection count |

For `reset` or `missing`, **all deltas are NULL**, including `num_backends_delta`.
Connection start/end counts remain available wherever the snapshot exists. `stats_reset` is
compared internally; equal NULL markers are accepted. `missing` denotes an OID
present in only one snapshot and is a defensive case, not a promise of live
catalog refresh. The statement still uses one MVCC catalog snapshot.

Session time fields are published cumulative statistics, not stopwatches sampled
continuously by this function. They can include time accrued before the interval
but published during it. Values are milliseconds, while `elapsed_seconds` is
seconds. `sessions_delta` counts newly established sessions and is distinct from
`num_backends_delta` (a change in current connections).

This development revision changes the returned row type: it adds four session
fields and removes `stats_reset_start` / `stats_reset_end` from the public result.
Existing SQL using those fields or positional SELECT * results needs adjustment.
PostgreSQL cannot apply this return-type change with CREATE OR REPLACE FUNCTION;
reload the development extension using the recreation instructions above. The
extension remains version 0.1.0.

See [docs/database-query.md](docs/database-query.md) for the plan comparison,
measurements and the scope of execution-order validation.

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
       n_tup_ins_delta, n_tup_upd_delta, n_tup_del_delta,
       n_live_tup, n_dead_tup, last_analyze
FROM pg_stat_user_tables_delta(2)
ORDER BY schemaname, relname;
```

The function samples `pg_stat_user_tables` in the **current database**. Flat native
snapshots are matched by `relid` using FULL OUTER JOIN, without JSON, dynamic SQL,
per-table queries or persistent snapshots. Only required columns are read; the
first snapshot does not collect the second snapshot's state fields. Results are
ordered by schema and table name. An outer WHERE filters the result, not sampling.

| Columns | Meaning |
| --- | --- |
| `relid`, `schemaname`, `relname` | Identity and names from the statement's catalog snapshot |
| `sampled_at_start`, `sampled_at_end`, `elapsed_seconds` | Actual timing, as with the database function |
| `status` | `ok`, `reset` (a reset/discontinuity was detected), or `missing` |
| `seq_scan_delta`, `seq_tup_read_delta` | Sequential scan counter deltas |
| `idx_scan_delta`, `idx_tup_fetch_delta` | Index scan counter deltas; NULL is preserved for tables without indexes |
| `n_tup_ins_delta`, `n_tup_upd_delta`, `n_tup_del_delta` | Tuple modification counter deltas |
| `n_tup_hot_upd_delta`, `n_tup_newpage_upd_delta` | HOT and new-page update deltas; subsets of updates, not extra operations |
| `n_live_tup`, `n_dead_tup` | Estimated live/dead tuple counts in the second snapshot |
| `n_mod_since_analyze`, `n_ins_since_vacuum` | Counts since maintenance in the second snapshot |
| `last_vacuum`, `last_autovacuum`, `last_analyze`, `last_autoanalyze` | Last maintenance times in the second snapshot |

The database reset marker is read **once per snapshot**, not per table. In
PostgreSQL 17 a single-table reset also updates that marker. This catches resets
even if subsequent activity has brought all table counters above their old values.
The marker does not identify the affected table, so a table/function reset
conservatively invalidates all tables' cumulative deltas in the sample.

Any decrease in the nine returned cumulative counters also produces `reset`;
this denotes an unreliable measurement, not proof of the cause (dropping an index
can decrease aggregated index counters too). For reset or missing rows **all nine
cumulative deltas are NULL**. Checking only scan counters or independently masking
negative deltas is insufficient to establish validity. `ok` means no discontinuity
was detected; snapshots across objects are not globally atomic.

State estimates and maintenance timestamps come directly from the second
snapshot, even for reset/missing-before rows. They are not subtracted or converted
to event rates. Missing-after rows have NULL end-state fields. ANALYZE, VACUUM,
TRUNCATE or a reset can decrease state values without implying a cumulative-counter
reset. Table counters retain the source view's physical/per-relation scope and
are not necessarily committed logical changes or sums over partition hierarchies.

This development revision removes the public database-reset timestamps,
maintenance-count deltas, scan timestamps, and state `_start`/`_end`/`_delta`
triples. It returns the compact end-state fields listed above instead. Recreate
the development extension to load this changed return type; CREATE OR REPLACE
FUNCTION cannot change the old returned row type in place. Version stays 0.1.0.

The source view aggregates index statistics, so snapshot reads retain explicit
cache-clear OFFSET dependencies. See [docs/table-query.md](docs/table-query.md)
for why the proposed cross joins alone are not used as ordering guarantees, the
reset regression tests, and the three-way performance comparison.

Creation, rename and drop during the wait do not refresh the statement's catalog
snapshot. New tables appear on the next call; renamed tables retain their initial
names; dropped tables may retain a row with invalid deltas. `track_counts` and
statistics publication delays affect observations. No table locks are added to
prevent DDL.

## User-index statistics

```sql
SELECT schemaname, relname, indexrelname, status,
       idx_scan_delta, idx_tup_read_delta, idx_tup_fetch_delta
FROM pg_stat_user_indexes_delta(2)
ORDER BY schemaname, relname, indexrelname;
```

The source is `pg_stat_user_indexes` in the current database. The function reads
required scalar columns into two flat snapshots and uses FULL OUTER JOIN by **indexrelid**,
not index name or table OID. This keeps different indexes on the same table
separate. There is no window function, JSON conversion, per-index query or
persistent snapshot. The first snapshot omits the last-scan timestamp, which is
only needed from the second. Results are sorted by schema, table and index name.
An outer WHERE filters output, not the two statistics scans. Idle indexes are included.

| Columns | Meaning |
| --- | --- |
| `relid`, `indexrelid` | Table and index OIDs |
| `schemaname`, `relname`, `indexrelname` | Names from the statement's catalog snapshot |
| `sampled_at_start`, `sampled_at_end`, `elapsed_seconds` | Same actual timing semantics as other samplers |
| `status` | `ok`, `reset` (a detected reset/discontinuity), or `missing` |
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

The database reset marker is still read once per snapshot internally, but is no
longer returned as public columns. A marker change returns `reset` for every
index, including a reset whose counters have already grown past their baseline.
In PostgreSQL 17, `pg_stat_reset_single_table_counters(index_oid)` changes that
marker too. Any decrease among the three counters also produces `reset`; this
marks a discontinuity rather than proving its cause. A missing snapshot row
produces `missing`.

For either invalid status **all three cumulative deltas are NULL**, not only the
decreasing counter's delta. `last_idx_scan_end` is the raw second-snapshot value,
even for reset or missing-before rows; it is NULL for a missing-after row.

This revision removes `database_stats_reset_start` and `database_stats_reset_end`
from the public result and replaces `counter_decreased` with `reset` for counter
decreases. The extension stays version 0.1.0. Recreate the development extension
as documented above to apply the changed return type; CREATE OR REPLACE FUNCTION
cannot change the old returned row type in place.

See [docs/index-query.md](docs/index-query.md) for the original proposal's reset
regressions, execution-plan checks, and performance comparison.

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
user table still has its own index and TOAST counters. Flat snapshots are matched
by `relid` with FULL OUTER JOIN. The function keeps native scalar types, explicit
pre-scan cache-clear dependencies, and conservative validity checks. There is no
JSON, per-table query or persistent write. Results are sorted by schema and table
name. An outer WHERE only filters output, not sampling work; unchanged user tables
are included.

| Columns | Meaning |
| --- | --- |
| `relid`, `schemaname`, `relname` | Table identity and names in the catalog snapshot |
| `sampled_at_start`, `sampled_at_end`, `elapsed_seconds` | Actual timing, as in other samplers |
| `status` | `ok`, `reset`, `counter_decreased`, or `missing` |
| `heap_blks_read_delta`, `heap_blks_hit_delta` | Table heap block reads and buffer hits |
| `idx_blks_read_delta`, `idx_blks_hit_delta` | Block reads and hits summed over the table's indexes |
| `toast_blks_read_delta`, `toast_blks_hit_delta` | Associated TOAST heap reads and hits |
| `tidx_blks_read_delta`, `tidx_blks_hit_delta` | Associated TOAST index reads and hits |

All eight counters are bigint differences. NULL is preserved for unavailable
components (for example, no index or no TOAST). The database reset marker is read
once per snapshot internally, without being returned as extra columns. A marker
change, including an index/table reset in PostgreSQL 17, yields `reset`. Any
decreasing component without a marker change yields `counter_decreased`.
A missing snapshot row yields `missing`.

**All eight deltas are NULL for every non-ok status**, even when some counters
are zero, unchanged or already above their pre-reset values. Independent
nonnegative subtraction is insufficient after a reset. Aggregated index counters
can decrease when indexes are dropped or replaced; statuses do not prove a
particular cause.

The two public database-reset timestamp columns have been removed, as requested
in the compact signature. Reload the development extension to apply this changed
return type; CREATE OR REPLACE FUNCTION cannot change the old row type in place.
Version remains 0.1.0. See [docs/table-io-query.md](docs/table-io-query.md) for the
proposed-query regression, execution ordering and performance comparison.

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

The result also includes `sampled_at_start`, `sampled_at_end`, `elapsed_seconds`
and `status`. The database reset marker is read once per snapshot internally;
it is no longer returned as public timestamp columns. A changed marker produces
`reset`; any decreased counter produces `counter_decreased`; an absent snapshot
row produces `missing`. **Both deltas are NULL for every non-ok status**, even if
one counter is zero, unchanged or has recovered past its pre-reset value.
PostgreSQL 17 index/table resets update the database marker and conservatively invalidate all indexes' deltas.

Flat snapshots are matched with FULL OUTER JOIN by `indexrelid`, independently
of other indexes sharing the table `relid`. The timing aggregates and clear/sleep
dependencies remain. There is no JSON, window function or per-index query. Results
are sorted by schema, table and index name. Indexes created or replaced with new
OIDs during the wait appear on the next call; renames retain their initial names; dropped indexes can
retain a catalog row with vanished counters. Unchanged indexes are returned too,
and an outer WHERE does not reduce sampling work. Add ORDER BY if needed.

The public reset timestamp columns were removed to match the compact signature.
Reload the development extension to apply the new return type; CREATE OR REPLACE
FUNCTION cannot change that row type in place. All functions stay version 0.1.0.
See [docs/index-io-query.md](docs/index-io-query.md) for validation and measurements.

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

## WAL statistics

```sql
SELECT * FROM pg_stat_wal_delta(1);
```

The source is `pg_stat_wal`: exactly one row for the **whole cluster**, including
activity from other databases and background processes. The result contains the
four common timing/status columns and these eight deltas:

| Column | Type | Meaning |
| --- | --- | --- |
| `wal_records_delta` | bigint | WAL records generated |
| `wal_fpi_delta` | bigint | Full-page images generated |
| `wal_bytes_delta` | numeric | WAL bytes generated |
| `wal_buffers_full_delta` | bigint | WAL writes caused by full WAL buffers |
| `wal_write_delta` | bigint | WAL write requests |
| `wal_sync_delta` | bigint | WAL synchronization requests |
| `wal_write_time_delta` | double precision | WAL write time, milliseconds |
| `wal_sync_time_delta` | double precision | WAL synchronization time, milliseconds |

Times depend on `track_wal_io_timing`; a zero does not establish absence of I/O.
Synchronization counts/times also depend on `wal_sync_method`; methods performing
synchronization within the write do not report separate sync operations in the
same way. These are PostgreSQL WAL statistics, not physical-device measurements.

A changed source `stats_reset` produces `reset`; any decreased counter without a
changed marker produces `counter_decreased`. Either invalidates **all eight**
deltas. Otherwise status is `ok`. The reset marker stays internal. No per-database
marker, object identifier, `missing` status, sort or identity matching is needed.
A reset is visible even when new activity has already overtaken old counters.

Two materialized native snapshots are separated by the requested wait. A zero
OFFSET InitPlan forces each cache clear before the source Function Scan starts;
this is needed because `pg_stat_wal` calls `pg_stat_get_wal()` in FROM. See
[docs/wal-query.md](docs/wal-query.md) for ordering and test details. Statistics
publication remains asynchronous; clearing this session's cache cannot force
other processes to publish. The common elapsed-time semantics apply.

## Cluster I/O statistics

```sql
SELECT * FROM pg_stat_io_delta(1);
```

The source is `pg_stat_io`, aggregated across the **whole cluster**, not a
particular database, relation or PID. Rows are matched on all three dimensions:
`backend_type`, `object`, `context` (text). The result is ordered by that key.
It returns the common timing/status columns, `op_bytes bigint`, and 13 deltas:

| Columns | Type | Meaning |
| --- | --- | --- |
| `reads_delta`, `writes_delta` | bigint | Read/write units of size `op_bytes` |
| `writebacks_delta` | bigint | Units requested for writeback toward permanent storage |
| `extends_delta` | bigint | Relation extension units |
| `hits_delta` | bigint | PostgreSQL buffer-cache hits |
| `evictions_delta`, `reuses_delta` | bigint | Buffer evictions and reuse within I/O-context rings |
| `fsyncs_delta` | bigint | File synchronization operations |
| `read_time_delta`, `write_time_delta`, `writeback_time_delta`, `extend_time_delta`, `fsync_time_delta` | double precision | Corresponding cumulative time differences, milliseconds |

`op_bytes` is the byte size per operation, **not a cumulative counter**. Its
second-snapshot value is returned, falling back to the first for a missing row.
No derived byte totals or rates are calculated. In the tested PostgreSQL 17
source the size is fixed per server build. Buffer hits, evictions and reuses are
not additional read/write operations and must not be summed as bytes.

Source NULLs indicate operations inapplicable to that backend/object/context
combination; they remain NULL. Timing depends on `track_io_timing` in the
processes doing the work. A zero time does not imply no I/O. Reads may be served
by the OS cache; writes/writebacks do not prove durable device writes.

In PostgreSQL 17 this view covers relation and temporary-relation I/O for its
listed backend types and contexts. It does **not** include every kind of server
I/O: WAL is sampled separately, and temporary sort/hash spill files are distinct
from temporary relations. Interpret each row according to the source view.

Changed source `stats_reset` means `reset`, any decreasing cumulative metric
means `counter_decreased`, and a key present in just one snapshot means `missing`.
All 13 deltas are NULL for any invalid status. The source reset marker stays
internal. `pg_stat_reset_shared('io')` resets cluster-wide I/O statistics; a
database statistics reset alone is not the I/O reset marker. Published statistics
are asynchronous and the measurement connection itself can contribute activity.

The implementation uses two flat native snapshots, explicit pre-scan OFFSET
cache-clear dependencies, FULL OUTER JOIN on the complete key, and status-ok
CASEs containing each subtraction. No JSON, snapshot tables, or additional
materialized classification set is used. See [I/O query analysis](docs/io-query.md).
Only PostgreSQL 17.11 has been verified; later pg_stat_io layouts are not claimed
compatible. All thirteen functions remain in version 0.1.0.

## Function statistics

```sql
-- Enable tracking in the sessions that execute the measured functions:
SET track_functions = 'pl';
-- After workloads have published baseline statistics:
SELECT * FROM pg_stat_user_functions_delta(1);
```

This samples `pg_stat_user_functions` in the **current database**, matching by
`funcid oid`. The result includes `schemaname name`, `funcname name`, the four
common timing/status columns, and:

| Column | Type | Meaning |
| --- | --- | --- |
| `calls_delta` | bigint | Published function-call count difference |
| `total_time_delta` | double precision | Inclusive execution time difference, milliseconds |
| `self_time_delta` | double precision | Execution time excluding other tracked functions, milliseconds |

Overloads can share schema and name, so use `funcid` to identify a function or
resolve its signature. Results are ordered by schema, name and function OID.
Inclusive times overlap across nested calls; summing them does not give total
server CPU time. These are elapsed execution statistics, including waits, not
CPU measurements.

`track_functions` defaults to `none`. `pl` tracks procedural-language functions;
`all` additionally enables other eligible functions, including non-inlined SQL
and C functions. Inlined SQL functions have no separate tracked execution.
Enable tracking in the **workload sessions**, not merely the measurement session;
changing it may require privileges. The sampler does not change this setting.
Existing tracked rows can remain when tracking is disabled, with no new calls
recorded from sessions where it is off. An empty result does not prove no
functions ran. The source view determines membership; no extra schema filter is
introduced.

A newly published function absent from the first snapshot yields `missing` and
NULL deltas: no zero baseline is invented. This can occur even when its catalog
entry predates the query. Catalog rename/create visibility still follows the
single statement's MVCC snapshot. A common timestamp pair describes the complete
read sets, not atomic per-function samples.

The internal database reset marker is read once per snapshot. In PostgreSQL 17,
`pg_stat_reset_single_function_counters(funcid)` also advances this marker,
allowing resets to be detected even after counters catch up. Such marker changes
conservatively invalidate all sampled function rows; any of the three counters
decreasing also produces `reset`. Missing or reset rows have all three deltas
NULL. Published statistics can lag execution; cache clearing does not force
workers to flush, and timing for a long call is not apportioned to the interval.
If the sampler itself is tracked, completed measurements can contribute activity.

Two flat snapshots, explicit pre-scan OFFSET dependencies, FULL OUTER JOIN and
status-ok guarded subtraction follow the common policy. No JSON or persistent
snapshots are used. See [function query analysis](docs/function-query.md).
Version remains 0.1.0; only PostgreSQL 17.11 is verified.

## Background-writer statistics

```sql
SELECT * FROM pg_stat_bgwriter_delta(1);
```

The source is PostgreSQL 17 `pg_stat_bgwriter`, one row for the **whole cluster**.
Along with the four common timing/status columns it returns:

| Column | Type | Meaning |
| --- | --- | --- |
| `buffers_clean_delta` | bigint | Buffers written by the background writer |
| `maxwritten_clean_delta` | bigint | Times the writer stopped a cleaning scan after reaching its write limit |
| `buffers_alloc_delta` | bigint | Shared-buffer allocations, not physical reads or new memory allocation |

PostgreSQL 17 moved checkpoint statistics into `pg_stat_checkpointer`. They are
not included here, and older pg_stat_bgwriter layouts are not claimed supported.
Allocation, writing, and limit-hit counts describe different events; do not sum
them as I/O bytes. A limit hit is not a write error. Zero writes can reflect the
writer's settings or workload, as well as publication delays.

A changed source `stats_reset` produces `reset`; any decreased counter without
a changed marker produces `counter_decreased`. Both invalidate **all three**
deltas. Matching NULL markers are accepted. There is no missing-object status,
identity join or sort. Both snapshots retain the common pre-scan OFFSET clear
dependency, and every difference is computed only in its status-ok CASE.

The marker belongs to `pg_stat_bgwriter`, not the current database.
`pg_stat_reset_shared('bgwriter')` resets this cluster-wide statistics set;
database, WAL and I/O resets do not by themselves invalidate it. The sampler
neither changes writer settings nor forces a checkpoint. Background-writer publication is
asynchronous, including idle/hibernation effects; `pg_stat_force_next_flush()`
in a client backend cannot force the background writer to publish. Very short
intervals can therefore return zero even when activity occurred.

The optional real-write check uses only a private temporary cluster with a small
buffer pool and aggressive writer settings:

```sh
python3 tests/check_bgwriter_workload.py --pg-bindir /path/to/postgresql/17/bin
```

It verifies positive deltas for all three counters and removes its own cluster.
Existing servers and their settings are untouched. See
[bgwriter query analysis](docs/bgwriter-query.md). Version remains 0.1.0.

## Checkpointer statistics

```sql
SELECT * FROM pg_stat_checkpointer_delta(1);
```

This PostgreSQL 17 source is one row for the **whole cluster**. The four common
timing/status fields are followed by:

| Columns | Type | Meaning |
| --- | --- | --- |
| `num_timed_delta`, `num_requested_delta` | bigint | Timed and requested checkpoints |
| `restartpoints_timed_delta`, `restartpoints_req_delta` | bigint | Timed and requested restartpoints |
| `restartpoints_done_delta` | bigint | Restartpoints actually performed |
| `write_time_delta`, `sync_time_delta` | double precision | Writing and synchronization phase time differences, milliseconds |
| `buffers_written_delta` | bigint | Buffers written by the checkpointer |

A requested restartpoint need not be performed. Restartpoints concern recovery;
a primary normally has zero restartpoint activity. Writing-phase time includes
checkpoint pacing and is not a physical-device latency measurement. These counts
are separate from background-writer statistics.

Changed source `stats_reset` produces `reset`; any decreased metric produces
`counter_decreased`. Either makes all eight deltas NULL. There is no missing-row
status, identity join or final sort. `pg_stat_reset_shared('checkpointer')` resets
this statistics set; a bgwriter reset alone does not invalidate it. The sampler
does not request checkpoints or restartpoints; tests explicitly do so in isolated
test environments. See [checkpointer analysis](docs/checkpointer-query.md).

## SLRU statistics

```sql
SELECT * FROM pg_stat_slru_delta(1);
```

This samples cluster-wide `pg_stat_slru` rows, keyed and ordered by `name text`.
It returns that name, the common timing/status fields, and seven bigint deltas:
`blks_zeroed_delta`, `blks_hit_delta`, `blks_read_delta`, `blks_written_delta`,
`blks_exists_delta`, `flushes_delta`, `truncates_delta`.

These are counts of SLRU events, not relation-buffer I/O. Existence checks,
flushes and truncations are distinct operations; flushes are not a device-fsync
count. No byte totals are derived. Reads may still be served by the OS cache.

Each row's own `stats_reset` validates its pair of snapshots. A marker change
means `reset`, a decrease means `counter_decreased`, and a name in just one
snapshot means `missing`. Every invalid row has all seven deltas NULL.
`pg_stat_reset_slru('transaction')` resets just that PG17 cache; a NULL argument
resets all SLRU caches. Other rows remain valid on a targeted reset. Names are
preserved from the source, without a hard-coded list; names/layouts in other
PostgreSQL versions are unverified. See [SLRU analysis](docs/slru-query.md).

## Recovery conflicts by database

```sql
SELECT * FROM pg_stat_database_conflicts_delta(1);
```

Rows match and sort by `datid oid`, include `datname name` and the common timing/
status columns, and return six bigint deltas: `confl_tablespace_delta`,
`confl_lock_delta`, `confl_snapshot_delta`, `confl_bufferpin_delta`,
`confl_deadlock_delta`, `confl_active_logicalslot_delta`.

These are **recovery conflicts**, normally accumulated on a standby, not ordinary
primary lock waits, application deadlocks, serialization failures, or query errors.
Primary activity normally produces zero. The source covers database catalog rows,
without the shared-object datid=0 row from pg_stat_database.

The source has no reset timestamp. Each snapshot adds only
`pg_stat_get_db_stat_reset_time(datid)` for that row, avoiding another statistics
view scan and keeping the marker internal. A changed marker gives `reset`, any
counter decrease gives `counter_decreased`, and a database in only one snapshot
gives `missing`. All six deltas are NULL for any invalid status. Database resets,
including ones triggered by individual relation/function resets in PostgreSQL 17,
can conservatively invalidate conflicts even when their values did not change.
Matching NULL markers are accepted. Catalog DDL still follows one statement's
MVCC snapshot; missing is defensive, not live database discovery.

[The private primary/standby test](tests/check_recovery_conflicts.py) actually
cancels standby queries through replayed exclusive locks in all three cache modes,
then verifies a requested/performed restartpoint. It creates only private
Unix-socket servers and removes both on completion:

```sh
python3 tests/check_recovery_conflicts.py --pg-bindir /path/to/postgresql/17/bin
```

See [conflict analysis](docs/conflicts-query.md). All three new samplers use the
common zero-OFFSET clear dependencies, native flat snapshots, guarded subtraction
and asynchronous publication semantics. They remain in version 0.1.0 and are
verified on PostgreSQL 17.11 only.

## Archiver statistics

```sql
SELECT * FROM pg_stat_archiver_delta(1);
```

The source is `pg_stat_archiver`, one row for the **whole cluster**, even when
archiving is disabled. Along with the four common timing/status fields, the
result returns:

| Column | Type | Meaning |
| --- | --- | --- |
| `archived_count_delta` | bigint | Successful archiving count difference |
| `failed_count_delta` | bigint | Failed archiving attempt count difference |
| `last_archived_wal_end` | text | Last successfully archived WAL filename at the second read |
| `last_archived_time_end` | timestamptz | That success's reported timestamp |
| `last_failed_wal_end` | text | Last WAL filename whose archiving failed at the second read |
| `last_failed_time_end` | timestamptz | That failure's reported timestamp |

Repeated failed attempts for the same file can increment `failed_count` more than
once. Some archiver process/command errors are not counted by PostgreSQL in this
view; the delta is not an exhaustive server-error count. Success means the
configured archive mechanism reported success, not a verification of backup
completeness or recoverability. Do not infer byte totals, LSN distance or newest
available WAL from the last filename.

The four `_end` values are **state**, not deltas or events guaranteed to have
occurred inside the sample. They can predate the interval and remain non-NULL
when count differences are zero. Source NULLs remain NULL. They are returned
from the second snapshot even for an invalid measurement, and are not invented
from the sampling timestamps.

A changed source `stats_reset` means `reset`; either count decreasing without
that change means `counter_decreased`. Both make **both deltas NULL** while
retaining the final event state. Matching NULL markers are accepted. There is
no missing-row status, identity join or sort. `pg_stat_reset_shared('archiver')`
resets these statistics, not the archive files. Other statistics resets do not
by themselves invalidate archiver deltas.

The first snapshot keeps only the two counters and marker; the second also
keeps last-event fields. Both use explicit pre-scan OFFSET clear dependencies.
The function does not change archive settings, switch WAL, execute archive
commands or inspect archive files. Publication is asynchronous; a client forced
flush cannot make another process report. Disabled/no-activity archiving can
return zero, which is not a diagnosis of configuration or archive health.

The optional private-cluster test exercises real successful archive copies,
command exit-code-1 failures and reset followed by success:

```sh
python3 tests/check_archiver_workload.py --pg-bindir /path/to/postgresql/17/bin
```

Only that temporary Unix-socket cluster has archive settings changed, and it is
removed afterward. See [archiver analysis](docs/archiver-query.md). The new
function remains version 0.1.0 and is verified on PostgreSQL 17.11.

## Integration tests

The suite currently contains **108 integration test methods**; some exercise
multiple cache modes or edge cases. The complete suite passed on PostgreSQL 17.11
with the current thirteen-function implementation. The optional private-cluster cold
block-read check also passed.

Tests require Python 3, `psql`, and a running PostgreSQL 17 server. Use a
**disposable test database and cluster**: tests reset database and cluster-wide
WAL, I/O, bgwriter, checkpointer, SLRU and archiver statistics, create and drop databases, tables and a role, and temporarily move
the extension between schemas.
Tests require the current 0.1.0 files and all thirteen functions loaded in the
selected test database.
The connection needs administrative privileges. No Python packages are required.
Cache tests explicitly read sum() of a statistic before sampling (for example,
sum(idx_blks_hit)); count(*) can be optimized to read only catalog identities
and is not a valid way to prime the statistics cache.

The session-timing test uses the standard `sleep` utility through psql's client-side
`\!` command to leave a transaction idle before continuing.

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
tests also distinguish indexes of the same table. WAL tests cover real inserts in
all three cache modes, alternate plans, shared WAL reset followed by new activity,
native numeric bytes, and each individual counter decreasing. A controlled-snapshot
regression checks all thirteen queries with invalid rows whose bigint subtraction
would overflow: every delta must be NULL without an arithmetic error. Cluster I/O
tests cover all three key dimensions, each counter decreasing, inapplicable NULL
metrics, cache modes, normal and temporary relations, shared I/O resets, repeated
calls and alternate plans. Bgwriter tests cover actual allocations, three cache
modes, shared resets and independence from unrelated resets, repeated calls,
alternate plans, native bigint precision and each counter decreasing. Function tests cover exact calls in three cache modes,
overloads, nested inclusive/self timing, disabled tracking, SQL inlining, first
statistics publication, reset/catch-up, database reset, catalog rename, repeated
calls and alternate plans. The private-cluster check also verifies positive read
counts and measured read time with track_io_timing enabled. Checkpointer tests
exercise explicit checkpoints and marker independence. SLRU tests cover real
transaction activity, targeted/global resets and stable names. Conflict tests
cover primary zeros, database resets and controlled missing/decreasing rows; the
optional primary/standby helper covers actual recovery cancellations and
restartpoints. Archiver tests cover cached and unrelated resets, repeated calls,
end-event state (including stale/NULL values), bigint precision and both individual
counter decreases. A private archive-mode cluster checks actual copies, failed
commands and reset followed by success. Installation tests
verify that
only 0.1.0 is available, both default and explicit version selection install all
thirteen extension members, and extension removal cleans up those functions. These
checks include another schema and empty user-table/index sets in a separate
disposable database. Sampling tests wait until the measurement connection enters
`pg_sleep` before generating activity.

# pg_stat_delta

On-demand PostgreSQL statistics deltas, without snapshot tables or background
workers. Version 0.1.0 provides `pg_stat_database_delta`,
`pg_stat_user_tables_delta`, `pg_stat_user_indexes_delta`,
`pg_statio_user_tables_delta`, and `pg_statio_user_indexes_delta`.
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

Each call reads two flat snapshots in one SQL query, waits between them, clears
the statistics cache for each read, and matches rows with FULL OUTER JOIN. All
functions return `sampled_at_start`, `sampled_at_end`, `elapsed_seconds` and
`status`. Cumulative differences use `_delta`; state estimates and last-event
timestamps are separate values. Database scope includes its shared-object row;
the four relation samplers follow their source user views in the current database.

| Status | Meaning | Availability |
| --- | --- | --- |
| `ok` | No discontinuity detected; source NULLs remain NULL | All functions |
| `reset` | A reset marker changed; table/index statistics also use this for counter decreases | All functions |
| `counter_decreased` | A block counter decreased without a changed reset marker | Both I/O functions |
| `missing` | An identity exists in only one sampled row set | All functions |

**Every cumulative delta is NULL for a non-ok row.** Connection counts, table
state estimates and last-event times can remain available where a snapshot exists.
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

The database function uses one SQL query with two materialized, **flat**
`pg_stat_database` snapshots, matched by `FULL OUTER JOIN`. This is the baseline
for further database-query optimization. It avoids composite-record field access,
`UNION ALL` and window functions. The table and index samplers also use full joins,
as described below.
All five samplers now use flat snapshots and FULL OUTER JOIN, with explicit
pre-scan cache-clear barriers retained for the aggregate table views.

`pg_stat_clear_snapshot()` runs for each read through the singleton clear CTE.
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

For `reset` or `missing`, **all cumulative counter deltas are NULL**. Connection
measurements remain available wherever the snapshot exists. `stats_reset` is
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

## Integration tests

The suite currently contains **54 integration test methods**; some exercise
multiple cache modes or edge cases. The complete suite passed on PostgreSQL 17.11
with the current five-function implementation. The optional private-cluster cold
block-read check also passed.

Tests require Python 3, `psql`, and a running PostgreSQL 17 server. Use a
**disposable test database and cluster**: tests reset database statistics, create
and drop databases, tables and a role, and temporarily move the extension between schemas.
Tests require the current 0.1.0 files and all five functions loaded in the
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
tests also distinguish indexes of the same table. Installation tests verify that
only 0.1.0 is available, both default and explicit version selection install all
five extension members, and extension removal cleans up those functions. These
checks include another schema and empty user-table/index sets in a separate
disposable database. Sampling tests wait until the measurement connection enters
`pg_sleep` before generating activity.

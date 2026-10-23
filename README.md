# pg_stat_delta

On-demand PostgreSQL statistics deltas, without snapshot tables or background
workers. Version 0.1.0 provides `pg_stat_database_delta(seconds numeric DEFAULT 5)`.
Implemented in PL/pgSQL; currently tested on **PostgreSQL 17.11**.

## Design priority

Correctness is mandatory. Among correct implementations, minimizing CPU, memory,
I/O and other overhead on the monitored server takes priority over convenience
and additional features. Queries should read only necessary statistics and avoid
redundant work and serialization. A single SQL query is preferred when it retains
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

The function runs with the caller's privileges, without privilege escalation.
It can be installed into another schema with `CREATE EXTENSION ... SCHEMA ...`.
Calls require schema USAGE and function EXECUTE (the latter is granted to PUBLIC
by PostgreSQL by default; administrators can revoke it).

## Result

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
* Only the listed common counters are included in this first version. Other
  PostgreSQL versions and per-table, per-index, or statement deltas are unverified.

## Integration tests

Tests require Python 3, `psql`, and a running PostgreSQL 17 server. Use a
**disposable test database and cluster**: tests reset database statistics, create
and drop a database and role, and temporarily move the extension between schemas.
The connection needs administrative privileges. No Python packages are required.

```sh
PGHOST=/path/to/socket PGPORT=5432 PGDATABASE=delta_test PGUSER=test_admin \
  python3 tests/integration.py
```

Set `PSQL` if the client is not on PATH. The suite checks input validation,
concurrent committed and rolled-back transactions in all three statistics cache
modes, repeated calls inside one transaction, reset handling, catalog snapshot visibility during database lifecycle changes,
and a non-superuser call after schema relocation. It waits until the sampling
connection enters `pg_sleep` before generating activity.

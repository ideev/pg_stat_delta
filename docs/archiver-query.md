# Archiver query baseline

pg_stat_archiver_delta is part of version 0.1.0. The PostgreSQL 17.11 source
returns one cluster-wide row from pg_stat_get_archiver(), including when archiving
is disabled. Two native bigint count deltas and four last-event fields are
returned along with the common timing/status fields.

## Query and snapshot state

The first flat materialized snapshot keeps just archived_count, failed_count
and stats_reset. The second keeps all seven source fields. The getter still
provides its record; first-snapshot projection avoids retaining unused event
fields in the materialized snapshot. Both scans use the common zero-OFFSET
clear InitPlan before entering the getter's Function Scan. Timing aggregates
fully consume each snapshot around sleep.

A singleton CROSS JOIN needs no identity match or sort. A regular measured
subquery names status/endpoints without promising a single status calculation.
Each subtraction remains inside CASE WHEN status = 'ok'. There is no JSON,
persistent storage or extra materialized classification set.

The source marker is internal. A changed stats_reset yields reset; either count
decreasing yields counter_decreased. Both invalidate all count deltas together.
Invalid raw bigint values cannot trigger a discarded subtraction overflow.
Matching NULL markers are accepted; no missing status is needed for a singleton.
The reset is pg_stat_reset_shared('archiver'), not a database or WAL marker.

last_archived_wal_end / last_archived_time_end and last_failed_wal_end /
last_failed_time_end are second-snapshot state, not deltas. They are available
on invalid measurements too and may predate the sampling interval, even when
both count deltas are zero. Source NULLs remain NULL. A reset can clear them;
subsequent activity can populate them again without making the deltas valid.

## Meaning and limits

failed_count counts attempts: one WAL file may fail repeatedly. Not every error
that interrupts archiving is included by PostgreSQL in that counter. A successful
count reflects the configured archive mechanism's reported success, not the
sampler verifying the destination or recovery readiness. The last filename is
not a byte counter, LSN calculation or guarantee of the newest available WAL.

The function never enables archiving, changes archive commands, switches WAL,
or reads archive files. Publication is asynchronous. A client forced flush
cannot make the archiver report. A zero delta, including with disabled archiving,
is not evidence of good archive configuration. Stats reset does not remove
already archived files.

## Validation

Six new integration methods cover invalid intervals, zero waits, return types,
archiver reset after priming archived_count in none/cache/snapshot, alternate
plans, unrelated resets, repeated calls, exact bigint precision above 2^53,
each count decreasing, matching NULL markers, reset with increasing counters,
and old/NULL end-event fields on valid/invalid measurements. The shared invalid
arithmetic fixture now includes the thirteenth query. Installation and ordinary
role/schema checks include all thirteen extension members, still only 0.1.0.

The optional tests/check_archiver_workload.py creates a private Unix-socket-only
cluster with one-MB WAL segments, archive_mode=on and a local archive-copy command.
It generates WAL and switches segments only in that private cluster. Success
samples in none/cache/snapshot each observed archived_count_delta=1 and a real
file matching last_archived_wal_end. A command deliberately returning exit code 1
produced failed_count_delta=3 and non-NULL failure fields: retries are counted.
After removing the failure gate, reset followed by success produced status reset,
both deltas NULL and populated end-success fields referencing a real file.
The helper cleans up its cluster/archive and changes no existing server settings.

## Plan and overhead

Use `python3 tests/explain_statistics.py --view archiver` to inspect internal SQL
with zero sleep instead of an outer PL/pgSQL Function Scan. Local measurements
follow; no speedup over an earlier implementation is claimed for a new function.

PostgreSQL 17.11 / Debian 13, one source row, local idle test cluster after the
functional suite, archive_mode=off and NULL event fields. Forty internal-query
EXPLAIN (ANALYZE, VERBOSE, BUFFERS, TIMING OFF) runs followed four warmups, with
zero intentional sleep. Median execution was 0.1565 ms (0.140–0.306 ms); median
planning was 0.2305 ms. These exclude client round trips, the PL/pgSQL wrapper
and the requested wait and are not CPU measurements or a production bound.
Active-archiving event payloads were functionally tested in the private cluster,
not included in this idle overhead measurement.

Both snapshot nodes were Limit nodes with pre-scan clear InitPlans. The plan
had no Sort or WindowAgg. It recorded no shared-buffer hits, reads or temporary
writes, which does not mean no statistics-memory access or CPU work. Snapshot
cardinality remains one regardless of database/table/process count. Recheck
plans and concurrent tests when changing PostgreSQL/query shape; no universal
speedup is claimed.

All 108 integration methods passed on PostgreSQL 17.11 in 189.386 seconds,
including thirteen-function installation and ordinary-role/schema checks. The
private archiver-workload helper passed separately.

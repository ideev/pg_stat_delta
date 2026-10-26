# Table sampler: evaluating the proposed full join

The implemented pg_stat_user_tables_delta adopts the proposed compact result and
flat snapshots matched by FULL OUTER JOIN. It remains in extension version 0.1.0.
Unlike the raw proposal, it retains reset validation and explicit cache ordering.

## Correctness findings

Five relevant existing integration checks were run against a separately named
copy of the original proposal. DML/cache modes, index scans and one table-reset
case passed. Two checks failed:

- A table reset followed by enough inserts to exceed its old counts returned ok.
- A database reset could return ok when scan counters did not decrease.

The proposal examines only seq_scan and idx_scan for status. It can label a row
ok even when n_tup_ins decreased, and its per-counter checks can return plausible
but invalid deltas for other counters after a reset. An insert-only table can
have zero sequential scans and NULL index scans, so neither scan condition is a
reliable reset indicator. A monotonic increase does not exclude reset/catch-up.

The corrected function reads pg_stat_get_db_stat_reset_time once per snapshot.
PostgreSQL 17 table/function resets update this database-wide timestamp. A change
invalidates all returned cumulative deltas, even if values caught up. It also
checks all nine cumulative counters for a decrease. The status name reset is
retained from the proposal for either discontinuity, without claiming its cause.
The database marker cannot identify the affected relation, so invalidation is
conservative across all tables in that sample.

Missing rows yield missing, with NULL cumulative deltas. State values and last
maintenance times are taken only from the second snapshot; they remain available
when there is a second row, even if cumulative deltas are invalid.

## Query shape and ordering

The first snapshot reads only identities and nine counters. The second reads
those fields plus the eight returned end-state fields. Maintenance counters and
scan timestamps omitted from the public result are not collected explicitly.
Native scalar fields avoid composite-record expansion; there is no window node.
The final schema/name ORDER BY remains.

pg_stat_user_tables contains index aggregation. EXPLAIN VERBOSE for the proposed
query on PostgreSQL 17.11 showed statistics getters both in the snapshot's root
Nested Loop projection and in a child Aggregate. This differs from the verified
flat pg_stat_database query, whose getters were only above the clear join. The
observed default table plan did put the clear CTE first, but CROSS JOIN text order
is not a general guarantee that source aggregation will follow it.

Consequently each snapshot retains a zero OFFSET whose InitPlan consumes the
appropriate clear CTE before entering the source view. The second clear depends
on sleep; timing aggregates consume whole snapshots and still return one timing
row when no user tables exist. The OFFSET explanation is next to the SQL.

A flat measured subquery computes status and raw differences once per row.
OFFSET 0 prevents inlining that would duplicate the nine-counter validity test
for every output delta; it does not create another materialized snapshot. The
outer projection returns cumulative deltas only when status is ok.

## Verified checks

The corrected function passed the existing table tests after adapting them to the
requested compact API: DML in none/cache/snapshot modes, index scans, ANALYZE state,
table/database resets, reset with counter catch-up, dropped tables, repeated calls,
invalid input and catalog snapshot behavior. Fresh installation and a non-superuser
call after schema relocation also passed.

Additional checks cover:

- Cached statistics plus concurrent writes with hash joins disabled and collapse
  limits set to one, and separately with merge/nested-loop/materialization
  preferences disabled. JIT is disabled for these deliberately penalized paths.
- The actual SQL run against controlled snapshots: missing first/second rows,
  NULL index counters, a write-counter decrease despite rising scan counts,
  and falling state estimates with unchanged cumulative counters. All nine deltas
  must be NULL for invalid rows; state decreases alone must remain valid.

## Local comparison

PostgreSQL 17.11, Debian 13, default 4 MB work_mem. A disposable database contained
100 and then 1,000 empty user tables, each with a primary-key index and a text
column/TOAST relation. Compared the previous query, the original proposal, and
the corrected implementation on exactly the same catalog. Sleep was zero. Each
variant had two warmups and seven measured EXPLAIN (ANALYZE, BUFFERS, TIMING OFF,
FORMAT JSON) runs; execution order rotated among the three variants.

| Tables | Query | Median execution | Range | Median planning | Estimated total cost |
| --- | --- | --- | --- | --- | --- |
| 100 | Previous | 2.640 ms | 2.277–3.182 ms | 2.193 ms | 132.58 |
| 100 | Proposed | 1.720 ms | 1.548–2.876 ms | 1.743 ms | 131.71 |
| 100 | Corrected | 1.946 ms | 1.697–2.134 ms | 2.062 ms | 127.92 |
| 1,000 | Previous | 17.773 ms | 16.071–32.416 ms | 2.642 ms | 643.20 |
| 1,000 | Proposed | 13.629 ms | 11.899–14.790 ms | 1.797 ms | 722.66 |
| 1,000 | Corrected | 13.504 ms | 12.150–15.740 ms | 2.378 ms | 684.04 |

At 1,000 tables, the corrected median was about 24% lower than the preceding
implementation. Its result is narrower (24 columns instead of 40), so this is a
comparison of complete implementations, not an isolated measurement of join
algorithm changes. The corrected/proposed ranges overlap; their tiny median
difference is not evidence that correctness checks themselves accelerate queries.
The uncorrected proposal is not suitable despite its lower times in some runs.

The previous plan had a WindowAgg; neither full-join plan did. All had one in-memory
sort in this catalog. At 1,000 tables, sort space fell from 705 kB to 314 kB. Final-run
shared hits were 349/345/346 respectively; there were no shared reads or temporary
writes. These instrumented execution times exclude intentional sleep, client
transfer and function-wrapper overhead. They are not CPU measurements or
production guarantees. Larger catalogs, cache state and load can alter results.

Inspect the new internal query with:

```sh
python3 tests/explain_statistics.py --view tables
```

The helper also accepts --source to inspect a saved per-function SQL revision.

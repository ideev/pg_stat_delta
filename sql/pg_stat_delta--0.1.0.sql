-- On-demand database statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_database_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    datid oid,
    datname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    stats_reset_start timestamptz,
    stats_reset_end timestamptz,
    num_backends_start integer,
    num_backends_end integer,
    num_backends_delta integer,
    xact_commit_delta bigint,
    xact_rollback_delta bigint,
    blks_read_delta bigint,
    blks_hit_delta bigint,
    tup_returned_delta bigint,
    tup_fetched_delta bigint,
    tup_inserted_delta bigint,
    tup_updated_delta bigint,
    tup_deleted_delta bigint,
    temp_files_delta bigint,
    temp_bytes_delta bigint,
    deadlocks_delta bigint,
    blk_read_time_delta double precision,
    blk_write_time_delta double precision
)
LANGUAGE plpgsql VOLATILE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF i_delta_seconds IS NULL OR i_delta_seconds < 0
       OR i_delta_seconds::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION 'interval must be a finite nonnegative number of seconds'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH initial_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot()
    ), first_snapshot AS MATERIALIZED (
        SELECT d AS r FROM pg_stat_database AS d
        -- OFFSET is evaluated before scanning the view and forces cache clearing.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- The aggregate consumes the entire first snapshot before timing/sleep.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        -- The materialized aggregate yields a row only after the first scan ends.
        SELECT pg_sleep(i_delta_seconds::double precision)
        FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited performs the sleep before clearing the cached statistics.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT d AS r FROM pg_stat_database AS d
        -- Evaluate the sleep/clear dependency before scanning statistics again.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), snapshots AS (
        SELECT 1 AS snap, r FROM first_snapshot
        UNION ALL
        SELECT 2 AS snap, r FROM second_snapshot
    ), windowed AS (
        SELECT snap, r,
               lag(r) OVER (PARTITION BY (r).datid ORDER BY snap) AS previous_row
        FROM snapshots
    ), paired AS (
        SELECT previous_row AS before_row, r AS after_row,
               CASE WHEN (previous_row).stats_reset IS DISTINCT FROM (r).stats_reset
                        THEN 'reset'
                    ELSE 'ok' END AS sample_status
        FROM windowed
        WHERE snap = 2
    )
    SELECT coalesce((after_row).datid, (before_row).datid) AS datid,
           coalesce((after_row).datname, (before_row).datname) AS datname,
           t1.started_at AS sampled_at_start,
           t2.finished_at AS sampled_at_end,
           extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
           sample_status AS status,
           (before_row).stats_reset AS stats_reset_start,
           (after_row).stats_reset AS stats_reset_end,
           (before_row).numbackends AS num_backends_start,
           (after_row).numbackends AS num_backends_end,
           (after_row).numbackends - (before_row).numbackends AS num_backends_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).xact_commit - (before_row).xact_commit END AS xact_commit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).xact_rollback - (before_row).xact_rollback END AS xact_rollback_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).blks_read - (before_row).blks_read END AS blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).blks_hit - (before_row).blks_hit END AS blks_hit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_returned - (before_row).tup_returned END AS tup_returned_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_fetched - (before_row).tup_fetched END AS tup_fetched_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_inserted - (before_row).tup_inserted END AS tup_inserted_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_updated - (before_row).tup_updated END AS tup_updated_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_deleted - (before_row).tup_deleted END AS tup_deleted_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).temp_files - (before_row).temp_files END AS temp_files_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).temp_bytes - (before_row).temp_bytes END AS temp_bytes_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).deadlocks - (before_row).deadlocks END AS deadlocks_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).blk_read_time - (before_row).blk_read_time END AS blk_read_time_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).blk_write_time - (before_row).blk_write_time END AS blk_write_time_delta
    FROM paired CROSS JOIN first_time AS t1 CROSS JOIN second_time AS t2
    ORDER BY coalesce((after_row).datid, (before_row).datid);
END;
$$;

COMMENT ON FUNCTION pg_stat_database_delta(numeric) IS
'Measure published database counters across an interval without persistent snapshots; invalid deltas are NULL.';
-- No persistent snapshots or JSON conversions.
CREATE FUNCTION pg_stat_user_tables_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    relid oid,
    schemaname name,
    relname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    database_stats_reset_start timestamptz,
    database_stats_reset_end timestamptz,
    seq_scan_delta bigint,
    seq_tup_read_delta bigint,
    idx_scan_delta bigint,
    idx_tup_fetch_delta bigint,
    n_tup_ins_delta bigint,
    n_tup_upd_delta bigint,
    n_tup_del_delta bigint,
    n_tup_hot_upd_delta bigint,
    n_tup_newpage_upd_delta bigint,
    vacuum_count_delta bigint,
    autovacuum_count_delta bigint,
    analyze_count_delta bigint,
    autoanalyze_count_delta bigint,
    n_live_tup_start bigint,
    n_live_tup_end bigint,
    n_live_tup_delta bigint,
    n_dead_tup_start bigint,
    n_dead_tup_end bigint,
    n_dead_tup_delta bigint,
    n_mod_since_analyze_start bigint,
    n_mod_since_analyze_end bigint,
    n_mod_since_analyze_delta bigint,
    n_ins_since_vacuum_start bigint,
    n_ins_since_vacuum_end bigint,
    n_ins_since_vacuum_delta bigint,
    last_seq_scan_end timestamptz,
    last_idx_scan_end timestamptz,
    last_vacuum_end timestamptz,
    last_autovacuum_end timestamptz,
    last_analyze_end timestamptz,
    last_autoanalyze_end timestamptz
)
LANGUAGE plpgsql VOLATILE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF i_delta_seconds IS NULL OR i_delta_seconds < 0
       OR i_delta_seconds::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION 'interval must be a finite nonnegative number of seconds'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH database_id AS MATERIALIZED (
        SELECT oid AS id FROM pg_database WHERE datname = current_database()
    ), initial_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot()
    ), first_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_stat_user_tables AS t
        -- The singleton clear CTE makes this OFFSET zero, after cache clearing.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume every table before sleeping, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        -- The materialized aggregate yields a row only after the first scan ends.
        SELECT pg_sleep(i_delta_seconds::double precision)
        FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited performs the sleep before clearing the cached statistics.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_stat_user_tables AS t
        -- Evaluate the sleep/clear dependency before scanning statistics again.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), snapshots AS (
        SELECT 1 AS snap, r FROM first_snapshot
        UNION ALL
        SELECT 2 AS snap, r FROM second_snapshot
    ), windowed AS (
        SELECT snap, r,
               lag(r) OVER (PARTITION BY (r).relid ORDER BY snap) AS previous_row
        FROM snapshots
    ), paired AS (
        SELECT previous_row AS before_row, r AS after_row
        FROM windowed WHERE snap = 2
    ), measured AS (
        SELECT p.*, a.started_at, b.finished_at,
               a.reset_at AS reset_start, b.reset_at AS reset_end,
               CASE WHEN a.reset_at IS DISTINCT FROM b.reset_at THEN 'reset'
                    WHEN (after_row).seq_scan < (before_row).seq_scan
                      OR (after_row).seq_tup_read < (before_row).seq_tup_read
                      OR (after_row).idx_scan < (before_row).idx_scan
                      OR (after_row).idx_tup_fetch < (before_row).idx_tup_fetch
                      OR (after_row).n_tup_ins < (before_row).n_tup_ins
                      OR (after_row).n_tup_upd < (before_row).n_tup_upd
                      OR (after_row).n_tup_del < (before_row).n_tup_del
                      OR (after_row).n_tup_hot_upd < (before_row).n_tup_hot_upd
                      OR (after_row).n_tup_newpage_upd < (before_row).n_tup_newpage_upd
                      OR (after_row).vacuum_count < (before_row).vacuum_count
                      OR (after_row).autovacuum_count < (before_row).autovacuum_count
                      OR (after_row).analyze_count < (before_row).analyze_count
                      OR (after_row).autoanalyze_count < (before_row).autoanalyze_count THEN 'counter_decreased'
                    ELSE 'ok' END AS sample_status
        FROM paired AS p CROSS JOIN first_time AS a CROSS JOIN second_time AS b
        -- Compute reset classification once per row, not once per output counter.
        OFFSET 0
    )
    SELECT (after_row).relid AS relid,
           (after_row).schemaname AS schemaname,
           (after_row).relname AS relname,
           started_at AS sampled_at_start,
           finished_at AS sampled_at_end,
           extract(epoch FROM finished_at - started_at)::double precision AS elapsed_seconds,
           sample_status AS status,
           reset_start AS database_stats_reset_start,
           reset_end AS database_stats_reset_end,
           CASE WHEN sample_status = 'ok' THEN (after_row).seq_scan - (before_row).seq_scan END AS seq_scan_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).seq_tup_read - (before_row).seq_tup_read END AS seq_tup_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_scan - (before_row).idx_scan END AS idx_scan_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_tup_fetch - (before_row).idx_tup_fetch END AS idx_tup_fetch_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).n_tup_ins - (before_row).n_tup_ins END AS n_tup_ins_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).n_tup_upd - (before_row).n_tup_upd END AS n_tup_upd_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).n_tup_del - (before_row).n_tup_del END AS n_tup_del_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).n_tup_hot_upd - (before_row).n_tup_hot_upd END AS n_tup_hot_upd_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).n_tup_newpage_upd - (before_row).n_tup_newpage_upd END AS n_tup_newpage_upd_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).vacuum_count - (before_row).vacuum_count END AS vacuum_count_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).autovacuum_count - (before_row).autovacuum_count END AS autovacuum_count_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).analyze_count - (before_row).analyze_count END AS analyze_count_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).autoanalyze_count - (before_row).autoanalyze_count END AS autoanalyze_count_delta,
           (before_row).n_live_tup AS n_live_tup_start,
           (after_row).n_live_tup AS n_live_tup_end,
           (after_row).n_live_tup - (before_row).n_live_tup AS n_live_tup_delta,
           (before_row).n_dead_tup AS n_dead_tup_start,
           (after_row).n_dead_tup AS n_dead_tup_end,
           (after_row).n_dead_tup - (before_row).n_dead_tup AS n_dead_tup_delta,
           (before_row).n_mod_since_analyze AS n_mod_since_analyze_start,
           (after_row).n_mod_since_analyze AS n_mod_since_analyze_end,
           (after_row).n_mod_since_analyze - (before_row).n_mod_since_analyze AS n_mod_since_analyze_delta,
           (before_row).n_ins_since_vacuum AS n_ins_since_vacuum_start,
           (after_row).n_ins_since_vacuum AS n_ins_since_vacuum_end,
           (after_row).n_ins_since_vacuum - (before_row).n_ins_since_vacuum AS n_ins_since_vacuum_delta,
           (after_row).last_seq_scan AS last_seq_scan_end,
           (after_row).last_idx_scan AS last_idx_scan_end,
           (after_row).last_vacuum AS last_vacuum_end,
           (after_row).last_autovacuum AS last_autovacuum_end,
           (after_row).last_analyze AS last_analyze_end,
           (after_row).last_autoanalyze AS last_autoanalyze_end
    FROM measured;
END;
$$;

COMMENT ON FUNCTION pg_stat_user_tables_delta(numeric) IS
'Published user-table deltas; database reset timestamps (including table resets in PG17) and decreasing counters invalidate deltas.';
-- Read index activity without persistent snapshots.
CREATE FUNCTION pg_stat_user_indexes_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    relid oid,
    indexrelid oid,
    schemaname name,
    relname name,
    indexrelname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    database_stats_reset_start timestamptz,
    database_stats_reset_end timestamptz,
    idx_scan_delta bigint,
    idx_tup_read_delta bigint,
    idx_tup_fetch_delta bigint,
    last_idx_scan_end timestamptz
)
LANGUAGE plpgsql VOLATILE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF i_delta_seconds IS NULL OR i_delta_seconds < 0
       OR i_delta_seconds::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION 'interval must be a finite nonnegative number of seconds'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH database_id AS MATERIALIZED (
        SELECT oid AS id FROM pg_database WHERE datname = current_database()
    ), initial_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot()
    ), first_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_stat_user_indexes AS t
        -- The singleton clear CTE makes this OFFSET zero, after cache clearing.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume every index before sleeping, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        -- The materialized aggregate yields a row only after the first scan ends.
        SELECT pg_sleep(i_delta_seconds::double precision)
        FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited performs the sleep before clearing the cached statistics.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_stat_user_indexes AS t
        -- Evaluate the sleep/clear dependency before scanning statistics again.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), snapshots AS (
        SELECT 1 AS snap, r FROM first_snapshot
        UNION ALL
        SELECT 2 AS snap, r FROM second_snapshot
    ), windowed AS (
        SELECT snap, r,
               lag(r) OVER (PARTITION BY (r).indexrelid ORDER BY snap) AS previous_row
        FROM snapshots
    ), paired AS (
        SELECT previous_row AS before_row, r AS after_row
        FROM windowed WHERE snap = 2
    ), measured AS (
        SELECT p.*, a.started_at, b.finished_at,
               a.reset_at AS reset_start, b.reset_at AS reset_end,
               CASE WHEN a.reset_at IS DISTINCT FROM b.reset_at THEN 'reset'
                    WHEN (after_row).idx_scan < (before_row).idx_scan
                      OR (after_row).idx_tup_read < (before_row).idx_tup_read
                      OR (after_row).idx_tup_fetch < (before_row).idx_tup_fetch THEN 'counter_decreased'
                    ELSE 'ok' END AS sample_status
        FROM paired AS p CROSS JOIN first_time AS a CROSS JOIN second_time AS b
        -- Compute reset classification once per row, not once per output counter.
        OFFSET 0
    )
    SELECT (after_row).relid AS relid,
           (after_row).indexrelid AS indexrelid,
           (after_row).schemaname AS schemaname,
           (after_row).relname AS relname,
           (after_row).indexrelname AS indexrelname,
           started_at AS sampled_at_start,
           finished_at AS sampled_at_end,
           extract(epoch FROM finished_at - started_at)::double precision AS elapsed_seconds,
           sample_status AS status,
           reset_start AS database_stats_reset_start,
           reset_end AS database_stats_reset_end,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_scan - (before_row).idx_scan END AS idx_scan_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_tup_read - (before_row).idx_tup_read END AS idx_tup_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_tup_fetch - (before_row).idx_tup_fetch END AS idx_tup_fetch_delta,
           (after_row).last_idx_scan AS last_idx_scan_end
    FROM measured;
END;
$$;

COMMENT ON FUNCTION pg_stat_user_indexes_delta(numeric) IS
'Published index counter deltas; database reset timestamps and decreasing counters invalidate deltas. Index-only and bitmap scans have distinct tuple-counter semantics.';
-- Samples user tables, including their index and TOAST block counters.
CREATE FUNCTION pg_statio_user_tables_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    relid oid,
    schemaname name,
    relname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    database_stats_reset_start timestamptz,
    database_stats_reset_end timestamptz,
    heap_blks_read_delta bigint,
    heap_blks_hit_delta bigint,
    idx_blks_read_delta bigint,
    idx_blks_hit_delta bigint,
    toast_blks_read_delta bigint,
    toast_blks_hit_delta bigint,
    tidx_blks_read_delta bigint,
    tidx_blks_hit_delta bigint
)
LANGUAGE plpgsql VOLATILE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF i_delta_seconds IS NULL OR i_delta_seconds < 0
       OR i_delta_seconds::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION 'interval must be a finite nonnegative number of seconds'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH database_id AS MATERIALIZED (
        SELECT oid AS id FROM pg_database WHERE datname = current_database()
    ), initial_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot()
    ), first_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_statio_user_tables AS t
        -- The singleton clear CTE makes this OFFSET zero, after cache clearing.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume every relation before sleeping, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        -- The materialized aggregate yields a row only after the first scan ends.
        SELECT pg_sleep(i_delta_seconds::double precision)
        FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited performs the sleep before clearing the cached statistics.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_statio_user_tables AS t
        -- Evaluate the sleep/clear dependency before scanning statistics again.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), snapshots AS (
        SELECT 1 AS snap, r FROM first_snapshot
        UNION ALL
        SELECT 2 AS snap, r FROM second_snapshot
    ), windowed AS (
        SELECT snap, r,
               lag(r) OVER (PARTITION BY (r).relid ORDER BY snap) AS previous_row
        FROM snapshots
    ), paired AS (
        SELECT previous_row AS before_row, r AS after_row
        FROM windowed WHERE snap = 2
    ), measured AS (
        SELECT p.*, a.started_at, b.finished_at,
               a.reset_at AS reset_start, b.reset_at AS reset_end,
               CASE WHEN a.reset_at IS DISTINCT FROM b.reset_at THEN 'reset'
                    WHEN (after_row).heap_blks_read < (before_row).heap_blks_read
                      OR (after_row).heap_blks_hit < (before_row).heap_blks_hit
                      OR (after_row).idx_blks_read < (before_row).idx_blks_read
                      OR (after_row).idx_blks_hit < (before_row).idx_blks_hit
                      OR (after_row).toast_blks_read < (before_row).toast_blks_read
                      OR (after_row).toast_blks_hit < (before_row).toast_blks_hit
                      OR (after_row).tidx_blks_read < (before_row).tidx_blks_read
                      OR (after_row).tidx_blks_hit < (before_row).tidx_blks_hit THEN 'counter_decreased'
                    ELSE 'ok' END AS sample_status
        FROM paired AS p CROSS JOIN first_time AS a CROSS JOIN second_time AS b
        -- Compute reset classification once per row, not once per output counter.
        OFFSET 0
    )
    SELECT (after_row).relid AS relid,
           (after_row).schemaname AS schemaname,
           (after_row).relname AS relname,
           started_at AS sampled_at_start,
           finished_at AS sampled_at_end,
           extract(epoch FROM finished_at - started_at)::double precision AS elapsed_seconds,
           sample_status AS status,
           reset_start AS database_stats_reset_start,
           reset_end AS database_stats_reset_end,
           CASE WHEN sample_status = 'ok' THEN (after_row).heap_blks_read - (before_row).heap_blks_read END AS heap_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).heap_blks_hit - (before_row).heap_blks_hit END AS heap_blks_hit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_blks_read - (before_row).idx_blks_read END AS idx_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_blks_hit - (before_row).idx_blks_hit END AS idx_blks_hit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).toast_blks_read - (before_row).toast_blks_read END AS toast_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).toast_blks_hit - (before_row).toast_blks_hit END AS toast_blks_hit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tidx_blks_read - (before_row).tidx_blks_read END AS tidx_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tidx_blks_hit - (before_row).tidx_blks_hit END AS tidx_blks_hit_delta
    FROM measured;
END;
$$;

COMMENT ON FUNCTION pg_statio_user_tables_delta(numeric) IS
'Published user-table block-read and buffer-cache-hit deltas, including their indexes and TOAST. Not physical device I/O; resets and decreasing counters invalidate deltas.';
-- Samples block counters for each user-table index.
CREATE FUNCTION pg_statio_user_indexes_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    relid oid,
    indexrelid oid,
    schemaname name,
    relname name,
    indexrelname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    database_stats_reset_start timestamptz,
    database_stats_reset_end timestamptz,
    idx_blks_read_delta bigint,
    idx_blks_hit_delta bigint
)
LANGUAGE plpgsql VOLATILE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF i_delta_seconds IS NULL OR i_delta_seconds < 0
       OR i_delta_seconds::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION 'interval must be a finite nonnegative number of seconds'
            USING ERRCODE = '22023';
    END IF;

    RETURN QUERY
    WITH database_id AS MATERIALIZED (
        SELECT oid AS id FROM pg_database WHERE datname = current_database()
    ), initial_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot()
    ), first_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_statio_user_indexes AS t
        -- The singleton clear CTE makes this OFFSET zero, after cache clearing.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume every index before sleeping, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        -- The materialized aggregate yields a row only after the first scan ends.
        SELECT pg_sleep(i_delta_seconds::double precision)
        FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited performs the sleep before clearing the cached statistics.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_statio_user_indexes AS t
        -- Evaluate the sleep/clear dependency before scanning statistics again.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), snapshots AS (
        SELECT 1 AS snap, r FROM first_snapshot
        UNION ALL
        SELECT 2 AS snap, r FROM second_snapshot
    ), windowed AS (
        SELECT snap, r,
               lag(r) OVER (PARTITION BY (r).indexrelid ORDER BY snap) AS previous_row
        FROM snapshots
    ), paired AS (
        SELECT previous_row AS before_row, r AS after_row
        FROM windowed WHERE snap = 2
    ), measured AS (
        SELECT p.*, a.started_at, b.finished_at,
               a.reset_at AS reset_start, b.reset_at AS reset_end,
               CASE WHEN a.reset_at IS DISTINCT FROM b.reset_at THEN 'reset'
                    WHEN (after_row).idx_blks_read < (before_row).idx_blks_read
                      OR (after_row).idx_blks_hit < (before_row).idx_blks_hit THEN 'counter_decreased'
                    ELSE 'ok' END AS sample_status
        FROM paired AS p CROSS JOIN first_time AS a CROSS JOIN second_time AS b
        -- Compute reset classification once per row, not once per output counter.
        OFFSET 0
    )
    SELECT (after_row).relid AS relid,
           (after_row).indexrelid AS indexrelid,
           (after_row).schemaname AS schemaname,
           (after_row).relname AS relname,
           (after_row).indexrelname AS indexrelname,
           started_at AS sampled_at_start,
           finished_at AS sampled_at_end,
           extract(epoch FROM finished_at - started_at)::double precision AS elapsed_seconds,
           sample_status AS status,
           reset_start AS database_stats_reset_start,
           reset_end AS database_stats_reset_end,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_blks_read - (before_row).idx_blks_read END AS idx_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_blks_hit - (before_row).idx_blks_hit END AS idx_blks_hit_delta
    FROM measured;
END;
$$;

COMMENT ON FUNCTION pg_statio_user_indexes_delta(numeric) IS
'Published per-index block-read and buffer-cache-hit deltas for user tables. Not physical device I/O; resets and decreasing counters invalidate deltas.';

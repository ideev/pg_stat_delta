-- On-demand database statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_database_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    datid oid,
    datname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
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
    blk_write_time_delta double precision,
    session_time_delta double precision,
    active_time_delta double precision,
    idle_in_transaction_time_delta double precision,
    sessions_delta bigint
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
        SELECT d.*
        FROM pg_stat_database AS d
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- The aggregate consumes the first snapshot before yielding the timing row.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited executes the sleep before clearing statistics again.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT d.*
        FROM pg_stat_database AS d
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        -- Consume the second snapshot and yield exactly one timing row, even if empty.
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.datid, s1.datid) AS datid,
               coalesce(s2.datname, s1.datname) AS datname,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.datid IS NULL OR s2.datid IS NULL THEN 'missing'
                    WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    ELSE 'ok' END AS status,
               s1.numbackends AS num_backends_start,
               s2.numbackends AS num_backends_end,
               s1.xact_commit AS xact_commit_start, s2.xact_commit AS xact_commit_end,
               s1.xact_rollback AS xact_rollback_start, s2.xact_rollback AS xact_rollback_end,
               s1.blks_read AS blks_read_start, s2.blks_read AS blks_read_end,
               s1.blks_hit AS blks_hit_start, s2.blks_hit AS blks_hit_end,
               s1.tup_returned AS tup_returned_start, s2.tup_returned AS tup_returned_end,
               s1.tup_fetched AS tup_fetched_start, s2.tup_fetched AS tup_fetched_end,
               s1.tup_inserted AS tup_inserted_start, s2.tup_inserted AS tup_inserted_end,
               s1.tup_updated AS tup_updated_start, s2.tup_updated AS tup_updated_end,
               s1.tup_deleted AS tup_deleted_start, s2.tup_deleted AS tup_deleted_end,
               s1.temp_files AS temp_files_start, s2.temp_files AS temp_files_end,
               s1.temp_bytes AS temp_bytes_start, s2.temp_bytes AS temp_bytes_end,
               s1.deadlocks AS deadlocks_start, s2.deadlocks AS deadlocks_end,
               s1.blk_read_time AS blk_read_time_start, s2.blk_read_time AS blk_read_time_end,
               s1.blk_write_time AS blk_write_time_start, s2.blk_write_time AS blk_write_time_end,
               s1.session_time AS session_time_start, s2.session_time AS session_time_end,
               s1.active_time AS active_time_start, s2.active_time AS active_time_end,
               s1.idle_in_transaction_time AS idle_in_transaction_time_start, s2.idle_in_transaction_time AS idle_in_transaction_time_end,
               s1.sessions AS sessions_start, s2.sessions AS sessions_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.datid = s2.datid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.datid, m.datname, m.sampled_at_start, m.sampled_at_end,
           m.elapsed_seconds, m.status, m.num_backends_start, m.num_backends_end,
           CASE WHEN m.status = 'ok' THEN m.num_backends_end - m.num_backends_start END AS num_backends_delta,
           CASE WHEN m.status = 'ok' THEN m.xact_commit_end - m.xact_commit_start END AS xact_commit_delta,
           CASE WHEN m.status = 'ok' THEN m.xact_rollback_end - m.xact_rollback_start END AS xact_rollback_delta,
           CASE WHEN m.status = 'ok' THEN m.blks_read_end - m.blks_read_start END AS blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.blks_hit_end - m.blks_hit_start END AS blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_returned_end - m.tup_returned_start END AS tup_returned_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_fetched_end - m.tup_fetched_start END AS tup_fetched_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_inserted_end - m.tup_inserted_start END AS tup_inserted_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_updated_end - m.tup_updated_start END AS tup_updated_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_deleted_end - m.tup_deleted_start END AS tup_deleted_delta,
           CASE WHEN m.status = 'ok' THEN m.temp_files_end - m.temp_files_start END AS temp_files_delta,
           CASE WHEN m.status = 'ok' THEN m.temp_bytes_end - m.temp_bytes_start END AS temp_bytes_delta,
           CASE WHEN m.status = 'ok' THEN m.deadlocks_end - m.deadlocks_start END AS deadlocks_delta,
           CASE WHEN m.status = 'ok' THEN m.blk_read_time_end - m.blk_read_time_start END AS blk_read_time_delta,
           CASE WHEN m.status = 'ok' THEN m.blk_write_time_end - m.blk_write_time_start END AS blk_write_time_delta,
           CASE WHEN m.status = 'ok' THEN m.session_time_end - m.session_time_start END AS session_time_delta,
           CASE WHEN m.status = 'ok' THEN m.active_time_end - m.active_time_start END AS active_time_delta,
           CASE WHEN m.status = 'ok' THEN m.idle_in_transaction_time_end - m.idle_in_transaction_time_start END AS idle_in_transaction_time_delta,
           CASE WHEN m.status = 'ok' THEN m.sessions_end - m.sessions_start END AS sessions_delta
    FROM measured AS m
    ORDER BY m.datid;
END;
$$;

COMMENT ON FUNCTION pg_stat_database_delta(numeric) IS
'Measure published database counters using two native snapshots and a full join; missing or reset snapshots have NULL counter deltas.';
-- Flat snapshots and a full join; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_user_tables_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    relid oid,
    schemaname name,
    relname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    seq_scan_delta bigint,
    seq_tup_read_delta bigint,
    idx_scan_delta bigint,
    idx_tup_fetch_delta bigint,
    n_tup_ins_delta bigint,
    n_tup_upd_delta bigint,
    n_tup_del_delta bigint,
    n_tup_hot_upd_delta bigint,
    n_tup_newpage_upd_delta bigint,
    n_live_tup bigint,
    n_dead_tup bigint,
    n_mod_since_analyze bigint,
    n_ins_since_vacuum bigint,
    last_vacuum timestamptz,
    last_autovacuum timestamptz,
    last_analyze timestamptz,
    last_autoanalyze timestamptz
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
        SELECT t.relid, t.schemaname, t.relname,
               t.seq_scan, t.seq_tup_read, t.idx_scan, t.idx_tup_fetch,
               t.n_tup_ins, t.n_tup_upd, t.n_tup_del,
               t.n_tup_hot_upd, t.n_tup_newpage_upd
        FROM pg_stat_user_tables AS t
        -- The source view aggregates indexes and can evaluate statistics below a
        -- CROSS JOIN. Its zero OFFSET is initialized before that scan starts.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the whole snapshot before waiting, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        -- The sleep is consumed before statistics are cleared for the second read.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT t.relid, t.schemaname, t.relname,
               t.seq_scan, t.seq_tup_read, t.idx_scan, t.idx_tup_fetch,
               t.n_tup_ins, t.n_tup_upd, t.n_tup_del,
               t.n_tup_hot_upd, t.n_tup_newpage_upd,
               t.n_live_tup, t.n_dead_tup, t.n_mod_since_analyze, t.n_ins_since_vacuum,
               t.last_vacuum, t.last_autovacuum, t.last_analyze, t.last_autoanalyze
        FROM pg_stat_user_tables AS t
        -- Complete sleep and cache clearing before entering the aggregate view.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.relid, s1.relid) AS relid,
               coalesce(s2.schemaname, s1.schemaname) AS schemaname,
               coalesce(s2.relname, s1.relname) AS relname,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.relid IS NULL OR s2.relid IS NULL THEN 'missing'
                    -- PG17 table resets update the database marker, even when
                    -- activity has already brought counters back above baseline.
                    WHEN t1.reset_at IS DISTINCT FROM t2.reset_at THEN 'reset'
                    WHEN s2.seq_scan < s1.seq_scan
                      OR s2.seq_tup_read < s1.seq_tup_read
                      OR s2.idx_scan < s1.idx_scan
                      OR s2.idx_tup_fetch < s1.idx_tup_fetch
                      OR s2.n_tup_ins < s1.n_tup_ins
                      OR s2.n_tup_upd < s1.n_tup_upd
                      OR s2.n_tup_del < s1.n_tup_del
                      OR s2.n_tup_hot_upd < s1.n_tup_hot_upd
                      OR s2.n_tup_newpage_upd < s1.n_tup_newpage_upd THEN 'reset'
                    ELSE 'ok' END AS status,
               s1.seq_scan AS seq_scan_start, s2.seq_scan AS seq_scan_end,
               s1.seq_tup_read AS seq_tup_read_start, s2.seq_tup_read AS seq_tup_read_end,
               s1.idx_scan AS idx_scan_start, s2.idx_scan AS idx_scan_end,
               s1.idx_tup_fetch AS idx_tup_fetch_start, s2.idx_tup_fetch AS idx_tup_fetch_end,
               s1.n_tup_ins AS n_tup_ins_start, s2.n_tup_ins AS n_tup_ins_end,
               s1.n_tup_upd AS n_tup_upd_start, s2.n_tup_upd AS n_tup_upd_end,
               s1.n_tup_del AS n_tup_del_start, s2.n_tup_del AS n_tup_del_end,
               s1.n_tup_hot_upd AS n_tup_hot_upd_start, s2.n_tup_hot_upd AS n_tup_hot_upd_end,
               s1.n_tup_newpage_upd AS n_tup_newpage_upd_start, s2.n_tup_newpage_upd AS n_tup_newpage_upd_end,
               s2.n_live_tup AS n_live_tup,
               s2.n_dead_tup AS n_dead_tup,
               s2.n_mod_since_analyze AS n_mod_since_analyze,
               s2.n_ins_since_vacuum AS n_ins_since_vacuum,
               s2.last_vacuum AS last_vacuum,
               s2.last_autovacuum AS last_autovacuum,
               s2.last_analyze AS last_analyze,
               s2.last_autoanalyze AS last_autoanalyze
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.relid = s2.relid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.relid, m.schemaname, m.relname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.seq_scan_end - m.seq_scan_start END AS seq_scan_delta,
           CASE WHEN m.status = 'ok' THEN m.seq_tup_read_end - m.seq_tup_read_start END AS seq_tup_read_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_scan_end - m.idx_scan_start END AS idx_scan_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_tup_fetch_end - m.idx_tup_fetch_start END AS idx_tup_fetch_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_ins_end - m.n_tup_ins_start END AS n_tup_ins_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_upd_end - m.n_tup_upd_start END AS n_tup_upd_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_del_end - m.n_tup_del_start END AS n_tup_del_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_hot_upd_end - m.n_tup_hot_upd_start END AS n_tup_hot_upd_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_newpage_upd_end - m.n_tup_newpage_upd_start END AS n_tup_newpage_upd_delta,
           m.n_live_tup AS n_live_tup,
           m.n_dead_tup AS n_dead_tup,
           m.n_mod_since_analyze AS n_mod_since_analyze,
           m.n_ins_since_vacuum AS n_ins_since_vacuum,
           m.last_vacuum AS last_vacuum,
           m.last_autovacuum AS last_autovacuum,
           m.last_analyze AS last_analyze,
           m.last_autoanalyze AS last_autoanalyze
    FROM measured AS m
    ORDER BY m.schemaname, m.relname;
END;
$$;

COMMENT ON FUNCTION pg_stat_user_tables_delta(numeric) IS
'Published user-table deltas and end-state gauges. Missing rows, reset markers or decreasing counters invalidate all cumulative deltas.';
-- Flat index snapshots and a full join; part of extension version 0.1.0.
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
        SELECT i.relid, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
               i.idx_scan, i.idx_tup_read, i.idx_tup_fetch
        FROM pg_stat_user_indexes AS i
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the whole snapshot before waiting, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        -- The sleep is consumed before statistics are cleared for the second read.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT i.relid, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
               i.idx_scan, i.idx_tup_read, i.idx_tup_fetch, i.last_idx_scan
        FROM pg_stat_user_indexes AS i
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.relid, s1.relid) AS relid,
               coalesce(s2.indexrelid, s1.indexrelid) AS indexrelid,
               coalesce(s2.schemaname, s1.schemaname) AS schemaname,
               coalesce(s2.relname, s1.relname) AS relname,
               coalesce(s2.indexrelname, s1.indexrelname) AS indexrelname,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.indexrelid IS NULL OR s2.indexrelid IS NULL THEN 'missing'
                    -- Index resets update the PG17 database marker; count growth
                    -- alone cannot exclude a reset followed by renewed activity.
                    WHEN t1.reset_at IS DISTINCT FROM t2.reset_at THEN 'reset'
                    WHEN s2.idx_scan < s1.idx_scan
                      OR s2.idx_tup_read < s1.idx_tup_read
                      OR s2.idx_tup_fetch < s1.idx_tup_fetch THEN 'reset'
                    ELSE 'ok' END AS status,
               s1.idx_scan AS idx_scan_start, s2.idx_scan AS idx_scan_end,
               s1.idx_tup_read AS idx_tup_read_start, s2.idx_tup_read AS idx_tup_read_end,
               s1.idx_tup_fetch AS idx_tup_fetch_start, s2.idx_tup_fetch AS idx_tup_fetch_end,
               s2.last_idx_scan AS last_idx_scan_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.indexrelid = s2.indexrelid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.relid, m.indexrelid, m.schemaname, m.relname, m.indexrelname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.idx_scan_end - m.idx_scan_start END AS idx_scan_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_tup_read_end - m.idx_tup_read_start END AS idx_tup_read_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_tup_fetch_end - m.idx_tup_fetch_start END AS idx_tup_fetch_delta,
           m.last_idx_scan_end
    FROM measured AS m
    ORDER BY m.schemaname, m.relname, m.indexrelname;
END;
$$;

COMMENT ON FUNCTION pg_stat_user_indexes_delta(numeric) IS
'Published per-index deltas and final scan time. Missing rows, reset markers or decreasing counters invalidate all three cumulative deltas.';
-- Flat block-I/O snapshots; part of extension version 0.1.0.
CREATE FUNCTION pg_statio_user_tables_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    relid oid,
    schemaname name,
    relname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
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
        SELECT t.* FROM pg_statio_user_tables AS t
        -- This view aggregates indexes; initialize its zero OFFSET and consume
        -- cache clearing before entering the source aggregate.
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
        SELECT t.* FROM pg_statio_user_tables AS t
        -- Complete sleep and clearing before entering the aggregate source view.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.relid, s1.relid) AS relid,
               coalesce(s2.schemaname, s1.schemaname) AS schemaname,
               coalesce(s2.relname, s1.relname) AS relname,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.relid IS NULL OR s2.relid IS NULL THEN 'missing'
                    WHEN t1.reset_at IS DISTINCT FROM t2.reset_at THEN 'reset'
                    WHEN s2.heap_blks_read < s1.heap_blks_read
                      OR s2.heap_blks_hit < s1.heap_blks_hit
                      OR s2.idx_blks_read < s1.idx_blks_read
                      OR s2.idx_blks_hit < s1.idx_blks_hit
                      OR s2.toast_blks_read < s1.toast_blks_read
                      OR s2.toast_blks_hit < s1.toast_blks_hit
                      OR s2.tidx_blks_read < s1.tidx_blks_read
                      OR s2.tidx_blks_hit < s1.tidx_blks_hit THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               s1.heap_blks_read AS heap_blks_read_start, s2.heap_blks_read AS heap_blks_read_end,
               s1.heap_blks_hit AS heap_blks_hit_start, s2.heap_blks_hit AS heap_blks_hit_end,
               s1.idx_blks_read AS idx_blks_read_start, s2.idx_blks_read AS idx_blks_read_end,
               s1.idx_blks_hit AS idx_blks_hit_start, s2.idx_blks_hit AS idx_blks_hit_end,
               s1.toast_blks_read AS toast_blks_read_start, s2.toast_blks_read AS toast_blks_read_end,
               s1.toast_blks_hit AS toast_blks_hit_start, s2.toast_blks_hit AS toast_blks_hit_end,
               s1.tidx_blks_read AS tidx_blks_read_start, s2.tidx_blks_read AS tidx_blks_read_end,
               s1.tidx_blks_hit AS tidx_blks_hit_start, s2.tidx_blks_hit AS tidx_blks_hit_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.relid = s2.relid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.relid, m.schemaname, m.relname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.heap_blks_read_end - m.heap_blks_read_start END AS heap_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.heap_blks_hit_end - m.heap_blks_hit_start END AS heap_blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_blks_read_end - m.idx_blks_read_start END AS idx_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_blks_hit_end - m.idx_blks_hit_start END AS idx_blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.toast_blks_read_end - m.toast_blks_read_start END AS toast_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.toast_blks_hit_end - m.toast_blks_hit_start END AS toast_blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.tidx_blks_read_end - m.tidx_blks_read_start END AS tidx_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.tidx_blks_hit_end - m.tidx_blks_hit_start END AS tidx_blks_hit_delta
    FROM measured AS m
    ORDER BY m.schemaname, m.relname;
END;
$$;

COMMENT ON FUNCTION pg_statio_user_tables_delta(numeric) IS
'Published user-table block I/O deltas. Missing rows, database reset markers or decreasing counters invalidate all eight deltas; reads are not necessarily device I/O.';
-- Flat index snapshots and a full join; part of extension version 0.1.0.
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
        SELECT i.relid, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
               i.idx_blks_read, i.idx_blks_hit
        FROM pg_statio_user_indexes AS i
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the whole snapshot before waiting, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        -- The sleep is consumed before statistics are cleared for the second read.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT i.relid, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
               i.idx_blks_read, i.idx_blks_hit
        FROM pg_statio_user_indexes AS i
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.relid, s1.relid) AS relid,
               coalesce(s2.indexrelid, s1.indexrelid) AS indexrelid,
               coalesce(s2.schemaname, s1.schemaname) AS schemaname,
               coalesce(s2.relname, s1.relname) AS relname,
               coalesce(s2.indexrelname, s1.indexrelname) AS indexrelname,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.indexrelid IS NULL OR s2.indexrelid IS NULL THEN 'missing'
                    -- Index resets update the PG17 database marker; count growth
                    -- alone cannot exclude a reset followed by renewed activity.
                    WHEN t1.reset_at IS DISTINCT FROM t2.reset_at THEN 'reset'
                    WHEN s2.idx_blks_read < s1.idx_blks_read
                      OR s2.idx_blks_hit < s1.idx_blks_hit THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               s1.idx_blks_read AS idx_blks_read_start, s2.idx_blks_read AS idx_blks_read_end,
               s1.idx_blks_hit AS idx_blks_hit_start, s2.idx_blks_hit AS idx_blks_hit_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.indexrelid = s2.indexrelid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.relid, m.indexrelid, m.schemaname, m.relname, m.indexrelname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.idx_blks_read_end - m.idx_blks_read_start END AS idx_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_blks_hit_end - m.idx_blks_hit_start END AS idx_blks_hit_delta
    FROM measured AS m
    ORDER BY m.schemaname, m.relname, m.indexrelname;
END;
$$;

COMMENT ON FUNCTION pg_statio_user_indexes_delta(numeric) IS
'Published per-index block I/O deltas. Missing rows, reset markers or decreased counters invalidate both deltas; reads need not be device I/O.';
-- Cluster-wide WAL statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_wal_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    wal_records_delta bigint,
    wal_fpi_delta bigint,
    wal_bytes_delta numeric,
    wal_buffers_full_delta bigint,
    wal_write_delta bigint,
    wal_sync_delta bigint,
    wal_write_time_delta double precision,
    wal_sync_time_delta double precision
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
        SELECT w.*
        FROM pg_stat_wal AS w
        -- The view calls a record-returning statistics getter in FROM. This zero
        -- OFFSET InitPlan clears cached WAL stats before that Function Scan starts.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the snapshot before starting the wait.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT w.*
        FROM pg_stat_wal AS w
        -- As above, clear after the wait and before invoking pg_stat_get_wal().
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    )
    SELECT t1.started_at AS sampled_at_start,
           t2.finished_at AS sampled_at_end,
           extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
           m.sample_status AS status,
           CASE WHEN m.sample_status = 'ok' THEN m.wal_records_end - m.wal_records_start END AS wal_records_delta,
           CASE WHEN m.sample_status = 'ok' THEN m.wal_fpi_end - m.wal_fpi_start END AS wal_fpi_delta,
           CASE WHEN m.sample_status = 'ok' THEN m.wal_bytes_end - m.wal_bytes_start END AS wal_bytes_delta,
           CASE WHEN m.sample_status = 'ok' THEN m.wal_buffers_full_end - m.wal_buffers_full_start END AS wal_buffers_full_delta,
           CASE WHEN m.sample_status = 'ok' THEN m.wal_write_end - m.wal_write_start END AS wal_write_delta,
           CASE WHEN m.sample_status = 'ok' THEN m.wal_sync_end - m.wal_sync_start END AS wal_sync_delta,
           CASE WHEN m.sample_status = 'ok' THEN m.wal_write_time_end - m.wal_write_time_start END AS wal_write_time_delta,
           CASE WHEN m.sample_status = 'ok' THEN m.wal_sync_time_end - m.wal_sync_time_start END AS wal_sync_time_delta
    FROM (
        SELECT CASE WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    WHEN s2.wal_records < s1.wal_records
                      OR s2.wal_fpi < s1.wal_fpi
                      OR s2.wal_bytes < s1.wal_bytes
                      OR s2.wal_buffers_full < s1.wal_buffers_full
                      OR s2.wal_write < s1.wal_write
                      OR s2.wal_sync < s1.wal_sync
                      OR s2.wal_write_time < s1.wal_write_time
                      OR s2.wal_sync_time < s1.wal_sync_time THEN 'counter_decreased'
                    ELSE 'ok' END AS sample_status,
               s1.wal_records AS wal_records_start, s2.wal_records AS wal_records_end,
               s1.wal_fpi AS wal_fpi_start, s2.wal_fpi AS wal_fpi_end,
               s1.wal_bytes AS wal_bytes_start, s2.wal_bytes AS wal_bytes_end,
               s1.wal_buffers_full AS wal_buffers_full_start, s2.wal_buffers_full AS wal_buffers_full_end,
               s1.wal_write AS wal_write_start, s2.wal_write AS wal_write_end,
               s1.wal_sync AS wal_sync_start, s2.wal_sync AS wal_sync_end,
               s1.wal_write_time AS wal_write_time_start, s2.wal_write_time AS wal_write_time_end,
               s1.wal_sync_time AS wal_sync_time_start, s2.wal_sync_time AS wal_sync_time_end
        -- pg_stat_wal always returns one cluster-wide row: no identity join or sort.
        FROM first_snapshot AS s1 CROSS JOIN second_snapshot AS s2
    ) AS m
    CROSS JOIN first_time AS t1
    CROSS JOIN second_time AS t2;
END;
$$;

COMMENT ON FUNCTION pg_stat_wal_delta(numeric) IS
'Measure published cluster-wide WAL counters; reset or decreased counters invalidate all deltas. WAL times are milliseconds.';
-- Cluster-wide I/O statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_io_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    backend_type text,
    object text,
    context text,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    op_bytes bigint,
    reads_delta bigint,
    read_time_delta double precision,
    writes_delta bigint,
    write_time_delta double precision,
    writebacks_delta bigint,
    writeback_time_delta double precision,
    extends_delta bigint,
    extend_time_delta double precision,
    hits_delta bigint,
    evictions_delta bigint,
    reuses_delta bigint,
    fsyncs_delta bigint,
    fsync_time_delta double precision
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
        SELECT i.*
        FROM pg_stat_io AS i
        -- The view calls a set-returning statistics getter in FROM. This zero
        -- OFFSET InitPlan clears cached I/O stats before that Function Scan starts.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the snapshot before starting the wait.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT i.*
        FROM pg_stat_io AS i
        -- As above, clear after the wait and before invoking pg_stat_get_io().
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.backend_type, s1.backend_type) AS backend_type,
               coalesce(s2.object, s1.object) AS object,
               coalesce(s2.context, s1.context) AS context,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.backend_type IS NULL OR s2.backend_type IS NULL THEN 'missing'
                    WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    WHEN s2.reads < s1.reads
                      OR s2.read_time < s1.read_time
                      OR s2.writes < s1.writes
                      OR s2.write_time < s1.write_time
                      OR s2.writebacks < s1.writebacks
                      OR s2.writeback_time < s1.writeback_time
                      OR s2.extends < s1.extends
                      OR s2.extend_time < s1.extend_time
                      OR s2.hits < s1.hits
                      OR s2.evictions < s1.evictions
                      OR s2.reuses < s1.reuses
                      OR s2.fsyncs < s1.fsyncs
                      OR s2.fsync_time < s1.fsync_time THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               coalesce(s2.op_bytes, s1.op_bytes) AS op_bytes,
               s1.reads AS reads_start, s2.reads AS reads_end,
               s1.read_time AS read_time_start, s2.read_time AS read_time_end,
               s1.writes AS writes_start, s2.writes AS writes_end,
               s1.write_time AS write_time_start, s2.write_time AS write_time_end,
               s1.writebacks AS writebacks_start, s2.writebacks AS writebacks_end,
               s1.writeback_time AS writeback_time_start, s2.writeback_time AS writeback_time_end,
               s1.extends AS extends_start, s2.extends AS extends_end,
               s1.extend_time AS extend_time_start, s2.extend_time AS extend_time_end,
               s1.hits AS hits_start, s2.hits AS hits_end,
               s1.evictions AS evictions_start, s2.evictions AS evictions_end,
               s1.reuses AS reuses_start, s2.reuses AS reuses_end,
               s1.fsyncs AS fsyncs_start, s2.fsyncs AS fsyncs_end,
               s1.fsync_time AS fsync_time_start, s2.fsync_time AS fsync_time_end
        FROM first_snapshot AS s1
        -- The source identifies an I/O bucket by all three dimensions, not a PID.
        FULL OUTER JOIN second_snapshot AS s2
          ON s1.backend_type = s2.backend_type
         AND s1.object = s2.object
         AND s1.context = s2.context
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.backend_type, m.object, m.context,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           m.op_bytes,
           CASE WHEN m.status = 'ok' THEN m.reads_end - m.reads_start END AS reads_delta,
           CASE WHEN m.status = 'ok' THEN m.read_time_end - m.read_time_start END AS read_time_delta,
           CASE WHEN m.status = 'ok' THEN m.writes_end - m.writes_start END AS writes_delta,
           CASE WHEN m.status = 'ok' THEN m.write_time_end - m.write_time_start END AS write_time_delta,
           CASE WHEN m.status = 'ok' THEN m.writebacks_end - m.writebacks_start END AS writebacks_delta,
           CASE WHEN m.status = 'ok' THEN m.writeback_time_end - m.writeback_time_start END AS writeback_time_delta,
           CASE WHEN m.status = 'ok' THEN m.extends_end - m.extends_start END AS extends_delta,
           CASE WHEN m.status = 'ok' THEN m.extend_time_end - m.extend_time_start END AS extend_time_delta,
           CASE WHEN m.status = 'ok' THEN m.hits_end - m.hits_start END AS hits_delta,
           CASE WHEN m.status = 'ok' THEN m.evictions_end - m.evictions_start END AS evictions_delta,
           CASE WHEN m.status = 'ok' THEN m.reuses_end - m.reuses_start END AS reuses_delta,
           CASE WHEN m.status = 'ok' THEN m.fsyncs_end - m.fsyncs_start END AS fsyncs_delta,
           CASE WHEN m.status = 'ok' THEN m.fsync_time_end - m.fsync_time_start END AS fsync_time_delta
    FROM measured AS m
    ORDER BY m.backend_type, m.object, m.context;
END;
$$;

COMMENT ON FUNCTION pg_stat_io_delta(numeric) IS
'Published cluster-wide I/O deltas by backend type, object and context; invalid rows have NULL deltas, unsupported source counters remain NULL. Times are milliseconds; op_bytes is a size, not a counter.';
-- Flat function snapshots and a full join; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_user_functions_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    funcid oid,
    schemaname name,
    funcname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    calls_delta bigint,
    total_time_delta double precision,
    self_time_delta double precision
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
        SELECT f.*
        FROM pg_stat_user_functions AS f
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the whole snapshot before waiting, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        -- The sleep is consumed before statistics are cleared for the second read.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT f.*
        FROM pg_stat_user_functions AS f
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.funcid, s1.funcid) AS funcid,
               coalesce(s2.schemaname, s1.schemaname) AS schemaname,
               coalesce(s2.funcname, s1.funcname) AS funcname,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.funcid IS NULL OR s2.funcid IS NULL THEN 'missing'
                    -- Function resets update the PG17 database marker; count growth
                    -- alone cannot exclude a reset followed by renewed activity.
                    WHEN t1.reset_at IS DISTINCT FROM t2.reset_at THEN 'reset'
                    WHEN s2.calls < s1.calls
                      OR s2.total_time < s1.total_time
                      OR s2.self_time < s1.self_time THEN 'reset'
                    ELSE 'ok' END AS status,
               s1.calls AS calls_start, s2.calls AS calls_end,
               s1.total_time AS total_time_start, s2.total_time AS total_time_end,
               s1.self_time AS self_time_start, s2.self_time AS self_time_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.funcid = s2.funcid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.funcid, m.schemaname, m.funcname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.calls_end - m.calls_start END AS calls_delta,
           CASE WHEN m.status = 'ok' THEN m.total_time_end - m.total_time_start END AS total_time_delta,
           CASE WHEN m.status = 'ok' THEN m.self_time_end - m.self_time_start END AS self_time_delta
    FROM measured AS m
    ORDER BY m.schemaname, m.funcname, m.funcid;
END;
$$;

COMMENT ON FUNCTION pg_stat_user_functions_delta(numeric) IS
'Published user-function calls and time deltas in milliseconds. Missing/reset rows invalidate all three deltas; tracking depends on track_functions in executing sessions.';

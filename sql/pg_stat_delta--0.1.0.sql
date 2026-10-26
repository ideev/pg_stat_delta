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
        -- Keep flat columns: verified PG17 plans project statistics getters above
        -- this join, after the clear CTE has produced its singleton row.
        SELECT d.*
        FROM pg_stat_database AS d
        CROSS JOIN initial_clear
    ), first_time AS MATERIALIZED (
        -- The aggregate consumes the first snapshot before yielding the timing row.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited executes the sleep before clearing statistics again.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        -- As above, the flat projection follows consumption of the sleep/clear row.
        SELECT d.*
        FROM pg_stat_database AS d
        CROSS JOIN second_clear
    ), second_time AS MATERIALIZED (
        -- Consume the second snapshot and yield exactly one timing row, even if empty.
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    )
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
           s2.numbackends - s1.numbackends AS num_backends_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.xact_commit - s1.xact_commit END AS xact_commit_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.xact_rollback - s1.xact_rollback END AS xact_rollback_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.blks_read - s1.blks_read END AS blks_read_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.blks_hit - s1.blks_hit END AS blks_hit_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_returned - s1.tup_returned END AS tup_returned_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_fetched - s1.tup_fetched END AS tup_fetched_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_inserted - s1.tup_inserted END AS tup_inserted_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_updated - s1.tup_updated END AS tup_updated_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_deleted - s1.tup_deleted END AS tup_deleted_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.temp_files - s1.temp_files END AS temp_files_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.temp_bytes - s1.temp_bytes END AS temp_bytes_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.deadlocks - s1.deadlocks END AS deadlocks_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.blk_read_time - s1.blk_read_time END AS blk_read_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.blk_write_time - s1.blk_write_time END AS blk_write_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.session_time - s1.session_time END AS session_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.active_time - s1.active_time END AS active_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.idle_in_transaction_time - s1.idle_in_transaction_time END AS idle_in_transaction_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.sessions - s1.sessions END AS sessions_delta
    FROM first_snapshot AS s1
    FULL OUTER JOIN second_snapshot AS s2 ON s1.datid = s2.datid
    CROSS JOIN first_time AS t1
    CROSS JOIN second_time AS t2
    ORDER BY coalesce(s2.datid, s1.datid);
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
               s2.seq_scan - s1.seq_scan AS seq_scan_delta,
               s2.seq_tup_read - s1.seq_tup_read AS seq_tup_read_delta,
               s2.idx_scan - s1.idx_scan AS idx_scan_delta,
               s2.idx_tup_fetch - s1.idx_tup_fetch AS idx_tup_fetch_delta,
               s2.n_tup_ins - s1.n_tup_ins AS n_tup_ins_delta,
               s2.n_tup_upd - s1.n_tup_upd AS n_tup_upd_delta,
               s2.n_tup_del - s1.n_tup_del AS n_tup_del_delta,
               s2.n_tup_hot_upd - s1.n_tup_hot_upd AS n_tup_hot_upd_delta,
               s2.n_tup_newpage_upd - s1.n_tup_newpage_upd AS n_tup_newpage_upd_delta,
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
        -- Keep reset classification once per row, without materializing another
        -- snapshot or repeating the nine-counter check for every output delta.
        OFFSET 0
    )
    SELECT m.relid, m.schemaname, m.relname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.seq_scan_delta END AS seq_scan_delta,
           CASE WHEN m.status = 'ok' THEN m.seq_tup_read_delta END AS seq_tup_read_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_scan_delta END AS idx_scan_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_tup_fetch_delta END AS idx_tup_fetch_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_ins_delta END AS n_tup_ins_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_upd_delta END AS n_tup_upd_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_del_delta END AS n_tup_del_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_hot_upd_delta END AS n_tup_hot_upd_delta,
           CASE WHEN m.status = 'ok' THEN m.n_tup_newpage_upd_delta END AS n_tup_newpage_upd_delta,
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
        -- Flat projection keeps getters above the clear join in verified PG17 plans.
        SELECT i.relid, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
               i.idx_scan, i.idx_tup_read, i.idx_tup_fetch
        FROM pg_stat_user_indexes AS i
        CROSS JOIN initial_clear
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
        -- Consume the sleep/clear row before projecting second-snapshot statistics.
        SELECT i.relid, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
               i.idx_scan, i.idx_tup_read, i.idx_tup_fetch, i.last_idx_scan
        FROM pg_stat_user_indexes AS i
        CROSS JOIN second_clear
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
               s2.idx_scan - s1.idx_scan AS idx_scan_delta,
               s2.idx_tup_read - s1.idx_tup_read AS idx_tup_read_delta,
               s2.idx_tup_fetch - s1.idx_tup_fetch AS idx_tup_fetch_delta,
               s2.last_idx_scan AS last_idx_scan_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.indexrelid = s2.indexrelid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
        -- Avoid repeating the three-counter reset classification for every delta,
        -- without materializing another snapshot.
        OFFSET 0
    )
    SELECT m.relid, m.indexrelid, m.schemaname, m.relname, m.indexrelname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.idx_scan_delta END AS idx_scan_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_tup_read_delta END AS idx_tup_read_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_tup_fetch_delta END AS idx_tup_fetch_delta,
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
               s2.heap_blks_read - s1.heap_blks_read AS heap_blks_read_delta,
               s2.heap_blks_hit - s1.heap_blks_hit AS heap_blks_hit_delta,
               s2.idx_blks_read - s1.idx_blks_read AS idx_blks_read_delta,
               s2.idx_blks_hit - s1.idx_blks_hit AS idx_blks_hit_delta,
               s2.toast_blks_read - s1.toast_blks_read AS toast_blks_read_delta,
               s2.toast_blks_hit - s1.toast_blks_hit AS toast_blks_hit_delta,
               s2.tidx_blks_read - s1.tidx_blks_read AS tidx_blks_read_delta,
               s2.tidx_blks_hit - s1.tidx_blks_hit AS tidx_blks_hit_delta
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.relid = s2.relid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
        -- Compute the eight-counter validity test once per row rather than once
        -- for every output delta, without another materialized snapshot.
        OFFSET 0
    )
    SELECT m.relid, m.schemaname, m.relname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.heap_blks_read_delta END AS heap_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.heap_blks_hit_delta END AS heap_blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_blks_read_delta END AS idx_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_blks_hit_delta END AS idx_blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.toast_blks_read_delta END AS toast_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.toast_blks_hit_delta END AS toast_blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.tidx_blks_read_delta END AS tidx_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.tidx_blks_hit_delta END AS tidx_blks_hit_delta
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
        -- Flat projection keeps getters above the clear join in verified PG17 plans.
        SELECT i.relid, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
               i.idx_blks_read, i.idx_blks_hit
        FROM pg_statio_user_indexes AS i
        CROSS JOIN initial_clear
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
        -- Consume the sleep/clear row before projecting second-snapshot statistics.
        SELECT i.relid, i.indexrelid, i.schemaname, i.relname, i.indexrelname,
               i.idx_blks_read, i.idx_blks_hit
        FROM pg_statio_user_indexes AS i
        CROSS JOIN second_clear
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
               s2.idx_blks_read - s1.idx_blks_read AS idx_blks_read_delta,
               s2.idx_blks_hit - s1.idx_blks_hit AS idx_blks_hit_delta
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.indexrelid = s2.indexrelid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
        -- Avoid repeating the two-counter reset classification for every delta,
        -- without materializing another snapshot.
        OFFSET 0
    )
    SELECT m.relid, m.indexrelid, m.schemaname, m.relname, m.indexrelname,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.idx_blks_read_delta END AS idx_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.idx_blks_hit_delta END AS idx_blks_hit_delta
    FROM measured AS m
    ORDER BY m.schemaname, m.relname, m.indexrelname;
END;
$$;

COMMENT ON FUNCTION pg_statio_user_indexes_delta(numeric) IS
'Published per-index block I/O deltas. Missing rows, reset markers or decreased counters invalidate both deltas; reads need not be device I/O.';

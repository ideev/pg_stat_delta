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

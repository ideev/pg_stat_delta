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

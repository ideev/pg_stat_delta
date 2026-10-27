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

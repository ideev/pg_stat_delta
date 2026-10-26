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

-- On-demand slru statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_slru_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    name text,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    blks_zeroed_delta bigint,
    blks_hit_delta bigint,
    blks_read_delta bigint,
    blks_written_delta bigint,
    blks_exists_delta bigint,
    flushes_delta bigint,
    truncates_delta bigint
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
        SELECT s.*
        FROM pg_stat_slru AS s
        -- Initialize the zero OFFSET before source getters to clear cached stats.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the complete first snapshot before starting the wait.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT s.*
        FROM pg_stat_slru AS s
        -- Consume the wait and clear before evaluating the second source read.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.name, s1.name) AS name,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.name IS NULL OR s2.name IS NULL THEN 'missing'
                    WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    WHEN s2.blks_zeroed < s1.blks_zeroed
                      OR s2.blks_hit < s1.blks_hit
                      OR s2.blks_read < s1.blks_read
                      OR s2.blks_written < s1.blks_written
                      OR s2.blks_exists < s1.blks_exists
                      OR s2.flushes < s1.flushes
                      OR s2.truncates < s1.truncates THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               s1.blks_zeroed AS blks_zeroed_start, s2.blks_zeroed AS blks_zeroed_end,
               s1.blks_hit AS blks_hit_start, s2.blks_hit AS blks_hit_end,
               s1.blks_read AS blks_read_start, s2.blks_read AS blks_read_end,
               s1.blks_written AS blks_written_start, s2.blks_written AS blks_written_end,
               s1.blks_exists AS blks_exists_start, s2.blks_exists AS blks_exists_end,
               s1.flushes AS flushes_start, s2.flushes AS flushes_end,
               s1.truncates AS truncates_start, s2.truncates AS truncates_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.name = s2.name
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.name, m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.blks_zeroed_end - m.blks_zeroed_start END AS blks_zeroed_delta,
           CASE WHEN m.status = 'ok' THEN m.blks_hit_end - m.blks_hit_start END AS blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.blks_read_end - m.blks_read_start END AS blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.blks_written_end - m.blks_written_start END AS blks_written_delta,
           CASE WHEN m.status = 'ok' THEN m.blks_exists_end - m.blks_exists_start END AS blks_exists_delta,
           CASE WHEN m.status = 'ok' THEN m.flushes_end - m.flushes_start END AS flushes_delta,
           CASE WHEN m.status = 'ok' THEN m.truncates_end - m.truncates_start END AS truncates_delta
    FROM measured AS m
    ORDER BY m.name;
END;
$$;

COMMENT ON FUNCTION pg_stat_slru_delta(numeric) IS
'Published PostgreSQL 17 slru deltas; invalid statuses return NULL for every delta. Two native snapshots with explicit pre-scan cache clearing.';

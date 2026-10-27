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

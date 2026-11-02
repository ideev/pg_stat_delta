-- Cluster-wide background-writer statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_bgwriter_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    buffers_clean_delta bigint,
    maxwritten_clean_delta bigint,
    buffers_alloc_delta bigint
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
        SELECT b.*
        FROM pg_stat_bgwriter AS b
        -- Initialize the zero OFFSET before source getters to clear cached stats.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the snapshot before starting the wait.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT b.*
        FROM pg_stat_bgwriter AS b
        -- Consume the wait and cache clear before evaluating second-snapshot getters.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    )
    SELECT t1.started_at AS sampled_at_start,
           t2.finished_at AS sampled_at_end,
           extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
           m.status,
           CASE WHEN m.status = 'ok' THEN m.buffers_clean_end - m.buffers_clean_start END AS buffers_clean_delta,
           CASE WHEN m.status = 'ok' THEN m.maxwritten_clean_end - m.maxwritten_clean_start END AS maxwritten_clean_delta,
           CASE WHEN m.status = 'ok' THEN m.buffers_alloc_end - m.buffers_alloc_start END AS buffers_alloc_delta
    FROM (
        SELECT CASE WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    WHEN s2.buffers_clean < s1.buffers_clean
                      OR s2.maxwritten_clean < s1.maxwritten_clean
                      OR s2.buffers_alloc < s1.buffers_alloc THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               s1.buffers_clean AS buffers_clean_start, s2.buffers_clean AS buffers_clean_end,
               s1.maxwritten_clean AS maxwritten_clean_start, s2.maxwritten_clean AS maxwritten_clean_end,
               s1.buffers_alloc AS buffers_alloc_start, s2.buffers_alloc AS buffers_alloc_end
        -- pg_stat_bgwriter is one cluster-wide row, so no identity join or sort.
        FROM first_snapshot AS s1 CROSS JOIN second_snapshot AS s2
    ) AS m
    CROSS JOIN first_time AS t1
    CROSS JOIN second_time AS t2;
END;
$$;

COMMENT ON FUNCTION pg_stat_bgwriter_delta(numeric) IS
'Published PostgreSQL 17 background-writer deltas. A reset or any decreased counter invalidates all three deltas; checkpoint statistics are in pg_stat_checkpointer.';

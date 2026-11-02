-- Cluster-wide archiver statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_archiver_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    archived_count_delta bigint,
    failed_count_delta bigint,
    last_archived_wal_end text,
    last_archived_time_end timestamptz,
    last_failed_wal_end text,
    last_failed_time_end timestamptz
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
        SELECT a.archived_count, a.failed_count, a.stats_reset
        FROM pg_stat_archiver AS a
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
        SELECT a.*
        FROM pg_stat_archiver AS a
        -- Consume the wait and cache clear before evaluating second-snapshot getters.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    )
    SELECT t1.started_at AS sampled_at_start,
           t2.finished_at AS sampled_at_end,
           extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
           m.status,
           CASE WHEN m.status = 'ok' THEN m.archived_count_end - m.archived_count_start END AS archived_count_delta,
           CASE WHEN m.status = 'ok' THEN m.failed_count_end - m.failed_count_start END AS failed_count_delta,
           m.last_archived_wal_end, m.last_archived_time_end,
           m.last_failed_wal_end, m.last_failed_time_end
    FROM (
        SELECT CASE WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    WHEN s2.archived_count < s1.archived_count
                      OR s2.failed_count < s1.failed_count THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               s1.archived_count AS archived_count_start, s2.archived_count AS archived_count_end,
               s1.failed_count AS failed_count_start, s2.failed_count AS failed_count_end,
               -- Last-event fields are second-snapshot state, even on invalid deltas.
               s2.last_archived_wal AS last_archived_wal_end,
               s2.last_archived_time AS last_archived_time_end,
               s2.last_failed_wal AS last_failed_wal_end,
               s2.last_failed_time AS last_failed_time_end
        -- pg_stat_archiver is one cluster-wide row, so no identity join or sort.
        FROM first_snapshot AS s1 CROSS JOIN second_snapshot AS s2
    ) AS m
    CROSS JOIN first_time AS t1
    CROSS JOIN second_time AS t2;
END;
$$;

COMMENT ON FUNCTION pg_stat_archiver_delta(numeric) IS
'Published cluster-wide archiver count deltas and final last-event fields. A reset or decrease invalidates both deltas, without discarding final event state.';

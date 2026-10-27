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

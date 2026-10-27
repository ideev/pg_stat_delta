-- Cluster-wide I/O statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_io_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    backend_type text,
    object text,
    context text,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    op_bytes bigint,
    reads_delta bigint,
    read_time_delta double precision,
    writes_delta bigint,
    write_time_delta double precision,
    writebacks_delta bigint,
    writeback_time_delta double precision,
    extends_delta bigint,
    extend_time_delta double precision,
    hits_delta bigint,
    evictions_delta bigint,
    reuses_delta bigint,
    fsyncs_delta bigint,
    fsync_time_delta double precision
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
        SELECT i.*
        FROM pg_stat_io AS i
        -- The view calls a set-returning statistics getter in FROM. This zero
        -- OFFSET InitPlan clears cached I/O stats before that Function Scan starts.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume the snapshot before starting the wait.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT i.*
        FROM pg_stat_io AS i
        -- As above, clear after the wait and before invoking pg_stat_get_io().
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.backend_type, s1.backend_type) AS backend_type,
               coalesce(s2.object, s1.object) AS object,
               coalesce(s2.context, s1.context) AS context,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.backend_type IS NULL OR s2.backend_type IS NULL THEN 'missing'
                    WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    WHEN s2.reads < s1.reads
                      OR s2.read_time < s1.read_time
                      OR s2.writes < s1.writes
                      OR s2.write_time < s1.write_time
                      OR s2.writebacks < s1.writebacks
                      OR s2.writeback_time < s1.writeback_time
                      OR s2.extends < s1.extends
                      OR s2.extend_time < s1.extend_time
                      OR s2.hits < s1.hits
                      OR s2.evictions < s1.evictions
                      OR s2.reuses < s1.reuses
                      OR s2.fsyncs < s1.fsyncs
                      OR s2.fsync_time < s1.fsync_time THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               coalesce(s2.op_bytes, s1.op_bytes) AS op_bytes,
               s1.reads AS reads_start, s2.reads AS reads_end,
               s1.read_time AS read_time_start, s2.read_time AS read_time_end,
               s1.writes AS writes_start, s2.writes AS writes_end,
               s1.write_time AS write_time_start, s2.write_time AS write_time_end,
               s1.writebacks AS writebacks_start, s2.writebacks AS writebacks_end,
               s1.writeback_time AS writeback_time_start, s2.writeback_time AS writeback_time_end,
               s1.extends AS extends_start, s2.extends AS extends_end,
               s1.extend_time AS extend_time_start, s2.extend_time AS extend_time_end,
               s1.hits AS hits_start, s2.hits AS hits_end,
               s1.evictions AS evictions_start, s2.evictions AS evictions_end,
               s1.reuses AS reuses_start, s2.reuses AS reuses_end,
               s1.fsyncs AS fsyncs_start, s2.fsyncs AS fsyncs_end,
               s1.fsync_time AS fsync_time_start, s2.fsync_time AS fsync_time_end
        FROM first_snapshot AS s1
        -- The source identifies an I/O bucket by all three dimensions, not a PID.
        FULL OUTER JOIN second_snapshot AS s2
          ON s1.backend_type = s2.backend_type
         AND s1.object = s2.object
         AND s1.context = s2.context
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.backend_type, m.object, m.context,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           m.op_bytes,
           CASE WHEN m.status = 'ok' THEN m.reads_end - m.reads_start END AS reads_delta,
           CASE WHEN m.status = 'ok' THEN m.read_time_end - m.read_time_start END AS read_time_delta,
           CASE WHEN m.status = 'ok' THEN m.writes_end - m.writes_start END AS writes_delta,
           CASE WHEN m.status = 'ok' THEN m.write_time_end - m.write_time_start END AS write_time_delta,
           CASE WHEN m.status = 'ok' THEN m.writebacks_end - m.writebacks_start END AS writebacks_delta,
           CASE WHEN m.status = 'ok' THEN m.writeback_time_end - m.writeback_time_start END AS writeback_time_delta,
           CASE WHEN m.status = 'ok' THEN m.extends_end - m.extends_start END AS extends_delta,
           CASE WHEN m.status = 'ok' THEN m.extend_time_end - m.extend_time_start END AS extend_time_delta,
           CASE WHEN m.status = 'ok' THEN m.hits_end - m.hits_start END AS hits_delta,
           CASE WHEN m.status = 'ok' THEN m.evictions_end - m.evictions_start END AS evictions_delta,
           CASE WHEN m.status = 'ok' THEN m.reuses_end - m.reuses_start END AS reuses_delta,
           CASE WHEN m.status = 'ok' THEN m.fsyncs_end - m.fsyncs_start END AS fsyncs_delta,
           CASE WHEN m.status = 'ok' THEN m.fsync_time_end - m.fsync_time_start END AS fsync_time_delta
    FROM measured AS m
    ORDER BY m.backend_type, m.object, m.context;
END;
$$;

COMMENT ON FUNCTION pg_stat_io_delta(numeric) IS
'Published cluster-wide I/O deltas by backend type, object and context; invalid rows have NULL deltas, unsupported source counters remain NULL. Times are milliseconds; op_bytes is a size, not a counter.';

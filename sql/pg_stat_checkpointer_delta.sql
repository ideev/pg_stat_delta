-- On-demand checkpointer statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_checkpointer_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    num_timed_delta bigint,
    num_requested_delta bigint,
    restartpoints_timed_delta bigint,
    restartpoints_req_delta bigint,
    restartpoints_done_delta bigint,
    write_time_delta double precision,
    sync_time_delta double precision,
    buffers_written_delta bigint
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
        SELECT c.*
        FROM pg_stat_checkpointer AS c
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
        SELECT c.*
        FROM pg_stat_checkpointer AS c
        -- Consume the wait and clear before evaluating the second source read.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), measured AS (
        SELECT t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    WHEN s2.num_timed < s1.num_timed
                      OR s2.num_requested < s1.num_requested
                      OR s2.restartpoints_timed < s1.restartpoints_timed
                      OR s2.restartpoints_req < s1.restartpoints_req
                      OR s2.restartpoints_done < s1.restartpoints_done
                      OR s2.write_time < s1.write_time
                      OR s2.sync_time < s1.sync_time
                      OR s2.buffers_written < s1.buffers_written THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               s1.num_timed AS num_timed_start, s2.num_timed AS num_timed_end,
               s1.num_requested AS num_requested_start, s2.num_requested AS num_requested_end,
               s1.restartpoints_timed AS restartpoints_timed_start, s2.restartpoints_timed AS restartpoints_timed_end,
               s1.restartpoints_req AS restartpoints_req_start, s2.restartpoints_req AS restartpoints_req_end,
               s1.restartpoints_done AS restartpoints_done_start, s2.restartpoints_done AS restartpoints_done_end,
               s1.write_time AS write_time_start, s2.write_time AS write_time_end,
               s1.sync_time AS sync_time_start, s2.sync_time AS sync_time_end,
               s1.buffers_written AS buffers_written_start, s2.buffers_written AS buffers_written_end
        FROM first_snapshot AS s1
        -- The source is one cluster-wide row: no identity join or sort.
        CROSS JOIN second_snapshot AS s2
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.num_timed_end - m.num_timed_start END AS num_timed_delta,
           CASE WHEN m.status = 'ok' THEN m.num_requested_end - m.num_requested_start END AS num_requested_delta,
           CASE WHEN m.status = 'ok' THEN m.restartpoints_timed_end - m.restartpoints_timed_start END AS restartpoints_timed_delta,
           CASE WHEN m.status = 'ok' THEN m.restartpoints_req_end - m.restartpoints_req_start END AS restartpoints_req_delta,
           CASE WHEN m.status = 'ok' THEN m.restartpoints_done_end - m.restartpoints_done_start END AS restartpoints_done_delta,
           CASE WHEN m.status = 'ok' THEN m.write_time_end - m.write_time_start END AS write_time_delta,
           CASE WHEN m.status = 'ok' THEN m.sync_time_end - m.sync_time_start END AS sync_time_delta,
           CASE WHEN m.status = 'ok' THEN m.buffers_written_end - m.buffers_written_start END AS buffers_written_delta
    FROM measured AS m;
END;
$$;

COMMENT ON FUNCTION pg_stat_checkpointer_delta(numeric) IS
'Published PostgreSQL 17 checkpointer deltas; invalid statuses return NULL for every delta. Two native snapshots with explicit pre-scan cache clearing.';

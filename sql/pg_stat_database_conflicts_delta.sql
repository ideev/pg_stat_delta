-- On-demand database_conflicts statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_database_conflicts_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    datid oid,
    datname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    confl_tablespace_delta bigint,
    confl_lock_delta bigint,
    confl_snapshot_delta bigint,
    confl_bufferpin_delta bigint,
    confl_deadlock_delta bigint,
    confl_active_logicalslot_delta bigint
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
        -- The source has no reset marker; fetch only the matching database marker.
        SELECT d.*, pg_stat_get_db_stat_reset_time(d.datid) AS stats_reset
        FROM pg_stat_database_conflicts AS d
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
        -- The source has no reset marker; fetch only the matching database marker.
        SELECT d.*, pg_stat_get_db_stat_reset_time(d.datid) AS stats_reset
        FROM pg_stat_database_conflicts AS d
        -- Consume the wait and clear before evaluating the second source read.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.datid, s1.datid) AS datid,
               coalesce(s2.datname, s1.datname) AS datname,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.datid IS NULL OR s2.datid IS NULL THEN 'missing'
                    WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    WHEN s2.confl_tablespace < s1.confl_tablespace
                      OR s2.confl_lock < s1.confl_lock
                      OR s2.confl_snapshot < s1.confl_snapshot
                      OR s2.confl_bufferpin < s1.confl_bufferpin
                      OR s2.confl_deadlock < s1.confl_deadlock
                      OR s2.confl_active_logicalslot < s1.confl_active_logicalslot THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               s1.confl_tablespace AS confl_tablespace_start, s2.confl_tablespace AS confl_tablespace_end,
               s1.confl_lock AS confl_lock_start, s2.confl_lock AS confl_lock_end,
               s1.confl_snapshot AS confl_snapshot_start, s2.confl_snapshot AS confl_snapshot_end,
               s1.confl_bufferpin AS confl_bufferpin_start, s2.confl_bufferpin AS confl_bufferpin_end,
               s1.confl_deadlock AS confl_deadlock_start, s2.confl_deadlock AS confl_deadlock_end,
               s1.confl_active_logicalslot AS confl_active_logicalslot_start, s2.confl_active_logicalslot AS confl_active_logicalslot_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.datid = s2.datid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.datid, m.datname, m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.confl_tablespace_end - m.confl_tablespace_start END AS confl_tablespace_delta,
           CASE WHEN m.status = 'ok' THEN m.confl_lock_end - m.confl_lock_start END AS confl_lock_delta,
           CASE WHEN m.status = 'ok' THEN m.confl_snapshot_end - m.confl_snapshot_start END AS confl_snapshot_delta,
           CASE WHEN m.status = 'ok' THEN m.confl_bufferpin_end - m.confl_bufferpin_start END AS confl_bufferpin_delta,
           CASE WHEN m.status = 'ok' THEN m.confl_deadlock_end - m.confl_deadlock_start END AS confl_deadlock_delta,
           CASE WHEN m.status = 'ok' THEN m.confl_active_logicalslot_end - m.confl_active_logicalslot_start END AS confl_active_logicalslot_delta
    FROM measured AS m
    ORDER BY m.datid;
END;
$$;

COMMENT ON FUNCTION pg_stat_database_conflicts_delta(numeric) IS
'Published PostgreSQL 17 database_conflicts deltas; invalid statuses return NULL for every delta. Two native snapshots with explicit pre-scan cache clearing.';

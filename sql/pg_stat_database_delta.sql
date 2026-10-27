-- On-demand database statistics; part of extension version 0.1.0.
CREATE FUNCTION pg_stat_database_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    datid oid,
    datname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    num_backends_start integer,
    num_backends_end integer,
    num_backends_delta integer,
    xact_commit_delta bigint,
    xact_rollback_delta bigint,
    blks_read_delta bigint,
    blks_hit_delta bigint,
    tup_returned_delta bigint,
    tup_fetched_delta bigint,
    tup_inserted_delta bigint,
    tup_updated_delta bigint,
    tup_deleted_delta bigint,
    temp_files_delta bigint,
    temp_bytes_delta bigint,
    deadlocks_delta bigint,
    blk_read_time_delta double precision,
    blk_write_time_delta double precision,
    session_time_delta double precision,
    active_time_delta double precision,
    idle_in_transaction_time_delta double precision,
    sessions_delta bigint
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
        SELECT d.*
        FROM pg_stat_database AS d
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- The aggregate consumes the first snapshot before yielding the timing row.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited executes the sleep before clearing statistics again.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT d.*
        FROM pg_stat_database AS d
        -- Initialize the zero OFFSET before the scan to clear cached statistics.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        -- Consume the second snapshot and yield exactly one timing row, even if empty.
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), measured AS (
        SELECT coalesce(s2.datid, s1.datid) AS datid,
               coalesce(s2.datname, s1.datname) AS datname,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.datid IS NULL OR s2.datid IS NULL THEN 'missing'
                    WHEN s1.stats_reset IS DISTINCT FROM s2.stats_reset THEN 'reset'
                    ELSE 'ok' END AS status,
               s1.numbackends AS num_backends_start,
               s2.numbackends AS num_backends_end,
               s1.xact_commit AS xact_commit_start, s2.xact_commit AS xact_commit_end,
               s1.xact_rollback AS xact_rollback_start, s2.xact_rollback AS xact_rollback_end,
               s1.blks_read AS blks_read_start, s2.blks_read AS blks_read_end,
               s1.blks_hit AS blks_hit_start, s2.blks_hit AS blks_hit_end,
               s1.tup_returned AS tup_returned_start, s2.tup_returned AS tup_returned_end,
               s1.tup_fetched AS tup_fetched_start, s2.tup_fetched AS tup_fetched_end,
               s1.tup_inserted AS tup_inserted_start, s2.tup_inserted AS tup_inserted_end,
               s1.tup_updated AS tup_updated_start, s2.tup_updated AS tup_updated_end,
               s1.tup_deleted AS tup_deleted_start, s2.tup_deleted AS tup_deleted_end,
               s1.temp_files AS temp_files_start, s2.temp_files AS temp_files_end,
               s1.temp_bytes AS temp_bytes_start, s2.temp_bytes AS temp_bytes_end,
               s1.deadlocks AS deadlocks_start, s2.deadlocks AS deadlocks_end,
               s1.blk_read_time AS blk_read_time_start, s2.blk_read_time AS blk_read_time_end,
               s1.blk_write_time AS blk_write_time_start, s2.blk_write_time AS blk_write_time_end,
               s1.session_time AS session_time_start, s2.session_time AS session_time_end,
               s1.active_time AS active_time_start, s2.active_time AS active_time_end,
               s1.idle_in_transaction_time AS idle_in_transaction_time_start, s2.idle_in_transaction_time AS idle_in_transaction_time_end,
               s1.sessions AS sessions_start, s2.sessions AS sessions_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2 ON s1.datid = s2.datid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.datid, m.datname, m.sampled_at_start, m.sampled_at_end,
           m.elapsed_seconds, m.status, m.num_backends_start, m.num_backends_end,
           CASE WHEN m.status = 'ok' THEN m.num_backends_end - m.num_backends_start END AS num_backends_delta,
           CASE WHEN m.status = 'ok' THEN m.xact_commit_end - m.xact_commit_start END AS xact_commit_delta,
           CASE WHEN m.status = 'ok' THEN m.xact_rollback_end - m.xact_rollback_start END AS xact_rollback_delta,
           CASE WHEN m.status = 'ok' THEN m.blks_read_end - m.blks_read_start END AS blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.blks_hit_end - m.blks_hit_start END AS blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_returned_end - m.tup_returned_start END AS tup_returned_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_fetched_end - m.tup_fetched_start END AS tup_fetched_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_inserted_end - m.tup_inserted_start END AS tup_inserted_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_updated_end - m.tup_updated_start END AS tup_updated_delta,
           CASE WHEN m.status = 'ok' THEN m.tup_deleted_end - m.tup_deleted_start END AS tup_deleted_delta,
           CASE WHEN m.status = 'ok' THEN m.temp_files_end - m.temp_files_start END AS temp_files_delta,
           CASE WHEN m.status = 'ok' THEN m.temp_bytes_end - m.temp_bytes_start END AS temp_bytes_delta,
           CASE WHEN m.status = 'ok' THEN m.deadlocks_end - m.deadlocks_start END AS deadlocks_delta,
           CASE WHEN m.status = 'ok' THEN m.blk_read_time_end - m.blk_read_time_start END AS blk_read_time_delta,
           CASE WHEN m.status = 'ok' THEN m.blk_write_time_end - m.blk_write_time_start END AS blk_write_time_delta,
           CASE WHEN m.status = 'ok' THEN m.session_time_end - m.session_time_start END AS session_time_delta,
           CASE WHEN m.status = 'ok' THEN m.active_time_end - m.active_time_start END AS active_time_delta,
           CASE WHEN m.status = 'ok' THEN m.idle_in_transaction_time_end - m.idle_in_transaction_time_start END AS idle_in_transaction_time_delta,
           CASE WHEN m.status = 'ok' THEN m.sessions_end - m.sessions_start END AS sessions_delta
    FROM measured AS m
    ORDER BY m.datid;
END;
$$;

COMMENT ON FUNCTION pg_stat_database_delta(numeric) IS
'Measure published database counters using two native snapshots and a full join; missing or reset snapshots have NULL counter deltas.';

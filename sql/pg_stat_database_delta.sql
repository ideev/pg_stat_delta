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
        -- Keep flat columns: verified PG17 plans project statistics getters above
        -- this join, after the clear CTE has produced its singleton row.
        SELECT d.*
        FROM pg_stat_database AS d
        CROSS JOIN initial_clear
    ), first_time AS MATERIALIZED (
        -- The aggregate consumes the first snapshot before yielding the timing row.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited executes the sleep before clearing statistics again.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        -- As above, the flat projection follows consumption of the sleep/clear row.
        SELECT d.*
        FROM pg_stat_database AS d
        CROSS JOIN second_clear
    ), second_time AS MATERIALIZED (
        -- Consume the second snapshot and yield exactly one timing row, even if empty.
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    )
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
           s2.numbackends - s1.numbackends AS num_backends_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.xact_commit - s1.xact_commit END AS xact_commit_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.xact_rollback - s1.xact_rollback END AS xact_rollback_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.blks_read - s1.blks_read END AS blks_read_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.blks_hit - s1.blks_hit END AS blks_hit_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_returned - s1.tup_returned END AS tup_returned_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_fetched - s1.tup_fetched END AS tup_fetched_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_inserted - s1.tup_inserted END AS tup_inserted_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_updated - s1.tup_updated END AS tup_updated_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.tup_deleted - s1.tup_deleted END AS tup_deleted_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.temp_files - s1.temp_files END AS temp_files_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.temp_bytes - s1.temp_bytes END AS temp_bytes_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.deadlocks - s1.deadlocks END AS deadlocks_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.blk_read_time - s1.blk_read_time END AS blk_read_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.blk_write_time - s1.blk_write_time END AS blk_write_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.session_time - s1.session_time END AS session_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.active_time - s1.active_time END AS active_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.idle_in_transaction_time - s1.idle_in_transaction_time END AS idle_in_transaction_time_delta,
           CASE WHEN s1.stats_reset IS NOT DISTINCT FROM s2.stats_reset THEN s2.sessions - s1.sessions END AS sessions_delta
    FROM first_snapshot AS s1
    FULL OUTER JOIN second_snapshot AS s2 ON s1.datid = s2.datid
    CROSS JOIN first_time AS t1
    CROSS JOIN second_time AS t2
    ORDER BY coalesce(s2.datid, s1.datid);
END;
$$;

COMMENT ON FUNCTION pg_stat_database_delta(numeric) IS
'Measure published database counters using two native snapshots and a full join; missing or reset snapshots have NULL counter deltas.';

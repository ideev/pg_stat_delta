-- Use CREATE EXTENSION pg_stat_delta to load this file.
CREATE FUNCTION pg_stat_database_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    datid oid,
    datname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    stats_reset_start timestamptz,
    stats_reset_end timestamptz,
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
    blk_write_time_delta double precision
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
        SELECT d AS r FROM pg_stat_database AS d
        -- OFFSET is evaluated before scanning the view and forces cache clearing.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- The aggregate consumes the entire first snapshot before timing/sleep.
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep(i_delta_seconds::double precision + t.n * 0)
        FROM first_time AS t
    ), second_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT d AS r FROM pg_stat_database AS d
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), snapshots AS (
        SELECT 1 AS snap, r FROM first_snapshot
        UNION ALL
        SELECT 2 AS snap, r FROM second_snapshot
    ), windowed AS (
        SELECT snap, r,
               lag(r) OVER (PARTITION BY (r).datid ORDER BY snap) AS previous_row
        FROM snapshots
    ), paired AS (
        SELECT previous_row AS before_row, r AS after_row,
               CASE WHEN (previous_row).stats_reset IS DISTINCT FROM (r).stats_reset
                        THEN 'reset'
                    ELSE 'ok' END AS sample_status
        FROM windowed
        WHERE snap = 2
    )
    SELECT coalesce((after_row).datid, (before_row).datid) AS datid,
           coalesce((after_row).datname, (before_row).datname) AS datname,
           t1.started_at AS sampled_at_start,
           t2.finished_at AS sampled_at_end,
           extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
           sample_status AS status,
           (before_row).stats_reset AS stats_reset_start,
           (after_row).stats_reset AS stats_reset_end,
           (before_row).numbackends AS num_backends_start,
           (after_row).numbackends AS num_backends_end,
           (after_row).numbackends - (before_row).numbackends AS num_backends_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).xact_commit - (before_row).xact_commit END AS xact_commit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).xact_rollback - (before_row).xact_rollback END AS xact_rollback_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).blks_read - (before_row).blks_read END AS blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).blks_hit - (before_row).blks_hit END AS blks_hit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_returned - (before_row).tup_returned END AS tup_returned_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_fetched - (before_row).tup_fetched END AS tup_fetched_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_inserted - (before_row).tup_inserted END AS tup_inserted_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_updated - (before_row).tup_updated END AS tup_updated_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_deleted - (before_row).tup_deleted END AS tup_deleted_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).temp_files - (before_row).temp_files END AS temp_files_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).temp_bytes - (before_row).temp_bytes END AS temp_bytes_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).deadlocks - (before_row).deadlocks END AS deadlocks_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).blk_read_time - (before_row).blk_read_time END AS blk_read_time_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).blk_write_time - (before_row).blk_write_time END AS blk_write_time_delta
    FROM paired CROSS JOIN first_time AS t1 CROSS JOIN second_time AS t2
    ORDER BY coalesce((after_row).datid, (before_row).datid);
END;
$$;

COMMENT ON FUNCTION pg_stat_database_delta(numeric) IS
'Measure published database counters across an interval without persistent snapshots; invalid deltas are NULL.';

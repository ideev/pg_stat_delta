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
    xact_commit bigint,
    xact_rollback bigint,
    blks_read bigint,
    blks_hit bigint,
    tup_returned bigint,
    tup_fetched bigint,
    tup_inserted bigint,
    tup_updated bigint,
    tup_deleted bigint,
    temp_files bigint,
    temp_bytes bigint,
    deadlocks bigint,
    blk_read_time double precision,
    blk_write_time double precision
)
LANGUAGE plpgsql VOLATILE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    first_snapshot jsonb;
    second_snapshot jsonb;
    started_at timestamptz;
    finished_at timestamptz;
BEGIN
    IF i_delta_seconds IS NULL OR i_delta_seconds < 0
       OR i_delta_seconds::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION 'interval must be a finite nonnegative number of seconds'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_stat_clear_snapshot();
    SELECT jsonb_agg(to_jsonb(d)) INTO first_snapshot FROM pg_stat_database AS d;
    started_at := clock_timestamp();

    PERFORM pg_sleep(i_delta_seconds::double precision);

    PERFORM pg_stat_clear_snapshot();
    SELECT jsonb_agg(to_jsonb(d)) INTO second_snapshot FROM pg_stat_database AS d;
    finished_at := clock_timestamp();

    RETURN QUERY
    WITH paired AS (
        SELECT a AS before_row, b AS after_row,
               CASE WHEN a.datid IS NULL THEN 'new'
                    WHEN b.datid IS NULL THEN 'dropped'
                    WHEN a.stats_reset IS DISTINCT FROM b.stats_reset THEN 'reset'
                    ELSE 'ok' END AS sample_status
        FROM jsonb_populate_recordset(NULL::pg_stat_database, first_snapshot) AS a
        FULL JOIN jsonb_populate_recordset(NULL::pg_stat_database, second_snapshot) AS b
            ON a.datid = b.datid
    )
    SELECT coalesce((after_row).datid, (before_row).datid),
           coalesce((after_row).datname, (before_row).datname),
           started_at, finished_at,
           extract(epoch FROM finished_at - started_at)::double precision,
           sample_status, (before_row).stats_reset, (after_row).stats_reset,
           (before_row).numbackends, (after_row).numbackends,
           (after_row).numbackends - (before_row).numbackends,
           CASE WHEN sample_status = 'ok' THEN (after_row).xact_commit - (before_row).xact_commit END,
           CASE WHEN sample_status = 'ok' THEN (after_row).xact_rollback - (before_row).xact_rollback END,
           CASE WHEN sample_status = 'ok' THEN (after_row).blks_read - (before_row).blks_read END,
           CASE WHEN sample_status = 'ok' THEN (after_row).blks_hit - (before_row).blks_hit END,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_returned - (before_row).tup_returned END,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_fetched - (before_row).tup_fetched END,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_inserted - (before_row).tup_inserted END,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_updated - (before_row).tup_updated END,
           CASE WHEN sample_status = 'ok' THEN (after_row).tup_deleted - (before_row).tup_deleted END,
           CASE WHEN sample_status = 'ok' THEN (after_row).temp_files - (before_row).temp_files END,
           CASE WHEN sample_status = 'ok' THEN (after_row).temp_bytes - (before_row).temp_bytes END,
           CASE WHEN sample_status = 'ok' THEN (after_row).deadlocks - (before_row).deadlocks END,
           CASE WHEN sample_status = 'ok' THEN (after_row).blk_read_time - (before_row).blk_read_time END,
           CASE WHEN sample_status = 'ok' THEN (after_row).blk_write_time - (before_row).blk_write_time END
    FROM paired
    ORDER BY coalesce((after_row).datid, (before_row).datid);
END;
$$;

COMMENT ON FUNCTION pg_stat_database_delta(numeric) IS
'Measure published database counters across an interval without persistent snapshots; invalid deltas are NULL.';

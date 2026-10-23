-- Read index activity without persistent snapshots.
CREATE FUNCTION pg_stat_user_indexes_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    relid oid,
    indexrelid oid,
    schemaname name,
    relname name,
    indexrelname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    database_stats_reset_start timestamptz,
    database_stats_reset_end timestamptz,
    idx_scan_delta bigint,
    idx_tup_read_delta bigint,
    idx_tup_fetch_delta bigint,
    last_idx_scan_end timestamptz
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
    WITH database_id AS MATERIALIZED (
        SELECT oid AS id FROM pg_database WHERE datname = current_database()
    ), initial_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot()
    ), first_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_stat_user_indexes AS t
        -- The singleton clear CTE makes this OFFSET zero, after cache clearing.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume every index before sleeping, including an empty snapshot.
        SELECT clock_timestamp() AS started_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM first_snapshot
    ), waited AS MATERIALIZED (
        -- The materialized aggregate yields a row only after the first scan ends.
        SELECT pg_sleep(i_delta_seconds::double precision)
        FROM first_time
    ), second_clear AS MATERIALIZED (
        -- Reading waited performs the sleep before clearing the cached statistics.
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        SELECT t AS r FROM pg_stat_user_indexes AS t
        -- Evaluate the sleep/clear dependency before scanning statistics again.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n,
               pg_stat_get_db_stat_reset_time((SELECT id FROM database_id)) AS reset_at
        FROM second_snapshot
    ), snapshots AS (
        SELECT 1 AS snap, r FROM first_snapshot
        UNION ALL
        SELECT 2 AS snap, r FROM second_snapshot
    ), windowed AS (
        SELECT snap, r,
               lag(r) OVER (PARTITION BY (r).indexrelid ORDER BY snap) AS previous_row
        FROM snapshots
    ), paired AS (
        SELECT previous_row AS before_row, r AS after_row
        FROM windowed WHERE snap = 2
    ), measured AS (
        SELECT p.*, a.started_at, b.finished_at,
               a.reset_at AS reset_start, b.reset_at AS reset_end,
               CASE WHEN a.reset_at IS DISTINCT FROM b.reset_at THEN 'reset'
                    WHEN (after_row).idx_scan < (before_row).idx_scan
                      OR (after_row).idx_tup_read < (before_row).idx_tup_read
                      OR (after_row).idx_tup_fetch < (before_row).idx_tup_fetch THEN 'counter_decreased'
                    ELSE 'ok' END AS sample_status
        FROM paired AS p CROSS JOIN first_time AS a CROSS JOIN second_time AS b
        -- Compute reset classification once per row, not once per output counter.
        OFFSET 0
    )
    SELECT (after_row).relid AS relid,
           (after_row).indexrelid AS indexrelid,
           (after_row).schemaname AS schemaname,
           (after_row).relname AS relname,
           (after_row).indexrelname AS indexrelname,
           started_at AS sampled_at_start,
           finished_at AS sampled_at_end,
           extract(epoch FROM finished_at - started_at)::double precision AS elapsed_seconds,
           sample_status AS status,
           reset_start AS database_stats_reset_start,
           reset_end AS database_stats_reset_end,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_scan - (before_row).idx_scan END AS idx_scan_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_tup_read - (before_row).idx_tup_read END AS idx_tup_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_tup_fetch - (before_row).idx_tup_fetch END AS idx_tup_fetch_delta,
           (after_row).last_idx_scan AS last_idx_scan_end
    FROM measured;
END;
$$;

COMMENT ON FUNCTION pg_stat_user_indexes_delta(numeric) IS
'Published index counter deltas; database reset timestamps and decreasing counters invalidate deltas. Index-only and bitmap scans have distinct tuple-counter semantics.';

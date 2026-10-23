-- Samples user tables, including their index and TOAST block counters.
CREATE FUNCTION pg_statio_user_tables_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    relid oid,
    schemaname name,
    relname name,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    database_stats_reset_start timestamptz,
    database_stats_reset_end timestamptz,
    heap_blks_read_delta bigint,
    heap_blks_hit_delta bigint,
    idx_blks_read_delta bigint,
    idx_blks_hit_delta bigint,
    toast_blks_read_delta bigint,
    toast_blks_hit_delta bigint,
    tidx_blks_read_delta bigint,
    tidx_blks_hit_delta bigint
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
        SELECT t AS r FROM pg_statio_user_tables AS t
        -- The singleton clear CTE makes this OFFSET zero, after cache clearing.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        -- Consume every relation before sleeping, including an empty snapshot.
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
        SELECT t AS r FROM pg_statio_user_tables AS t
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
               lag(r) OVER (PARTITION BY (r).relid ORDER BY snap) AS previous_row
        FROM snapshots
    ), paired AS (
        SELECT previous_row AS before_row, r AS after_row
        FROM windowed WHERE snap = 2
    ), measured AS (
        SELECT p.*, a.started_at, b.finished_at,
               a.reset_at AS reset_start, b.reset_at AS reset_end,
               CASE WHEN a.reset_at IS DISTINCT FROM b.reset_at THEN 'reset'
                    WHEN (after_row).heap_blks_read < (before_row).heap_blks_read
                      OR (after_row).heap_blks_hit < (before_row).heap_blks_hit
                      OR (after_row).idx_blks_read < (before_row).idx_blks_read
                      OR (after_row).idx_blks_hit < (before_row).idx_blks_hit
                      OR (after_row).toast_blks_read < (before_row).toast_blks_read
                      OR (after_row).toast_blks_hit < (before_row).toast_blks_hit
                      OR (after_row).tidx_blks_read < (before_row).tidx_blks_read
                      OR (after_row).tidx_blks_hit < (before_row).tidx_blks_hit THEN 'counter_decreased'
                    ELSE 'ok' END AS sample_status
        FROM paired AS p CROSS JOIN first_time AS a CROSS JOIN second_time AS b
        -- Compute reset classification once per row, not once per output counter.
        OFFSET 0
    )
    SELECT (after_row).relid AS relid,
           (after_row).schemaname AS schemaname,
           (after_row).relname AS relname,
           started_at AS sampled_at_start,
           finished_at AS sampled_at_end,
           extract(epoch FROM finished_at - started_at)::double precision AS elapsed_seconds,
           sample_status AS status,
           reset_start AS database_stats_reset_start,
           reset_end AS database_stats_reset_end,
           CASE WHEN sample_status = 'ok' THEN (after_row).heap_blks_read - (before_row).heap_blks_read END AS heap_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).heap_blks_hit - (before_row).heap_blks_hit END AS heap_blks_hit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_blks_read - (before_row).idx_blks_read END AS idx_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).idx_blks_hit - (before_row).idx_blks_hit END AS idx_blks_hit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).toast_blks_read - (before_row).toast_blks_read END AS toast_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).toast_blks_hit - (before_row).toast_blks_hit END AS toast_blks_hit_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tidx_blks_read - (before_row).tidx_blks_read END AS tidx_blks_read_delta,
           CASE WHEN sample_status = 'ok' THEN (after_row).tidx_blks_hit - (before_row).tidx_blks_hit END AS tidx_blks_hit_delta
    FROM measured;
END;
$$;

COMMENT ON FUNCTION pg_statio_user_tables_delta(numeric) IS
'Published user-table block-read and buffer-cache-hit deltas, including their indexes and TOAST. Not physical device I/O; resets and decreasing counters invalidate deltas.';

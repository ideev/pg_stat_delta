-- Optional pg_stat_statements 1.11 sampler; extension version 0.1.0.
CREATE FUNCTION pg_stat_statements_delta(i_delta_seconds numeric DEFAULT 5)
RETURNS TABLE (
    userid oid,
    dbid oid,
    toplevel boolean,
    queryid bigint,
    query text,
    sampled_at_start timestamptz,
    sampled_at_end timestamptz,
    elapsed_seconds double precision,
    status text,
    plans_delta bigint,
    total_plan_time_delta double precision,
    calls_delta bigint,
    total_exec_time_delta double precision,
    rows_delta bigint,
    shared_blks_hit_delta bigint,
    shared_blks_read_delta bigint,
    shared_blks_dirtied_delta bigint,
    shared_blks_written_delta bigint,
    local_blks_hit_delta bigint,
    local_blks_read_delta bigint,
    local_blks_dirtied_delta bigint,
    local_blks_written_delta bigint,
    temp_blks_read_delta bigint,
    temp_blks_written_delta bigint,
    shared_blk_read_time_delta double precision,
    shared_blk_write_time_delta double precision,
    local_blk_read_time_delta double precision,
    local_blk_write_time_delta double precision,
    temp_blk_read_time_delta double precision,
    temp_blk_write_time_delta double precision,
    wal_records_delta bigint,
    wal_fpi_delta bigint,
    wal_bytes_delta numeric,
    jit_functions_delta bigint,
    jit_generation_time_delta double precision,
    jit_inlining_count_delta bigint,
    jit_inlining_time_delta double precision,
    jit_optimization_count_delta bigint,
    jit_optimization_time_delta double precision,
    jit_emission_count_delta bigint,
    jit_emission_time_delta double precision,
    jit_deform_count_delta bigint,
    jit_deform_time_delta double precision
)
LANGUAGE plpgsql VOLATILE PARALLEL UNSAFE SECURITY INVOKER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    statements_schema name;
    statements_version text;
BEGIN
    IF i_delta_seconds IS NULL OR i_delta_seconds < 0
       OR i_delta_seconds::text IN ('NaN', 'Infinity', '-Infinity') THEN
        RAISE EXCEPTION 'interval must be a finite nonnegative number of seconds'
            USING ERRCODE = '22023';
    END IF;

    SELECT n.nspname, e.extversion INTO statements_schema, statements_version
    FROM pg_extension AS e JOIN pg_namespace AS n ON n.oid = e.extnamespace
    WHERE e.extname = 'pg_stat_statements';
    IF statements_schema IS NULL THEN
        RAISE EXCEPTION 'pg_stat_statements is not installed in this database'
            USING ERRCODE = '55000',
                  HINT = 'Preload pg_stat_statements and install version 1.11 in this database before calling this optional sampler.';
    END IF;
    IF statements_version <> '1.11' THEN
        RAISE EXCEPTION 'pg_stat_statements version 1.11 is required (installed: %)', statements_version
            USING ERRCODE = '0A000';
    END IF;

    -- Resolve and quote only the extension-owned namespace; keep invoker rights
    -- and the fixed search_path. EXECUTE avoids a mandatory extension dependency.
    -- The interval is a bound parameter, never interpolated into the SQL text.
    RETURN QUERY EXECUTE format($query$
    WITH initial_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot()
    ), first_snapshot AS MATERIALIZED (
        -- false avoids loading query texts for the first snapshot.
        SELECT s.userid, s.dbid, s.toplevel, s.queryid, s.stats_since,
               s.plans, s.total_plan_time, s.calls,
               s.total_exec_time, s.rows, s.shared_blks_hit,
               s.shared_blks_read, s.shared_blks_dirtied, s.shared_blks_written,
               s.local_blks_hit, s.local_blks_read, s.local_blks_dirtied,
               s.local_blks_written, s.temp_blks_read, s.temp_blks_written,
               s.shared_blk_read_time, s.shared_blk_write_time, s.local_blk_read_time,
               s.local_blk_write_time, s.temp_blk_read_time, s.temp_blk_write_time,
               s.wal_records, s.wal_fpi, s.wal_bytes,
               s.jit_functions, s.jit_generation_time, s.jit_inlining_count,
               s.jit_inlining_time, s.jit_optimization_count, s.jit_optimization_time,
               s.jit_emission_count, s.jit_emission_time, s.jit_deform_count,
               s.jit_deform_time
        FROM %1$I.pg_stat_statements(false) AS s
        -- Hidden query IDs cannot safely identify rows; never join them as one key.
        WHERE s.queryid IS NOT NULL
        -- Initialize the zero OFFSET before entering the statistics Function Scan.
        OFFSET (SELECT count(*) - 1 FROM initial_clear)
    ), first_time AS MATERIALIZED (
        SELECT clock_timestamp() AS started_at, count(*) AS n FROM first_snapshot
    ), waited AS MATERIALIZED (
        SELECT pg_sleep($1::double precision) FROM first_time
    ), second_clear AS MATERIALIZED (
        SELECT pg_stat_clear_snapshot() FROM waited
    ), second_snapshot AS MATERIALIZED (
        -- Fetch representative query text only once, with the final counters.
        SELECT s.userid, s.dbid, s.toplevel, s.queryid, s.query, s.stats_since,
               s.plans, s.total_plan_time, s.calls,
               s.total_exec_time, s.rows, s.shared_blks_hit,
               s.shared_blks_read, s.shared_blks_dirtied, s.shared_blks_written,
               s.local_blks_hit, s.local_blks_read, s.local_blks_dirtied,
               s.local_blks_written, s.temp_blks_read, s.temp_blks_written,
               s.shared_blk_read_time, s.shared_blk_write_time, s.local_blk_read_time,
               s.local_blk_write_time, s.temp_blk_read_time, s.temp_blk_write_time,
               s.wal_records, s.wal_fpi, s.wal_bytes,
               s.jit_functions, s.jit_generation_time, s.jit_inlining_count,
               s.jit_inlining_time, s.jit_optimization_count, s.jit_optimization_time,
               s.jit_emission_count, s.jit_emission_time, s.jit_deform_count,
               s.jit_deform_time
        FROM %1$I.pg_stat_statements(true) AS s
        WHERE s.queryid IS NOT NULL
        -- Consume the wait and clear before taking the second statistics scan.
        OFFSET (SELECT count(*) - 1 FROM second_clear)
    ), second_time AS MATERIALIZED (
        SELECT clock_timestamp() AS finished_at, count(*) AS n FROM second_snapshot
    ), measured AS MATERIALIZED (
        -- Keep the 34-metric validity check single-evaluated: measured against
        -- inlining/extra joins. Native endpoint materialization can spill for
        -- large entry/text sets; see docs/statements-query.md for the tradeoff.
        SELECT coalesce(s2.userid, s1.userid) AS userid,
               coalesce(s2.dbid, s1.dbid) AS dbid,
               coalesce(s2.toplevel, s1.toplevel) AS toplevel,
               coalesce(s2.queryid, s1.queryid) AS queryid,
               s2.query,
               t1.started_at AS sampled_at_start,
               t2.finished_at AS sampled_at_end,
               extract(epoch FROM t2.finished_at - t1.started_at)::double precision AS elapsed_seconds,
               CASE WHEN s1.queryid IS NULL OR s2.queryid IS NULL THEN 'missing'
                    -- Per-entry markers detect selective resets and eviction/reentry,
                    -- even when new counters have already caught up. Min/max-only
                    -- resets leave these additive counters and stats_since intact.
                    WHEN s1.stats_since IS DISTINCT FROM s2.stats_since THEN 'reset'
                    WHEN s2.plans < s1.plans
                      OR s2.total_plan_time < s1.total_plan_time
                      OR s2.calls < s1.calls
                      OR s2.total_exec_time < s1.total_exec_time
                      OR s2.rows < s1.rows
                      OR s2.shared_blks_hit < s1.shared_blks_hit
                      OR s2.shared_blks_read < s1.shared_blks_read
                      OR s2.shared_blks_dirtied < s1.shared_blks_dirtied
                      OR s2.shared_blks_written < s1.shared_blks_written
                      OR s2.local_blks_hit < s1.local_blks_hit
                      OR s2.local_blks_read < s1.local_blks_read
                      OR s2.local_blks_dirtied < s1.local_blks_dirtied
                      OR s2.local_blks_written < s1.local_blks_written
                      OR s2.temp_blks_read < s1.temp_blks_read
                      OR s2.temp_blks_written < s1.temp_blks_written
                      OR s2.shared_blk_read_time < s1.shared_blk_read_time
                      OR s2.shared_blk_write_time < s1.shared_blk_write_time
                      OR s2.local_blk_read_time < s1.local_blk_read_time
                      OR s2.local_blk_write_time < s1.local_blk_write_time
                      OR s2.temp_blk_read_time < s1.temp_blk_read_time
                      OR s2.temp_blk_write_time < s1.temp_blk_write_time
                      OR s2.wal_records < s1.wal_records
                      OR s2.wal_fpi < s1.wal_fpi
                      OR s2.wal_bytes < s1.wal_bytes
                      OR s2.jit_functions < s1.jit_functions
                      OR s2.jit_generation_time < s1.jit_generation_time
                      OR s2.jit_inlining_count < s1.jit_inlining_count
                      OR s2.jit_inlining_time < s1.jit_inlining_time
                      OR s2.jit_optimization_count < s1.jit_optimization_count
                      OR s2.jit_optimization_time < s1.jit_optimization_time
                      OR s2.jit_emission_count < s1.jit_emission_count
                      OR s2.jit_emission_time < s1.jit_emission_time
                      OR s2.jit_deform_count < s1.jit_deform_count
                      OR s2.jit_deform_time < s1.jit_deform_time THEN 'counter_decreased'
                    ELSE 'ok' END AS status,
               s1.plans AS plans_start, s2.plans AS plans_end,
               s1.total_plan_time AS total_plan_time_start, s2.total_plan_time AS total_plan_time_end,
               s1.calls AS calls_start, s2.calls AS calls_end,
               s1.total_exec_time AS total_exec_time_start, s2.total_exec_time AS total_exec_time_end,
               s1.rows AS rows_start, s2.rows AS rows_end,
               s1.shared_blks_hit AS shared_blks_hit_start, s2.shared_blks_hit AS shared_blks_hit_end,
               s1.shared_blks_read AS shared_blks_read_start, s2.shared_blks_read AS shared_blks_read_end,
               s1.shared_blks_dirtied AS shared_blks_dirtied_start, s2.shared_blks_dirtied AS shared_blks_dirtied_end,
               s1.shared_blks_written AS shared_blks_written_start, s2.shared_blks_written AS shared_blks_written_end,
               s1.local_blks_hit AS local_blks_hit_start, s2.local_blks_hit AS local_blks_hit_end,
               s1.local_blks_read AS local_blks_read_start, s2.local_blks_read AS local_blks_read_end,
               s1.local_blks_dirtied AS local_blks_dirtied_start, s2.local_blks_dirtied AS local_blks_dirtied_end,
               s1.local_blks_written AS local_blks_written_start, s2.local_blks_written AS local_blks_written_end,
               s1.temp_blks_read AS temp_blks_read_start, s2.temp_blks_read AS temp_blks_read_end,
               s1.temp_blks_written AS temp_blks_written_start, s2.temp_blks_written AS temp_blks_written_end,
               s1.shared_blk_read_time AS shared_blk_read_time_start, s2.shared_blk_read_time AS shared_blk_read_time_end,
               s1.shared_blk_write_time AS shared_blk_write_time_start, s2.shared_blk_write_time AS shared_blk_write_time_end,
               s1.local_blk_read_time AS local_blk_read_time_start, s2.local_blk_read_time AS local_blk_read_time_end,
               s1.local_blk_write_time AS local_blk_write_time_start, s2.local_blk_write_time AS local_blk_write_time_end,
               s1.temp_blk_read_time AS temp_blk_read_time_start, s2.temp_blk_read_time AS temp_blk_read_time_end,
               s1.temp_blk_write_time AS temp_blk_write_time_start, s2.temp_blk_write_time AS temp_blk_write_time_end,
               s1.wal_records AS wal_records_start, s2.wal_records AS wal_records_end,
               s1.wal_fpi AS wal_fpi_start, s2.wal_fpi AS wal_fpi_end,
               s1.wal_bytes AS wal_bytes_start, s2.wal_bytes AS wal_bytes_end,
               s1.jit_functions AS jit_functions_start, s2.jit_functions AS jit_functions_end,
               s1.jit_generation_time AS jit_generation_time_start, s2.jit_generation_time AS jit_generation_time_end,
               s1.jit_inlining_count AS jit_inlining_count_start, s2.jit_inlining_count AS jit_inlining_count_end,
               s1.jit_inlining_time AS jit_inlining_time_start, s2.jit_inlining_time AS jit_inlining_time_end,
               s1.jit_optimization_count AS jit_optimization_count_start, s2.jit_optimization_count AS jit_optimization_count_end,
               s1.jit_optimization_time AS jit_optimization_time_start, s2.jit_optimization_time AS jit_optimization_time_end,
               s1.jit_emission_count AS jit_emission_count_start, s2.jit_emission_count AS jit_emission_count_end,
               s1.jit_emission_time AS jit_emission_time_start, s2.jit_emission_time AS jit_emission_time_end,
               s1.jit_deform_count AS jit_deform_count_start, s2.jit_deform_count AS jit_deform_count_end,
               s1.jit_deform_time AS jit_deform_time_start, s2.jit_deform_time AS jit_deform_time_end
        FROM first_snapshot AS s1
        FULL OUTER JOIN second_snapshot AS s2
          ON s1.userid = s2.userid
         AND s1.dbid = s2.dbid
         AND s1.toplevel = s2.toplevel
         AND s1.queryid = s2.queryid
        CROSS JOIN first_time AS t1
        CROSS JOIN second_time AS t2
    )
    SELECT m.userid, m.dbid, m.toplevel, m.queryid, m.query,
           m.sampled_at_start, m.sampled_at_end, m.elapsed_seconds, m.status,
           CASE WHEN m.status = 'ok' THEN m.plans_end - m.plans_start END AS plans_delta,
           CASE WHEN m.status = 'ok' THEN m.total_plan_time_end - m.total_plan_time_start END AS total_plan_time_delta,
           CASE WHEN m.status = 'ok' THEN m.calls_end - m.calls_start END AS calls_delta,
           CASE WHEN m.status = 'ok' THEN m.total_exec_time_end - m.total_exec_time_start END AS total_exec_time_delta,
           CASE WHEN m.status = 'ok' THEN m.rows_end - m.rows_start END AS rows_delta,
           CASE WHEN m.status = 'ok' THEN m.shared_blks_hit_end - m.shared_blks_hit_start END AS shared_blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.shared_blks_read_end - m.shared_blks_read_start END AS shared_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.shared_blks_dirtied_end - m.shared_blks_dirtied_start END AS shared_blks_dirtied_delta,
           CASE WHEN m.status = 'ok' THEN m.shared_blks_written_end - m.shared_blks_written_start END AS shared_blks_written_delta,
           CASE WHEN m.status = 'ok' THEN m.local_blks_hit_end - m.local_blks_hit_start END AS local_blks_hit_delta,
           CASE WHEN m.status = 'ok' THEN m.local_blks_read_end - m.local_blks_read_start END AS local_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.local_blks_dirtied_end - m.local_blks_dirtied_start END AS local_blks_dirtied_delta,
           CASE WHEN m.status = 'ok' THEN m.local_blks_written_end - m.local_blks_written_start END AS local_blks_written_delta,
           CASE WHEN m.status = 'ok' THEN m.temp_blks_read_end - m.temp_blks_read_start END AS temp_blks_read_delta,
           CASE WHEN m.status = 'ok' THEN m.temp_blks_written_end - m.temp_blks_written_start END AS temp_blks_written_delta,
           CASE WHEN m.status = 'ok' THEN m.shared_blk_read_time_end - m.shared_blk_read_time_start END AS shared_blk_read_time_delta,
           CASE WHEN m.status = 'ok' THEN m.shared_blk_write_time_end - m.shared_blk_write_time_start END AS shared_blk_write_time_delta,
           CASE WHEN m.status = 'ok' THEN m.local_blk_read_time_end - m.local_blk_read_time_start END AS local_blk_read_time_delta,
           CASE WHEN m.status = 'ok' THEN m.local_blk_write_time_end - m.local_blk_write_time_start END AS local_blk_write_time_delta,
           CASE WHEN m.status = 'ok' THEN m.temp_blk_read_time_end - m.temp_blk_read_time_start END AS temp_blk_read_time_delta,
           CASE WHEN m.status = 'ok' THEN m.temp_blk_write_time_end - m.temp_blk_write_time_start END AS temp_blk_write_time_delta,
           CASE WHEN m.status = 'ok' THEN m.wal_records_end - m.wal_records_start END AS wal_records_delta,
           CASE WHEN m.status = 'ok' THEN m.wal_fpi_end - m.wal_fpi_start END AS wal_fpi_delta,
           CASE WHEN m.status = 'ok' THEN m.wal_bytes_end - m.wal_bytes_start END AS wal_bytes_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_functions_end - m.jit_functions_start END AS jit_functions_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_generation_time_end - m.jit_generation_time_start END AS jit_generation_time_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_inlining_count_end - m.jit_inlining_count_start END AS jit_inlining_count_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_inlining_time_end - m.jit_inlining_time_start END AS jit_inlining_time_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_optimization_count_end - m.jit_optimization_count_start END AS jit_optimization_count_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_optimization_time_end - m.jit_optimization_time_start END AS jit_optimization_time_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_emission_count_end - m.jit_emission_count_start END AS jit_emission_count_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_emission_time_end - m.jit_emission_time_start END AS jit_emission_time_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_deform_count_end - m.jit_deform_count_start END AS jit_deform_count_delta,
           CASE WHEN m.status = 'ok' THEN m.jit_deform_time_end - m.jit_deform_time_start END AS jit_deform_time_delta
    FROM measured AS m
    ORDER BY m.userid, m.dbid, m.toplevel, m.queryid
    $query$, statements_schema) USING i_delta_seconds;
END;
$$;

COMMENT ON FUNCTION pg_stat_statements_delta(numeric) IS
'Optional pg_stat_statements 1.11 deltas keyed by userid/dbid/toplevel/queryid. Per-entry reset/reentry or missing/decreasing rows invalidate all additive deltas. Query text is read only at the end; source privileges are preserved.';

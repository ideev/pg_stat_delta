"""Integration tests against an isolated PostgreSQL database (standard PG* variables)."""
import json
import os
from pathlib import Path
import subprocess
import time
import unittest

PSQL = os.environ.get('PSQL', 'psql')


def sql(query, **extra):
    return subprocess.check_output(
        [PSQL, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', query],
        env={**os.environ, **extra}, text=True).strip()


class DeltaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        sql('CREATE EXTENSION IF NOT EXISTS pg_stat_delta')

    def sample(self, action, prefix='', function='pg_stat_database_delta', condition='TRUE'):
        # Cache-priming prefixes must read a counter: count(*) can skip the getters.
        proc = subprocess.Popen(
            [PSQL, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', prefix +
             'SELECT coalesce(jsonb_agg(to_jsonb(d)),\'[]\'::jsonb) '
             f'FROM {function}(1.5) d WHERE {condition}'],
            env={**os.environ, 'PGAPPNAME': 'delta_test_sampler'},
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 5
            while sql("SELECT count(*) FROM pg_stat_activity WHERE "
                       "application_name='delta_test_sampler' AND wait_event='PgSleep'") != '1':
                if proc.poll() is not None or time.monotonic() > deadline:
                    self.fail('sampler did not enter pg_sleep')
                time.sleep(.02)
            action()
            out, err = proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, 0, err)
            return json.loads(out.splitlines()[-1])
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()

    def current(self, rows):
        return next(r for r in rows if r['datname'] == sql('SELECT current_database()'))

    def test_validation_and_zero(self):
        for value in ['NULL', '-1', "'NaN'", "'Infinity'", "'-Infinity'"]:
            result = subprocess.run([PSQL, '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                                     f'SELECT * FROM pg_stat_database_delta({value})'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('finite nonnegative', result.stderr)
        self.assertEqual(sql("SELECT bool_and(status='ok' AND elapsed_seconds>=0) "
                             'FROM pg_stat_database_delta(0)'), 't')

    def test_transactions_and_cache_modes(self):
        def workload():
            commands = ['SELECT 1'] * 20 + ['BEGIN; SELECT 1; ROLLBACK;',
                                              'SELECT pg_stat_force_next_flush()']
            args = [PSQL, '-XAt', '-v', 'ON_ERROR_STOP=1']
            for command in commands:
                args.extend(['-c', command])
            subprocess.check_output(args, text=True)

        for mode in ['none', 'cache', 'snapshot']:
            rows = self.sample(
                workload,
                f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; "
                'SELECT sum(xact_commit) FROM pg_stat_database; ')
            row = self.current(rows)
            self.assertEqual(row['status'], 'ok')
            self.assertGreaterEqual(row['xact_commit_delta'], 20)
            self.assertGreaterEqual(row['xact_rollback_delta'], 1)
            self.assertGreaterEqual(row['elapsed_seconds'], 1.5)

    def test_reset(self):
        row = self.current(self.sample(lambda: sql('SELECT pg_stat_reset()')))
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['xact_commit_delta'])
        self.assertIsNone(row['blks_read_delta'])

    def test_session_counters(self):
        def workload():
            # A client-side pause leaves the backend idle in a transaction;
            # server-side pg_sleep instead contributes active execution time.
            subprocess.check_output(
                [PSQL, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', 'BEGIN',
                 '-c', r'\! sleep 0.08', '-c', 'SELECT pg_sleep(0.03)', '-c', 'COMMIT',
                 '-c', 'SELECT pg_stat_force_next_flush()'], text=True)
        row = self.current(self.sample(workload))
        self.assertEqual(row['status'], 'ok')
        for field in ['session_time_delta', 'active_time_delta', 'idle_in_transaction_time_delta']:
            self.assertGreater(row[field], 0)
        self.assertGreaterEqual(row['sessions_delta'], 1)
        self.assertNotIn('stats_reset_start', row)
        self.assertNotIn('stats_reset_end', row)

    def test_alternative_join_plans(self):
        for settings in [
            'SET LOCAL enable_hashjoin=off; SET LOCAL join_collapse_limit=1; '
            'SET LOCAL from_collapse_limit=1; ',
            'SET LOCAL enable_mergejoin=off; SET LOCAL enable_nestloop=off; '
            'SET LOCAL enable_material=off; ',
        ]:
            def workload():
                args = [PSQL, '-XAt', '-v', 'ON_ERROR_STOP=1']
                for _ in range(5):
                    args.extend(['-c', 'SELECT 1'])
                args.extend(['-c', 'SELECT pg_stat_force_next_flush()'])
                subprocess.check_output(args, text=True)
            row = self.current(self.sample(workload,
                "BEGIN; SET LOCAL jit=off; SET LOCAL stats_fetch_consistency='snapshot'; "
                + settings + 'SELECT sum(xact_commit) FROM pg_stat_database; '))
            self.assertEqual(row['status'], 'ok')
            self.assertGreaterEqual(row['xact_commit_delta'], 5)
            self.assertGreaterEqual(row['elapsed_seconds'], 1.5)

    def test_full_join_edge_cases(self):
        # Exercise the actual query with controlled snapshots: membership changes
        # cannot normally be induced through pg_database within one MVCC snapshot.
        counters = ('xact_commit xact_rollback blks_read blks_hit tup_returned '
                    'tup_fetched tup_inserted tup_updated tup_deleted temp_files '
                    'temp_bytes deadlocks blk_read_time blk_write_time session_time '
                    'active_time idle_in_transaction_time sessions').split()
        columns = ['datid', 'datname', 'numbackends', 'stats_reset'] + counters
        def fixture(rows):
            values = []
            for oid, name, backends, reset, amount in rows:
                fields = [f'{oid}::oid', 'NULL::name' if name is None else f"'{name}'::name",
                          f'{backends}::integer', f'{reset}::timestamptz']
                fields += [f'{amount}::' + ('double precision' if c.endswith('_time') else 'bigint')
                           for c in counters]
                values.append('(' + ','.join(fields) + ')')
            return 'FROM (VALUES ' + ','.join(values) + ') AS d(' + ','.join(columns) + ')'
        before = [(0, None, 0, 'NULL', 10), (90001, 'both', 2, 'NULL', 10),
                  (90002, 'gone', 2, 'NULL', 10),
                  (90004, 'reset', 2, "'2026-01-01 UTC'", 10)]
        after = [(0, None, 0, 'NULL', 15), (90001, 'both', 4, 'NULL', 20),
                 (90003, 'new', 4, 'NULL', 20),
                 (90004, 'reset', 4, "'2026-01-02 UTC'", 30)]
        source = (Path(__file__).resolve().parents[1] / 'sql/pg_stat_database_delta.sql').read_text()
        query = source.split('RETURN QUERY\n', 1)[1].split('\nEND;', 1)[0]
        query = query.replace('FROM pg_stat_database AS d', fixture(before), 1)
        query = query.replace('FROM pg_stat_database AS d', fixture(after), 1)
        query = query.replace('i_delta_seconds::double precision', '0::double precision').rstrip().rstrip(';')
        rows = json.loads(sql('SELECT jsonb_agg(to_jsonb(q)) FROM (' + query + ') q'))
        by_id = {int(r['datid']): r for r in rows}
        self.assertEqual(set(by_id), {0, 90001, 90002, 90003, 90004})
        for oid in [90002, 90003, 90004]:
            self.assertEqual(by_id[oid]['status'], 'reset' if oid == 90004 else 'missing')
            for counter in counters:
                self.assertIsNone(by_id[oid][counter+'_delta'])
            self.assertIsNone(by_id[oid]['num_backends_delta'])
        self.assertEqual(by_id[0]['status'], 'ok')
        self.assertIsNone(by_id[0]['datname'])
        for counter in counters:
            self.assertEqual(by_id[0][counter+'_delta'], 5)
            self.assertEqual(by_id[90001][counter+'_delta'], 10)
        self.assertEqual(by_id[90001]['num_backends_delta'], 2)

    def test_catalog_snapshot(self):
        name = 'delta_test_lifecycle'
        try:
            rows = self.sample(lambda: sql(f'CREATE DATABASE {name}'))
            # One SQL statement retains its original catalog snapshot.
            self.assertFalse(any(r['datname'] == name for r in rows))
            oid = sql(f"SELECT oid FROM pg_database WHERE datname='{name}'")
            rows = self.sample(lambda: sql(f'ALTER DATABASE {name} RENAME TO {name}_renamed'))
            row = next(r for r in rows if r['datid'] == oid)
            self.assertEqual(row['datname'], name)
            self.assertEqual(row['status'], 'ok')
            rows = self.sample(lambda: sql(f'DROP DATABASE {name}_renamed'))
            row = next(r for r in rows if r['datid'] == oid)
            self.assertEqual(row['datname'], name + '_renamed')
            # Its catalog row remains visible, but its statistics may disappear.
            self.assertIn(row['status'], ['ok', 'reset'])
        finally:
            sql(f'DROP DATABASE IF EXISTS {name}')
            sql(f'DROP DATABASE IF EXISTS {name}_renamed')

    def test_schema_and_invoker(self):
        sql('CREATE SCHEMA delta_test_schema; '
            'CREATE ROLE delta_test_reader; '
            'GRANT USAGE ON SCHEMA delta_test_schema TO delta_test_reader; '
            'ALTER EXTENSION pg_stat_delta SET SCHEMA delta_test_schema;')
        try:
            result = sql('SET ROLE delta_test_reader; '
                         "SET search_path = ''; "
                         'SELECT count(*)>0 FROM delta_test_schema.pg_stat_database_delta(0); '
                         'SELECT count(*)>=0 FROM delta_test_schema.pg_stat_user_tables_delta(0); '
                         'SELECT count(*)>=0 FROM delta_test_schema.pg_stat_user_indexes_delta(0); '
                         'SELECT count(*)>=0 FROM delta_test_schema.pg_statio_user_tables_delta(0); '
                         'SELECT count(*)>=0 FROM delta_test_schema.pg_statio_user_indexes_delta(0);')
            self.assertEqual(result.splitlines()[-1], 't')
        finally:
            sql('ALTER EXTENSION pg_stat_delta SET SCHEMA public; '
                'DROP SCHEMA delta_test_schema; DROP ROLE delta_test_reader;')

    def test_repeated_calls(self):
        result = sql('BEGIN; '
                     "SET LOCAL stats_fetch_consistency='snapshot'; "
                     'SELECT count(*)>0 FROM pg_stat_database_delta(0); '
                     'SELECT count(*)>0 FROM pg_stat_database_delta(0); COMMIT;')
        self.assertEqual(result.splitlines().count('t'), 2)


class TableDeltaTests(unittest.TestCase):
    sample = DeltaTests.sample

    @classmethod
    def setUpClass(cls):
        sql('CREATE SCHEMA delta_table_tests; '
            'CREATE TABLE delta_table_tests.heap(id integer, payload integer) '
            'WITH (autovacuum_enabled=false); '
            'CREATE TABLE delta_table_tests.indexed(id integer PRIMARY KEY) '
            'WITH (autovacuum_enabled=false); '
            'INSERT INTO delta_table_tests.indexed SELECT generate_series(1,1000); '
            'SELECT pg_stat_force_next_flush();')

    @classmethod
    def tearDownClass(cls):
        sql('DROP SCHEMA delta_table_tests CASCADE')

    def table_sample(self, action, table='heap', prefix=''):
        rows = self.sample(action, prefix, 'pg_stat_user_tables_delta',
                           f"schemaname='delta_table_tests' AND relname='{table}'")
        self.assertEqual(len(rows), 1)
        self.assertGreaterEqual(rows[0]['elapsed_seconds'], 1.5)
        return rows[0]

    def test_dml_and_cache_modes(self):
        for number, mode in enumerate(['none', 'cache', 'snapshot']):
            base = 10000 + number * 100
            row = self.table_sample(
                lambda: sql(f'INSERT INTO delta_table_tests.heap '
                            f'SELECT i,0 FROM generate_series({base},{base+99}) i; '
                            f'UPDATE delta_table_tests.heap SET payload=1 '
                            f'WHERE id BETWEEN {base} AND {base+9}; '
                            f'DELETE FROM delta_table_tests.heap '
                            f'WHERE id BETWEEN {base+95} AND {base+99}; '
                            'SELECT pg_stat_force_next_flush();'),
                prefix=f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; "
                       'SELECT sum(n_tup_ins) FROM pg_stat_user_tables; ')
            self.assertEqual(row['status'], 'ok')
            self.assertEqual(row['n_tup_ins_delta'], 100)
            self.assertEqual(row['n_tup_upd_delta'], 10)
            self.assertEqual(row['n_tup_del_delta'], 5)
            self.assertGreater(row['seq_scan_delta'], 0)
            self.assertIsNone(row['idx_scan_delta'])
            self.assertIsNone(row['idx_tup_fetch_delta'])

    def test_index_scan(self):
        row = self.table_sample(
            lambda: sql('SET enable_seqscan=off; '
                        'SELECT sum(id) FROM delta_table_tests.indexed WHERE id BETWEEN 1 AND 50; '
                        'SELECT pg_stat_force_next_flush();'), table='indexed')
        self.assertEqual(row['status'], 'ok')
        self.assertGreater(row['idx_scan_delta'], 0)

    def test_maintenance_gauges(self):
        sql('INSERT INTO delta_table_tests.heap VALUES (90000,0); '
            'SELECT pg_stat_force_next_flush();')
        row = self.table_sample(lambda: sql('ANALYZE delta_table_tests.heap'))
        self.assertEqual(row['status'], 'ok')
        self.assertEqual(row['n_mod_since_analyze'], 0)
        self.assertGreaterEqual(row['n_live_tup'], 1)
        self.assertIsNotNone(row['last_analyze'])
        self.assertNotIn('analyze_count_delta', row)

    def test_table_reset(self):
        sql('INSERT INTO delta_table_tests.heap VALUES (90001,0); '
            'SELECT pg_stat_force_next_flush();')
        row = self.table_sample(lambda: sql(
            "SELECT pg_stat_reset_single_table_counters('delta_table_tests.heap'::regclass)"))
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['n_tup_ins_delta'])
        self.assertIsNone(row['seq_scan_delta'])

    def test_reset_with_counters_catching_up(self):
        sql('CREATE TABLE delta_table_tests.reset_catchup(id integer) '
            'WITH (autovacuum_enabled=false); '
            'INSERT INTO delta_table_tests.reset_catchup SELECT generate_series(1,10); '
            'SELECT pg_stat_force_next_flush();')
        row = self.table_sample(lambda: sql(
            "SELECT pg_stat_reset_single_table_counters('delta_table_tests.reset_catchup'::regclass); "
            'INSERT INTO delta_table_tests.reset_catchup SELECT generate_series(11,30); '
            'SELECT pg_stat_force_next_flush();'), table='reset_catchup')
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['n_tup_ins_delta'])
        self.assertGreaterEqual(row['n_live_tup'], 20)
        self.assertNotIn('database_stats_reset_start', row)
        self.assertNotIn('n_live_tup_start', row)

    def test_dropped_table_statistics(self):
        sql('CREATE TABLE delta_table_tests.dropped(id integer); '
            'INSERT INTO delta_table_tests.dropped SELECT generate_series(1,10); '
            'SELECT pg_stat_force_next_flush();')
        row = self.table_sample(lambda: sql('DROP TABLE delta_table_tests.dropped'), table='dropped')
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['n_tup_ins_delta'])

    def test_database_reset(self):
        row = self.table_sample(lambda: sql('SELECT pg_stat_reset()'))
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['n_tup_ins_delta'])
        self.assertIsNone(row['seq_scan_delta'])

    def test_validation_and_repeated_calls(self):
        for value in ['NULL', '-1', "'NaN'", "'Infinity'", "'-Infinity'"]:
            result = subprocess.run([PSQL, '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                                     f'SELECT * FROM pg_stat_user_tables_delta({value})'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('finite nonnegative', result.stderr)
        result = sql('BEGIN; '
                     "SET LOCAL stats_fetch_consistency='snapshot'; "
                     'SELECT count(*)>0 FROM pg_stat_user_tables_delta(0); '
                     'SELECT count(*)>0 FROM pg_stat_user_tables_delta(0); COMMIT;')
        self.assertEqual(result.splitlines().count('t'), 2)

    def test_alternative_join_plans(self):
        for number, settings in enumerate([
            'SET LOCAL enable_hashjoin=off; SET LOCAL join_collapse_limit=1; '
            'SET LOCAL from_collapse_limit=1; ',
            'SET LOCAL enable_mergejoin=off; SET LOCAL enable_nestloop=off; '
            'SET LOCAL enable_material=off; ',
        ]):
            row = self.table_sample(lambda: sql(
                f'INSERT INTO delta_table_tests.heap VALUES ({110000+number},0); '
                'SELECT pg_stat_force_next_flush();'),
                prefix="BEGIN; SET LOCAL jit=off; SET LOCAL stats_fetch_consistency='snapshot'; "
                       + settings + 'SELECT sum(n_tup_ins) FROM pg_stat_user_tables; ')
            self.assertEqual(row['status'], 'ok')
            self.assertEqual(row['n_tup_ins_delta'], 1)

    def test_full_join_edge_cases(self):
        counters = ('seq_scan seq_tup_read idx_scan idx_tup_fetch n_tup_ins '
                    'n_tup_upd n_tup_del n_tup_hot_upd n_tup_newpage_upd').split()
        gauges = 'n_live_tup n_dead_tup n_mod_since_analyze n_ins_since_vacuum'.split()
        times = 'last_vacuum last_autovacuum last_analyze last_autoanalyze'.split()
        columns = ['relid', 'schemaname', 'relname'] + counters + gauges + times
        def fixture(rows, day):
            values = []
            for oid, amount, gauge, inserted in rows:
                fields = [f'{oid}::oid', "'fixture'::name", f"'t{oid}'::name"]
                fields += ['NULL::bigint' if c.startswith('idx_') else
                           f'{inserted if c == "n_tup_ins" else amount}::bigint' for c in counters]
                fields += [f'{gauge}::bigint' for _ in gauges]
                fields += [f"'2026-01-0{day} UTC'::timestamptz" for _ in times]
                values.append('(' + ','.join(fields) + ')')
            return 'FROM (VALUES ' + ','.join(values) + ') AS t(' + ','.join(columns) + ')'
        before = [(90001,10,100,10), (90002,10,100,10),
                  (90004,10,100,20), (90005,10,100,10)]
        after = [(90001,20,200,20), (90003,20,200,20),
                 (90004,20,200,10), (90005,10,0,10)]
        source = (Path(__file__).resolve().parents[1] / 'sql/pg_stat_user_tables_delta.sql').read_text()
        query = source.split('RETURN QUERY\n', 1)[1].split('\nEND;', 1)[0]
        query = query.replace('FROM pg_stat_user_tables AS t', fixture(before, 1), 1)
        query = query.replace('FROM pg_stat_user_tables AS t', fixture(after, 2), 1)
        query = query.replace('i_delta_seconds::double precision', '0::double precision').rstrip().rstrip(';')
        rows = json.loads(sql('SELECT jsonb_agg(to_jsonb(q)) FROM (' + query + ') q'))
        by_id = {int(r['relid']): r for r in rows}
        self.assertEqual(set(by_id), {90001, 90002, 90003, 90004, 90005})
        for oid in [90002,90003,90004]:
            self.assertEqual(by_id[oid]['status'], 'reset' if oid == 90004 else 'missing')
            for c in counters:
                self.assertIsNone(by_id[oid][c+'_delta'])
        for oid in [90001,90005]:
            self.assertEqual(by_id[oid]['status'], 'ok')
            for c in counters:
                expected = None if c.startswith('idx_') else (10 if oid == 90001 else 0)
                self.assertEqual(by_id[oid][c+'_delta'], expected)
        for g in gauges:
            self.assertIsNone(by_id[90002][g])
            self.assertEqual(by_id[90003][g], 200)
            self.assertEqual(by_id[90005][g], 0)
        self.assertTrue(by_id[90005]['last_analyze'].startswith('2026-01-02'))

    def test_catalog_snapshot(self):
        sql('CREATE TABLE delta_table_tests.before_rename(id integer)')
        try:
            rows = self.sample(
                lambda: sql('ALTER TABLE delta_table_tests.before_rename RENAME TO after_rename; '
                            'CREATE TABLE delta_table_tests.created_during_sample(id integer)'),
                function='pg_stat_user_tables_delta')
            names = [r['relname'] for r in rows if r['schemaname'] == 'delta_table_tests']
            self.assertIn('before_rename', names)
            self.assertNotIn('after_rename', names)
            self.assertNotIn('created_during_sample', names)
        finally:
            sql('DROP TABLE IF EXISTS delta_table_tests.before_rename, '
                'delta_table_tests.after_rename, delta_table_tests.created_during_sample')


class IndexDeltaTests(unittest.TestCase):
    sample = DeltaTests.sample

    @classmethod
    def setUpClass(cls):
        sql('CREATE SCHEMA delta_index_tests; '
            'CREATE TABLE delta_index_tests.items(id integer PRIMARY KEY, payload integer) '
            'WITH (autovacuum_enabled=false); '
            'INSERT INTO delta_index_tests.items SELECT i,i FROM generate_series(1,10000) i; '
            'SELECT pg_stat_force_next_flush();')

    @classmethod
    def tearDownClass(cls):
        sql('DROP SCHEMA delta_index_tests CASCADE')

    def index_sample(self, action, index='items_pkey', prefix=''):
        rows = self.sample(action, prefix, 'pg_stat_user_indexes_delta',
                           f"schemaname='delta_index_tests' AND indexrelname='{index}'")
        self.assertEqual(len(rows), 1)
        self.assertGreaterEqual(rows[0]['elapsed_seconds'], 1.5)
        return rows[0]

    def test_plain_scan_and_cache_modes(self):
        settings = 'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
        query = 'SELECT sum(payload) FROM delta_index_tests.items WHERE id BETWEEN 1 AND 50; '
        self.assertIn('Index Scan', sql(settings + 'EXPLAIN ' + query))
        for mode in ['none', 'cache', 'snapshot']:
            row = self.index_sample(
                lambda: sql(settings + query + 'SELECT pg_stat_force_next_flush();'),
                prefix=f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; "
                       'SELECT sum(idx_scan) FROM pg_stat_user_indexes; ')
            self.assertEqual(row['status'], 'ok')
            self.assertGreaterEqual(row['idx_scan_delta'], 1)
            # Planning can also read boundary index tuples for selectivity estimates.
            self.assertGreaterEqual(row['idx_tup_read_delta'], 50)
            self.assertEqual(row['idx_tup_fetch_delta'], 50)
            self.assertIsNotNone(row['last_idx_scan_end'])

    def test_bitmap_scan(self):
        settings = ('SET enable_seqscan=off; SET enable_indexscan=off; '
                    'SET enable_indexonlyscan=off; SET enable_bitmapscan=on; ')
        query = 'SELECT sum(payload) FROM delta_index_tests.items WHERE id BETWEEN 1 AND 50; '
        self.assertIn('Bitmap Heap Scan', sql(settings + 'EXPLAIN ' + query))
        row = self.index_sample(lambda: sql(settings + query + 'SELECT pg_stat_force_next_flush();'))
        self.assertEqual(row['status'], 'ok')
        self.assertGreaterEqual(row['idx_scan_delta'], 1)
        # Returned index entries can include the planner's boundary-value probes.
        self.assertGreaterEqual(row['idx_tup_read_delta'], 50)
        self.assertEqual(row['idx_tup_fetch_delta'], 0)

    def test_index_only_scan(self):
        sql('VACUUM ANALYZE delta_index_tests.items')
        settings = 'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=on; '
        query = 'SELECT sum(id) FROM delta_index_tests.items WHERE id BETWEEN 1 AND 50; '
        self.assertIn('Index Only Scan', sql(settings + 'EXPLAIN ' + query))
        row = self.index_sample(lambda: sql(settings + query + 'SELECT pg_stat_force_next_flush();'))
        self.assertEqual(row['status'], 'ok')
        self.assertGreaterEqual(row['idx_scan_delta'], 1)
        # Returned index entries can include the planner's boundary-value probes.
        self.assertGreaterEqual(row['idx_tup_read_delta'], 50)
        self.assertEqual(row['idx_tup_fetch_delta'], 0)

    def test_separate_indexes_on_same_table(self):
        sql('CREATE INDEX payload_idx ON delta_index_tests.items(payload)')
        try:
            rows = self.sample(lambda: sql(
                'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
                'SELECT sum(payload) FROM delta_index_tests.items WHERE id BETWEEN 1 AND 50; '
                'SELECT pg_stat_force_next_flush();'),
                function='pg_stat_user_indexes_delta', condition="schemaname='delta_index_tests'")
            by_name = {r['indexrelname']: r for r in rows}
            active, idle = by_name['items_pkey'], by_name['payload_idx']
            self.assertEqual(active['relid'], idle['relid'])
            self.assertNotEqual(active['indexrelid'], idle['indexrelid'])
            self.assertEqual(active['status'], 'ok')
            self.assertEqual(idle['status'], 'ok')
            self.assertGreaterEqual(active['idx_tup_read_delta'], 50)
            self.assertEqual(idle['idx_scan_delta'], 0)
            self.assertEqual(idle['idx_tup_read_delta'], 0)
        finally:
            sql('DROP INDEX delta_index_tests.payload_idx')

    def test_index_reset(self):
        row = self.index_sample(lambda: sql(
            "SELECT pg_stat_reset_single_table_counters('delta_index_tests.items_pkey'::regclass)"))
        self.assertEqual(row['status'], 'reset')
        for counter in ['idx_scan_delta', 'idx_tup_read_delta', 'idx_tup_fetch_delta']:
            self.assertIsNone(row[counter])

    def test_reset_with_counters_catching_up(self):
        settings = 'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
        query = 'SELECT sum(payload) FROM delta_index_tests.items WHERE id BETWEEN 1 AND 50; '
        # Establish a known baseline, then exceed it after an explicit index reset.
        sql("SELECT pg_stat_reset_single_table_counters('delta_index_tests.items_pkey'::regclass)")
        sql(settings + query + 'SELECT pg_stat_force_next_flush();')
        row = self.index_sample(lambda: sql(
            "SELECT pg_stat_reset_single_table_counters('delta_index_tests.items_pkey'::regclass); "
            + settings + query * 3 + 'SELECT pg_stat_force_next_flush();'))
        self.assertEqual(row['status'], 'reset')
        for field in ['idx_scan_delta', 'idx_tup_read_delta', 'idx_tup_fetch_delta']:
            self.assertIsNone(row[field])

    def test_database_reset(self):
        row = self.index_sample(lambda: sql('SELECT pg_stat_reset()'))
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['idx_scan_delta'])

    def test_alternative_join_plans(self):
        for settings in [
            'SET LOCAL enable_hashjoin=off; SET LOCAL join_collapse_limit=1; '
            'SET LOCAL from_collapse_limit=1; ',
            'SET LOCAL enable_mergejoin=off; SET LOCAL enable_nestloop=off; '
            'SET LOCAL enable_material=off; ',
        ]:
            row = self.index_sample(lambda: sql(
                'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
                'SELECT sum(payload) FROM delta_index_tests.items WHERE id BETWEEN 1 AND 50; '
                'SELECT pg_stat_force_next_flush();'),
                prefix="BEGIN; SET LOCAL jit=off; SET LOCAL stats_fetch_consistency='snapshot'; "
                       + settings + 'SELECT sum(idx_scan) FROM pg_stat_user_indexes; ')
            self.assertEqual(row['status'], 'ok')
            self.assertGreaterEqual(row['idx_scan_delta'], 1)
            self.assertGreaterEqual(row['idx_tup_read_delta'], 50)
            self.assertEqual(row['idx_tup_fetch_delta'], 50)

    def test_full_join_edge_cases(self):
        counters = ['idx_scan', 'idx_tup_read', 'idx_tup_fetch']
        columns = ['relid','indexrelid','schemaname','relname','indexrelname'] + counters + ['last_idx_scan']
        def fixture(rows, day):
            values = []
            for oid, amounts in rows:
                # Every index belongs to the same table: joining on relid is wrong.
                fields = ['90000::oid',f'{oid}::oid',"'fixture'::name","'t'::name",f"'idx{oid}'::name"]
                fields += [f'{n}::bigint' for n in amounts]
                fields += [f"'2026-01-0{day} UTC'::timestamptz"]
                values.append('(' + ','.join(fields) + ')')
            return 'FROM (VALUES ' + ','.join(values) + ') AS i(' + ','.join(columns) + ')'
        before = [(90101,(10,100,90)),(90102,(20,200,180)),(90103,(10,100,90))]
        after = [(90101,(20,200,180)),(90102,(21,190,181)),(90104,(10,100,90))]
        source = (Path(__file__).resolve().parents[1] / 'sql/pg_stat_user_indexes_delta.sql').read_text()
        query = source.split('RETURN QUERY\n',1)[1].split('\nEND;',1)[0]
        query = query.replace('FROM pg_stat_user_indexes AS i',fixture(before,1),1)
        query = query.replace('FROM pg_stat_user_indexes AS i',fixture(after,2),1)
        query = query.replace('i_delta_seconds::double precision','0::double precision').rstrip().rstrip(';')
        rows = json.loads(sql('SELECT jsonb_agg(to_jsonb(q)) FROM (' + query + ') q'))
        by_id = {int(r['indexrelid']):r for r in rows}
        self.assertEqual(len(rows),4)
        self.assertEqual(set(by_id),{90101,90102,90103,90104})
        for oid in [90102,90103,90104]:
            self.assertEqual(by_id[oid]['status'],'reset' if oid==90102 else 'missing')
            for counter in counters:
                self.assertIsNone(by_id[oid][counter+'_delta'])
        self.assertEqual(by_id[90101]['status'],'ok')
        self.assertEqual([by_id[90101][c+'_delta'] for c in counters],[10,100,90])
        self.assertTrue(by_id[90101]['last_idx_scan_end'].startswith('2026-01-02'))
        self.assertIsNone(by_id[90103]['last_idx_scan_end'])
        self.assertTrue(by_id[90104]['last_idx_scan_end'].startswith('2026-01-02'))
        self.assertNotIn('database_stats_reset_start',by_id[90101])
        self.assertNotIn('database_stats_reset_end',by_id[90101])

    def test_catalog_snapshot(self):
        try:
            rows = self.sample(lambda: sql(
                'ALTER INDEX delta_index_tests.items_pkey RENAME TO renamed_pkey; '
                'CREATE INDEX created_during_sample ON delta_index_tests.items(payload)'),
                function='pg_stat_user_indexes_delta')
            names = [r['indexrelname'] for r in rows if r['schemaname']=='delta_index_tests']
            self.assertIn('items_pkey', names)
            self.assertNotIn('renamed_pkey', names)
            self.assertNotIn('created_during_sample', names)
        finally:
            sql('DROP INDEX IF EXISTS delta_index_tests.created_during_sample; '
                'ALTER INDEX delta_index_tests.renamed_pkey RENAME TO items_pkey;')

    def test_dropped_index(self):
        sql('CREATE TABLE delta_index_tests.dropped(id integer, payload integer) '
            'WITH (autovacuum_enabled=false); '
            'CREATE INDEX dropped_idx ON delta_index_tests.dropped(id); '
            'INSERT INTO delta_index_tests.dropped SELECT i,i FROM generate_series(1,100) i; '
            'SET enable_seqscan=off; SET enable_bitmapscan=off; '
            'SELECT sum(payload) FROM delta_index_tests.dropped WHERE id<=50; '
            'SELECT pg_stat_force_next_flush();')
        row = self.index_sample(lambda: sql('DROP INDEX delta_index_tests.dropped_idx'),
                                index='dropped_idx')
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['idx_scan_delta'])

    def test_validation_and_repeated_calls(self):
        for value in ['NULL', '-1', "'NaN'", "'Infinity'", "'-Infinity'"]:
            result = subprocess.run([PSQL, '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                                     f'SELECT * FROM pg_stat_user_indexes_delta({value})'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('finite nonnegative', result.stderr)
        result = sql('BEGIN; '
                     "SET LOCAL stats_fetch_consistency='snapshot'; "
                     'SELECT count(*)>0 FROM pg_stat_user_indexes_delta(0); '
                     'SELECT count(*)>0 FROM pg_stat_user_indexes_delta(0); COMMIT;')
        self.assertEqual(result.splitlines().count('t'), 2)


class StatioDeltaTests(unittest.TestCase):
    sample = DeltaTests.sample
    counters = ['heap_blks_read', 'heap_blks_hit', 'idx_blks_read', 'idx_blks_hit',
                'toast_blks_read', 'toast_blks_hit', 'tidx_blks_read', 'tidx_blks_hit']

    @classmethod
    def setUpClass(cls):
        sql('CREATE SCHEMA delta_statio_tests; '
            'CREATE TABLE delta_statio_tests.heap(id integer, payload integer) '
            'WITH (autovacuum_enabled=false); '
            'CREATE TABLE delta_statio_tests.indexed(id integer PRIMARY KEY, payload integer) '
            'WITH (autovacuum_enabled=false); '
            'CREATE TABLE delta_statio_tests.toasted(id integer PRIMARY KEY, payload text) '
            'WITH (autovacuum_enabled=false, toast.autovacuum_enabled=false); '
            'ALTER TABLE delta_statio_tests.toasted ALTER COLUMN payload SET STORAGE EXTERNAL; '
            'INSERT INTO delta_statio_tests.heap SELECT i,i FROM generate_series(1,1000) i; '
            'INSERT INTO delta_statio_tests.indexed SELECT i,i FROM generate_series(1,1000) i; '
            'INSERT INTO delta_statio_tests.toasted SELECT i,repeat(md5(i::text),500) '
            'FROM generate_series(1,20) i; SELECT pg_stat_force_next_flush();')

    @classmethod
    def tearDownClass(cls):
        sql('DROP SCHEMA delta_statio_tests CASCADE')

    def io_sample(self, action, table='heap', prefix=''):
        rows = self.sample(action, prefix, 'pg_statio_user_tables_delta',
                           f"schemaname='delta_statio_tests' AND relname='{table}'")
        self.assertEqual(len(rows), 1)
        self.assertGreaterEqual(rows[0]['elapsed_seconds'], 1.5)
        return rows[0]

    def test_heap_and_cache_modes(self):
        for mode in ['none', 'cache', 'snapshot']:
            row = self.io_sample(lambda: sql(
                'SELECT sum(payload) FROM delta_statio_tests.heap; '
                'SELECT pg_stat_force_next_flush();'),
                prefix=f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; "
                       'SELECT sum(heap_blks_hit) FROM pg_statio_user_tables; ')
            self.assertEqual(row['status'], 'ok')
            self.assertGreater(row['heap_blks_hit_delta'], 0)
            self.assertGreaterEqual(row['heap_blks_read_delta'], 0)
            for name in ['idx_blks_read', 'idx_blks_hit', 'toast_blks_read',
                         'toast_blks_hit', 'tidx_blks_read', 'tidx_blks_hit']:
                self.assertIsNone(row[name+'_delta'])

    def test_index_io(self):
        row = self.io_sample(lambda: sql(
            'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
            'SELECT sum(payload) FROM delta_statio_tests.indexed WHERE id BETWEEN 1 AND 50; '
            'SELECT pg_stat_force_next_flush();'), table='indexed')
        self.assertEqual(row['status'], 'ok')
        self.assertGreater(row['idx_blks_hit_delta'], 0)
        self.assertGreater(row['heap_blks_hit_delta'], 0)

    def test_toast_io(self):
        # md5 forces payload access; length alone can use external-value metadata.
        row = self.io_sample(lambda: sql(
            'SELECT md5(payload) FROM delta_statio_tests.toasted; '
            'SELECT pg_stat_force_next_flush();'), table='toasted')
        self.assertEqual(row['status'], 'ok')
        self.assertGreater(row['toast_blks_hit_delta'], 0)
        self.assertGreater(row['tidx_blks_hit_delta'], 0)

    def test_table_reset(self):
        row = self.io_sample(lambda: sql(
            "SELECT pg_stat_reset_single_table_counters('delta_statio_tests.heap'::regclass)"))
        self.assertEqual(row['status'], 'reset')
        for name in self.counters:
            self.assertIsNone(row[name+'_delta'])

    def test_index_reset(self):
        row = self.io_sample(lambda: sql(
            "SELECT pg_stat_reset_single_table_counters('delta_statio_tests.indexed_pkey'::regclass)"),
            table='indexed')
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['idx_blks_hit_delta'])

    def test_reset_with_io_counters_catching_up(self):
        reset = "SELECT pg_stat_reset_single_table_counters('delta_statio_tests.indexed_pkey'::regclass); "
        settings = 'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
        query = 'SELECT sum(payload) FROM delta_statio_tests.indexed WHERE id BETWEEN 1 AND 50; '
        sql(reset)
        sql(settings + query + 'SELECT pg_stat_force_next_flush();')
        row = self.io_sample(lambda: sql(reset + settings + query * 5 +
                             'SELECT pg_stat_force_next_flush();'), table='indexed')
        self.assertEqual(row['status'], 'reset')
        for counter in self.counters:
            self.assertIsNone(row[counter+'_delta'])

    def test_database_reset(self):
        row = self.io_sample(lambda: sql('SELECT pg_stat_reset()'))
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['heap_blks_hit_delta'])

    def test_alternative_join_plans(self):
        for settings in [
            'SET LOCAL enable_hashjoin=off; SET LOCAL join_collapse_limit=1; '
            'SET LOCAL from_collapse_limit=1; ',
            'SET LOCAL enable_mergejoin=off; SET LOCAL enable_nestloop=off; '
            'SET LOCAL enable_material=off; ',
        ]:
            row = self.io_sample(lambda: sql(
                'SELECT sum(payload) FROM delta_statio_tests.heap; '
                'SELECT pg_stat_force_next_flush();'),
                prefix="BEGIN; SET LOCAL jit=off; SET LOCAL stats_fetch_consistency='snapshot'; "
                       + settings + 'SELECT sum(heap_blks_hit) FROM pg_statio_user_tables; ')
            self.assertEqual(row['status'],'ok')
            self.assertGreater(row['heap_blks_hit_delta'],0)

    def test_full_join_edge_cases(self):
        columns = ['relid','schemaname','relname'] + self.counters
        def fixture(rows):
            values=[]
            for oid, amounts in rows:
                fields=[f'{oid}::oid',"'fixture'::name",f"'t{oid}'::name"]
                fields+=['NULL::bigint' if n is None else f'{n}::bigint' for n in amounts]
                values.append('(' + ','.join(fields) + ')')
            return 'FROM (VALUES ' + ','.join(values) + ') AS t(' + ','.join(columns) + ')'
        before=[(90001,(5,100,None,None,None,None,None,None)),
                (90002,(10,)*8),(90004,(0,)*8),
                (90005,(5,100,0,200,0,0,0,0)),(90006,(10,)*8)]
        after=[(90001,(5,110,None,None,None,None,None,None)),
               (90003,(20,)*8),(90004,(0,)*8),
               (90005,(5,110,0,190,0,0,0,0)),(90006,(20,)*8)]
        source=(Path(__file__).resolve().parents[1] / 'sql/pg_statio_user_tables_delta.sql').read_text()
        query=source.split('RETURN QUERY\n',1)[1].split('\nEND;',1)[0]
        query=query.replace('FROM pg_statio_user_tables AS t',fixture(before),1)
        query=query.replace('FROM pg_statio_user_tables AS t',fixture(after),1)
        query=query.replace('i_delta_seconds::double precision','0::double precision').rstrip().rstrip(';')
        marker='pg_stat_get_db_stat_reset_time((SELECT id FROM database_id))'
        def run(reset):
            q=query.replace(marker,"'2026-01-01 UTC'::timestamptz",1)
            q=q.replace(marker,f"'2026-01-0{2 if reset else 1} UTC'::timestamptz",1)
            rows=json.loads(sql('SELECT jsonb_agg(to_jsonb(q)) FROM (' + q + ') q'))
            return {int(r['relid']):r for r in rows}
        rows=run(False)
        self.assertEqual(set(rows),{90001,90002,90003,90004,90005,90006})
        for oid,status in [(90002,'missing'),(90003,'missing'),(90005,'counter_decreased')]:
            self.assertEqual(rows[oid]['status'],status)
            for c in self.counters:
                self.assertIsNone(rows[oid][c+'_delta'])
        for oid in [90001,90004,90006]:
            self.assertEqual(rows[oid]['status'],'ok')
        self.assertEqual([rows[90001][c+'_delta'] for c in self.counters],
                         [0,10,None,None,None,None,None,None])
        self.assertEqual([rows[90004][c+'_delta'] for c in self.counters],[0]*8)
        self.assertEqual([rows[90006][c+'_delta'] for c in self.counters],[10]*8)
        # Reset markers invalidate even unchanged zero counters and caught-up values.
        reset_rows=run(True)
        for oid,row in reset_rows.items():
            self.assertEqual(row['status'],'missing' if oid in [90002,90003] else 'reset')
            for c in self.counters:
                self.assertIsNone(row[c+'_delta'])
        self.assertNotIn('database_stats_reset_start',rows[90001])
        self.assertNotIn('database_stats_reset_end',rows[90001])

    def test_catalog_snapshot_and_drop(self):
        sql('CREATE TABLE delta_statio_tests.before_rename(id integer) '
            'WITH (autovacuum_enabled=false); '
            'INSERT INTO delta_statio_tests.before_rename SELECT generate_series(1,10); '
            'SELECT sum(id) FROM delta_statio_tests.before_rename; '
            'SELECT pg_stat_force_next_flush();')
        try:
            rows = self.sample(lambda: sql(
                'ALTER TABLE delta_statio_tests.before_rename RENAME TO after_rename; '
                'CREATE TABLE delta_statio_tests.created_during_sample(id integer)'),
                function='pg_statio_user_tables_delta')
            names = [r['relname'] for r in rows if r['schemaname']=='delta_statio_tests']
            self.assertIn('before_rename', names)
            self.assertNotIn('after_rename', names)
            self.assertNotIn('created_during_sample', names)
            row = self.io_sample(lambda: sql('DROP TABLE delta_statio_tests.after_rename'),
                                 table='after_rename')
            self.assertEqual(row['status'], 'counter_decreased')
            self.assertIsNone(row['heap_blks_hit_delta'])
        finally:
            sql('DROP TABLE IF EXISTS delta_statio_tests.before_rename, '
                'delta_statio_tests.after_rename, delta_statio_tests.created_during_sample')

    def test_user_scope_validation_and_repeat(self):
        self.assertEqual(sql("SELECT count(*)>0 FROM pg_statio_user_tables_delta(0) "
                             "WHERE schemaname='pg_catalog'"), 'f')
        self.assertEqual(sql("SELECT count(*)>0 FROM pg_statio_user_tables_delta(0) "
                             "WHERE schemaname='pg_toast'"), 'f')
        for value in ['NULL', '-1', "'NaN'", "'Infinity'", "'-Infinity'"]:
            result = subprocess.run([PSQL, '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                                     f'SELECT * FROM pg_statio_user_tables_delta({value})'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('finite nonnegative', result.stderr)
        result = sql('BEGIN; '
                     "SET LOCAL stats_fetch_consistency='snapshot'; "
                     'SELECT count(*)>0 FROM pg_statio_user_tables_delta(0); '
                     'SELECT count(*)>0 FROM pg_statio_user_tables_delta(0); COMMIT;')
        self.assertEqual(result.splitlines().count('t'), 2)


class IndexIODeltaTests(unittest.TestCase):
    sample = DeltaTests.sample

    @classmethod
    def setUpClass(cls):
        sql('CREATE SCHEMA delta_index_io_tests; '
            'CREATE TABLE delta_index_io_tests.items(id integer PRIMARY KEY, payload integer) '
            'WITH (autovacuum_enabled=false); '
            'INSERT INTO delta_index_io_tests.items SELECT i,i FROM generate_series(1,1000) i; '
            'SELECT pg_stat_force_next_flush();')

    @classmethod
    def tearDownClass(cls):
        sql('DROP SCHEMA delta_index_io_tests CASCADE')

    def io_sample(self, action, index='items_pkey', prefix=''):
        rows = self.sample(action, prefix, 'pg_statio_user_indexes_delta',
                           f"schemaname='delta_index_io_tests' AND indexrelname='{index}'")
        self.assertEqual(len(rows), 1)
        self.assertGreaterEqual(rows[0]['elapsed_seconds'], 1.5)
        return rows[0]

    def test_hits_and_cache_modes(self):
        for mode in ['none', 'cache', 'snapshot']:
            row = self.io_sample(lambda: sql(
                'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
                'SELECT sum(payload) FROM delta_index_io_tests.items WHERE id BETWEEN 1 AND 50; '
                'SELECT pg_stat_force_next_flush();'),
                prefix=f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; "
                       'SELECT sum(idx_blks_hit) FROM pg_statio_user_indexes; ')
            self.assertEqual(row['status'], 'ok')
            self.assertGreater(row['idx_blks_hit_delta'], 0)
            self.assertGreaterEqual(row['idx_blks_read_delta'], 0)

    def test_separate_indexes(self):
        sql('CREATE INDEX payload_idx ON delta_index_io_tests.items(payload)')
        query = 'SELECT sum(payload) FROM delta_index_io_tests.items WHERE id BETWEEN 1 AND 50; '
        try:
            rows = self.sample(lambda: sql(
                'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
                + query * 10 + 'SELECT pg_stat_force_next_flush();'),
                function='pg_statio_user_indexes_delta', condition="schemaname='delta_index_io_tests'")
            by_name = {r['indexrelname']: r for r in rows}
            active, idle = by_name['items_pkey'], by_name['payload_idx']
            self.assertEqual(active['relid'], idle['relid'])
            self.assertNotEqual(active['indexrelid'], idle['indexrelid'])
            self.assertEqual(active['status'], 'ok')
            self.assertEqual(idle['status'], 'ok')
            self.assertGreater(active['idx_blks_hit_delta'], 0)
            # The planner can access metadata pages of an unused index too.
            self.assertGreaterEqual(idle['idx_blks_read_delta'], 0)
            self.assertGreaterEqual(idle['idx_blks_hit_delta'], 0)
            self.assertGreater(active['idx_blks_hit_delta'], idle['idx_blks_hit_delta'])
        finally:
            sql('DROP INDEX delta_index_io_tests.payload_idx')

    def test_index_reset(self):
        row = self.io_sample(lambda: sql(
            "SELECT pg_stat_reset_single_table_counters('delta_index_io_tests.items_pkey'::regclass)"))
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['idx_blks_read_delta'])
        self.assertIsNone(row['idx_blks_hit_delta'])

    def test_reset_with_io_counters_catching_up(self):
        reset = "SELECT pg_stat_reset_single_table_counters('delta_index_io_tests.items_pkey'::regclass); "
        settings = 'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
        query = 'SELECT sum(payload) FROM delta_index_io_tests.items WHERE id BETWEEN 1 AND 50; '
        sql(reset)
        sql(settings + query + 'SELECT pg_stat_force_next_flush();')
        row = self.io_sample(lambda: sql(reset + settings + query * 5 +
                             'SELECT pg_stat_force_next_flush();'))
        self.assertEqual(row['status'],'reset')
        self.assertIsNone(row['idx_blks_read_delta'])
        self.assertIsNone(row['idx_blks_hit_delta'])

    def test_alternative_join_plans(self):
        for settings in [
            'SET LOCAL enable_hashjoin=off; SET LOCAL join_collapse_limit=1; '
            'SET LOCAL from_collapse_limit=1; ',
            'SET LOCAL enable_mergejoin=off; SET LOCAL enable_nestloop=off; '
            'SET LOCAL enable_material=off; ',
        ]:
            row = self.io_sample(lambda: sql(
                'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
                'SELECT sum(payload) FROM delta_index_io_tests.items WHERE id BETWEEN 1 AND 50; '
                'SELECT pg_stat_force_next_flush();'),
                prefix="BEGIN; SET LOCAL jit=off; SET LOCAL stats_fetch_consistency='snapshot'; "
                       + settings + 'SELECT sum(idx_blks_hit) FROM pg_statio_user_indexes; ')
            self.assertEqual(row['status'],'ok')
            self.assertGreater(row['idx_blks_hit_delta'],0)

    def test_full_join_edge_cases(self):
        columns=['relid','indexrelid','schemaname','relname','indexrelname','idx_blks_read','idx_blks_hit']
        def fixture(rows):
            values=[]
            for oid,read,hit in rows:
                fields=['90000::oid',f'{oid}::oid',"'fixture'::name","'t'::name",f"'idx{oid}'::name",
                        f'{read}::bigint',f'{hit}::bigint']
                values.append('(' + ','.join(fields) + ')')
            return 'FROM (VALUES ' + ','.join(values) + ') AS i(' + ','.join(columns) + ')'
        before=[(90101,5,100),(90102,10,200),(90103,10,100),(90105,0,0)]
        after=[(90101,5,110),(90102,20,190),(90104,20,200),(90105,0,0)]
        source=(Path(__file__).resolve().parents[1] / 'sql/pg_statio_user_indexes_delta.sql').read_text()
        query=source.split('RETURN QUERY\n',1)[1].split('\nEND;',1)[0]
        query=query.replace('FROM pg_statio_user_indexes AS i',fixture(before),1)
        query=query.replace('FROM pg_statio_user_indexes AS i',fixture(after),1)
        query=query.replace('i_delta_seconds::double precision','0::double precision').rstrip().rstrip(';')
        marker='pg_stat_get_db_stat_reset_time((SELECT id FROM database_id))'
        def run(reset):
            q=query.replace(marker,"'2026-01-01 UTC'::timestamptz",1)
            q=q.replace(marker,f"'2026-01-0{2 if reset else 1} UTC'::timestamptz",1)
            rows=json.loads(sql('SELECT jsonb_agg(to_jsonb(q)) FROM (' + q + ') q'))
            self.assertEqual(len(rows),5)
            return {int(r['indexrelid']):r for r in rows}
        rows=run(False)
        self.assertEqual(set(rows),{90101,90102,90103,90104,90105})
        for oid,status in [(90102,'counter_decreased'),(90103,'missing'),(90104,'missing')]:
            self.assertEqual(rows[oid]['status'],status)
            self.assertIsNone(rows[oid]['idx_blks_read_delta'])
            self.assertIsNone(rows[oid]['idx_blks_hit_delta'])
        self.assertEqual(rows[90101]['status'],'ok')
        self.assertEqual(rows[90101]['idx_blks_read_delta'],0)
        self.assertEqual(rows[90101]['idx_blks_hit_delta'],10)
        self.assertEqual(rows[90105]['status'],'ok')
        self.assertEqual(rows[90105]['idx_blks_read_delta'],0)
        self.assertEqual(rows[90105]['idx_blks_hit_delta'],0)
        for oid,row in run(True).items():
            self.assertEqual(row['status'],'missing' if oid in [90103,90104] else 'reset')
            self.assertIsNone(row['idx_blks_read_delta'])
            self.assertIsNone(row['idx_blks_hit_delta'])
        self.assertNotIn('database_stats_reset_start',rows[90101])
        self.assertNotIn('database_stats_reset_end',rows[90101])

    def test_database_reset(self):
        row = self.io_sample(lambda: sql('SELECT pg_stat_reset()'))
        self.assertEqual(row['status'], 'reset')
        self.assertIsNone(row['idx_blks_read_delta'])
        self.assertIsNone(row['idx_blks_hit_delta'])

    def test_catalog_snapshot(self):
        try:
            rows = self.sample(lambda: sql(
                'ALTER INDEX delta_index_io_tests.items_pkey RENAME TO renamed_pkey; '
                'CREATE INDEX created_during_sample ON delta_index_io_tests.items(payload)'),
                function='pg_statio_user_indexes_delta')
            names = [r['indexrelname'] for r in rows if r['schemaname']=='delta_index_io_tests']
            self.assertIn('items_pkey', names)
            self.assertNotIn('renamed_pkey', names)
            self.assertNotIn('created_during_sample', names)
        finally:
            sql('DROP INDEX IF EXISTS delta_index_io_tests.created_during_sample; '
                'ALTER INDEX delta_index_io_tests.renamed_pkey RENAME TO items_pkey;')

    def test_dropped_index(self):
        sql('CREATE TABLE delta_index_io_tests.dropped(id integer) '
            'WITH (autovacuum_enabled=false); '
            'CREATE INDEX dropped_idx ON delta_index_io_tests.dropped(id); '
            'INSERT INTO delta_index_io_tests.dropped SELECT generate_series(1,100); '
            'SELECT pg_stat_force_next_flush();')
        row = self.io_sample(lambda: sql('DROP INDEX delta_index_io_tests.dropped_idx'), index='dropped_idx')
        self.assertEqual(row['status'], 'counter_decreased')
        self.assertIsNone(row['idx_blks_hit_delta'])

    def test_user_scope_validation_and_repeat(self):
        self.assertEqual(sql("SELECT count(*) FROM pg_statio_user_indexes_delta(0) "
                             "WHERE schemaname IN ('pg_catalog', 'pg_toast')"), '0')
        for value in ['NULL', '-1', "'NaN'", "'Infinity'", "'-Infinity'"]:
            result = subprocess.run([PSQL, '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                                     f'SELECT * FROM pg_statio_user_indexes_delta({value})'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('finite nonnegative', result.stderr)
        result = sql('BEGIN; '
                     "SET LOCAL stats_fetch_consistency='snapshot'; "
                     'SELECT count(*)>0 FROM pg_statio_user_indexes_delta(0); '
                     'SELECT count(*)>0 FROM pg_statio_user_indexes_delta(0); COMMIT;')
        self.assertEqual(result.splitlines().count('t'), 2)


class WALDeltaTests(unittest.TestCase):
    sample = DeltaTests.sample
    counters = ('wal_records wal_fpi wal_bytes wal_buffers_full wal_write wal_sync '
                'wal_write_time wal_sync_time').split()

    @classmethod
    def setUpClass(cls):
        sql('CREATE EXTENSION IF NOT EXISTS pg_stat_delta')
        sql('CREATE TABLE delta_wal_test (id integer, payload text)')

    @classmethod
    def tearDownClass(cls):
        sql('DROP TABLE delta_wal_test')

    def workload(self):
        sql("INSERT INTO delta_wal_test SELECT i, repeat(md5(i::text), 100) "
            "FROM generate_series(1,1000) i; SELECT pg_stat_force_next_flush()")

    def test_validation_and_types(self):
        for value in ['NULL', '-1', "'NaN'", "'Infinity'", "'-Infinity'"]:
            result = subprocess.run([PSQL, '-X', '-v', 'ON_ERROR_STOP=1', '-c',
                                    f'SELECT * FROM pg_stat_wal_delta({value})'],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('finite nonnegative', result.stderr)
        self.assertEqual(sql("SELECT count(*)=1 AND bool_and(status='ok' AND elapsed_seconds>=0) "
                             'FROM pg_stat_wal_delta(0)'), 't')
        self.assertEqual(sql('SELECT pg_typeof(wal_bytes_delta) FROM pg_stat_wal_delta(0)'), 'numeric')

    def test_workload_and_cache_modes(self):
        for mode in ['none', 'cache', 'snapshot']:
            row, = self.sample(self.workload,
                f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; "
                'SELECT wal_records FROM pg_stat_wal; ', function='pg_stat_wal_delta')
            self.assertEqual(row['status'], 'ok')
            self.assertGreater(row['wal_records_delta'], 0)
            self.assertGreater(row['wal_bytes_delta'], 0)
            self.assertGreaterEqual(row['elapsed_seconds'], 1.5)
            for counter in self.counters:
                self.assertGreaterEqual(row[counter+'_delta'], 0)

    def test_reset_with_new_activity(self):
        def reset():
            sql("SELECT pg_stat_reset_shared('wal')")
            self.workload()
        row, = self.sample(reset, function='pg_stat_wal_delta')
        self.assertEqual(row['status'], 'reset')
        for counter in self.counters:
            self.assertIsNone(row[counter+'_delta'])

    def test_alternative_plans(self):
        for settings in [
            'SET LOCAL enable_hashjoin=off; SET LOCAL join_collapse_limit=1; '
            'SET LOCAL from_collapse_limit=1; ',
            'SET LOCAL enable_mergejoin=off; SET LOCAL enable_nestloop=off; '
            'SET LOCAL enable_material=off; ',
        ]:
            row, = self.sample(self.workload,
                "BEGIN; SET LOCAL jit=off; SET LOCAL stats_fetch_consistency='snapshot'; "
                + settings + 'SELECT wal_records FROM pg_stat_wal; ',
                function='pg_stat_wal_delta')
            self.assertEqual(row['status'], 'ok')
            self.assertGreater(row['wal_records_delta'], 0)

    def test_controlled_counters(self):
        source = (Path(__file__).resolve().parents[1] / 'sql/pg_stat_wal_delta.sql').read_text()
        query = source.split('RETURN QUERY\n', 1)[1].split('\nEND;', 1)[0]
        query = query.replace('i_delta_seconds::double precision', '0::double precision').rstrip().rstrip(';')
        def fixture(values, reset):
            fields = [str(v)+'::'+('numeric' if c=='wal_bytes' else
                      'double precision' if c.endswith('_time') else 'bigint')
                      for c,v in zip(self.counters, values)]
            fields.append(reset+'::timestamptz')
            return ('FROM (VALUES ('+','.join(fields)+')) AS w('
                    + ','.join(self.counters+['stats_reset'])+')')
        before = [10]*8
        # Beyond bigint range: wal_bytes must retain native numeric precision.
        before[2] = 10**24
        after = [x+7 for x in before]
        cases = [(after, 'NULL', 'ok'), (after, "'2026-10-27 UTC'", 'reset')]
        for i in range(8):
            decreased = after.copy()
            decreased[i] = before[i]-1
            cases.append((decreased, 'NULL', 'counter_decreased'))
        for values, reset, status in cases:
            q = query.replace('FROM pg_stat_wal AS w', fixture(before, 'NULL'), 1)
            q = q.replace('FROM pg_stat_wal AS w', fixture(values, reset), 1)
            row = json.loads(sql('SELECT to_jsonb(q) FROM ('+q+') q'))
            self.assertEqual(row['status'], status)
            for counter in self.counters:
                self.assertEqual(row[counter+'_delta'], 7 if status=='ok' else None)


class InvalidDeltaArithmeticTests(unittest.TestCase):
    def test_invalid_snapshots_skip_subtraction(self):
        # Invalid rows must not subtract counters at all: a bigint difference
        # could overflow even though its result should have been discarded.
        cases = [
            ('pg_stat_database', 'd', 'xact_commit', None, 'reset'),
            ('pg_stat_user_tables', 't', 'n_tup_ins', 'seq_scan', 'reset'),
            ('pg_stat_user_indexes', 'i', 'idx_tup_read', 'idx_scan', 'reset'),
            ('pg_statio_user_tables', 't', 'heap_blks_hit', 'heap_blks_read', 'counter_decreased'),
            ('pg_statio_user_indexes', 'i', 'idx_blks_hit', 'idx_blks_read', 'counter_decreased'),
            ('pg_stat_wal', 'w', 'wal_fpi', 'wal_records', 'counter_decreased'),
        ]
        for view, alias, overflow, decrease, status in cases:
            with self.subTest(view=view):
                columns = json.loads(sql("SELECT json_agg(json_build_array(attname, "
                    "format_type(atttypid, atttypmod))) FROM pg_attribute "
                    f"WHERE attrelid='{view}'::regclass AND attnum>0 AND NOT attisdropped"))
                def fixture(second):
                    fields = []
                    for name, typ in columns:
                        if name == overflow:
                            value = '9223372036854775807' if second else '-9223372036854775807'
                        elif name == decrease:
                            value = '9' if second else '10'
                        elif name == 'stats_reset':
                            value = "'2026-01-02 UTC'" if second and decrease is None else "'2026-01-01 UTC'"
                        elif typ == 'oid':
                            value = '1'
                        elif typ == 'name':
                            value = "'fixture'"
                        elif typ in ['bigint', 'integer', 'numeric', 'double precision']:
                            value = '0'
                        else:
                            value = 'NULL'
                        fields.append(f'{value}::{typ} AS {name}')
                    return 'FROM (SELECT '+', '.join(fields)+f') AS {alias}'
                source = (Path(__file__).resolve().parents[1] / 'sql' / (view+'_delta.sql')).read_text()
                query = source.split('RETURN QUERY\n', 1)[1].split('\nEND;', 1)[0]
                query = query.replace(f'FROM {view} AS {alias}', fixture(False), 1)
                query = query.replace(f'FROM {view} AS {alias}', fixture(True), 1)
                query = query.replace('i_delta_seconds::double precision', '0::double precision').rstrip().rstrip(';')
                row = json.loads(sql('SELECT to_jsonb(q) FROM ('+query+') q'))
                self.assertEqual(row['status'], status)
                for name, value in row.items():
                    if name.endswith('_delta'):
                        self.assertIsNone(value, name)


class InstallationTests(unittest.TestCase):
    def test_single_version_install(self):
        name = 'delta_test_installation'
        functions = ['pg_stat_database_delta', 'pg_stat_user_tables_delta',
                     'pg_stat_user_indexes_delta', 'pg_statio_user_tables_delta',
                     'pg_statio_user_indexes_delta', 'pg_stat_wal_delta']
        sql(f'CREATE DATABASE {name}')
        try:
            self.assertEqual(sql("SELECT version FROM pg_available_extension_versions "
                                 "WHERE name='pg_stat_delta' ORDER BY version", PGDATABASE=name), '0.1.0')
            sql('CREATE SCHEMA diagnostics', PGDATABASE=name)
            for schema in ['public', 'diagnostics']:
                # Test both the default version and explicit 0.1.0 selection.
                version = " VERSION '0.1.0'" if schema == 'diagnostics' else ''
                sql(f'CREATE EXTENSION pg_stat_delta SCHEMA {schema}' + version, PGDATABASE=name)
                self.assertEqual(sql("SELECT extversion FROM pg_extension WHERE extname='pg_stat_delta'",
                                     PGDATABASE=name), '0.1.0')
                for function in functions:
                    rows = sql(f'SELECT count(*) FROM {schema}.{function}(0)', PGDATABASE=name)
                    if function in ['pg_stat_database_delta', 'pg_stat_wal_delta']:
                        self.assertGreater(int(rows), 0)
                    else:
                        self.assertEqual(rows, '0')
                # All six functions must be extension members, not loose SQL objects.
                self.assertEqual(sql("SELECT count(*) FROM pg_depend d "
                                     "JOIN pg_extension e ON e.oid=d.refobjid "
                                     "JOIN pg_proc p ON p.oid=d.objid "
                                     "WHERE e.extname='pg_stat_delta' AND d.deptype='e' "
                                     "AND d.classid='pg_proc'::regclass "
                                     "AND d.refclassid='pg_extension'::regclass",
                                     PGDATABASE=name), '6')
                start = time.monotonic()
                sql(f'SELECT count(*) FROM {schema}.pg_statio_user_indexes_delta(0.1)', PGDATABASE=name)
                self.assertGreaterEqual(time.monotonic() - start, .1)
                sql('DROP EXTENSION pg_stat_delta', PGDATABASE=name)
                for function in functions:
                    self.assertEqual(sql(f"SELECT to_regprocedure('{schema}.{function}(numeric)') IS NULL",
                                         PGDATABASE=name), 't')
        finally:
            sql(f'DROP DATABASE {name}')


if __name__ == '__main__':
    unittest.main(verbosity=2)

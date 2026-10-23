"""Integration tests against an isolated PostgreSQL database (standard PG* variables)."""
import json
import os
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

    def sample(self, action, prefix=''):
        proc = subprocess.Popen(
            [PSQL, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c', prefix +
             'SELECT coalesce(jsonb_agg(to_jsonb(d)),\'[]\'::jsonb) '
             'FROM pg_stat_database_delta(1.5) d'],
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
                'SELECT count(*) FROM pg_stat_database; ')
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
                         'SELECT count(*)>0 FROM delta_test_schema.pg_stat_database_delta(0);')
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


if __name__ == '__main__':
    unittest.main(verbosity=2)

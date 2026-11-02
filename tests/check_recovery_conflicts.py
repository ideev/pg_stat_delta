"""Verify real recovery conflicts and restartpoints using a private primary/standby.

Run as a non-root user with PostgreSQL 17 and the current extension installed.
Both servers use only private Unix sockets; existing servers are untouched.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from unittest.mock import patch

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pg-bindir', type=Path, required=True)
bindir = parser.parse_args().pg_bindir.resolve()
spec = importlib.util.spec_from_file_location('delta_integration', Path(__file__).with_name('integration.py'))
tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
tests.PSQL = str(bindir / 'psql')
with tempfile.TemporaryDirectory(prefix='delta-recovery-', dir='/tmp') as directory:
    root = Path(directory)
    primary = root / 'primary'
    standby = root / 'standby'
    primary_socket = root / 'primary_socket'
    standby_socket = root / 'standby_socket'
    primary_socket.mkdir()
    standby_socket.mkdir()
    def pg(command, *args):
        subprocess.run([str(bindir / command), *map(str, args)], check=True, stdout=subprocess.DEVNULL)
    pg('initdb', '-D', primary, '-A', 'trust', '-U', 'recovery_test_admin', '--no-locale')
    pg('pg_ctl', '-D', primary, '-l', root / 'primary.log', '-o',
       f'-k {primary_socket} -p 5432 -h ""', 'start')
    standby_started = False
    try:
        with patch.dict(os.environ, {'PGHOST': str(primary_socket), 'PGPORT': '5432',
                                   'PGUSER': 'recovery_test_admin', 'PGDATABASE': 'postgres'}):
            tests.sql('CREATE EXTENSION pg_stat_delta; '
                      'CREATE TABLE recovery_conflict_probe (id integer); '
                      'INSERT INTO recovery_conflict_probe SELECT i FROM generate_series(1,1000) i')
            pg('pg_basebackup', '-D', standby, '-X', 'stream', '-R', '-c', 'fast',
               '-h', primary_socket, '-p', '5432', '-U', 'recovery_test_admin')
            pg('pg_ctl', '-D', standby, '-l', root / 'standby.log', '-o',
               f'-k {standby_socket} -p 5433 -h "" -c max_standby_streaming_delay=100ms '
               '-c hot_standby_feedback=off', 'start')
            standby_started = True
            with patch.dict(os.environ, {'PGHOST': str(standby_socket), 'PGPORT': '5433'}):
                assert tests.sql('SELECT pg_is_in_recovery()') == 't'
                tests.sql('SELECT 1; SELECT pg_stat_force_next_flush()')
                for number, mode in enumerate(['none', 'cache', 'snapshot']):
                    locker = subprocess.Popen([tests.PSQL, '-XAt', '-v', 'ON_ERROR_STOP=1', '-c',
                        'BEGIN; SELECT sum(id) FROM recovery_conflict_probe; SELECT pg_sleep(15)'],
                        env={**os.environ, 'PGAPPNAME': 'delta_conflict_locker'},
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    try:
                        deadline = time.monotonic() + 5
                        while tests.sql("SELECT count(*) FROM pg_stat_activity WHERE "
                                        "application_name='delta_conflict_locker' AND wait_event='PgSleep'") != '1':
                            if locker.poll() is not None or time.monotonic() > deadline:
                                raise AssertionError('standby locker did not enter pg_sleep')
                            time.sleep(.02)
                        def conflict():
                            tests.sql(f'ALTER TABLE recovery_conflict_probe ADD COLUMN column_{number} integer',
                                      PGHOST=str(primary_socket), PGPORT='5432')
                        rows = tests.DeltaTests().sample(conflict,
                            f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; "
                            'SELECT sum(confl_lock) FROM pg_stat_database_conflicts; ',
                            function='pg_stat_database_conflicts_delta')
                        row = next(r for r in rows if r['datname'] == 'postgres')
                        assert row['status'] == 'ok', row
                        assert row['confl_lock_delta'] >= 1, row
                        _, error = locker.communicate(timeout=5)
                        assert locker.returncode != 0 and 'conflict with recovery' in error, error
                        print(json.dumps({'cache_mode': mode, 'status': row['status'],
                                          'confl_lock_delta': row['confl_lock_delta']}), flush=True)
                    finally:
                        if locker.poll() is None:
                            locker.kill()
                            locker.communicate()
                # Replay a fresh safe checkpoint before requesting a restartpoint.
                tests.sql('CHECKPOINT', PGHOST=str(primary_socket), PGPORT='5432')
                lsn = tests.sql('SELECT pg_current_wal_lsn()', PGHOST=str(primary_socket), PGPORT='5432')
                deadline = time.monotonic() + 10
                while tests.sql(f"SELECT pg_last_wal_replay_lsn() >= '{lsn}'::pg_lsn") != 't':
                    if time.monotonic() > deadline:
                        raise AssertionError('standby did not replay the checkpoint')
                    time.sleep(.02)
                row, = tests.DeltaTests().sample(lambda: tests.sql('CHECKPOINT'),
                    "BEGIN; SET LOCAL stats_fetch_consistency='snapshot'; "
                    'SELECT restartpoints_req FROM pg_stat_checkpointer; ',
                    function='pg_stat_checkpointer_delta')
                assert row['status'] == 'ok', row
                assert row['restartpoints_req_delta'] >= 1, row
                assert row['restartpoints_done_delta'] >= 1, row
                print(json.dumps({'restartpoints_req_delta': row['restartpoints_req_delta'],
                                  'restartpoints_done_delta': row['restartpoints_done_delta']}), flush=True)
    finally:
        if standby_started:
            pg('pg_ctl', '-D', standby, '-m', 'fast', 'stop')
        pg('pg_ctl', '-D', primary, '-m', 'fast', 'stop')

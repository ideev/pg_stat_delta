"""Optional real bgwriter-write check in an isolated PostgreSQL 17 cluster.

Run as a non-root user. Creates and removes a private Unix-socket-only cluster;
its small buffer pool and aggressive writer settings never affect other servers.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pg-bindir', type=Path, required=True)
bindir = parser.parse_args().pg_bindir.resolve()
spec = importlib.util.spec_from_file_location('delta_integration', Path(__file__).with_name('integration.py'))
tests = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
tests.PSQL = str(bindir / 'psql')
with tempfile.TemporaryDirectory(prefix='delta-bgwriter-', dir='/tmp') as directory:
    root = Path(directory)
    data = root / 'data'
    def pg(command, *args):
        subprocess.run([str(bindir / command), *map(str, args)], check=True, stdout=subprocess.DEVNULL)
    pg('initdb', '-D', data, '-A', 'trust', '-U', 'bgwriter_test_admin', '--no-locale')
    options = (f'-k {root} -p 5432 -h "" -c shared_buffers=1MB '
               '-c bgwriter_delay=10ms -c bgwriter_lru_maxpages=1 '
               '-c bgwriter_lru_multiplier=10 -c checkpoint_timeout=1h '
               '-c max_wal_size=1GB -c autovacuum=off')
    pg('pg_ctl', '-D', data, '-l', root / 'server.log', '-o', options, 'start')
    try:
        with patch.dict(os.environ, {'PGHOST': str(root), 'PGPORT': '5432',
                                   'PGUSER': 'bgwriter_test_admin', 'PGDATABASE': 'postgres'}):
            tests.sql('CREATE EXTENSION pg_stat_delta; CREATE TABLE pressure (payload text)')
            def workload():
                tests.sql("DO $$ BEGIN FOR i IN 1..80 LOOP "
                          "INSERT INTO pressure SELECT repeat(md5(j::text),32) "
                          "FROM generate_series(1,64) j; PERFORM pg_sleep(0.01); "
                          "END LOOP; END $$; SELECT pg_stat_force_next_flush()")
            row, = tests.DeltaTests().sample(workload, function='pg_stat_bgwriter_delta', seconds=3)
            assert row['status'] == 'ok', row
            for counter in ['buffers_clean', 'maxwritten_clean', 'buffers_alloc']:
                assert row[counter + '_delta'] > 0, row
            print(json.dumps(row))
    finally:
        pg('pg_ctl', '-D', data, '-m', 'fast', 'stop')

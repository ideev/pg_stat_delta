"""Explain the actual sampling SQL with zero sleep, using the standard PG* variables.

Run against a representative disposable database; output is a complete plan.
This executes the query and clears this connection's statistics cache.
"""
import argparse
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--view', choices=['database', 'wal', 'tables', 'indexes', 'statio_user_tables', 'statio_user_indexes'], default='tables')
parser.add_argument('--source', type=Path, help='Optional per-function SQL file, e.g. a previous revision')
args = parser.parse_args()
filename = ('pg_stat_database_delta.sql' if args.view == 'database'
            else 'pg_stat_wal_delta.sql' if args.view == 'wal'
            else f'pg_{args.view}_delta.sql' if args.view.startswith('statio_')
            else f'pg_stat_user_{args.view}_delta.sql')
source_path = args.source or Path(__file__).resolve().parents[1] / 'sql' / filename
source = source_path.read_text()
query = source.split('RETURN QUERY\n', 1)[1].split('\nEND;', 1)[0]
query = query.replace('i_delta_seconds::double precision', '0::double precision')
subprocess.run([os.environ.get('PSQL', 'psql'), '-X', '-v', 'ON_ERROR_STOP=1',
                '-c', 'SET search_path = pg_catalog, pg_temp',
                '-c', 'EXPLAIN (ANALYZE, BUFFERS, TIMING OFF) ' + query], check=True)

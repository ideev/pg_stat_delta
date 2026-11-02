"""Run pg_stat_statements integration tests in an isolated preloaded PG17 cluster.

Run as a non-root user. Only this helper's private Unix-socket server is restarted
or configured. Requires the current extension installed under the given bindir.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from unittest.mock import patch

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--pg-bindir',type=Path,required=True)
parser.add_argument('--benchmark-only',action='store_true',help='Measure materialized/inlined SQL in a fresh private cluster instead of running functional tests')
args=parser.parse_args();bindir=args.pg_bindir.resolve()
spec=importlib.util.spec_from_file_location('delta_integration',Path(__file__).with_name('integration.py'))
tests=importlib.util.module_from_spec(spec);spec.loader.exec_module(tests);tests.PSQL=str(bindir/'psql')
with tempfile.TemporaryDirectory(prefix='delta-statements-',dir='/tmp') as directory:
    root=Path(directory);data=root/'data'
    def pg(name,*params):
        subprocess.run([str(bindir/name),*map(str,params)],check=True,stdout=subprocess.DEVNULL)
    pg('initdb','-D',data,'-A','trust','-U','statements_test_admin','--no-locale')
    options=f'-k {root} -p 5432 -h ""'
    pg('pg_ctl','-D',data,'-l',root/'server.log','-o',options,'start')
    running=True
    try:
        with patch.dict(os.environ,{'PGHOST':str(root),'PGPORT':'5432','PGUSER':'statements_test_admin',
                                   'PGDATABASE':'postgres','PSQL':str(bindir/'psql')}):
            tests.sql('CREATE SCHEMA "statement stats"; CREATE SCHEMA diagnostics; '
                'CREATE EXTENSION pg_stat_statements SCHEMA "statement stats"; '
                'CREATE EXTENSION pg_stat_delta SCHEMA diagnostics; '
                'GRANT USAGE ON SCHEMA diagnostics,"statement stats" TO PUBLIC')
            p=subprocess.run([tests.PSQL,'-X','-v','ON_ERROR_STOP=1','-c',
                'SELECT * FROM diagnostics.pg_stat_statements_delta(0)'],capture_output=True,text=True)
            assert p.returncode!=0 and 'shared_preload_libraries' in p.stderr,p.stderr
            print('Installed but not preloaded: expected failure verified',flush=True)
            pg('pg_ctl','-D',data,'-m','fast','stop');running=False
            preload=' -c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.max='+('10000' if args.benchmark_only else '100')+' '
            preload+='-c pg_stat_statements.track=all -c pg_stat_statements.track_planning=on -c compute_query_id=on -c jit=off'
            pg('pg_ctl','-D',data,'-l',root/'server.log','-o',options+preload,'start');running=True
            if args.benchmark_only:
                tests.sql("ALTER SYSTEM SET pg_stat_statements.track_utility=off")
                tests.sql("SELECT pg_reload_conf()")
                subprocess.run([sys.executable,str(Path(__file__).with_name('benchmark_statements.py'))],check=True)
            else:
                subprocess.run([sys.executable,str(Path(__file__).with_name('statements_integration.py'))],check=True)
    finally:
        if running:pg('pg_ctl','-D',data,'-m','fast','stop')

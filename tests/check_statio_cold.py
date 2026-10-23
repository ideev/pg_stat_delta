"""Optional cold-shared-buffer check. Run as a non-root user with PostgreSQL 17.

Creates and cleans up its own Unix-socket-only cluster. Existing servers are not
stopped or modified. No third-party Python packages or extensions are required.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch

parser = argparse.ArgumentParser(description='Verify block-read deltas using a private temporary PostgreSQL cluster.')
parser.add_argument('--pg-bindir', type=Path, required=True, help='Directory containing initdb, pg_ctl and psql')
bindir = parser.parse_args().pg_bindir.resolve()
spec=importlib.util.spec_from_file_location('delta_integration',Path(__file__).with_name('integration.py'))
tests=importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
tests.PSQL = str(bindir / 'psql')
with tempfile.TemporaryDirectory(prefix='delta-statio-cold-',dir='/tmp') as root:
    root=Path(root)
    data=root/'data'
    def pg(command,*args):
        subprocess.run([str(bindir/command),*map(str,args)],check=True,stdout=subprocess.DEVNULL)
    pg('initdb','-D',data,'-A','trust','-U','statio_test_admin','--no-locale')
    pg('pg_ctl','-D',data,'-l',root/'server.log','-o',f'-k {root} -p 5432 -h ""','start')
    try:
        with patch.dict(os.environ, {'PGHOST':str(root),'PGPORT':'5432',
                                   'PGUSER':'statio_test_admin','PGDATABASE':'postgres'}):
            tests.sql('CREATE EXTENSION pg_stat_delta')
            tests.StatioDeltaTests.setUpClass()
            # A clean private-cluster restart clears shared buffers, not the OS cache.
            pg('pg_ctl','-D',data,'-m','fast','stop')
            pg('pg_ctl','-D',data,'-l',root/'server.log','-o',f'-k {root} -p 5432 -h ""','start')
            case=tests.StatioDeltaTests()
            rows=case.sample(lambda: tests.sql(
                'SELECT sum(payload) FROM delta_statio_tests.heap; '
                'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
                'SELECT sum(payload) FROM delta_statio_tests.indexed WHERE id BETWEEN 1 AND 50; '
                'SET enable_seqscan=on; '
                'SELECT md5(payload) FROM delta_statio_tests.toasted; '
                'SELECT pg_stat_force_next_flush();'),
                function='pg_statio_user_tables_delta',condition="schemaname='delta_statio_tests'")
            by_name={r['relname']:r for r in rows}
            for table,field in [('heap','heap_blks_read_delta'),('indexed','idx_blks_read_delta'),
                                ('toasted','toast_blks_read_delta'),('toasted','tidx_blks_read_delta')]:
                assert by_name[table]['status']=='ok', by_name[table]
                assert by_name[table][field]>0, by_name[table]
            print(json.dumps([{k:r[k] for k in ['relname','heap_blks_read_delta','idx_blks_read_delta',
                          'toast_blks_read_delta','tidx_blks_read_delta']} for r in rows]))
            # The first workload warmed the index; restart only our private cluster again.
            pg('pg_ctl','-D',data,'-m','fast','stop')
            pg('pg_ctl','-D',data,'-l',root/'server.log','-o',f'-k {root} -p 5432 -h ""','start')
            index_rows = case.sample(lambda: tests.sql(
                'SET enable_seqscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off; '
                'SELECT sum(payload) FROM delta_statio_tests.indexed WHERE id BETWEEN 1 AND 50; '
                'SELECT pg_stat_force_next_flush();'), function='pg_statio_user_indexes_delta',
                condition="schemaname='delta_statio_tests' AND indexrelname='indexed_pkey'")
            assert len(index_rows) == 1, index_rows
            assert index_rows[0]['status'] == 'ok', index_rows
            assert index_rows[0]['idx_blks_read_delta'] > 0, index_rows
            print(json.dumps([{k:r[k] for k in ['indexrelname','idx_blks_read_delta',
                                              'idx_blks_hit_delta']} for r in index_rows]))

    finally:
        pg('pg_ctl','-D',data,'-m','fast','stop')

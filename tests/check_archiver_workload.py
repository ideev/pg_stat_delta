"""Verify successful/failed WAL archiving using a private PostgreSQL 17 cluster.

Run as a non-root user. Only this helper's temporary cluster has archive_mode
and archive_command changed; it binds a private Unix socket and is removed.
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
bindir=parser.parse_args().pg_bindir.resolve()
spec=importlib.util.spec_from_file_location('delta_integration',Path(__file__).with_name('integration.py'))
tests=importlib.util.module_from_spec(spec)
spec.loader.exec_module(tests)
tests.PSQL=str(bindir/'psql')
with tempfile.TemporaryDirectory(prefix='delta-archiver-',dir='/tmp') as directory:
    root=Path(directory);data=root/'data';archive=root/'archive';archive.mkdir()
    command=root/'archive.py'
    command.write_text(f'#!{sys.executable}\n'+'''import filecmp
from pathlib import Path
import shutil
import sys
root=Path(__file__).parent
if (root/'fail').exists():
    sys.exit(1)
source=Path(sys.argv[1]);target=root/'archive'/sys.argv[2]
if target.exists():
    sys.exit(0 if filecmp.cmp(source,target,shallow=False) else 1)
temporary=target.with_suffix('.tmp')
shutil.copyfile(source,temporary)
temporary.replace(target)
''')
    command.chmod(0o755)
    def pg(name,*args):
        subprocess.run([str(bindir/name),*map(str,args)],check=True,stdout=subprocess.DEVNULL)
    pg('initdb','-D',data,'-A','trust','-U','archiver_test_admin','--no-locale','--wal-segsize=1')
    with (data/'postgresql.conf').open('a') as conf:
        conf.write("\narchive_mode=on\narchive_command='"+str(command)+' "%p" "%f"' + "'\n")
    pg('pg_ctl','-D',data,'-l',root/'server.log','-o',f'-k {root} -p 5432 -h ""','start')
    try:
        with patch.dict(os.environ,{'PGHOST':str(root),'PGPORT':'5432','PGUSER':'archiver_test_admin','PGDATABASE':'postgres'}):
            tests.sql('CREATE EXTENSION pg_stat_delta; CREATE TABLE archive_workload (payload text)')
            def workload():
                tests.sql("INSERT INTO archive_workload SELECT repeat(md5(i::text),10) "
                          'FROM generate_series(1,100) i; SELECT pg_switch_wal()')
            case=tests.DeltaTests()
            for mode in ['none','cache','snapshot']:
                row,=case.sample(workload,
                    f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; SELECT archived_count FROM pg_stat_archiver; ",
                    function='pg_stat_archiver_delta',seconds=3)
                assert row['status']=='ok',row
                assert row['archived_count_delta']>=1,row
                assert row['last_archived_wal_end'] and row['last_archived_time_end'],row
                assert (archive/row['last_archived_wal_end']).is_file(),row
                print(json.dumps({'phase':'success','cache_mode':mode,
                                  'archived_count_delta':row['archived_count_delta']}),flush=True)
            def fail():
                (root/'fail').touch()
                workload()
            row,=case.sample(fail,
                "BEGIN; SET LOCAL stats_fetch_consistency='snapshot'; SELECT failed_count FROM pg_stat_archiver; ",
                function='pg_stat_archiver_delta',seconds=3)
            assert row['status']=='ok' and row['failed_count_delta']>=1,row
            assert row['last_failed_wal_end'] and row['last_failed_time_end'],row
            print(json.dumps({'phase':'command_exit_1','failed_count_delta':row['failed_count_delta']}),flush=True)
            (root/'fail').unlink()
            def reset_and_archive():
                tests.sql("SELECT pg_stat_reset_shared('archiver')")
                workload()
            row,=case.sample(reset_and_archive,
                "BEGIN; SET LOCAL stats_fetch_consistency='snapshot'; SELECT archived_count FROM pg_stat_archiver; ",
                function='pg_stat_archiver_delta',seconds=3)
            assert row['status']=='reset',row
            assert row['archived_count_delta'] is None and row['failed_count_delta'] is None,row
            assert row['last_archived_wal_end'] and row['last_archived_time_end'],row
            assert (archive/row['last_archived_wal_end']).is_file(),row
            print(json.dumps({'phase':'reset_with_success','status':row['status'],
                              'last_archived_wal_end':row['last_archived_wal_end']}),flush=True)
    finally:
        pg('pg_ctl','-D',data,'-m','fast','stop')

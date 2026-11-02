"""pg_stat_statements tests, run by check_statements_workload.py in its private cluster."""
import json
import os
from pathlib import Path
import subprocess
import unittest

import integration as core

sql=core.sql
PSQL=core.PSQL
PGSS='"statement stats"'
SAMPLER='diagnostics.pg_stat_statements_delta'
TARGET='SELECT sum(payload) FROM statements_workload.items WHERE id >= 0'
SOURCE=Path(__file__).resolve().parents[1]/'sql/pg_stat_statements_delta.sql'
import re
METRICS=dict(re.findall(r'^    (\w+)_delta (bigint|numeric|double precision)',SOURCE.read_text(),re.M))


def execute(query,n=1,dbname=None,role=None):
    args=[PSQL,'-XAt','-v','ON_ERROR_STOP=1']
    if role:args+=['-c',f'SET ROLE {role}']
    for _ in range(n):args+=['-c',query]
    subprocess.check_output(args,env={**os.environ,**({'PGDATABASE':dbname} if dbname else {})},text=True)


class StatementDeltaTests(unittest.TestCase):
    sample=core.DeltaTests.sample

    @classmethod
    def setUpClass(cls):
        sql('CREATE SCHEMA statements_workload; CREATE TABLE statements_workload.items (id integer,payload integer); '
            'INSERT INTO statements_workload.items SELECT i,i FROM generate_series(1,100) i; '
            'CREATE ROLE statements_reader; GRANT USAGE ON SCHEMA statements_workload TO statements_reader; '
            'GRANT SELECT ON statements_workload.items TO statements_reader; '
            'CREATE FUNCTION statements_workload.nested_sum() RETURNS bigint LANGUAGE plpgsql AS $$ '
            'DECLARE n bigint; BEGIN SELECT sum(payload) INTO n FROM statements_workload.items WHERE id>=0; RETURN n; END $$')
        cls.dbid=int(sql("SELECT oid FROM pg_database WHERE datname=current_database()"))
        cls.userid=int(sql("SELECT oid FROM pg_roles WHERE rolname=current_user"))

    @classmethod
    def tearDownClass(cls):
        sql('DROP OWNED BY statements_reader; DROP ROLE statements_reader; DROP SCHEMA statements_workload CASCADE')

    def setUp(self):
        sql(f'SELECT {PGSS}.pg_stat_statements_reset()')
        self.workload(1)

    def workload(self,n=10):execute(TARGET,n)

    def key(self):
        return json.loads(sql(f"SELECT to_jsonb(q) FROM (SELECT userid,dbid,toplevel,queryid FROM {PGSS}.pg_stat_statements "
            f"WHERE userid={self.userid} AND dbid={self.dbid} AND toplevel "
            "AND query LIKE 'SELECT sum(payload) FROM statements_workload.items WHERE id >=%' LIMIT 1) q"))

    def matches(self,row,key):
        return all(str(row[k])==str(key[k]) for k in ['userid','dbid','toplevel','queryid'])

    def sampled(self,action,prefix='',seconds=1.5):
        return self.sample(action,prefix,function=SAMPLER,seconds=seconds)

    def target(self,rows,key):return next(r for r in rows if self.matches(r,key))

    def reset_sql(self,key,minmax=False):
        return f"SELECT {PGSS}.pg_stat_statements_reset({key['userid']}::oid,{key['dbid']}::oid,{key['queryid']}::bigint,{str(minmax).lower()})"

    def test_validation_and_zero(self):
        for value in ['NULL','-1',"'NaN'","'Infinity'","'-Infinity'"]:
            p=subprocess.run([PSQL,'-X','-v','ON_ERROR_STOP=1','-c',f'SELECT * FROM {SAMPLER}({value})'],capture_output=True,text=True)
            self.assertNotEqual(p.returncode,0);self.assertIn('finite nonnegative',p.stderr)
        rows=json.loads(sql(f'SELECT json_agg(d) FROM {SAMPLER}(0) d'))
        self.assertTrue(rows)
        self.assertTrue(all(r['queryid'] is not None for r in rows))
        self.assertEqual(sql(f'SELECT pg_typeof(wal_bytes_delta) FROM {SAMPLER}(0) LIMIT 1'),'numeric')

    def test_calls_planning_and_cache_modes(self):
        for mode in ['none','cache','snapshot']:
            key=self.key()
            row=self.target(self.sampled(self.workload,
                f"BEGIN; SET LOCAL stats_fetch_consistency='{mode}'; SELECT sum(calls) FROM {PGSS}.pg_stat_statements; "),key)
            self.assertEqual(row['status'],'ok')
            self.assertEqual(row['calls_delta'],10);self.assertEqual(row['plans_delta'],10)
            self.assertEqual(row['rows_delta'],10)
            self.assertGreater(row['total_exec_time_delta'],0);self.assertGreater(row['total_plan_time_delta'],0)
            self.assertIsNotNone(row['query']);self.assertGreaterEqual(row['elapsed_seconds'],1.5)

    def test_selective_reset_and_catchup(self):
        key=self.key()
        def reset():sql(self.reset_sql(key));self.workload(20)
        row=self.target(self.sampled(reset),key)
        self.assertEqual(row['status'],'reset')
        for c in METRICS:self.assertIsNone(row[c+'_delta'])
        self.assertIsNotNone(row['query'])

    def test_global_reset_and_catchup(self):
        key=self.key()
        def reset():sql(f'SELECT {PGSS}.pg_stat_statements_reset()');self.workload(20)
        row=self.target(self.sampled(reset),key)
        self.assertEqual(row['status'],'reset')
        for c in METRICS:self.assertIsNone(row[c+'_delta'])

    def test_minmax_reset_preserves_deltas(self):
        key=self.key()
        def reset():sql(self.reset_sql(key,True));self.workload(5)
        row=self.target(self.sampled(reset),key)
        self.assertEqual(row['status'],'ok');self.assertEqual(row['calls_delta'],5)
        self.assertEqual(row['plans_delta'],5)

    def test_new_and_disappeared_entries(self):
        rows=self.sampled(lambda:execute('SELECT sum(payload) FROM statements_workload.items WHERE id > 0'))
        new=next(r for r in rows if r['query'] and r['query'].startswith('SELECT sum(payload) FROM statements_workload.items WHERE id > '))
        self.assertEqual(new['status'],'missing')
        for c in METRICS:self.assertIsNone(new[c+'_delta'])
        key=self.key()
        row=self.target(self.sampled(lambda:sql(f'SELECT {PGSS}.pg_stat_statements_reset()')),key)
        self.assertEqual(row['status'],'missing');self.assertIsNone(row['query'])
        for c in METRICS:self.assertIsNone(row[c+'_delta'])

    def test_planning_tracking_disabled(self):
        key=self.key()
        def workload():
            args=[PSQL,'-XAt','-v','ON_ERROR_STOP=1','-c','SET pg_stat_statements.track_planning=off']
            for _ in range(3):args+=['-c',TARGET]
            subprocess.check_output(args,text=True)
        row=self.target(self.sampled(workload),key)
        self.assertEqual(row['status'],'ok');self.assertEqual(row['calls_delta'],3)
        self.assertEqual(row['plans_delta'],0);self.assertEqual(row['total_plan_time_delta'],0)
        self.assertGreater(row['total_exec_time_delta'],0)

    def test_unrelated_database_reset(self):
        key=self.key()
        def workload():sql('SELECT pg_stat_reset()');self.workload(3)
        row=self.target(self.sampled(workload),key)
        self.assertEqual(row['status'],'ok');self.assertEqual(row['calls_delta'],3)

    def test_dml_rows_and_wal(self):
        query='INSERT INTO statements_workload.items SELECT i,i FROM generate_series(1000,1009) g(i)'
        execute(query)
        key=json.loads(sql(f"SELECT to_jsonb(q) FROM (SELECT userid,dbid,toplevel,queryid FROM {PGSS}.pg_stat_statements "
            "WHERE query LIKE 'INSERT INTO statements_workload.items SELECT%' LIMIT 1) q"))
        row=self.target(self.sampled(lambda:execute(query,3)),key)
        self.assertEqual(row['status'],'ok');self.assertEqual(row['calls_delta'],3);self.assertEqual(row['rows_delta'],30)
        self.assertGreater(row['wal_records_delta'],0);self.assertGreater(row['wal_bytes_delta'],0)

    def test_nested_statements(self):
        execute('SELECT statements_workload.nested_sum()')
        key=json.loads(sql(f"SELECT to_jsonb(q) FROM (SELECT userid,dbid,toplevel,queryid FROM {PGSS}.pg_stat_statements "
            "WHERE NOT toplevel AND query LIKE '%sum(payload)%statements_workload.items%' LIMIT 1) q"))
        row=self.target(self.sampled(lambda:execute('SELECT statements_workload.nested_sum()',4)),key)
        self.assertEqual(row['status'],'ok');self.assertEqual(row['calls_delta'],4);self.assertFalse(row['toplevel'])

    def test_invoker_privileges_and_empty_search_path(self):
        execute(TARGET,role='statements_reader')
        roleid=int(sql("SELECT oid FROM pg_roles WHERE rolname='statements_reader'"))
        rows=self.sampled(lambda:execute(TARGET,2,role='statements_reader'),
                          "SET ROLE statements_reader; SET search_path=''; ")
        self.assertTrue(rows);self.assertTrue(all(int(r['userid'])==roleid for r in rows))
        target=next(r for r in rows if r['query'] and r['query'].startswith('SELECT sum(payload) FROM statements_workload.items WHERE id >= '))
        self.assertEqual(target['calls_delta'],2)
        sql('GRANT pg_read_all_stats TO statements_reader')
        self.assertEqual(sql(f"SET ROLE statements_reader; SET search_path=''; SELECT bool_or(userid<>{roleid}) FROM {SAMPLER}(0)" ).splitlines()[-1],'t')
        sql('REVOKE pg_read_all_stats FROM statements_reader')

    def test_database_key(self):
        name='statements_other'
        sql('CREATE DATABASE '+name)
        try:
            query='SELECT sum(i) FROM generate_series(1,5) g(i)'
            execute(query);execute(query,dbname=name)
            key=json.loads(sql(f"SELECT to_jsonb(q) FROM (SELECT userid,dbid,toplevel,queryid FROM {PGSS}.pg_stat_statements "
                f"WHERE dbid={self.dbid} AND query LIKE 'SELECT sum(i) FROM generate_series%' LIMIT 1) q"))
            rows=self.sampled(lambda:execute(query,3,dbname=name))
            matched=[r for r in rows if str(r['queryid'])==str(key['queryid']) and int(r['userid'])==self.userid and r['toplevel']]
            self.assertEqual(len(matched),2)
            for r in matched:
                self.assertEqual(r['status'],'ok');self.assertEqual(r['calls_delta'],0 if int(r['dbid'])==self.dbid else 3)
        finally:sql('DROP DATABASE '+name)

    def test_eviction_and_reentry(self):
        key=self.key()
        before=int(sql(f'SELECT dealloc FROM {PGSS}.pg_stat_statements_info'))
        def evict():
            sql("DO $$ DECLARE i integer; BEGIN FOR i IN 1..400 LOOP "
                "EXECUTE 'SELECT count(*) FROM (VALUES ' || repeat('(1),',i) || '(1)) v(i)'; "
                "END LOOP; END $$")
            self.workload(1)
        row=self.target(self.sampled(evict,seconds=3),key)
        self.assertGreater(int(sql(f'SELECT dealloc FROM {PGSS}.pg_stat_statements_info')),before)
        self.assertEqual(row['status'],'reset')
        for c in METRICS:self.assertIsNone(row[c+'_delta'])

    def test_schema_relocation(self):
        sql('CREATE SCHEMA "moved stats"; ALTER EXTENSION pg_stat_statements SET SCHEMA "moved stats"')
        try:self.assertGreater(int(sql(f'SELECT count(*) FROM {SAMPLER}(0)')),0)
        finally:sql('ALTER EXTENSION pg_stat_statements SET SCHEMA "statement stats"; DROP SCHEMA "moved stats"')
        sql('CREATE SCHEMA "moved delta"; ALTER EXTENSION pg_stat_delta SET SCHEMA "moved delta"')
        try:self.assertGreater(int(sql('SELECT count(*) FROM "moved delta".pg_stat_statements_delta(0)')),0)
        finally:sql('ALTER EXTENSION pg_stat_delta SET SCHEMA diagnostics; DROP SCHEMA "moved delta"')

    def test_old_version_rejected(self):
        name='statements_old_version'
        sql('CREATE DATABASE '+name)
        try:
            sql("CREATE EXTENSION pg_stat_statements VERSION '1.10'; CREATE EXTENSION pg_stat_delta",PGDATABASE=name)
            p=subprocess.run([PSQL,'-X','-v','ON_ERROR_STOP=1','-c','SELECT * FROM pg_stat_statements_delta(0)'],
                             env={**os.environ,'PGDATABASE':name},capture_output=True,text=True)
            self.assertNotEqual(p.returncode,0);self.assertIn('version 1.11 is required',p.stderr)
        finally:sql('DROP DATABASE '+name)

    def test_empty_snapshots_wait(self):
        import time
        start=time.monotonic()
        out=sql(f"SET pg_stat_statements.track='none'; SELECT {PGSS}.pg_stat_statements_reset(); "
                f"SELECT count(*) FROM {SAMPLER}(0.1)")
        self.assertEqual(out.splitlines()[-1],'0')
        self.assertGreaterEqual(time.monotonic()-start,.1)

    def test_alternative_plans(self):
        for settings in [
            'SET LOCAL enable_hashjoin=off; SET LOCAL join_collapse_limit=1; SET LOCAL from_collapse_limit=1; ',
            'SET LOCAL enable_mergejoin=off; SET LOCAL enable_nestloop=off; SET LOCAL enable_material=off; ',
        ]:
            key=self.key()
            row=self.target(self.sampled(self.workload,
                "BEGIN; SET LOCAL jit=off; SET LOCAL stats_fetch_consistency='snapshot'; "+settings+
                f'SELECT sum(calls) FROM {PGSS}.pg_stat_statements; '),key)
            self.assertEqual(row['status'],'ok');self.assertEqual(row['calls_delta'],10)

    def test_repeated_calls(self):
        out=sql(f"BEGIN; SET LOCAL stats_fetch_consistency='snapshot'; SELECT sum(calls) FROM {PGSS}.pg_stat_statements; "
                f"SELECT bool_and(elapsed_seconds>=0.05) FROM {SAMPLER}(0.05); "
                f"SELECT bool_and(elapsed_seconds>=0.05) FROM {SAMPLER}(0.05); COMMIT;")
        self.assertEqual(out.splitlines()[-3:],['t','t','COMMIT'])

    def test_controlled_keys_resets_and_overflow(self):
        query=SOURCE.read_text().split('$query$',2)[1].replace('$1::double precision','0::double precision')
        def fixture(rows,showtext):
            vals=[]
            for key,amount,reset in rows:
                fields=[f'{key[0]}::oid',f'{key[1]}::oid',str(key[2]).lower()+'::boolean',
                        'NULL::bigint' if key[3] is None else f'{key[3]}::bigint',"'representative'::text",reset+'::timestamptz']
                fields += [str(amount[c])+'::'+typ for c,typ in METRICS.items()]
                vals.append('('+','.join(fields)+')')
            return 'FROM (VALUES '+','.join(vals)+') AS s(userid,dbid,toplevel,queryid,query,stats_since,'+','.join(METRICS)+')'
        def execute_fixture(before,after):
            q=query.replace('FROM %1$I.pg_stat_statements(false) AS s',fixture(before,False),1)
            q=q.replace('FROM %1$I.pg_stat_statements(true) AS s',fixture(after,True),1)
            return json.loads(sql('SELECT json_agg(q) FROM ('+q+') q'))
        def amounts(value):return {c:value for c in METRICS}
        keys=[(1,1,True,10),(2,1,True,10),(1,2,True,10),(1,1,False,10),(1,1,True,11)]
        before=[(k,amounts(10),'NULL') for k in keys]+[((1,1,True,None),amounts(10),'NULL')]
        after=[(k,amounts(15),'NULL') for k in keys[:-1]]+[((1,1,True,12),amounts(15),'NULL'),((1,1,True,None),amounts(15),'NULL')]
        rows=execute_fixture(before,after)
        self.assertEqual(len(rows),6)
        for row in rows:
            self.assertIsNotNone(row['queryid'])
            expected='missing' if int(row['queryid']) in [11,12] else 'ok'
            self.assertEqual(row['status'],expected)
            for c in METRICS:self.assertEqual(row[c+'_delta'],5 if expected=='ok' else None)
        key=keys[0]
        for c in METRICS:
            after=amounts(20);after[c]=9
            row,=execute_fixture([(key,amounts(10),'NULL')],[(key,after,'NULL')])
            self.assertEqual(row['status'],'counter_decreased')
            for metric in METRICS:self.assertIsNone(row[metric+'_delta'])
        row,=execute_fixture([(key,amounts(10),"'2026-01-01 UTC'")],[(key,amounts(20),"'2026-01-02 UTC'")])
        self.assertEqual(row['status'],'reset')
        for c in METRICS:self.assertIsNone(row[c+'_delta'])
        low=amounts(10);high=amounts(20)
        low['calls']=-9223372036854775807;high['calls']=9223372036854775807
        high['plans']=9
        low['wal_bytes']=10**24;high['wal_bytes']=10**24+7
        row,=execute_fixture([(key,low,'NULL')],[(key,high,'NULL')])
        for c in METRICS:self.assertIsNone(row[c+'_delta'])
        low=amounts(10);high=amounts(15);low['wal_bytes']=10**24;high['wal_bytes']=10**24+7
        row,=execute_fixture([(key,low,'NULL')],[(key,high,'NULL')])
        self.assertEqual(row['wal_bytes_delta'],7)


if __name__=='__main__':unittest.main(verbosity=2)

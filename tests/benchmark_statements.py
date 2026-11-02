"""Internal-query measurements; called only by the private statements helper.

Creates a workload table and resets pg_stat_statements in that disposable
cluster. Never run this benchmark on a monitored production server.
"""
import json
import re
import os
from pathlib import Path
import statistics
import subprocess

PSQL=os.environ['PSQL']
def sql(query):
    return subprocess.check_output([PSQL,'-XAt','-v','ON_ERROR_STOP=1',
        '-c',"SET pg_stat_statements.track='none'",'-c',query],text=True).splitlines()[1:]
def result(query):return '\n'.join(sql(query))
def nodes(n):
    yield n
    for c in n.get('Plans',[]):yield from nodes(c)

source=(Path(__file__).resolve().parents[1]/'sql/pg_stat_statements_delta.sql').read_text()
query=source.split('$query$',2)[1].replace('%1$I','"statement stats"').replace('$1::double precision','0::double precision')
METRICS=dict(re.findall(r'^    (\w+)_delta (bigint|numeric|double precision)',source,re.M))

def thin_variant(q):
    if 'AS plans_start' not in q:
        return q
    start=q.index('    ), measured AS MATERIALIZED (')
    outer=q.index('    SELECT m.userid',start)
    classification=q[start:outer].replace('               s2.query,\n','')
    a=classification.index("                    ELSE 'ok' END AS status,")
    b=classification.index('        FROM first_snapshot AS s1',a)
    classification=classification[:a]+"                    ELSE 'ok' END AS status\n"+classification[b:]
    tail=q[outer:].replace('m.query,','s2.query,')
    for c in METRICS:
        tail=tail.replace(f'm.{c}_end - m.{c}_start',f's2.{c} - s1.{c}')
    joins='    FROM measured AS m\n'
    for alias,snapshot in [('s1','first_snapshot'),('s2','second_snapshot')]:
        joins+=f'    LEFT JOIN {snapshot} AS {alias}\n      ON '+ '\n     AND '.join(f'm.{k} = {alias}.{k}' for k in ['userid','dbid','toplevel','queryid'])+'\n'
    tail=tail.replace('    FROM measured AS m\n',joins)
    return q[:start]+classification+tail


def wide_variant(q):
    if 'AS plans_start' in q:
        return q
    start=q.index('    ), measured AS MATERIALIZED (')
    outer=q.index('    SELECT m.userid',start)
    classification=q[start:outer]
    classification=classification.replace('               t1.started_at','               s2.query,\n               t1.started_at',1)
    ends=',\n'.join(f'               s1.{c} AS {c}_start, s2.{c} AS {c}_end' for c in METRICS)
    classification=classification.replace("                    ELSE 'ok' END AS status\n", "                    ELSE 'ok' END AS status,\n"+ends+'\n')
    tail=q[outer:].replace('s2.query,','m.query,')
    for c in METRICS:
        tail=tail.replace(f's2.{c} - s1.{c}',f'm.{c}_end - m.{c}_start')
    a=tail.index('    FROM measured AS m\n');b=tail.index('    ORDER BY',a)
    tail=tail[:a]+'    FROM measured AS m\n'+tail[b:]
    return q[:start]+classification+tail

wide=wide_variant(query)
variants={'wide_materialized':wide,'wide_inlined':wide.replace('measured AS MATERIALIZED (','measured AS NOT MATERIALIZED ('),'thin_materialized':thin_variant(query)}
columns=','.join('c'+str(i)+' integer' for i in range(1,1001))
result('CREATE TABLE benchmark_statements ('+columns+'); INSERT INTO benchmark_statements VALUES ('+','.join(['1']*1000)+')')
measurements=[]
for size in [0,100,1000,5000]:
    result('SELECT "statement stats".pg_stat_statements_reset()')
    if size:
        result("SET pg_stat_statements.track='all'; DO $$ DECLARE i integer; op text; BEGIN "
               f"FOR i IN 1..{size} LOOP op := (ARRAY['=','>','<','<>','>='])[((i-1)/1000)+1]; "
               "EXECUTE format('SELECT c%s FROM benchmark_statements WHERE c%s %s 0',((i-1)%1000)+1,((i-1)%1000)+1,op); "
               "END LOOP; END $$; SET pg_stat_statements.track='none'")
    plans={v:[] for v in variants}
    for i in range(14):
        labels=list(variants)
        if i%2:labels.reverse()
        for label in labels:
            p=json.loads(result('EXPLAIN (ANALYZE,VERBOSE,BUFFERS,TIMING OFF,FORMAT JSON) '+variants[label]))[0]
            if i>=4:plans[label].append(p)
    for label,ps in plans.items():
        last=ps[-1];ns=list(nodes(last['Plan']))
        snapshots=[n for n in ns if n.get('Subplan Name') in ['CTE first_snapshot','CTE second_snapshot']]
        assert len(snapshots)==2
        for snap in snapshots:
            assert snap['Node Type']=='Limit'
            assert any(c.get('Parent Relationship')=='InitPlan' for c in snap['Plans'])
        assert sum(n.get('Function Name')=='pg_stat_statements' for n in ns)==2
        row={'workload_queries':size,'variant':label,'returned_rows':last['Plan']['Actual Rows'],
             'median_ms':statistics.median(p['Execution Time'] for p in ps),
             'range_ms':[min(p['Execution Time'] for p in ps),max(p['Execution Time'] for p in ps)],
             'planning_median_ms':statistics.median(p['Planning Time'] for p in ps),
             'sorts':[{k:n.get(k) for k in ['Sort Method','Sort Space Used','Sort Space Type']} for n in ns if n['Node Type']=='Sort'],
             'temp_writes':last['Plan'].get('Temp Written Blocks'),
             'shared_hits':last['Plan'].get('Shared Hit Blocks'),'shared_reads':last['Plan'].get('Shared Read Blocks')}
        print(json.dumps(row),flush=True);measurements.append(row)
if os.environ.get('STATEMENTS_BENCHMARK_OUTPUT'):
    Path(os.environ['STATEMENTS_BENCHMARK_OUTPUT']).write_text(json.dumps(measurements,indent=2))

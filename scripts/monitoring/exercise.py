#!/usr/bin/env python3
"""Run only in an isolated test namespace: verify real alert firing and resolution."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

context, namespace = os.environ['KUBE_CONTEXT'], os.environ['APP_NAMESPACE']
root = Path(__file__).resolve().parents[2]
port = int(os.environ.get('EXERCISE_PROMETHEUS_PORT','19091'))
base = f'http://127.0.0.1:{port}'
forward = None
outage = None
with tempfile.TemporaryFile() as log:
    try:
        forward = subprocess.Popen(['kubectl','--context='+context,'-n','monitoring','port-forward','--address=127.0.0.1','svc/monitoring-prometheus',f'{port}:9090'],stdout=log,stderr=log)
        def query(expr):
            with urllib.request.urlopen(base+'/api/v1/query?'+urllib.parse.urlencode({'query':expr}),timeout=10) as response:
                return json.load(response)['data']['result']
        for attempt in range(30):
            try:
                if query(f'pg_up{{namespace="{namespace}"}}')[0]['value'][1]=='1': break
            except Exception: pass
            time.sleep(2)
        else: raise RuntimeError('Prometheus or database exporter is not ready')
        env = dict(os.environ, NAMESPACE=namespace, OUTAGE_HOLD_SECONDS='180')
        outage = subprocess.Popen(['bash',str(root/'scripts/test/test-database-outage.sh')],env=env)
        fired = set()
        deadline = time.monotonic()+240
        while time.monotonic()<deadline and outage.poll() is None:
            result = query(f'ALERTS{{namespace="{namespace}",alertstate="firing",alertname=~"DatabaseDown|GatewayUnavailable"}}')
            fired.update(x['metric']['alertname'] for x in result)
            if len(fired)==2:
                targets = query(f'up{{namespace="{namespace}",service="api-metrics"}}')
                assert targets and all(float(x['value'][1])==1 for x in targets), 'API metrics disappeared during outage'
                print('DatabaseDown and GatewayUnavailable firing; API still scrapeable: PASS',flush=True)
                break
            time.sleep(5)
        if len(fired)!=2: raise RuntimeError('Expected outage alerts did not fire')
        if outage.wait(timeout=180)!=0: raise RuntimeError('Database outage/recovery test failed')
        deadline = time.monotonic()+120
        while time.monotonic()<deadline:
            if not query(f'ALERTS{{namespace="{namespace}",alertname=~"DatabaseDown|GatewayUnavailable"}}'):
                print('Database/gateway alerts resolved after recovery: PASS',flush=True)
                break
            time.sleep(5)
        else: raise RuntimeError('Outage alerts did not resolve')
    finally:
        if outage and outage.poll() is None:
            outage.terminate()
            try: outage.wait(timeout=15)
            except subprocess.TimeoutExpired: outage.kill(); outage.wait()
            # Restore even if the child shell was interrupted while waiting.
            subprocess.run(['kubectl','--context='+context,'-n',namespace,'scale','statefulset/postgres','--replicas=1'],check=True)
        if forward:
            forward.terminate(); forward.wait(timeout=10)

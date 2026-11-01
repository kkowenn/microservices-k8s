#!/usr/bin/env python3
"""Read-only integration assertions; credentials stay in memory and are never printed."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

context = os.environ['KUBE_CONTEXT']
namespace = os.environ['APP_NAMESPACE']
kube = ['kubectl', '--context='+context]
forwards = []

def forward(service, remote, port):
    log = tempfile.TemporaryFile()
    proc = subprocess.Popen(kube+['-n','monitoring','port-forward','--address=127.0.0.1',service,f'{port}:{remote}'], stdout=log, stderr=log)
    forwards.append((proc, log))
    return f'http://127.0.0.1:{port}'

def get(url, auth=None):
    req = urllib.request.Request(url)
    if auth:
        req.add_header('Authorization', 'Basic '+base64.b64encode(auth.encode()).decode())
    with urllib.request.urlopen(req, timeout=10) as response:
        return json.load(response)

def eventually(check, description, timeout=180):
    end = time.monotonic()+timeout
    last = None
    while time.monotonic() < end:
        try:
            if check():
                print(description+': PASS', flush=True)
                return
        except Exception as exc:
            last = type(exc).__name__
        time.sleep(3)
    raise RuntimeError(description+' failed'+(' ('+last+')' if last else ''))

try:
    prometheus = forward('svc/monitoring-prometheus',9090,int(os.environ.get('TEST_PROMETHEUS_PORT','19090')))
    loki = forward('svc/loki',3100,int(os.environ.get('TEST_LOKI_PORT','13100')))
    grafana = forward('svc/monitoring-grafana',80,int(os.environ.get('TEST_GRAFANA_PORT','13001')))
    def query(expr):
        return get(prometheus+'/api/v1/query?'+urllib.parse.urlencode({'query':expr}))['data']['result']
    for service in ('api-metrics','postgres-exporter','gateway-probe'):
        eventually(lambda service=service: bool(query(f'up{{namespace="{namespace}",service="{service}"}}')) and all(float(x['value'][1])==1 for x in query(f'up{{namespace="{namespace}",service="{service}"}}')), service+' target UP')
    for expr, label in [(f'pg_up{{namespace="{namespace}"}}','database exporter connected'),(f'probe_success{{namespace="{namespace}"}}','gateway available'),(f'http_requests_total{{namespace="{namespace}",route="/api/items"}}','API request metrics'),(f'go_sql_max_open_connections{{namespace="{namespace}"}}','database pool metrics'),(f'kube_pod_container_status_restarts_total{{namespace="{namespace}"}}','Kubernetes pod metrics')]:
        eventually(lambda expr=expr: any(float(x['value'][1])>0 for x in query(expr)) if 'restarts_total' not in expr else bool(query(expr)), label)
    def logs():
        response = get(loki+'/loki/api/v1/query_range?'+urllib.parse.urlencode({'query':f'{{namespace="{namespace}",app="api"}} | json | msg="request"','limit':10}))
        return any(stream['values'] for stream in response['data']['result'])
    eventually(logs,'API JSON logs ingested in Loki')
    raw = json.loads(subprocess.check_output(kube+['-n','monitoring','get','secret/grafana-admin','-o','json']))['data']
    user = base64.b64decode(raw['admin-user']).decode()
    password = base64.b64decode(raw['admin-password']).decode()
    eventually(lambda: get(grafana+'/api/dashboards/uid/microservices-overview', user+':'+password)['dashboard']['uid']=='microservices-overview', 'Grafana dashboard provisioned')
    eventually(lambda: any(x['uid']=='loki' for x in get(grafana+'/api/datasources',user+':'+password)), 'Grafana Loki datasource provisioned')
finally:
    for proc, log in forwards:
        proc.terminate()
        try: proc.wait(timeout=5)
        except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        log.close()

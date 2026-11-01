"""Validate the optional monitoring integration without requiring a live cluster."""
import json
from pathlib import Path
import os
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]
MONITORING = ROOT / 'k8s/monitoring'

class MonitoringTests(unittest.TestCase):
    def render(self, path):
        return list(yaml.safe_load_all(subprocess.check_output(
            [os.environ.get('KUBECTL', 'kubectl'), 'kustomize', str(path)], text=True)))

    def test_optional_resources_and_internal_metrics(self):
        for name in ('local', 'dev', 'staging', 'prod', 'dev-cnpg'):
            docs = self.render(ROOT / 'k8s/overlays' / name)
            self.assertFalse(any(d['apiVersion'].startswith('monitoring.coreos.com') for d in docs))
            api = next(d for d in docs if d['kind']=='Service' and d['metadata']['name']=='api')
            self.assertEqual(api['spec']['ports'][0]['name'], 'http')
            self.assertEqual(len(api['spec']['ports']), 1)
        docs = self.render(MONITORING/'application')
        service = next(d for d in docs if d['kind']=='Service' and d['metadata']['name']=='api-metrics')
        monitor = next(d for d in docs if d['kind']=='ServiceMonitor' and d['metadata']['name']=='api')
        self.assertTrue(service['spec']['publishNotReadyAddresses'])
        self.assertEqual(service['spec']['type'], 'ClusterIP')
        self.assertEqual(monitor['spec']['endpoints'][0]['port'], service['spec']['ports'][0]['name'])
        for key, value in monitor['spec']['selector']['matchLabels'].items():
            self.assertEqual(service['metadata']['labels'][key], value)

    def test_rules_manifest_is_identical_to_tested_rules(self):
        expected = yaml.safe_load((MONITORING/'alerts/rules.yaml').read_text())
        docs = self.render(MONITORING)
        actual = next(d for d in docs if d['kind']=='PrometheusRule')
        self.assertEqual(actual['spec'], expected)
        fixtures = yaml.safe_load((MONITORING/'alerts/rules.test.yaml').read_text())
        tested = {t['alertname'] for c in fixtures['tests'] for t in c['alert_rule_test']}
        for group in actual['spec']['groups']:
            for rule in group['rules']:
                self.assertIn(rule['alert'], tested)
                self.assertIn('#'+rule['alert'].lower(), rule['annotations']['runbook_url'])

    def test_dashboard_is_provisioned_and_uses_real_metric_names(self):
        docs = self.render(MONITORING)
        cm = next(d for d in docs if d['kind']=='ConfigMap')
        self.assertEqual(cm['metadata']['labels']['grafana_dashboard'], '1')
        dashboard = json.loads(cm['data']['api-overview.json'])
        self.assertEqual(dashboard['uid'], 'microservices-overview')
        queries = [t['expr'] for panel in dashboard['panels'] for t in panel['targets']]
        self.assertTrue(any('go_sql_in_use_connections' in q for q in queries))
        self.assertFalse(any('postgres_sql_' in q for q in queries))
        self.assertTrue(any(panel['type']=='logs' for panel in dashboard['panels']))

    def test_credentials_and_notifications_are_external(self):
        values = yaml.safe_load((MONITORING/'kube-prometheus-values.yaml').read_text())
        self.assertEqual(values['grafana']['admin']['existingSecret'], 'grafana-admin')
        self.assertNotIn('adminPassword', values['grafana'])
        self.assertEqual(values['alertmanager']['config']['route']['receiver'], 'null')
        exporter = yaml.safe_load((MONITORING/'postgres-exporter-values.yaml').read_text())
        self.assertEqual(exporter['config']['datasource']['user'], 'metrics_reader')
        self.assertNotIn('password', exporter['config']['datasource'])

    def test_helm_monitoring_selectors_match_rendered_resources(self):
        rendered = os.environ.get('MONITORING_RENDER_DIR')
        if not rendered:
            self.skipTest('Set MONITORING_RENDER_DIR via scripts/monitoring/validate.sh for chart checks')
        docs = list(yaml.safe_load_all((Path(rendered)/'kube-prometheus-stack.yaml').read_text()))
        prom = next(d for d in docs if d and d['kind']=='Prometheus')
        labels = prom['spec']['serviceMonitorSelector']['matchLabels']
        services = [d for d in docs if d and d['kind']=='ServiceMonitor']
        self.assertTrue(any('kube-state-metrics' in d['metadata']['name'] for d in services))
        for monitor in services:
            self.assertTrue(all(monitor['metadata']['labels'].get(k)==v for k,v in labels.items()), monitor['metadata']['name'])
        for chart in ('loki', 'alloy', 'prometheus-postgres-exporter'):
            self.assertTrue(list(yaml.safe_load_all((Path(rendered)/(chart+'.yaml')).read_text())))

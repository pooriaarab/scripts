#!/usr/bin/env python3
"""Exercise the full collector CLI against an HTTP fixture; no Cloudflare token required."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import urllib.parse

mode = 'ok'
calls = []


class Fixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, value):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(json.dumps(value).encode())

    def do_GET(self):
        calls.append(self.path)
        if 'billable-usage' in self.path:
            return self.respond({'success': True, 'result': [{'BilledCost': 999, 'CumulatedContractedCost': 12}]})
        page = int(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)['page'][0])
        key = 'a' if page == 1 or mode == 'repeat' else 'b'
        rows = [] if mode == 'empty' and page == 2 else [{'uuid': key, 'name': key}]
        self.respond({'success': True, 'result': rows,
                      'result_info': {'total_count': 2, 'per_page': 1, 'page': page}})

    def do_POST(self):
        calls.append(self.path)
        self.rfile.read(int(self.headers['Content-Length']))
        if mode == 'graphql-error':
            return self.respond({'errors': [{'message': 'private response must not print'}]})
        group = {'dimensions': {'databaseId': 'a'}, 'sum': {
            'rowsRead': 900, 'rowsWritten': None if mode == 'null' else 12,
            'readQueries': 2, 'writeQueries': 1}}
        groups = [group] * 10000 if mode == 'limit' else [group]
        self.respond({'data': {'viewer': {'accounts': [{'d1AnalyticsAdaptiveGroups': groups}]}}})


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
threading.Thread(target=server.serve_forever, daemon=True).start()
script = Path(__file__).with_name('cloudflare-cost-audit')
runner = '''import runpy,sys
scope=runpy.run_path(sys.argv.pop(1))
scope['main'].__globals__['API']=sys.argv.pop(1)
sys.exit(scope['main']())
'''
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    for scenario in ('missing', 'ok', 'empty', 'repeat', 'graphql-error', 'null', 'limit', 'exists'):
        mode = scenario
        calls.clear()
        env = dict(os.environ, CLOUDFLARE_ACCOUNT_ID='testaccount', CLOUDFLARE_API_TOKEN='fake-token')
        if scenario == 'missing':
            env.pop('CLOUDFLARE_API_TOKEN')
        output = root / scenario
        if scenario == 'exists':
            output.mkdir()
        result = subprocess.run([sys.executable, '-c', runner, str(script),
            f'http://127.0.0.1:{server.server_port}', '--start', '2026-10-01',
            '--end', '2026-10-02', '--output', str(output), '--billing'], env=env, capture_output=True, text=True)
        assert 'fake-token' not in result.stdout + result.stderr
        assert 'private response' not in result.stdout + result.stderr
        if scenario == 'ok':
            assert result.returncode == 0, result.stderr
            summary = json.loads((output / 'summary.json').read_text())
            assert summary['databaseCount'] == 2
            assert summary['rowsRead'] == 900 and summary['rowsWritten'] == 12
            assert len(calls) == 4
            assert (output / 'billing-current-period.json').exists()
            assert 'BilledCost' not in result.stdout
            assert output.stat().st_mode & 0o777 == 0o700
            assert all(path.stat().st_mode & 0o777 == 0o600 for path in output.iterdir())
        else:
            assert result.returncode != 0, scenario
            assert not (output / 'summary.json').exists(), scenario
            if scenario in ('missing', 'exists'):
                assert not calls
        print(scenario + ': PASS')
server.shutdown()
print('8 CLI scenarios passed')

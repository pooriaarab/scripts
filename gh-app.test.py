#!/usr/bin/env python3
"""CLI E2E: fake browser/API, real files and OpenSSL. No real App mutations.
Failure cases: wrong shared tab/state, existing folder, bad name/permission,
missing installation, API failure, browser timeout, and secret output.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).with_name('gh-app')
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    env = dict(os.environ, HOME=tmp, PATH=f'{bin_dir}:{os.environ["PATH"]}')
    subprocess.run(['openssl', 'genrsa', '-out', str(root / 'fixture.pem'), '2048'],
                   check=True, capture_output=True)
    stub = '''#!/usr/bin/env python3
import base64, html, json, os, re, subprocess, sys
from pathlib import Path
from urllib.parse import parse_qs, urlparse
root = Path(os.environ['HOME'])
if Path(sys.argv[0]).name == 'zsh':
    args = sys.argv[4:]
    if args[:2] == ['tab', 'new']:
        url = args[2]
        if url.startswith('file:'):
            page = Path(urlparse(url).path).read_text()
            manifest = json.loads(html.unescape(re.search('name="manifest" value="([^"]+)"', page)[1]))
            assert manifest['default_permissions'] == {'administration': 'write', 'actions': 'read'}
            assert manifest['hook_attributes']['active'] == manifest['public']
            assert manifest['hook_attributes']['url'] == ('https://example.com/hook' if manifest['public'] else 'https://example.com/unused')
            assert manifest['default_events'] == (['workflow_job'] if manifest['public'] else [])
            state = parse_qs(urlparse(html.unescape(re.search('action="([^"]+)"', page)[1])).query)['state'][0]
            (root / 'redirect').write_text(manifest['redirect_url'] + '?code=correct&state=' + state)
        else:
            assert url == 'https://github.com/apps/demo-app/installations/new'
            (root / 'redirect').write_text('https://github.com/settings/installations/42')
        print('{}')
    else:
        assert args == ['tab', 'list', '--json'], args
        urls = ['https://github.com/?code=wrong&state=foreign']
        if (root / 'redirect').exists() and not os.getenv('TIMEOUT'):
            redirect = (root / 'redirect').read_text()
            urls.extend((['https://github.com/settings/installations/99'] if '/installations/' in redirect else []) + [redirect])
        print(json.dumps({'success': True, 'data': {'tabs': [{'url': u} for u in urls]}}))
else:
    config = sys.stdin.read()
    if os.getenv('API_FAIL'):
        print('private-response-must-not-leak', file=sys.stderr)
        sys.exit(22)
    if '/conversions' in config:
        assert '/app-manifests/correct/conversions' in config and 'Authorization' not in config
        print(json.dumps(dict(id=123, slug='demo-app', client_id='Iv1.fixture', pem=(root/'fixture.pem').read_text())))
    else:
        jwt = re.search('Bearer ([^"\\n]+)', config)[1]
        h, p, s = jwt.split('.')
        payload = json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)))
        assert payload['iss'] == '123' and payload['exp'] - payload['iat'] == 600
        (root/'signature').write_bytes(base64.urlsafe_b64decode(s + '=' * (-len(s) % 4)))
        subprocess.run(['openssl', 'rsa', '-in', str(root/'fixture.pem'), '-pubout', '-out', str(root/'public.pem')], check=True, capture_output=True)
        subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(root/'public.pem'), '-signature', str(root/'signature')], input=(h+'.'+p).encode(), check=True, capture_output=True)
        print(json.dumps({'token': 'fixture-token'} if '/access_tokens' in config else {'id': 42, 'app_id': 999 if '/installations/99' in config else 123}))
'''
    for name in ['zsh', 'curl']:
        p = bin_dir / name
        p.write_text(stub)
        p.chmod(0o700)

    def run(*args, ok=True, extra=None):
        p = subprocess.run([str(SCRIPT), *args], env=dict(env, **(extra or {})),
                           capture_output=True, text=True)
        assert (p.returncode == 0) == ok, (args, p.stderr)
        assert 'PRIVATE KEY' not in p.stdout + p.stderr
        assert 'private-response-must-not-leak' not in p.stdout + p.stderr
        return p

    run('create', '--name', '../escape', ok=False)
    run('create', '--name', 'bad', '--perm', 'actions=owner', ok=False)
    run('create', '--name', 'bad', '--event', 'push', ok=False)
    run('create', '--name', 'bad', '--hook-url', 'http://example.com', ok=False)
    for name, options in [('demo', []), ('hooks', ['--hook-url', 'https://example.com/hook', '--event', 'workflow_job', '--public'])]:
        run('create', '--name', name, '--perm', 'administration=write', '--perm', 'actions=read', *options)
        folder = root / 'Documents/Personal/.secrets' / name
        assert folder.stat().st_mode & 0o777 == 0o700
        for filename in ['app.env', 'app.pem', 'app-pkcs8.pem', 'conversion.json', 'create.html']:
            assert (folder / filename).stat().st_mode & 0o777 == 0o600
        subprocess.run(['openssl', 'pkey', '-in', str(folder/'app-pkcs8.pem'), '-noout'], check=True, capture_output=True)
    run('create', '--name', 'api-error', '--perm', 'administration=write', '--perm', 'actions=read',
        ok=False, extra={'API_FAIL': '1'})
    run('create', '--name', 'demo', ok=False)
    run('token', 'demo', ok=False)
    # Remove the second fixture, so the slug resolves to exactly one saved App.
    import shutil
    shutil.rmtree(root / 'Documents/Personal/.secrets/hooks')
    run('install', 'demo-app')
    assert run('token', 'demo').stdout == 'fixture-token\n'
    run('token', 'demo', ok=False, extra={'API_FAIL': '1'})
    run('create', '--name', 'timeout', '--perm', 'administration=write', '--perm', 'actions=read',
        ok=False, extra={'TIMEOUT': '1', 'GH_APP_WAIT_SECONDS': '0'})
    print('PASS: create, install, token, shared tabs, file modes, JWT signature, and failure cases')

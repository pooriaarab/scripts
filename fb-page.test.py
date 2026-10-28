#!/usr/bin/env python3
"""CLI E2E: fake browser, real script, real registry file. No Facebook account is touched.
Failure cases: namesake Page already managed, permission toggle that stays off, ambiguous Page search, validation before Page creation, missing terms flag, denied name, missing portfolio, missing category,
logged-out Chrome, hidden tab, wait timeout, Page already in the portfolio,
Page ID not found, browser crash that prints a secret.
Success case: JSON output, 0600 registry file, no secret in any output.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).with_name('fb-page')
SECRET = 'EAAB-fake-secret-token'
STUB = '''#!/usr/bin/env python3
import json, os, sys
mode = os.environ['STUB_MODE']
args = sys.argv[4:]
def out(value):
    print(json.dumps(json.dumps(value)))
if args[0] == 'eval':
    js = args[1]
    if mode == 'crash':
        print('cookie=%s' % os.environ['STUB_SECRET']); sys.exit(1)
    if 'visibilityState' in js:
        out('hidden' if mode == 'hidden' else 'visible')
    elif 'login|checkpoint' in js:
        out(mode == 'loggedout')
    elif js.startswith('JSON.stringify(Boolean('):
        out(mode != 'timeout')
    elif '.some(l=>' in js:
        out(mode == 'namesake')
    elif 'role=option' in js and '.length)' in js:
        out(2 if mode == 'ambiguous' else 1)
    elif '.some(' in js:
        out(mode == 'listed')
    elif 'ID:' in js and 'match' in js:
        out(None if mode == 'noid' else '1467561843088600')
    elif 'aria-checked' in js:
        out(mode != 'stuckoff')
    elif 'getBoundingClientRect' in js:
        out({'x': 5, 'y': 6})
    else:
        out(True)
'''


def run(args, mode='ok', env_extra=None):
    with tempfile.TemporaryDirectory() as tmp:
        bin_dir = Path(tmp) / 'bin'
        bin_dir.mkdir()
        for name, body in (('zsh', STUB), ('osascript', '#!/bin/sh\nexit 0\n')):
            (bin_dir / name).write_text(body)
            (bin_dir / name).chmod(0o755)
        env = dict(os.environ, PATH=f'{bin_dir}:{os.environ["PATH"]}', STUB_MODE=mode, STUB_SECRET=SECRET,
                   FB_PAGE_FAST='1', FB_PAGE_WAIT_SECONDS='1', FB_PAGE_DENY='blocked')
        env.pop('FB_PAGE_PORTFOLIO_ID', None)
        env.update(env_extra or {})
        registry = Path(tmp) / 'registry.json'
        result = subprocess.run([str(SCRIPT), *args, '--registry', str(registry), '--site', 'a.example'],
                                capture_output=True, text=True, env=env)
        data = json.loads(registry.read_text()) if registry.exists() else None
        mode_bits = registry.stat().st_mode & 0o777 if registry.exists() else None
        return result, data, mode_bits


def expect_fail(args, text, mode='ok'):
    result, _, _ = run(args, mode)
    assert result.returncode == 1, (args, result.stdout, result.stderr)
    assert text in result.stderr, (text, result.stderr)
    assert SECRET not in result.stdout + result.stderr


BASE = ['attach', '--name', 'Acme', '--portfolio', '111', '--accept-terms']
expect_fail([a for a in BASE if a != '--accept-terms'], '--accept-terms')
expect_fail(['attach', '--name', 'Blocked Co', '--portfolio', '111', '--accept-terms'], 'FB_PAGE_DENY')
expect_fail(['attach', '--name', 'Acme', '--accept-terms'], 'portfolio')
expect_fail(['attach', '--name', 'Acme', '--portfolio', '111&x=1', '--accept-terms'], 'digits')
expect_fail(['create', '--name', 'Acme', '--portfolio', '111', '--accept-terms'], '--category')
expect_fail(BASE, 'not logged in', 'loggedout')
expect_fail(BASE, 'hidden', 'hidden')
expect_fail(BASE, 'Timed out', 'timeout')
expect_fail(BASE, 'already in the portfolio', 'listed')
expect_fail(BASE, 'Page ID not found', 'noid')
expect_fail(BASE, 'browser eval failed', 'crash')
expect_fail(BASE, 'exactly one Page', 'ambiguous')
expect_fail(['create', '--name', 'Acme', '--category', 'Website', '--portfolio', '111', '--accept-terms'], 'already manage', 'namesake')
expect_fail(BASE + ['--assign-user', 'Some System User'], 'did not turn on', 'stuckoff')
# Validation runs before any browser call, so a bad create never makes a Page.
expect_fail(['create', '--name', 'Acme', '--category', 'Website', '--accept-terms'], 'portfolio', 'crash')
expect_fail(['create', '--name', 'Acme', '--category', 'Website', '--portfolio', '111'], '--accept-terms', 'crash')

result, data, bits = run(BASE + ['--assign-user', 'Some System User', '--permission', 'Ads', '--permission', 'Ads'])
assert result.returncode == 0, result.stderr
line = json.loads(result.stdout)
assert line['page_id'] == '1467561843088600' and line['assigned'] == 'Some System User'
assert data['sites']['a.example'] == {'brand': 'Acme', 'meta_page_id': '1467561843088600'}
assert bits == 0o600
assert SECRET not in result.stdout + result.stderr
print('fb-page.test: ok')

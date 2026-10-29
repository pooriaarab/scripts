#!/usr/bin/env python3
"""Exercise the rollout CLI with real Git repositories and isolated service shims."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().with_name('tsc-rs-fleet-rollout')
results = []
# Fixture pushes must not invoke hooks or credentials from the operator's Git config.
BASE_ENV = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')

def run(args, cwd=None, env=None):
    return subprocess.run(args, cwd=cwd, env=env if env is not None else BASE_ENV, text=True, capture_output=True)

with tempfile.TemporaryDirectory(prefix='tsc-rs-e2e-') as tmp:
    root = Path(tmp)
    bins = root / 'bin'
    bins.mkdir()
    fixture = root / 'source'
    fixture.mkdir()
    (fixture / '.github').mkdir()
    (fixture / '.github/pr-standards.json').write_text('{"prefix":"fx"}')
    package = {'scripts': {'typecheck': 'tsc --noEmit', 'ci:local': 'echo ci', 'build': 'tsc -b'},
               'devDependencies': {'typescript': '5.9.3'}}
    (fixture / 'package.json').write_text(json.dumps(package))
    (fixture / 'bun.lock').write_text('{}')
    for args in [['git', 'init', '-b', 'main'], ['git', 'add', '.'],
                 ['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                  'commit', '-m', 'Create fixture']]:
        result = run(args, fixture)
        assert result.returncode == 0, result.stderr
    remote = root / 'remote.git'
    assert run(['git', 'clone', '--bare', str(fixture), str(remote)]).returncode == 0
    gh = bins / 'gh'
    gh.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
a=sys.argv[1:]
with open(os.environ['CALLS'],'a') as f: f.write(json.dumps(a)+'\\n')
if a[:2]==['auth','status']: pass
elif a[:2]==['repo','clone']:
    sys.exit(subprocess.call(['git','clone','--quiet',os.environ['REMOTE'],a[3]]))
elif a[:2]==['pr','list'] or a[:2]==['issue','list']: pass
elif a[:2]==['issue','create']: print('https://github.com/fixture/fixture/issues/7')
elif a[0]=='api': print('99')
elif a[:2]==['pr','create']:
    pathlib.Path(os.environ['BODY']).write_text(pathlib.Path(a[a.index('--body-file')+1]).read_text())
    print('https://github.com/fixture/fixture/pull/8')
elif a[:2]==['pr','view']: print('abc123')
elif a[:2]==['pr','merge']: raise SystemExit('must not merge blocked PR')
else: raise SystemExit('unexpected gh call: '+repr(a))
''')
    bun = bins / 'bun'
    bun.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
if sys.argv[1]=='add':
    p=pathlib.Path('package.json'); d=json.loads(p.read_text())
    d.setdefault('devDependencies',{})['tsc-rs']='0.8.0'; p.write_text(json.dumps(d,indent=2)+'\\n')
    pathlib.Path('bun.lock').write_text('updated')
if sys.argv[1:]==['run','ci:local'] and os.environ.get('FAIL_CI')=='1': sys.exit(23)
''')
    premerge = bins / 'premerge'
    premerge.write_text('#!/bin/sh\nexit 1\n')
    for path in (gh, bun, premerge):
        path.chmod(0o755)
    env = dict(BASE_ENV, PATH=f'{bins}:{os.environ["PATH"]}', REMOTE=str(remote),
               CALLS=str(root / 'calls'), BODY=str(root / 'body'),
               GIT_AUTHOR_NAME='Fixture', GIT_COMMITTER_NAME='Fixture',
               GIT_AUTHOR_EMAIL='fixture@example.invalid', GIT_COMMITTER_EMAIL='fixture@example.invalid')

    def exercise(name, flags, failed=False):
        (root / 'calls').write_text('')
        result = run([str(SCRIPT), '--owner', 'fixture', '--repo', 'fixture', *flags], env=env)
        assert (result.returncode != 0) == failed, result.stdout + result.stderr
        calls = [json.loads(line) for line in (root / 'calls').read_text().splitlines()]
        results.append({'case': name, 'exit': result.returncode, 'passed': True})
        return calls

    calls = exercise('dry-run', ['--dry-run'])
    assert not any(a[:2] in (['issue', 'create'], ['pr', 'create']) for a in calls)
    env['FAIL_CI'] = '1'
    calls = exercise('local CI failure blocks push and PR', [], failed=True)
    assert not any(a[:2] == ['pr', 'create'] for a in calls)
    assert run(['git', '--git-dir', str(remote), 'branch', '--list', 'fx-*']).stdout == ''
    del env['FAIL_CI']
    calls = exercise('apply and pending merge gate', ['--merge-when-green'])
    assert any(a[:2] == ['pr', 'create'] for a in calls)
    assert not any(a[:2] == ['pr', 'merge'] for a in calls)
    manifest = json.loads(run(['git', '--git-dir', str(remote), 'show',
                               'fx-7-tsc-rs-0-8:package.json']).stdout)
    assert manifest['scripts']['typecheck'] == 'tsc-rs --noEmit'
    assert manifest['scripts']['build'] == 'tsc-rs -b'
    assert manifest['devDependencies']['tsc-rs'] == '0.8.0'
    assert 'tsc-rs' in manifest['trustedDependencies']
    body = (root / 'body').read_text()
    assert 'Closes #7' in body and 'Assisted-by:' in body
    assert 'Reviewed-by:' not in body
    assert any(a[:3] == ['api', '-X', 'PATCH'] for a in calls)
    assert run(['git', '--git-dir', str(remote), 'update-ref', 'refs/heads/main',
                'refs/heads/fx-7-tsc-rs-0-8']).returncode == 0
    calls = exercise('already configured repository', [])
    assert not any(a[:2] in (['issue', 'create'], ['pr', 'create']) for a in calls)
    (fixture / 'package.json').write_text('{invalid')
    assert run(['git', 'add', '.'], fixture).returncode == 0
    assert run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                'commit', '-m', 'Create invalid manifest'], fixture).returncode == 0
    sha = run(['git', 'rev-parse', 'HEAD'], fixture).stdout.strip()
    assert run(['git', '--git-dir', str(remote), 'fetch', str(fixture), 'main']).returncode == 0
    assert run(['git', '--git-dir', str(remote), 'update-ref', 'refs/heads/main', sha]).returncode == 0
    calls = exercise('invalid manifest reports failure', [], failed=True)
    assert not any(a[:2] in (['issue', 'create'], ['pr', 'create']) for a in calls)
    result = run([str(SCRIPT), '--repo', '../escape'], env=env)
    assert result.returncode == 2
    results.append({'case': 'reject unsafe repository name', 'exit': 2, 'passed': True})

artifact = Path(os.environ.get('TSC_RS_TEST_ARTIFACT', '/tmp/tsc-rs-fleet-rollout-e2e.json'))
artifact.write_text(json.dumps(results, indent=2) + '\n')
print(f'{len(results)} rollout E2E cases passed; artifact: {artifact}')

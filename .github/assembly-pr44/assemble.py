#!/usr/bin/env python3
"""Assemble reviewed PR source into verified Git objects; never move a branch."""
import base64
import hashlib
import json
import lzma
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

BASE = '0779780173c2fb9c1a14edfc9aa3e238360c997f'
PACKED = '826aaced1a4837b2986d36b19f3c2b8c1cd9982e5b53ef4ff13dfa70dba8cadd'
PATCH = '49130281c28bcbe59c93a1dc090c7337d595bcb9108f5670dde03a2ba45a6a08'
ASSEMBLY = '.github/assembly-pr44'
WORKFLOW = '.github/workflows/assemble-pr44.yml'
REPO = 'getbible/api'
ROOT = Path.cwd()
TEMP = Path(os.environ.get('RUNNER_TEMP', '/tmp'))


def git(*args):
    return subprocess.check_output(['git', *args], cwd=ROOT)


def post(path, value):
    request = urllib.request.Request('https://api.github.com/repos/' + REPO + '/git/' + path,
        data=json.dumps(value).encode(), method='POST', headers={
            'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
            'Accept': 'application/vnd.github+json', 'Content-Type': 'application/json',
            'X-GitHub-Api-Version': '2022-11-28', 'User-Agent': 'getbible-upgrade-assembly'})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f'Git object creation failed: HTTP {exc.code}: ' + exc.read().decode()[:1000]) from None


def prepare():
    if git('rev-parse', 'HEAD^').decode().strip() != BASE:
        raise ValueError('Assembly parent differs from the reviewed base; do not guess/rebase the snapshot')
    if git('rev-parse', 'HEAD').decode().strip() != os.environ['ASSEMBLY_HEAD']:
        raise ValueError('Not running on the requested PR head')
    parts = sorted((ROOT / ASSEMBLY).glob('patch.part*'))
    if [p.name for p in parts] != [f'patch.part{i:02}' for i in range(6)]:
        raise ValueError('Incomplete implementation payload')
    packed = b''.join(p.read_bytes() for p in parts)
    if hashlib.sha256(packed).hexdigest() != PACKED:
        raise ValueError('Compressed snapshot integrity failure')
    patch = lzma.decompress(packed, memlimit=128 * 1024**2)
    if hashlib.sha256(patch).hexdigest() != PATCH:
        raise ValueError('Reviewed patch integrity failure')
    destination = TEMP / 'reviewed-upgrades.patch'
    destination.write_bytes(patch)
    changes = git('apply', '--numstat', str(destination)).decode().splitlines()
    allowed = [line.split('\t', 2)[2] for line in changes]
    (TEMP / 'assembly-paths.json').write_text(json.dumps(allowed))
    subprocess.run(['git', 'apply', '--check', str(destination)], check=True)
    subprocess.run(['git', 'apply', str(destination)], check=True)
    subprocess.run(['git', 'diff', '--check'], check=True)
    print(f'Applied {len(allowed)} reviewed source/test/documentation paths; frontend rebuilt in the next step.')


def publish():
    # The branch must not contain compressed patches or this assembly job in
    # the final implementation. This script is copied outside the checkout.
    shutil.rmtree(ROOT / ASSEMBLY)
    (ROOT / WORKFLOW).unlink()
    subprocess.run(['git', 'add', '-A', '--', '.'], check=True)
    subprocess.run(['git', 'diff', '--cached', '--check'], check=True)
    allowed = set(json.loads((TEMP / 'assembly-paths.json').read_text()))
    paths = [p.decode() for p in git('diff', '--cached', '--name-only', '-z', 'HEAD').split(b'\0') if p]
    entries = []
    evidence = []
    for path in paths:
        if path not in allowed and not path.startswith(('src/apps/dashboard/static/', ASSEMBLY + '/')) and path != WORKFLOW:
            raise ValueError('Unexpected generated path: ' + path)
        index = git('ls-files', '--stage', '--', path).decode().strip()
        if not index:
            entries.append({'path': path, 'mode': '100644', 'type': 'blob', 'sha': None})
            evidence.append({'path': path, 'deleted': True})
            continue
        mode, expected, stage = index.split('\t', 1)[0].split()
        if mode not in {'100644', '100755'} or stage != '0':
            raise ValueError('Unexpected object mode/stage: ' + path)
        content = git('show', ':' + path)
        remote = post('blobs', {'content': base64.b64encode(content).decode(), 'encoding': 'base64'})
        if remote['sha'] != expected:
            raise ValueError('Uploaded object differs from tested source: ' + path)
        entries.append({'path': path, 'mode': mode, 'type': 'blob', 'sha': expected})
        evidence.append({'path': path, 'sha': expected, 'sha256': hashlib.sha256(content).hexdigest()})
        print('Verified source object:', path, expected)
    expected_tree = git('write-tree').decode().strip()
    base_tree = git('rev-parse', 'HEAD^{tree}').decode().strip()
    remote = post('trees', {'base_tree': base_tree, 'tree': entries})
    if remote['sha'] != expected_tree:
        raise ValueError('Remote tree differs from the tested local index')
    result = {'base_head': git('rev-parse', 'HEAD').decode().strip(), 'tree_sha': remote['sha'],
              'reviewed_base': BASE, 'patch_sha256': PATCH, 'files': evidence,
              'checks': 'Focused Python and CLI tests plus pinned frontend build/unit tests passed; full branch CI must run after committing this tree.'}
    (TEMP / 'upgrade-implementation-tree.json').write_text(json.dumps(result, indent=2) + '\n')
    print('Tested implementation tree:', remote['sha'])
    print('No commit, branch update, merge, release or deployment was performed by this job.')


if sys.argv[1] == 'prepare':
    prepare()
elif sys.argv[1] == 'publish':
    publish()
else:
    raise ValueError('Unknown assembly action')

#!/usr/bin/env python3
"""Read-only checks for this checkout-dependent skill and its evidence index."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit


def git(repo, *args):
    result = subprocess.run(['git', '-C', str(repo), *args], capture_output=True, text=True)
    if result.returncode:
        raise ValueError('Git check failed: ' + ' '.join(args))
    return result.stdout.strip()


def audit(repo, package):
    errors = []
    expected = repo / '.agents/skills/remotedesk-harmonyos-dev'
    required = ('AGENTS.md', 'docs/codex/STATE.json',
                'entry/src/main/ets/services/ExtensionLoader.ets')
    for name in required:
        if not (repo / name).is_file():
            errors.append('Not a usable project checkout: missing ' + name)
    if errors:
        return errors, []
    if Path(git(repo, 'rev-parse', '--show-toplevel')).resolve() != repo:
        return ['--repo must identify the repository root'], []
    count = 0
    commits = set()
    for doc in sorted(package.rglob('*.md')):
        content = doc.read_text(encoding='utf-8')
        commits.update(re.findall(r'`([0-9a-f]{7,40})`', content))
        for raw in re.findall(r'\[[^\]]*\]\(([^\s)]+)\)', content):
            target = urlsplit(raw)
            if target.scheme in ('https', 'http'):
                continue
            if target.scheme or raw.startswith('/'):
                errors.append(f'{doc.relative_to(package)}: nonportable link {raw}')
                continue
            if not target.path:
                continue
            logical = (expected / doc.relative_to(package).parent / unquote(target.path)).resolve()
            if not logical.is_relative_to(repo):
                errors.append(f'{doc.relative_to(package)}: link escapes checkout {raw}')
                continue
            actual = (package / logical.relative_to(expected)
                      if logical.is_relative_to(expected) else logical)
            if not actual.exists():
                errors.append(f'{doc.relative_to(package)}: missing link {raw}')
            count += 1
    catalog = json.loads((package / 'references/source-catalog.json').read_text(encoding='utf-8'))
    if catalog.get('schema') != 1:
        return errors + ['Unsupported catalog schema'], []
    snapshot = catalog['source_head']
    public = catalog['public_main']
    for name, value in (('source_head', snapshot), ('public_main', public)):
        if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{40}', value):
            return errors + ['Invalid full commit hash in catalog: ' + name], []
    # Check only explicitly recorded public/main and authorized task ancestry.
    # Never enumerate private refs or fetch history implicitly.
    for commit in (snapshot, public):
        git(repo, 'cat-file', '-e', commit + '^{commit}')
    rows = git(repo, 'log', '--first-parent', '--reverse', '--format=%H', public).splitlines()
    if rows != catalog['public_first_parent']:
        errors.append('Public history differs from catalog; check for shallow history or refresh the index')
    known = set(git(repo, 'rev-list', snapshot).splitlines())
    for commit in sorted(commits):
        resolved = git(repo, 'rev-parse', '--verify', commit + '^{commit}')
        if resolved not in known:
            errors.append('Evidence commit is outside recorded authorized ancestry: ' + commit)
    tracked_at_snapshot = set(git(repo, 'ls-tree', '-r', '--name-only', snapshot, '--', 'docs').splitlines())
    indexed = set()
    for item in catalog['documents']:
        name = item['path']
        if name in indexed:
            errors.append('Duplicate catalog path: ' + name)
        indexed.add(name)
        path = (repo / name).resolve()
        if not name.startswith('docs/') or not path.is_relative_to(repo):
            errors.append('Invalid catalog path: ' + name)
        elif name not in tracked_at_snapshot:
            errors.append('Catalog path was not tracked at its stated snapshot: ' + name)
        elif not path.is_file():
            errors.append('Catalog source is absent; inspect rename/removal: ' + name)
    expected_docs = {p for p in tracked_at_snapshot if p.endswith('.md')}
    if indexed != expected_docs:
        errors.append('Catalog does not fully match tracked Markdown at its stated snapshot')
    current = {p for p in git(repo, 'ls-files', '--', 'docs').splitlines() if p.endswith('.md')}
    info = [f'{count} local links; {len(commits)} cited commit IDs; '
            f'{len(rows)} public milestones; {len(indexed)} indexed documents',
            f'{len(current - indexed)} tracked Markdown added since snapshot '
            '(historical catalog remains a snapshot)']
    return errors, info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True, type=Path, help='RemoteDeskHarmonyOS checkout root')
    args = parser.parse_args()
    try:
        errors, info = audit(args.repo.resolve(), Path(__file__).resolve().parents[1])
        for line in info:
            print(line)
        for error in errors:
            print('FAIL: ' + error, file=sys.stderr)
        if errors:
            return 1
        print('PASS: structural references and recorded evidence; technical claims require review')
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print('FAIL: ' + str(exc), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())

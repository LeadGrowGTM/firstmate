#!/usr/bin/env python3
"""Deterministic collector implementation; fm-domain-freshness.sh owns the CLI."""
import base64
import binascii
import datetime as dt
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote


class CoverageError(Exception):
    pass


MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_PAGES = 20


def encoded_size(value):
    return len(json.dumps(value, sort_keys=True, ensure_ascii=True).encode()) + 1


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def instant(value):
    if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ', value):
        raise ValueError('expected an ISO UTC timestamp')
    return dt.datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=dt.timezone.utc)


def iso(value):
    return value.strftime('%Y-%m-%dT%H:%M:%SZ')


def safe_path(path):
    """Reject symlinks in collector-owned storage, including ancestors."""
    path = Path(path)
    if not path.is_absolute() or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('unsafe collector path')
    return path


def load(path, limit=MAX_JSON_BYTES):
    safe_path(path)
    if path.stat().st_size > limit:
        raise ValueError('JSON input exceeds read limit')
    with path.open() as handle:
        return json.load(handle)


def publish(path, value):
    safe_path(path)
    fd, temporary = tempfile.mkstemp(prefix='.publish-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, sort_keys=True, ensure_ascii=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def api(path):
    # The shared timeout owner bounds the complete gh-axi process group.
    owner = str(Path(__file__).with_name('fm-timeout-lib.sh'))
    # gh-axi emits TOON even for caller-shaped JSON. Base64 makes the raw
    # response a single bounded-alphabet field in its documented raw envelope.
    command = ['bash', '-c', '. "$1"; fm_run_timed 10 gh-axi api GET "$2" --jq @base64 --full', '_', owner, path]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise CoverageError('forge read failed (exit %s): %s' % (result.returncode, path))
    try:
        match = re.fullmatch(r'api_response:\s*\n  body: ([A-Za-z0-9+/=]+)\n  truncated: false\s*', result.stdout)
        if not match:
            raise ValueError('expected a complete raw API envelope')
        return json.loads(base64.b64decode(match[1], validate=True))
    except (ValueError, TypeError) as error:
        raise CoverageError('malformed forge response: ' + path) from error


def pages(path):
    for page in range(1, MAX_PAGES + 1):
        rows = api(path + ('&' if '?' in path else '?') + 'per_page=100&page=' + str(page))
        if not isinstance(rows, list) or len(rows) > 100 or any(not isinstance(row, dict) for row in rows):
            raise CoverageError('malformed forge page: ' + path)
        yield rows
        if len(rows) < 100:
            return
    raise CoverageError('pagination limit reached: ' + path)


def stable_feed(path, ordering, lower):
    def scan():
        result = []
        for rows in pages(path):
            result.append(rows)
            if any(instant(row.get(ordering)) < lower for row in rows):
                break
        return result

    first = scan()
    second = scan()
    if first != second:
        raise CoverageError('forge feed changed during pagination: ' + path)
    return second


def linked_observations(home):
    result = {}
    data = safe_path(Path(home) / 'data')
    for path in sorted(data.glob('*/contributions.json')):
        record = load(path, 1024 * 1024)
        if not isinstance(record, dict) or record.get('schema') != 'fm-contributions.v1' or record.get('task') != path.parent.name or not isinstance(record.get('records'), list):
            raise CoverageError('invalid durable contribution record')
        for row in record['records']:
            if not isinstance(row, dict):
                raise CoverageError('invalid durable contribution row')
            if row.get('retired') is not None:
                continue
            observed = row.get('observation')
            if observed is not None and not isinstance(observed, dict):
                raise CoverageError('invalid durable contribution observation')
            fields = ('head', 'state', 'draft', 'mergeable') if row.get('kind') == 'pr' else ('state', 'ready')
            result.setdefault(str(row.get('url')).casefold(), []).append({'task': record['task'], 'checked_at': row.get('checked_at'),
                'error': row.get('error'), 'observation': None if observed is None else
                {key: observed.get(key) for key in fields}})
    return result


def forge_identity(url, repo, kind, number):
    match = re.fullmatch(r'https://github\.com/([^/]+/[^/]+)/(pull|issues)/([1-9]\d*)', url or '')
    if not match or match[1].casefold() != repo.casefold() or match[2] != kind or int(match[3]) != number:
        raise CoverageError('noncanonical forge identity')
    return match[1]


def instruction_file(path):
    parts = path.lower().split('/')
    return parts[-1] in ('agents.md', 'claude.md', 'gemini.md', 'skill.md') or ('skills' in parts[:-1] and parts[-1].endswith('.md'))


def instruction_excerpt(value):
    if not isinstance(value, dict) or value.get('encoding') != 'base64' or not isinstance(value.get('content'), str):
        raise CoverageError('invalid PR instruction content')
    try:
        content = base64.b64decode(''.join(value['content'].splitlines()), validate=True)
        excerpt = content.decode('utf-8')
    except (ValueError, UnicodeDecodeError, binascii.Error) as error:
        raise CoverageError('invalid PR instruction content') from error
    if len(content) > 1048576:
        raise CoverageError('PR instruction exceeds 1 MiB')
    return {'digest': hashlib.sha256(content).hexdigest(), 'bytes': len(content),
            'content': excerpt[:4096], 'content_truncated': len(excerpt) > 4096}


def pr_instruction(repo, path, revision):
    value = api('/repos/%s/contents/%s?ref=%s' % (repo, quote(path, safe='/'), quote(revision, safe='')))
    if not isinstance(value, dict) or value.get('type') != 'file':
        raise CoverageError('invalid PR instruction content')
    return instruction_excerpt(value)


def pr_instruction_blob(repo, sha):
    if not isinstance(sha, str) or not re.fullmatch(r'[0-9a-fA-F]{40}', sha):
        raise CoverageError('missing PR instruction blob identity')
    value = api('/repos/%s/git/blobs/%s' % (repo, sha))
    if not isinstance(value, dict) or value.get('sha') != sha:
        raise CoverageError('inconsistent PR instruction blob')
    return instruction_excerpt(value)


def forge(source, previous, now, contributions):
    start = instant(previous['checkpoint']) if previous else now - dt.timedelta(days=1)
    lower = start - dt.timedelta(seconds=300) if previous else start
    seen = dict(previous.get('seen', {})) if previous else {}
    events = []
    repo = source['repo']
    prefix = '/repos/' + repo
    for kind, endpoint, timestamp in [('merged-pr', '/pulls?state=closed&sort=updated&direction=desc', 'merged_at'),
                                       ('new-issue', '/issues?state=all&sort=created&direction=desc&since=' + iso(lower), 'created_at')]:
        ordering = 'updated_at' if kind == 'merged-pr' else 'created_at'
        for rows in stable_feed(prefix + endpoint, ordering, lower):
            for row in rows:
                if kind == 'new-issue' and 'pull_request' in row:
                    continue
                when = row.get(timestamp)
                if when is None and kind == 'merged-pr':
                    continue
                occurred = instant(when)
                if not lower <= occurred <= now:
                    continue
                number = row.get('number')
                if type(number) is not int or number < 1:
                    raise CoverageError('invalid forge object number')
                url = row.get('html_url')
                actual_repo = forge_identity(url, repo, 'pull' if kind == 'merged-pr' else 'issues', number)
                key = kind + ':' + url
                if key in seen:
                    continue
                event = {'kind': kind, 'url': url, 'repository': actual_repo, timestamp: when,
                         'title': row.get('title'), 'labels': row.get('labels', [])}
                if kind == 'merged-pr':
                    detail = api(prefix + '/pulls/' + str(number))
                    if not isinstance(detail, dict) or detail.get('merged_at') != when or detail.get('html_url') != url:
                        raise CoverageError('inconsistent merged PR detail')
                    base, head = detail.get('base', {}), detail.get('head', {})
                    base_repo = (base.get('repo') or {}).get('full_name')
                    head_repo = (head.get('repo') or {}).get('full_name')
                    if not base.get('ref') or not base.get('sha') or not head.get('sha') or not isinstance(base_repo, str) or base_repo.casefold() != repo.casefold():
                        raise CoverageError('missing PR base/head metadata')
                    if head_repo is not None and (not isinstance(head_repo, str) or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', head_repo)):
                        raise CoverageError('invalid PR head repository')
                    files = []
                    for file_rows in pages(prefix + '/pulls/' + str(number) + '/files'):
                        for item in file_rows:
                            if not isinstance(item.get('filename'), str) or not isinstance(item.get('status'), str):
                                raise CoverageError('malformed PR file metadata')
                            file = {key: item.get(key) for key in ['filename', 'previous_filename', 'status', 'sha', 'additions', 'deletions', 'changes', 'blob_url', 'raw_url']}
                            old_path = item.get('previous_filename') if item['status'] == 'renamed' else item['filename']
                            if instruction_file(item['filename']) or (isinstance(old_path, str) and instruction_file(old_path)):
                                file['instruction'] = {
                                    'before': None if item['status'] == 'added' else pr_instruction(base_repo, old_path, base['sha']),
                                    'after': None if item['status'] == 'removed' else (
                                        pr_instruction(head_repo, item['filename'], head['sha']) if head_repo else
                                        pr_instruction_blob(base_repo, item.get('sha')))}
                            files.append(file)
                    if type(detail.get('changed_files')) is not int or len(files) != detail['changed_files']:
                        raise CoverageError('truncated PR changed-file set')
                    event.update(base={'repository': base_repo, 'ref': base['ref'], 'sha': base['sha']},
                                 head={'repository': head_repo, 'ref': head.get('ref'), 'sha': head['sha']},
                                 files=files)
                event['linked_contributions'] = contributions.get(url.casefold(), [])
                events.append(event)
                seen[key] = when
    # Only identities in the overlap need retention after a complete read.
    seen = {key: value for key, value in seen.items() if instant(value) >= now - dt.timedelta(seconds=300)}
    return {'checkpoint': iso(now), 'seen': seen}, events, {'window_start': iso(lower), 'window_end': iso(now)}


FORBIDDEN = {'.ssh', '.git', 'credentials', 'credentials.json', '.credentials.json', 'auth.json',
             'secrets', 'clients', 'browser', 'profiles', 'logs', 'state'}


def inventory_path(path, roots):
    absolute = Path(path).absolute()
    resolved = absolute.resolve(strict=True)
    if any(part.lower() in FORBIDDEN or part.lower().startswith('.env') for part in (*absolute.parts, *resolved.parts)):
        raise CoverageError('excluded inventory path')
    if not any(resolved == root or root in resolved.parents for root in roots):
        raise CoverageError('inventory symlink escapes declared safe roots')
    return resolved


def projection(value, kind):
    if not isinstance(value, dict):
        raise CoverageError('manifest must be an object')
    if kind == 'plugin-enablement':
        enabled = value.get('enabledPlugins')
        if not isinstance(enabled, dict) or any(type(v) is not bool for v in enabled.values()):
            raise CoverageError('missing effective enabledPlugins map')
        return {'enabledPlugins': enabled}
    if kind == 'plugin-version':
        if not isinstance(value.get('version'), str) or not isinstance(value.get('name'), str):
            raise CoverageError('missing plugin name/version')
        return {'name': value['name'], 'version': value['version']}
    plugins = value.get('plugins')
    if not isinstance(plugins, dict):
        raise CoverageError('missing installed plugins map')
    result = {}
    for name, entries in plugins.items():
        if not isinstance(entries, list):
            raise CoverageError('malformed installed plugin entries')
        result[name] = []
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get('version'), str):
                raise CoverageError('missing installed plugin version')
            result[name].append({key: entry.get(key) for key in ['version', 'scope', 'projectPath', 'installPath']})
        result[name].sort(key=lambda item: json.dumps(item, sort_keys=True))
    return {'plugins': result}


def inventory_snapshot(source):
    if source['kind'] == 'plugin-files' and not {'plugin-manifest', 'plugin-enablement'} <= {item['kind'] for item in source['files']}:
        raise CoverageError('plugin manifest and enablement surfaces are required')
    root = Path(source['root'])
    roots = [Path(item).resolve(strict=True) for item in [source['root'], *source.get('symlink_roots', [])]]
    inventory_path(root, roots)
    paths = []
    if source['kind'] == 'skills':
        visited = set()
        entries = 0

        def walk(directory):
            nonlocal entries
            actual = inventory_path(directory, roots)
            if actual in visited:
                raise CoverageError('duplicate or cyclic skill symlink')
            visited.add(actual)
            remaining = 2000 - entries
            items = list(itertools.islice(directory.iterdir(), remaining + 1))
            if len(items) > remaining:
                raise CoverageError('skill inventory limit reached')
            entries += len(items)
            for item in sorted(items):
                if item.name.lower() in FORBIDDEN or item.name.lower().startswith('.env'):
                    continue
                resolved = inventory_path(item, roots)
                if resolved.is_dir():
                    walk(item)
                elif resolved.is_file():
                    paths.append((item, 'instruction' if item.suffix.lower() == '.md' else 'asset'))
        walk(root)
    else:
        paths = [(root / item['path'], item['kind']) for item in source['files']]
    records = {}
    for path, kind in paths:
        if source['kind'] == 'plugin-files' and kind in ('instruction', 'plugin-version', 'asset') and not path.exists() and not path.is_symlink():
            inventory_path(path.parent, roots)
            continue
        resolved = inventory_path(path, roots)
        if not resolved.is_file() or resolved.stat().st_size > 1048576:
            raise CoverageError('inventory file unavailable or exceeds 1 MiB')
        content = resolved.read_bytes()
        if kind == 'instruction':
            text = content.decode('utf-8')
            metadata = {'digest': hashlib.sha256(content).hexdigest(), 'bytes': len(content),
                        'content': text[:4096], 'content_truncated': len(text) > 4096}
        elif kind == 'asset':
            metadata = {'digest': hashlib.sha256(content).hexdigest(), 'bytes': len(content)}
        else:
            value = projection(json.loads(content), kind)
            metadata = {'digest': digest(value), 'manifest': value}
        records[str(path.relative_to(root))] = {'kind': kind, **metadata}
    return {'root': str(root), 'inventory': records, 'surfaces': sorted({record['kind'] for record in records.values()}),
            'source_binding': digest({key: source.get(key) for key in ('kind', 'root', 'files', 'symlink_roots')})}


def inventory_changes(snapshot, previous, now):
    root = Path(snapshot['root'])
    records = snapshot['inventory']
    old = previous.get('inventory', {}) if previous else {}
    changes = []
    for path in sorted(set(records) | set(old)):
        if records.get(path) != old.get(path):
            changes.append({'kind': 'inventory-baseline' if previous is None else 'inventory-change',
                            'path': str(root / path), 'before': None if previous is None else old.get(path), 'after': records.get(path)})
    # An empty first baseline is still explicit evidence.
    if previous is None and not changes:
        changes.append({'kind': 'inventory-baseline', 'root': str(root), 'entries': 0})
    return {'checkpoint': iso(now), 'inventory': records}, changes, {'baseline': previous is None, 'root': str(root),
            'surfaces': snapshot['surfaces'], 'session_visibility': 'unmeasured'}


def remote_inventory(source, home):
    command = ['bash', str(Path(__file__).with_name('fm-on.sh')), source['route'],
               'fm-domain-freshness.sh', 'inventory', source['source']]
    try:
        result = subprocess.run(command, env={**os.environ, 'FM_HOME': home}, capture_output=True, timeout=60, check=False)
    except subprocess.TimeoutExpired as error:
        raise CoverageError('remote inventory transport timed out') from error
    if result.returncode:
        raise CoverageError('remote inventory transport failed (exit %s)' % result.returncode)
    if len(result.stdout) > MAX_JSON_BYTES:
        raise CoverageError('remote inventory exceeds read limit')
    try:
        snapshot = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError) as error:
        raise CoverageError('invalid remote inventory response') from error
    if not isinstance(snapshot, dict) or snapshot.get('source') != source['source'] or not isinstance(snapshot.get('root'), str) or not isinstance(snapshot.get('inventory'), dict) or not isinstance(snapshot.get('surfaces'), list) or not isinstance(snapshot.get('source_binding'), str):
        raise CoverageError('invalid remote inventory response')
    return snapshot


def validate_config(config):
    if not isinstance(config, dict) or config.get('version') != 1 or type(config.get('enabled')) is not bool:
        raise ValueError('config requires version:1 and boolean enabled')
    if 'max_pages' in config:
        raise ValueError('max_pages is unsupported')
    sources = config.get('sources')
    if not isinstance(sources, list) or len(sources) > 100:
        raise ValueError('sources must be an array of at most 100 entries')
    ids = set()
    for source in sources:
        if not isinstance(source, dict) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', source.get('id', '')) or source['id'] in ids:
            raise ValueError('source ids must be unique safe identifiers')
        ids.add(source['id'])
        kind = source.get('kind')
        if kind == 'repository':
            if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', source.get('repo', '')):
                raise ValueError('invalid repository')
        elif kind in ('skills', 'plugin-files'):
            for path in [source.get('root', ''), *source.get('symlink_roots', [])]:
                if not isinstance(path, str) or not Path(path).is_absolute() or path == '/':
                    raise ValueError('inventory roots must be specific absolute paths')
            if kind == 'plugin-files':
                files = source.get('files')
                if not isinstance(files, list) or not files or len(files) > 2000:
                    raise ValueError('plugin-files requires a bounded files list')
                names = set()
                for item in files:
                    if not isinstance(item, dict):
                        raise ValueError('inventory files must be objects')
                    path = item.get('path', '')
                    if not isinstance(path, str) or not path or Path(path).is_absolute() or '..' in Path(path).parts or path in names:
                        raise ValueError('invalid or duplicate inventory filename')
                    names.add(path)
                    if item.get('kind') not in ('instruction', 'asset', 'plugin-manifest', 'plugin-enablement', 'plugin-version'):
                        raise ValueError('invalid inventory file kind')
        elif kind == 'unavailable':
            if not isinstance(source.get('reason'), str) or not source['reason'].strip():
                raise ValueError('unavailable source requires a reason')
        elif kind == 'remote-inventory':
            if not all(isinstance(source.get(field), str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', source[field]) for field in ('route', 'source')):
                raise ValueError('remote inventory requires safe route and source ids')
        else:
            raise ValueError('unsupported source kind')


def inventory_cli(home, config_path, source_id):
    config = load(Path(config_path))
    validate_config(config)
    source = next((item for item in config['sources'] if item['id'] == source_id), None)
    if source is None or source['kind'] not in ('skills', 'plugin-files'):
        raise ValueError('undeclared local inventory source')
    snapshot = {'source': source_id, **inventory_snapshot(source)}
    if encoded_size(snapshot) > MAX_JSON_BYTES:
        raise CoverageError('inventory exceeds read limit')
    print(json.dumps(snapshot, sort_keys=True, ensure_ascii=True))
    return 0


def main():
    home, config_path, domains_path, clock = sys.argv[1:]
    config = load(Path(config_path))
    validate_config(config)
    if not config['enabled']:
        return 0
    now = instant(clock)
    directory = safe_path(Path(home) / 'data' / 'domain-freshness')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    bundles = safe_path(directory / 'bundles')
    bundles.mkdir(mode=0o700, exist_ok=True)
    lock = directory / '.collect.lock'
    # Advisory locks release on process death. Keep the inode permanently so a
    # concurrent opener cannot accidentally lock a different replacement file.
    fd = os.open(safe_path(lock), os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        cursor_path = directory / 'cursors.json'
        cursor = load(cursor_path) if cursor_path.exists() else {'version': 1, 'sources': {}}
        if cursor.get('version') != 1 or not isinstance(cursor.get('sources'), dict):
            raise ValueError('invalid collector cursor')
        for saved in cursor['sources'].values():
            if not isinstance(saved, dict) or not isinstance(saved.get('binding'), str):
                raise ValueError('invalid source cursor')
            instant(saved.get('checkpoint'))
            if not isinstance(saved.get('seen', {}), dict) or not isinstance(saved.get('inventory', {}), dict):
                raise ValueError('invalid source cursor data')
        domains = load(Path(domains_path))
        coverage = []
        evidence = []
        contributions = {}
        contribution_error = None
        if any(source['kind'] == 'repository' for source in config['sources']):
            try:
                contributions = linked_observations(home)
            except (CoverageError, OSError, ValueError, KeyError, TypeError) as error:
                contribution_error = error
        if domains['coverage'] not in ('complete', 'absent'):
            coverage.append({'id': 'registry', 'complete': False, 'reason': domains['coverage']})
        elif len({row['id'] for row in domains['domains']}) != len(domains['domains']):
            coverage.append({'id': 'registry', 'complete': False, 'reason': 'duplicate domain id'})
        for source in config['sources']:
            key = source['id']
            binding = digest(source)
            previous = cursor['sources'].get(key)
            try:
                snapshot = remote_inventory(source, home) if source['kind'] == 'remote-inventory' else None
                if snapshot is not None:
                    binding = digest({'source': source, 'remote': snapshot['source_binding']})
                if previous and previous.get('binding') != binding:
                    previous = None
                if previous and instant(previous['checkpoint']) > now:
                    raise CoverageError('clock precedes successful checkpoint')
                if source['kind'] == 'repository':
                    if contribution_error is not None:
                        raise CoverageError('durable contributions unavailable: ' + str(contribution_error))
                    saved, events, detail = forge(source, previous, now, contributions)
                elif source['kind'] == 'unavailable':
                    raise CoverageError(source['reason'])
                elif source['kind'] == 'remote-inventory':
                    saved, events, detail = inventory_changes(snapshot, previous, now)
                else:
                    saved, events, detail = inventory_changes(inventory_snapshot(source), previous, now)
                candidate = {**cursor, 'sources': {**cursor['sources'], key: {**saved, 'binding': binding}}}
                if encoded_size(candidate) > MAX_JSON_BYTES:
                    raise CoverageError('cursor exceeds read limit')
                cursor = candidate
                coverage.append({'id': key, 'kind': source['kind'], 'complete': True, **detail})
                evidence.extend({'source': key, **event} for event in events)
            except (CoverageError, OSError, ValueError, KeyError, TypeError) as error:
                coverage.append({'id': key, 'kind': source['kind'], 'complete': False, 'reason': str(error)})
        complete = all(row['complete'] for row in coverage)
        bundle = {'schema': 'fm-domain-evidence.v1', 'collected_at': iso(now), 'complete': complete,
                  'registry_coverage': domains['coverage'], 'domains': domains['domains'], 'coverage': coverage, 'evidence': evidence}
        identity = digest(bundle)
        output = bundles / (identity + '.json')
        if output.exists():
            if load(output, max(MAX_JSON_BYTES, encoded_size(bundle))) != bundle:
                raise ValueError('bundle identity collision')
        else:
            publish(output, bundle)
        publish(cursor_path, cursor)
        if evidence or not complete:
            print(output)
        return 0 if complete else 2
    finally:
        os.close(fd)


if __name__ == '__main__':
    try:
        sys.exit(inventory_cli(*sys.argv[2:]) if sys.argv[1] == 'inventory' else main())
    except (OSError, ValueError, KeyError, TypeError, CoverageError) as exc:
        print('fm-domain-freshness: ' + str(exc), file=sys.stderr)
        sys.exit(1)

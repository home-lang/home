#!/usr/bin/env python3
"""Validate retained native corpus evidence without retrying or inventing cases.

Exit 0 requires complete, internally consistent, successful execution. Skipped
and TODO cases stay separate, and are never credited as passing features.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


COUNTS = ('passed', 'failed', 'skipped', 'todo')


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def summarize(directory):
    directory = Path(directory)
    errors, selected, started, completed, cases = [], {}, {}, {}, []
    finished = None
    totals = dict.fromkeys(COUNTS, 0)
    run = None

    def check(condition, message):
        if not condition:
            errors.append(message)
        return condition

    def artifact(row, kind):
        name = row.get(kind + '_file')
        if not check(isinstance(name, str) and Path(name).name == name, f"{row['id']}: invalid {kind} artifact name"):
            return None
        path = directory / name
        try:
            check(digest(path) == row.get(kind + '_sha256'), f"{row['id']}: {kind} SHA256 mismatch")
            return path
        except OSError as error:
            errors.append(f"{row['id']}: cannot read {kind}: {error}")
            return None

    try:
        data = (directory / 'events.jsonl').read_bytes()
    except OSError as error:
        return {'directory': str(directory), 'successful': False, 'errors': [str(error)]}
    check(data.endswith(b'\n'), 'journal has an incomplete final line')
    for number, line in enumerate(data.splitlines(), 1):
        try:
            row = json.loads(line)
            event = row['event']
            check(finished is None, f'line {number}: event after finished')
            if event == 'run':
                check(number == 1 and run is None and row.get('schema') == 1, 'invalid run header')
                run = row
            elif event == 'selected':
                identity = row['id']
                check(not started and identity == len(selected) and identity not in selected, f'line {number}: invalid selection order')
                selected[identity] = row
            elif event == 'started':
                identity = row['id']
                check(identity in selected and identity == len(started) and len(started) == len(completed), f'line {number}: invalid start order')
                check(row.get('phase') == 'launch_attempt', f'{identity}: unknown start phase')
                check(isinstance(row.get('argv'), list) and bool(row['argv']), f'{identity}: missing argv')
                check(isinstance(row.get('timeout_ms'), int) and row['timeout_ms'] > 0, f'{identity}: missing deadline')
                for key in ('source_sha256', 'executable_sha256'):
                    value = row.get(key)
                    check(isinstance(value, str) and len(value) == 64 and all(c in '0123456789abcdef' for c in value), f'{identity}: missing {key}')
                started[identity] = row
            elif event == 'completed':
                identity = row['id']
                check(identity in started and identity == len(completed) and len(started) == len(completed) + 1, f'line {number}: invalid completion order')
                completed[identity] = row
                for kind in ('stdout', 'stderr'):
                    artifact(row, kind)
                check(row.get('source_unchanged') is True, f'{identity}: source changed during execution')
                for key in ('timed_out', 'expected_failure_verified'):
                    check(type(row.get(key)) is bool, f'{identity}: invalid {key} state')
                counts = row.get('counts', {})
                for key in COUNTS:
                    check(type(counts.get(key)) is int and counts[key] >= 0, f'{identity}: invalid {key} count')
                if not all(type(counts.get(key)) is int for key in COUNTS):
                    continue
                if row.get('junit') == 'retained':
                    path = artifact(row, 'junit')
                    if path:
                        try:
                            xml = ET.parse(path).getroot()
                            check(xml.tag in ('testsuites', 'testsuite'), f'{identity}: unexpected XML root')
                            observed = dict.fromkeys(COUNTS, 0)
                            for case in xml.iter('testcase'):
                                skipped = case.find('skipped')
                                failed = case.find('failure') is not None or case.find('error') is not None
                                check(not (failed and skipped is not None), f'{identity}: case has failure and skip')
                                status = 'failed' if failed else ('todo' if skipped.get('message') == 'TODO' else 'skipped') if skipped is not None else 'passed'
                                observed[status] += 1
                                cases.append({'file_id': identity, 'name': case.get('name'), 'classname': case.get('classname'), 'status': status})
                            check(observed == {key: counts[key] for key in COUNTS}, f'{identity}: JUnit cases disagree with process counters: {observed} != {counts}')
                        except (ET.ParseError, OSError) as error:
                            errors.append(f'{identity}: invalid JUnit: {error}')
                elif row.get('junit') == 'missing':
                    check(sum(counts[key] for key in COUNTS) == 0, f'{identity}: missing JUnit for registered cases')
                else:
                    check(row.get('junit') == 'not_requested', f'{identity}: unknown JUnit state')
                if not row.get('expected_failure_verified'):
                    for key in COUNTS:
                        totals[key] += counts[key]
            elif event == 'preparation_failed':
                errors.append(f"{row.get('id')}: preparation failed: {row.get('error_name')}")
            elif event == 'finished':
                finished = row
                for key, collection in [('selected', selected), ('started', started), ('completed', completed)]:
                    check(row.get(key) == len(collection), f'finished {key} count mismatch')
                check(row.get('all_selected_completed') is True and len(completed) == len(selected), 'not all selected files completed')
                summary = row.get('summary', {})
                for key in COUNTS:
                    check(summary.get(key) == totals[key], f'finished {key} does not match completed counters')
                check(summary.get('files') == len(completed), 'finished file count mismatch')
            else:
                errors.append(f'line {number}: unknown event {event}')
        except (ValueError, KeyError, TypeError, AttributeError) as error:
            errors.append(f'line {number}: malformed event: {error}')
    check(run is not None, 'missing run header')
    check(finished is not None, 'run did not finish')
    check(bool(selected), 'no files selected')
    failures = []
    for identity, row in completed.items():
        term = row.get('term', {})
        expected = row.get('expected_failure_verified') is True
        if row.get('timed_out') or (term != {'exited': 0} and not expected) or (isinstance(row.get('counts'), dict) and row['counts'].get('failed', 0) and not expected):
            failures.append(identity)
    summary = finished.get('summary', {}) if finished else {}
    if not isinstance(summary, dict):
        errors.append('malformed final summary')
        summary = {}
    successful = not errors and not failures and summary.get('failed_files') == 0 and summary.get('unsupported') == 0
    return {'directory': str(directory), 'successful': successful, 'selected': len(selected), 'started': len(started), 'completed': len(completed),
            'unstarted': [row for identity, row in selected.items() if identity not in started],
            'incomplete': [selected[identity] for identity in started if identity in selected and identity not in completed],
            'counts': totals, 'summary': summary, 'failed_file_ids': failures, 'cases': cases, 'errors': errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    result = summarize(args.directory)
    print(json.dumps(result, indent=2))
    return 0 if result['successful'] else 1


if __name__ == '__main__':
    sys.exit(main())

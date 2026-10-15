#!/usr/bin/env python3
"""Check native JUnit XML and its journal against the control's original labels."""
import base64
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
cases = list(ET.parse(root / 'control.xml').getroot().iter('testcase'))
metadata = [json.loads(line) for line in (root / 'control.cases.jsonl').read_text().splitlines()
            if json.loads(line).get('event') != 'terminal']
assert len(cases) == len(metadata) == 5
for case, row in zip(cases, metadata):
    for key in ('name', 'classname', 'file'):
        encoded = case.get('bun-' + key + '-base64')
        original = base64.b64decode(encoded, validate=True).decode() if encoded is not None else case.get(key)
        assert original == row[key], (key, original, row[key])

expected_names = ['case\x1b[0m\x01\x0b\x1f\ufffe\uffff',
                  'tabs\tnewlines\nreturns\r remain exact',
                  'literal &#27; and replacement \ufffd remain distinct',
                  'skip\x1b[0m', 'todo\x00']
expected_class = 'suite\x1b[35m\x00\ufffe\uffff & < > "'
assert [row['name'] for row in metadata] == expected_names
assert all(row['classname'] == expected_class for row in metadata)
assert [row['status'] for row in metadata] == ['pass', 'pass', 'pass', 'skip', 'todo']
assert all(case.find('failure') is None and case.find('error') is None for case in cases)
assert sum(case.find('skipped') is None for case in cases) == 3
assert sum(case.find('skipped') is not None for case in cases) == 2
print(json.dumps({'cases': 5, 'passed': 3, 'skipped_or_todo': 2,
                  'identities_exact': True, 'xml_valid': True}))

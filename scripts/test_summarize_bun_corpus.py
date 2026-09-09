"""Storage-validator controls; these do not represent native corpus passes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('corpus_summary', Path(__file__).with_name('summarize-bun-corpus.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class JournalValidation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.counts = dict(passed=1, failed=0, skipped=1, todo=1)
        self.rows = [
            dict(event='run', schema=1, corpus_root='/control'),
            dict(event='selected', id=0, path='control.test.js'),
            dict(event='started', id=0, phase='launch_attempt', mode='test_runner', argv=['/control/home', 'test', 'control.test.js'], timeout_ms=180000, source_sha256='a' * 64, executable_sha256='b' * 64),
            dict(event='completed', id=0, term={'exited': 0}, timed_out=False, source_unchanged=True, expected_failure_verified=False, counts=self.counts.copy(), junit='retained'),
            dict(event='finished', selected=1, started=1, completed=1, all_selected_completed=True, summary=dict(files=1, failed_files=0, unsupported=0, **self.counts)),
        ]
        self.artifact('stdout', b'raw\x00bytes')
        self.artifact('stderr', b'original diagnostics')
        self.artifact('junit', b'<testsuites><testsuite><testcase name="pass"/><testcase name="skip"><skipped/></testcase><testcase name="todo"><skipped message="TODO"/></testcase></testsuite></testsuites>')

    def artifact(self, kind, data):
        name = '000000.' + kind
        (self.root / name).write_bytes(data)
        self.rows[3][kind + '_file'] = name
        self.rows[3][kind + '_sha256'] = hashlib.sha256(data).hexdigest()

    def result(self):
        (self.root / 'events.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in self.rows))
        return module.summarize(self.root)

    def test_distinct_cases_and_binary_integrity(self):
        result = self.result()
        self.assertTrue(result['successful'], result)
        self.assertEqual([case['status'] for case in result['cases']], ['passed', 'skipped', 'todo'])
        (self.root / '000000.stdout').write_bytes(b'altered')
        self.assertFalse(module.summarize(self.root)['successful'])

    def test_malformed_xml_and_missing_cases(self):
        self.artifact('junit', b'<testsuites>truncated')
        self.assertFalse(self.result()['successful'])
        self.artifact('junit', b'<testsuites/>')
        self.assertFalse(self.result()['successful'])
        self.rows[3]['junit'] = 'missing'
        self.assertFalse(self.result()['successful'])

    def test_interrupted_and_unstarted_are_preserved(self):
        self.rows.insert(2, dict(event='selected', id=1, path='unstarted.test.js'))
        self.rows = self.rows[:4]
        result = self.result()
        self.assertFalse(result['successful'])
        self.assertEqual(result['incomplete'][0]['path'], 'control.test.js')
        self.assertEqual(result['unstarted'][0]['path'], 'unstarted.test.js')

    def test_exit_signal_timeout_and_source_change_fail(self):
        for key, value in [('term', {'exited': 1}), ('term', {'signal': 'TERM'}), ('timed_out', True), ('source_unchanged', False)]:
            with self.subTest(key=key, value=value):
                old = self.rows[3][key]
                self.rows[3][key] = value
                self.assertFalse(self.result()['successful'])
                self.rows[3][key] = old

    def test_malformed_truncated_and_wrong_order_fail(self):
        self.result()
        path = self.root / 'events.jsonl'
        path.write_bytes(path.read_bytes() + b'{"event":')
        self.assertFalse(module.summarize(self.root)['successful'])
        self.rows[1], self.rows[2] = self.rows[2], self.rows[1]
        self.assertFalse(self.result()['successful'])

    def test_malformed_summary_is_reported_without_crashing(self):
        self.rows[4]['summary'] = ['invalid']
        result = self.result()
        self.assertFalse(result['successful'])
        self.assertIn('malformed final summary', result['errors'])

    def test_verified_negative_retains_failure_without_passing_case_credit(self):
        counts = dict(passed=0, failed=1, skipped=0, todo=0)
        self.rows[3].update(counts=counts, term={'exited': 1}, expected_failure_verified=True)
        self.artifact('junit', b'<testsuites><testsuite><testcase name="expected failure"><failure/></testcase></testsuite></testsuites>')
        self.rows[4]['summary'].update(dict.fromkeys(counts, 0), process_checks_passed=1)
        result = self.result()
        self.assertTrue(result['successful'], result)
        self.assertEqual(result['cases'][0]['status'], 'failed')
        self.assertEqual(sum(result['counts'].values()), 0)

    def test_schema_two_requires_complete_captures(self):
        self.rows[0]['schema'] = 2
        self.assertFalse(self.result()['successful'])
        self.rows[3]['output_complete'] = False
        result = self.result()
        self.assertFalse(result['successful'])
        self.assertEqual(result['capture_completeness']['incomplete'], 1)
        self.rows[3]['output_complete'] = True
        result = self.result()
        self.assertTrue(result['successful'], result)
        self.assertEqual(result['capture_completeness']['complete'], 1)

    def test_selection_exclusions_are_separate_and_inventory_cannot_disappear(self):
        policy = dict(event='selection', contract='bun-4982b91e-primary',
                      inventory=['control.test.js', 'excluded.test.js', 'outside-range.test.js'],
                      selected_indices=[0, 2], excluded=[dict(index=1, reason='expectation', rule=0)],
                      home_expectations=[dict(filename='test/excluded.test.js', line=1)],
                      additional_home_coverage=[0], range_start=0, range_end=1)
        self.rows.insert(1, policy)
        result = self.result()
        self.assertTrue(result['successful'], result)
        self.assertEqual(result['selected'], 1)
        self.assertEqual(result['counts'], self.counts)
        self.assertEqual(len(result['selection_policy']['excluded']), 1)
        policy['selected_indices'] = [0]
        self.assertFalse(self.result()['successful'])
        policy['selected_indices'] = [2, 0]
        self.assertFalse(self.result()['successful'])
        policy['selected_indices'] = [0, 2]
        policy['excluded'][0]['rule'] = 99
        self.assertFalse(self.result()['successful'])

    def test_native_platform_records_reject_mismatches_and_unknown_values(self):
        policy = dict(event='selection', contract='bun-4982b91e-primary',
                      native_platform_detected=True, asan_step=False,
                      context=dict(os='darwin', arch='aarch64', distro_version='27.0', abi=None, is_ci=False),
                      expected_platform=dict(os='darwin', release='27'),
                      inventory=['control.test.js'], selected_indices=[0], excluded=[],
                      additional_home_coverage=[], range_start=0, range_end=1)
        self.rows.insert(1, policy)
        self.assertTrue(self.result()['successful'])
        policy['expected_platform']['release'] = '270'
        self.assertFalse(self.result()['successful'])
        policy['expected_platform'] = dict(os='darwin', abi='gnu')
        self.assertFalse(self.result()['successful'])
        policy['expected_platform'] = dict(arch='wrong-but-no-os-declared')
        self.assertTrue(self.result()['successful'])
        policy['context']['is_ci'] = 'false'
        self.assertFalse(self.result()['successful'])

    def test_prepared_vendor_scope_and_original_skip_remain_visible(self):
        policy = dict(event='selection', contract='bun-4982b91e-vendor',
                      execution='prepared-vendor', setup_performed=False,
                      vendor=dict(skipTests={'ws*connection.test.ts': 'original reason'}),
                      inventory=['control.test.js', 'ws/connection.test.ts'], selected_indices=[0],
                      excluded=[dict(index=1, reason='skip_rule', skip_pattern='ws*connection.test.ts')],
                      additional_home_coverage=[], range_start=0, range_end=1)
        self.rows.insert(1, policy)
        result = self.result()
        self.assertTrue(result['successful'], result)
        self.assertFalse(result['selection_policy']['setup_performed'])
        self.assertEqual(result['counts'], self.counts)
        policy['setup_performed'] = True
        self.assertFalse(self.result()['successful'])
        policy['setup_performed'] = False
        policy['excluded'][0]['skip_pattern'] = 'invented exclusion'
        self.assertFalse(self.result()['successful'])

    def test_script_success_has_no_registered_case_credit(self):
        self.rows[3].update(counts=dict.fromkeys(self.counts, 0), junit='not_requested', junit_file=None, junit_sha256=None)
        self.rows[4]['summary'].update(dict.fromkeys(self.counts, 0), process_checks_passed=1)
        result = self.result()
        self.assertTrue(result['successful'], result)
        self.assertEqual(result['cases'], [])
        self.assertEqual(sum(result['counts'].values()), 0)


class SetupValidation(unittest.TestCase):
    result = JournalValidation.result
    artifact = JournalValidation.artifact
    def setUp(self):
        JournalValidation.setUp(self)
        completed = self.rows[3].copy()
        completed.update(counts=dict(passed=0, failed=0, skipped=0, todo=0, observed=False), junit='not_requested', junit_file=None, junit_sha256=None, output_complete=True)
        self.rows = [dict(event='run', schema=2, purpose='setup', corpus_root='/control'),
                     dict(event='setup_plan', contract='bun-4982b91e-root-test-setup', bun_pin='a'*40, manifest_sha256='b'*64, host=dict(os='darwin', arch='aarch64'), expected_platform={},
                          inputs=[dict(path=path, sha256='a'*64) for path in ('package.json', 'test/package.json')],
                          steps=[dict(path=path, operation='install', timeout_ms=180000) for path in ('package.json', 'test/package.json')]),
                     dict(event='selected', id=0, path='package.json'), dict(event='selected', id=1, path='test/package.json')]
        for identity, cwd in enumerate(('/control', '/control/test')):
            self.rows.extend([dict(event='started', id=identity, phase='launch_attempt', mode='setup_install', argv=['/control/home', 'install'], cwd=cwd, timeout_ms=180000, source_sha256='a'*64, executable_sha256='b'*64), dict(completed, id=identity)])
        self.rows.append(dict(event='finished', selected=2, started=2, completed=2, all_selected_completed=True,
                              summary=dict(files=2, passed=0, failed=0, skipped=0, todo=0, failed_files=0, unsupported=0, process_checks_passed=0, setup_steps_succeeded=2, setup_steps_failed=0, inputs_unchanged=True)))

    def test_setup_contract(self):
        result = self.result()
        self.assertTrue(result['successful'], result)
        self.assertEqual(result['cases'], [])
        for index, key, value in [(0, 'schema', 1), (1, 'host', {}), (4, 'timeout_ms', 180001), (4, 'argv', ['/control/home', 'install', '--ignore-scripts']), (5, 'expected_failure_verified', True), (5, 'counts', dict(passed=999, failed=0, skipped=0, todo=0, observed=True))]:
            old = self.rows[index][key]
            self.rows[index][key] = value
            self.assertFalse(self.result()['successful'])
            self.rows[index][key] = old

    def test_setup_failure_and_interruption(self):
        self.rows[5]['term'] = {'exited': 7}
        self.rows[-1]['summary'].update(failed_files=1, setup_steps_failed=1, setup_steps_succeeded=1)
        result = self.result()
        self.assertFalse(result['successful'])
        self.assertEqual(result['errors'], [])
        self.assertEqual(result['failed_file_ids'], [0])
        self.rows = self.rows[:6]
        result = self.result()
        self.assertFalse(result['successful'])
        self.assertEqual(result['unstarted'][0]['path'], 'test/package.json')

    # This fixture uses setup events; inherited corpus fixtures run in their own class.


if __name__ == '__main__':
    unittest.main()

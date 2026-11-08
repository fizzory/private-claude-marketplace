"""Offline regression checks for the live harness (no model calls)."""
import contextlib
import copy
import io
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('mentor_eval_harness', HERE / 'harness.py')
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)
CASES = json.loads((HERE / 'evals.json').read_text())['evals']
LIVE_FAILURES = json.loads((HERE / 'fixtures/selection/claude-live-failures.json').read_text())['cases']
PLACEHOLDER = json.loads((HERE / 'fixtures/selection/claude-selection-placeholder.json').read_text())


def init_event():
    return dict(type='system', subtype='init', skills=h.SKILLS + sorted(h.BUILTIN_SKILLS),
                agents=sorted(h.BUILTIN_AGENTS), plugins=[{'name': n, 'path': 'builtin', 'source': n + '@builtin'} for n in sorted(h.MANAGED_PLUGINS)], mcp_servers=[])


def tool(name, inputs, ident):
    return dict(type='assistant', message={'content': [dict(type='tool_use', id=ident, name=name, input=inputs)]})


def read(path, ident, success=True):
    return [tool('Read', {'file_path': path}, ident),
            dict(type='user', message={'content': [dict(type='tool_result', tool_use_id=ident, content='read output', is_error=not success)]})]


def transcript(case, root, host='claude'):
    events = [init_event()]
    if case['expected'] != 'none':
        events.append(tool('Skill', {'skill': case['expected']}, 'skill'))
    for i, path in enumerate(case.get('expected_reads', [])):
        # Case 93 intentionally permits either ordering of the two matching files.
        absolute = root / '.claude' / 'skills' / path if not path.startswith('.mentor/') else root / path
        events.extend(read(str(absolute), f'read-{i}'))
    if 'expected_reads' in case:
        owner = case['expected_delivery_owner']
        owner = owner[0] if isinstance(owner, list) else owner
        marker = 'EVAL_SELECTION ' + json.dumps(dict(delivery_owner=owner, history_to_recheck=case.get('expected_history_to_recheck', [])))
        events.append(dict(type='assistant', message={'content': [dict(type='text', text=marker)]}))
    events.append(dict(type='result', subtype='success', is_error=False))
    return events


def encode(events):
    return '\n'.join(json.dumps(event) for event in events)


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.case = next(case for case in CASES if case['id'] == 83)

    def grade(self, events, case=None, **kwargs):
        evidence = h.observe_transcript(encode(events), self.root, 'claude')
        return h.score_case(case or self.case, evidence, **kwargs)

    def placeholder_events(self):
        return json.loads(json.dumps([entry['event'] for entry in PLACEHOLDER['events']])
                          .replace(PLACEHOLDER['root'], str(self.root)))

    def test_selection_boundary_distinguishes_general_delivery_from_no_planning(self):
        boundary = ' '.join(h.SELECTION_BOUNDARY.split())
        self.assertIn('if planning is selected and no playbook is chosen, use "general"', boundary)
        self.assertIn('use "none" only when planning was not selected', boundary)
        self.assertIn('History to recheck: []', boundary)
        self.assertIn('No punctuation, explanation, or unlabeled continuation lines', boundary)

    def test_every_case_has_a_passing_synthetic_transcript(self):
        for case in CASES:
            with self.subTest(id=case['id']):
                result = self.grade(transcript(case, self.root), case)
                self.assertTrue(result['pass'], result['failures'])

    def test_missing_read_wrong_order_failed_read_and_parallel_read_fail(self):
        events = transcript(self.case, self.root)
        for variant in (events[:2] + events[4:],
                        events[:2] + events[4:6] + events[2:4] + events[6:],
                        events[:3] + [dict(type='user', message={'content': [dict(type='tool_result', tool_use_id='read-0', is_error=True)]})] + events[4:],
                        events[:3] + events[4:5] + events[3:4] + events[5:]):
            with self.subTest(variant=variant):
                self.assertFalse(self.grade(variant)['pass'])

    def test_unexpected_playbook_and_missing_boundary_fail(self):
        events = transcript(self.case, self.root)
        extra = read(str(self.root / '.claude/skills/planning/references/playbooks/prototype.md'), 'extra')
        self.assertFalse(self.grade(events[:-1] + extra + events[-1:])['pass'])
        self.assertFalse(self.grade(events[:-2] + events[-1:])['pass'])
        self.assertFalse(self.grade(events[:1] + events[2:6] + events[1:2] + events[6:])['pass'])

    def test_namespace_pick_is_preserved_and_not_scored_none(self):
        case = next(case for case in CASES if case['expected'] == 'none')
        events = transcript(case, self.root)
        events.insert(1, tool('Skill', {'skill': 'other-plugin:planning'}, 'competitor'))
        result = self.grade(events, case)
        self.assertEqual(result['got'], 'other-plugin:planning')
        self.assertEqual(result['actual_picks'], ['other-plugin:planning'])
        self.assertIn('incomplete (contaminated)', ' '.join(result['failures']))
        self.assertFalse(result['pass'])

    def test_recorded_harness_failures_replay_without_changing_expectations(self):
        self.assertEqual({f['id'] for f in LIVE_FAILURES}, {11, 16, 73, 84, 85, 86, 96})
        for fixture in LIVE_FAILURES:
            with self.subTest(id=fixture['id']):
                case = next(case for case in CASES if case['id'] == fixture['id'])
                events = [entry['event'] for entry in fixture['events']]
                evidence = h.observe_transcript(encode(events), Path(fixture['root']), 'claude')
                result = h.score_case(case, evidence)
                self.assertTrue(result['pass'], result['failures'])
                self.assertEqual(result['got'], case['expected'])
                self.assertEqual(result['actual_picks'], fixture['actual_picks'])
                self.assertEqual(result['read_paths'], fixture['read_paths'])
                denials = [e for e in events if e.get('subtype') == 'permission_denied']
                self.assertEqual([dict(e, at=i) for i, e in enumerate(events) if e in denials],
                                 evidence['permission_denials'])

    def test_recorded_resume_shell_reads_include_plan_and_verdict_despite_later_error(self):
        fixture = json.loads((HERE / 'fixtures/selection/claude-resume-shell-reads.json').read_text())
        case = next(case for case in CASES if case['id'] == fixture['id'])
        h.stage_project(self.root, {skill: 'description' for skill in h.SKILLS}, 'claude', case)
        events = json.loads(json.dumps([entry['event'] for entry in fixture['events']])
                            .replace(fixture['root'], str(self.root)))
        result = self.grade(events, case)
        self.assertTrue(result['pass'], result['failures'])
        self.assertEqual(set(result['read_paths']), set(case['expected_reads']))
        shell_reads = [entry for entry in result['evidence']['reads'] if entry['path'].startswith('.mentor/')]
        self.assertEqual([entry['path'] for entry in shell_reads],
                         ['.mentor/plans/eval-resume/plan.md', '.mentor/plans/eval-resume/verdicts/step-2.md'])
        # Keep the actual error: the verdict was printed before a later ls failed.
        verdict_result = next(event for event in events if event.get('type') == 'user'
                              and 'Verdict: PASS' in str(event))
        self.assertTrue(verdict_result['message']['content'][0]['is_error'])

    def test_recorded_placeholder_with_prose_owner_requires_a_grammar_report(self):
        case = next(case for case in CASES if case['id'] == PLACEHOLDER['id'])
        result = self.grade(self.placeholder_events(), case)
        self.assertFalse(result['pass'])
        self.assertEqual(result['actual_picks'], PLACEHOLDER['actual_picks'])
        self.assertEqual(result['read_paths'], PLACEHOLDER['read_paths'])
        self.assertIn('incomplete selection boundary', result['failures'])
        self.assertIsNone(result['evidence']['selection'])

    def test_recorded_hillclimb_prose_owner_agrees_with_valid_marker(self):
        fixture = json.loads((HERE / 'fixtures/selection/claude-hillclimb-prose-owner.json').read_text())
        case = next(case for case in CASES if case['id'] == fixture['id'])
        events = [entry['event'] for entry in fixture['events']]
        evidence = h.observe_transcript(encode(events), Path(fixture['root']), 'claude')
        result = h.score_case(case, evidence)
        self.assertTrue(result['pass'], result['failures'])
        self.assertEqual(evidence['selection'], dict(delivery_owner='hillclimb', history_to_recheck=[]))

    def test_labeled_report_still_requires_observed_skill_and_ordered_reads(self):
        case = next(case for case in CASES if case['id'] == PLACEHOLDER['id'])
        events = transcript(case, self.root)
        events[-2]['message']['content'][0]['text'] = (
            'Delivery owner: retrospective\nHistory to recheck: []')
        self.assertTrue(self.grade(events, case)['pass'])
        extra = read(str(self.root / '.claude/skills/planning/references/playbooks/prototype.md'), 'extra')
        variants = [events[:1] + events[2:],                    # no Skill event
                    events[:2] + events[4:],                    # missing index
                    events[:2] + events[4:6] + events[2:4] + events[6:],
                    events[:3] + events[4:5] + events[3:4] + events[5:],
                    events[:-2] + extra + events[-2:]]
        failed_read = copy.deepcopy(events)
        failed_read[5]['message']['content'][0]['is_error'] = True
        variants.append(failed_read)
        for variant in variants:
            with self.subTest(events=variant):
                self.assertFalse(self.grade(variant, case)['pass'])
        for name in ('Write', 'Edit', 'Agent', 'Task', 'TodoWrite'):
            with self.subTest(tool=name):
                self.assertFalse(self.grade(events[:-1] + [tool(name, {}, 'work')] + events[-1:], case)['pass'])
        self.assertFalse(self.grade(events[:-1], case)['pass'])

    def test_prose_owner_is_required_explicit_single_known_and_in_final_message(self):
        case = next(case for case in CASES if case['id'] == PLACEHOLDER['id'])
        for report in ('EVALATION_PLACEHOLDER',
                       'Selected retrospective; read its playbook.\nEVALATION_PLACEHOLDER',
                       'Who delivers: retrospective and software-change.',
                       'Who delivers: retrospective or software-change.',
                       'Who delivers: unknown.',
                       'Who delivers: software-change.',
                       'Who delivers: retrospective. Delivery owner: software-change.',
                       'Who delivers: retrospective.\nDelivery owner: software-change.'):
            events = self.placeholder_events()
            events[-2]['message']['content'][0]['text'] = report
            with self.subTest(report=report):
                self.assertFalse(self.grade(events, case)['pass'])
        # An earlier assertion or a user/tool echo cannot fill in a missing final owner.
        events = self.placeholder_events()
        events.insert(-1, dict(type='assistant', message={'content': [dict(type='text', text='Stopped. EVALATION_PLACEHOLDER')]}))
        self.assertFalse(self.grade(events, case)['pass'])
        events = self.placeholder_events()
        events[-1:-1] = read('/unrelated.md', 'late')
        result = self.grade(events, case)
        self.assertEqual(result['evidence']['errors'], [])
        self.assertFalse(result['pass'])
        events = self.placeholder_events()
        events[-2]['type'] = 'user'
        self.assertFalse(self.grade(events, case)['pass'])

    def test_labeled_report_does_not_default_missing_or_wrong_history_to_empty(self):
        case = next(case for case in CASES if case['id'] == 96)
        for history, accepted in [('', False), ('none.', False), ('[]', True),
                                   ('[1, 2]', False), ('"[]"', False), ('unknown', False),
                                   ('[]. History to recheck: [1]', False),
                                   ('[]\nHistory to recheck: [1]', False)]:
            events = transcript(case, self.root)
            report = 'Delivery owner: software-change'
            if history:
                report += '\nHistory to recheck: ' + history
            events[-2]['message']['content'][0]['text'] = report
            result = self.grade(events, case)
            with self.subTest(history=history):
                self.assertEqual(result['pass'], accepted, result['failures'])
                if not history:
                    self.assertNotIn('history_to_recheck', result['evidence']['selection'])

    def test_marker_can_be_inline_fenced_or_multiline_but_must_remain_unambiguous(self):
        marker = 'EVAL_SELECTION {"delivery_owner":"software-change","history_to_recheck":[]}'
        labels = 'Delivery owner: software-change\nHistory to recheck: []'
        for report in (marker, 'Selection: `' + marker + '`.',
                       '```json\n' + marker + '\n```', marker.replace(',', ',\n'),
                       marker + '\n' + labels, labels + '\n' + marker,
                       labels + '\n```json\n' + marker + '\n```',
                       labels + '\n~~~text\n' + marker + '\n~~~'):
            events = transcript(self.case, self.root)
            events[-2]['message']['content'][0]['text'] = report
            result = self.grade(events)
            with self.subTest(report=report):
                self.assertTrue(result['pass'], result['failures'])
                self.assertEqual(result['evidence']['selection_source'], 'marker')
        for report in (marker + '\n' + marker,
                       labels + '\n```json\n' + marker + '\nStep 2 needs re-checking.\n```',
                       'EVAL_SELECTION {bad json}\nDelivery owner: software-change',
                       'EVAL_SELECTION {"delivery_owner":null}\nDelivery owner: software-change',
                       'EVAL_SELECTION {"delivery_owner":"software-change"}',
                       'EVAL_SELECTION {"delivery_owner":"software-change","history_to_recheck":[],"extra":0}',
                       'EVAL_SELECTION {"delivery_owner":"retrospective","delivery_owner":"software-change","history_to_recheck":[]}',
                       'EVAL_SELECTION {"delivery_owner":"software-change","history_to_recheck":[true]}',
                       'EVAL_SELECTION {"delivery_owner":"software-change","history_to_recheck":[2,2]}'):
            events = transcript(self.case, self.root)
            events[-2]['message']['content'][0]['text'] = report
            with self.subTest(report=report):
                self.assertFalse(self.grade(events)['pass'])

    def test_owner_field_rejects_negation_and_unknown_compound(self):
        for owner in ('not software-change', 'software-change and custom-release'):
            report = 'Delivery owner: ' + owner + '\nHistory to recheck: []'
            for marked in (False, True):
                events = transcript(self.case, self.root)
                prefix = events[-2]['message']['content'][0]['text'] + '\n' if marked else ''
                events[-2]['message']['content'][0]['text'] = prefix + report
                with self.subTest(owner=owner, marker=marked):
                    result = self.grade(events)
                    self.assertFalse(result['pass'])
                    self.assertIn('wrong or multiple delivery owners: ' + owner, result['failures'])

    def test_owner_field_rejects_unlabeled_continuations(self):
        case = next(case for case in CASES if case['id'] == 93)
        for owner in ('software-change and\nhillclimb', 'software-change\nhillclimb',
                      'software-change\n\nhillclimb'):
            report = 'Delivery owner: ' + owner + '\nHistory to recheck: []'
            for marked in (False, True):
                events = transcript(case, self.root)
                prefix = events[-2]['message']['content'][0]['text'] + '\n' if marked else ''
                events[-2]['message']['content'][0]['text'] = prefix + report
                with self.subTest(owner=owner, marker=marked):
                    result = self.grade(events, case)
                    self.assertFalse(result['pass'])
                    self.assertIn('unlabeled continuation after selection field', result['failures'])

    def test_history_field_rejects_contradictory_residue(self):
        case = next(case for case in CASES if case['id'] == 96)
        for history in ('none\n- Step 2 needs re-checking.', '[]. Step 2 needs re-checking.',
                        'nothing\n\nStep 2 needs re-checking.', 'no steps', 'None', '[] trailing'):
            report = 'Delivery owner: software-change\nHistory to recheck: ' + history
            for marked in (False, True):
                events = transcript(case, self.root)
                prefix = events[-2]['message']['content'][0]['text'] + '\n' if marked else ''
                events[-2]['message']['content'][0]['text'] = prefix + report
                with self.subTest(history=history, marker=marked):
                    result = self.grade(events, case)
                    self.assertFalse(result['pass'])
                    self.assertTrue(any('history re-check' in reason or 'unlabeled continuation' in reason
                                        for reason in result['failures']), result['failures'])

    def test_native_read_requires_nonempty_returned_content(self):
        for content, nonempty in (('', False), (' \n\t', False), (None, False), ([], False),
                                  ([{'type': 'text', 'text': ''}], False),
                                  ([{'type': 'text', 'text': '  \n'}], False), ([{}], False),
                                  ('reference content', True),
                                  ([{'type': 'text', 'text': 'reference content'}], True)):
            events = transcript(self.case, self.root)
            events[4]['message']['content'][0]['input']['offset'] = 0 if nonempty else 999999
            events[5]['message']['content'][0]['content'] = content
            with self.subTest(content=content):
                result = self.grade(events)
                self.assertEqual(result['pass'], nonempty, result['failures'])
                if not nonempty:
                    self.assertIn('missing reads: ' + self.case['expected_reads'][1], result['failures'])

    def test_native_read_offset_warning_is_not_file_data(self):
        warning = ('<system-reminder>Warning: the file exists but is shorter than the '
                   'provided offset (999999). The file has 2 lines.</system-reminder>')
        for content in (warning, [{'type': 'text', 'text': warning}]):
            events = transcript(self.case, self.root)
            events[4]['message']['content'][0]['input'].update(offset=999999, limit=10)
            events[5]['message']['content'][0]['content'] = content
            with self.subTest(content=content):
                result = self.grade(events)
                self.assertFalse(result['pass'])
                self.assertNotIn(self.case['expected_reads'][1], result['read_paths'])

    def test_failed_shell_reader_cannot_borrow_echo_output(self):
        path = self.root / '.claude/skills' / self.case['expected_reads'][1]
        path.parent.mkdir(parents=True)
        path.write_text('A distinctive reference.\nIts complete contents.\n')
        command = f'cat -Z {path}; echo {h.shlex.quote(path.read_text())}'
        events = transcript(self.case, self.root)
        events[4:6] = [tool('Bash', {'command': command}, 'spoofed-read'),
                       dict(type='user', message={'content': [dict(
                           type='tool_result', tool_use_id='spoofed-read',
                           content='cat: invalid option -- Z\n' + path.read_text(), is_error=False)]})]
        result = self.grade(events)
        self.assertFalse(result['pass'])
        self.assertNotIn(self.case['expected_reads'][1], result['read_paths'])
        self.assertIn('missing reads: ' + self.case['expected_reads'][1], result['failures'])
        codex = dict(type='item.completed', item=dict(
            id='spoofed-read', type='command_execution', command=command,
            aggregated_output=path.read_text(), exit_code=0))
        self.assertEqual(h.observe_transcript(encode([codex]), self.root, 'codex')['reads'], [])
        for command, success, diagnostic in ((f'cat {path}', False, ''),
                (f'cat -Z {path}; ls', True, 'cat: illegal option -- Z\n'),
                (f'cat -Z {path}; ls missing', False, 'cat: invalid option -- Z\n'),
                (f'head -Z {path}; ls', True, 'head: illegal option -- Z\n'),
                (f'tail -Z {path}; ls', True, 'tail: unrecognized option -- Z\n'),
                (f'sed -n 1p {path}; ls', True, f"sed: can't read {path}: Permission denied\n")):
            with self.subTest(command=command, success=success):
                self.assertEqual(h.completed_command_reads(
                    command, self.root, self.root, diagnostic + path.read_text(), success)[0], [])
        # Printed content alone cannot prove a read even if diagnostics are absent.
        for printer in (f'echo {h.shlex.quote(path.read_text())}',
                        f"printf '%s' {h.shlex.quote(path.read_text())}"):
            command = f'cat -Z {path}; ' + printer
            with self.subTest(printer=printer):
                self.assertEqual(h.completed_command_reads(
                    command, self.root, self.root, path.read_text(), True)[0], [])

    def test_marker_compares_decorated_owner_and_history_labels(self):
        for assertion in ('delivery owner: retrospective', '**Delivery owner:** retrospective',
                          '- Delivery owner: retrospective', 'DELIVERY OWNER: retrospective',
                          'history to recheck: [2]', '**History to recheck:** [2]',
                          '> History to recheck: [2]', 'HISTORY TO RECHECK: [2]'):
            events = transcript(self.case, self.root)
            events[-2]['message']['content'][0]['text'] += '\n' + assertion
            with self.subTest(assertion=assertion):
                result = self.grade(events)
                self.assertFalse(result['pass'])
                self.assertTrue(any('contradictory selection reports:' in reason
                                    for reason in result['failures']), result['failures'])
        for assertion in ('delivery owner: software-change',
                          '**Delivery owner:** software-change supplies delivery',
                          '**Delivery owner:** the task follows the chosen playbook',
                          'history to recheck: []', '**History to recheck:** none',
                          '> History to recheck: nothing',
                          '**History to recheck:** no inherited claims exist'):
            events = transcript(self.case, self.root)
            events[-2]['message']['content'][0]['text'] += '\n' + assertion
            with self.subTest(assertion=assertion):
                result = self.grade(events)
                self.assertTrue(result['pass'], result['failures'])

    def test_honest_bounded_native_and_plain_shell_reads_still_pass(self):
        path = self.root / '.claude/skills' / self.case['expected_reads'][1]
        path.parent.mkdir(parents=True)
        path.write_text('A real reference.\nIts second line.\n')
        events = transcript(self.case, self.root)
        events[4]['message']['content'][0]['input'].update(offset=1, limit=1)
        events[5]['message']['content'][0]['content'] = [dict(
            type='text', text='     1→A real reference.\n<system-reminder>Read guidance.</system-reminder>')]
        result = self.grade(events)
        self.assertTrue(result['pass'], result['failures'])
        for command in (f'cat {path}', f"sed -n '1,2p' {path}"):
            events = transcript(self.case, self.root)
            events[4:6] = [tool('Bash', {'command': command}, 'honest-read'),
                           dict(type='user', message={'content': [dict(
                               type='tool_result', tool_use_id='honest-read',
                               content=path.read_text(), is_error=False)]})]
            with self.subTest(command=command):
                result = self.grade(events)
                self.assertTrue(result['pass'], result['failures'])
                codex = dict(type='item.completed', item=dict(
                    id='honest-read', type='command_execution', command=command,
                    aggregated_output=path.read_text(), exit_code=0))
                self.assertEqual(len(h.observe_transcript(encode([codex]), self.root, 'codex')['reads']), 1)

    def shell_reference(self):
        path = self.root / '.claude/skills' / self.case['expected_reads'][1]
        path.parent.mkdir(parents=True)
        path.write_text('A distinctive reference whose contents exceed the printer literal cap.\n'
                        'Every line must come from the reader.\n')
        return path, path.read_text()

    def shell_events(self, command, output, success=True):
        events = transcript(self.case, self.root)
        events[4:6] = [tool('Bash', {'command': command}, 'shell-reference'),
                       dict(type='user', message={'content': [dict(
                           type='tool_result', tool_use_id='shell-reference',
                           content=output, is_error=not success)]})]
        return events

    def test_printer_collision_cannot_forge_empty_head_read(self):
        path, content = self.shell_reference()
        command = f'head -n 0 {path}; echo x; echo {h.shlex.quote(content + "x")}'
        result = self.grade(self.shell_events(command, 'x\n' + content + 'x\n'))
        self.assertFalse(result['pass'])
        self.assertNotIn(self.case['expected_reads'][1], result['read_paths'])
        self.assertIn('continued beyond selection boundary', result['failures'])
        printers = ("printf '%s' x", 'echo -e x', 'echo -n x', 'echo -E x',
                    'echo -en x', r"echo 'a\b'", r'echo a\b', 'echo %s',
                    'echo ' + 'x' * 40, 'echo short#' + 'x' * 40,
                    'echo ' + "'" + '${VAR:-' + 'x' * 40 + '}' + "'",
                    'echo ' + "'" + 'x' * 20 + "''" + 'x' * 20 + "'",
                    "cat <<'EOF'\nprinted text\nEOF")
        for printer in printers:
            command = f'cat {path}; ' + printer
            with self.subTest(printer=printer):
                result = self.grade(self.shell_events(command, content))
                self.assertFalse(result['pass'])
                self.assertNotIn(self.case['expected_reads'][1], result['read_paths'])
                self.assertIn('continued beyond selection boundary', result['failures'])

    def test_escaped_echo_cannot_forge_failed_head_read(self):
        path, content = self.shell_reference()
        escaped = ''.join(f'\\x{byte:02x}' for byte in content.encode())
        command = f'head -n bad {path}; echo -e {h.shlex.quote(escaped)}'
        result = self.grade(self.shell_events(command, content))
        self.assertFalse(result['pass'])
        self.assertNotIn(self.case['expected_reads'][1], result['read_paths'])
        self.assertIn('continued beyond selection boundary', result['failures'])

    def test_marker_compares_linked_selection_labels(self):
        for assertion in ('[Delivery owner](#owner): retrospective',
                          '[History to recheck](#history): [2]',
                          '<strong>Delivery owner</strong>: retrospective',
                          '> 1. **[History to recheck](#history)**: [2]',
                          '[Delivery owner](https://example.test/(nested/(owner))): retrospective',
                          '[Delivery owner](#owner "Delivery"): retrospective',
                          '[History to recheck](#history "Recheck (maybe"): [2]',
                          '`Delivery owner`: retrospective',
                          '<em>delivery</em> <b>owner</b>: retrospective'):
            events = transcript(self.case, self.root)
            events[-2]['message']['content'][0]['text'] += '\n' + assertion
            with self.subTest(assertion=assertion):
                result = self.grade(events)
                self.assertFalse(result['pass'])
                self.assertTrue(any('contradictory selection reports:' in reason
                                    for reason in result['failures']), result['failures'])
        for assertion in ('[Delivery owner](#owner "Delivery"): software-change',
                          '[History to recheck](#history "Recheck (maybe"): []',
                          '[Delivery owner](#owner): the deliverable follows planning'):
            events = transcript(self.case, self.root)
            events[-2]['message']['content'][0]['text'] += '\n' + assertion
            with self.subTest(assertion=assertion):
                result = self.grade(events)
                self.assertTrue(result['pass'], result['failures'])

    def test_cat_credits_successful_operand_when_another_operand_fails(self):
        path, content = self.shell_reference()
        command = f'cat {path} missing.md'
        result = self.grade(self.shell_events(
            command, content + 'cat: missing.md: No such file or directory\n', False))
        self.assertTrue(result['pass'], result['failures'])
        self.assertIn(self.case['expected_reads'][1], result['read_paths'])
        for printer, credited, breach in (
                ('echo', True, False), ('echo ---', True, False),
                ('echo ' + 'x' * 39, False, True), ("echo '$VAR'", False, False),
                ('echo $VAR', False, False), ('echo ${VAR}', False, False),
                ('echo ${VAR:-fallback}', False, False),
                ('echo "PR=${PLUGIN_ROOT:-} CPR=${CLAUDE_PLUGIN_ROOT:-}"', False, False),
                ('echo "PR=${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT}}"', False, False)):
            with self.subTest(printer=printer):
                result = self.grade(self.shell_events(f'cat {path}; ' + printer, content))
                self.assertEqual(result['pass'], credited, result['failures'])
                self.assertEqual(self.case['expected_reads'][1] in result['read_paths'], credited)
                self.assertEqual('continued beyond selection boundary' in result['failures'], breach)

    def test_variable_commands_and_text_printers_never_earn_read_credit(self):
        path, content = self.shell_reference()
        other = self.root / 'other.md'
        other.write_text('')
        commands = [f"sed -n '999p' {path}; echo {h.shlex.quote(line)}"
                    for line in content.splitlines()]
        for operation in ('i', 'a', 'c'):
            script = '1' + operation + '\\' + content.rstrip('\n')
            commands.append(f"sed -n '999p' {path}; sed {h.shlex.quote(script)} {other}")
        commands += [f"cat {path}; echo '<<'", f"cat {path}; printf '%s' ---"]
        for command in commands:
            with self.subTest(command=command):
                result = self.grade(self.shell_events(command, content))
                self.assertFalse(result['pass'])
                self.assertNotIn(self.case['expected_reads'][1], result['read_paths'])
                self.assertIn('continued beyond selection boundary', result['failures'])

    def test_later_invalid_reader_keeps_earlier_read_credit(self):
        path, content = self.shell_reference()
        (self.root / 'other.md').write_text('A different file.\n')
        command = f'cat {path}; cat -Z other.md'
        result = self.grade(self.shell_events(command, content + 'cat: illegal option -- Z\n', False))
        self.assertTrue(result['pass'], result['failures'])
        self.assertIn(self.case['expected_reads'][1], result['read_paths'])
        self.assertNotIn('other.md', result['read_paths'])

    def test_shell_comment_preserves_read_credit_and_selection_boundary(self):
        path, content = self.shell_reference()
        result = self.grade(self.shell_events(f'cat {path} # Read; no edits', content))
        self.assertTrue(result['pass'], result['failures'])
        self.assertIn(self.case['expected_reads'][1], result['read_paths'])

    def test_echo_descriptor_redirection_is_not_printed_text(self):
        path, content = self.shell_reference()
        result = self.grade(self.shell_events(f'cat {path}; echo --- 1>&2', content + '---\n'))
        self.assertTrue(result['pass'], result['failures'])
        self.assertIn(self.case['expected_reads'][1], result['read_paths'])

    def test_long_variable_diagnostic_has_no_credit_or_boundary_breach(self):
        command = 'echo "Plugin root is $PLUGIN_ROOT and installation root is $CLAUDE_PLUGIN_ROOT"'
        result = self.grade(self.shell_events(command, 'Plugin root is /plugin and installation root is /install\n'))
        self.assertFalse(result['pass'])
        self.assertNotIn(self.case['expected_reads'][1], result['read_paths'])
        self.assertEqual(result['failures'], ['missing reads: ' + self.case['expected_reads'][1]])

    def test_compound_shell_reads_require_literal_commands_and_returned_file_content(self):
        folder = self.root.resolve() / 'a folder'
        folder.mkdir()
        path = folder / 'saved plan.md'
        path.write_text('A distinctive saved plan.\nSecond line.\n')
        content = path.read_text().rstrip('\n')
        command = "cd 'a folder' && ls; cat 'saved plan.md'; ls missing"
        for output, success, expected in [(content, False, [str(path)]),
                                           ('saved plan.md', True, []),
                                           ('cat: saved plan.md: Permission denied', False, []),
                                           ('A distinctive saved plan.', False, [])]:
            with self.subTest(output=output, success=success):
                paths, cwd = h.completed_command_reads(command, self.root, self.root, output, success)
                self.assertEqual(paths, expected)
                if expected:
                    self.assertEqual(cwd, folder)
        for command in ["echo 'a folder/saved plan.md'", "false && cat 'a folder/saved plan.md'",
                        "cat 'a folder/saved plan.md' > /dev/null", "cat 'a folder/saved plan.md' | head",
                        "cat 'a folder/saved plan.md' || echo ignored", "cd missing; cat 'saved plan.md'",
                        "cat $PLAN_FILE; echo done", "echo `cat 'a folder/saved plan.md'`",
                        "bash -lc \"cat 'a folder/saved plan.md'\" > /dev/null"]:
            with self.subTest(command=command):
                self.assertEqual(h.completed_command_reads(command, self.root, self.root, content, True)[0], [])
        # Separators need not be surrounded by whitespace; quoted paths may contain spaces.
        paths, _ = h.completed_command_reads("cd 'a folder';cat 'saved plan.md'", self.root,
                                              self.root, content, True)
        self.assertEqual(paths, [str(path)])
        self.assertEqual(h.command_reads("cat first.md;cat second.md"), [])
        # A wrapped shell can read after cd without moving the next tool's cwd.
        paths, cwd = h.completed_command_reads(
            "bash -lc \"cd 'a folder'; cat 'saved plan.md'\"", self.root, self.root, content, True)
        self.assertEqual(paths, [str(path)])
        self.assertEqual(cwd, self.root)

    def test_successful_simple_shell_reads_require_returned_reference_content(self):
        fixture = json.loads((HERE / 'fixtures/selection/empty-shell-read.json').read_text())
        path = self.root / '.claude/skills' / self.case['expected_reads'][1]
        path.parent.mkdir(parents=True)
        path.write_text(fixture['reference_content'])
        for command in fixture['commands']:
            command = command.format(path=path)
            events = transcript(self.case, self.root)
            events[4:6] = [tool('Bash', {'command': command}, 'empty-read'),
                           dict(type='user', message={'content': [dict(
                               type='tool_result', tool_use_id='empty-read',
                               content=fixture['empty_output'], is_error=False)]})]
            with self.subTest(command=command):
                result = self.grade(events)
                self.assertFalse(result['pass'])
                self.assertIn('missing reads: ' + self.case['expected_reads'][1], result['failures'])
                codex = dict(type='item.completed', item=dict(
                    id='empty-read', type='command_execution', command=command,
                    aggregated_output=fixture['empty_output'], exit_code=0))
                self.assertEqual(h.observe_transcript(encode([codex]), self.root, 'codex')['reads'], [])
                for output in (path.read_text(), path.read_text().splitlines()[0]):
                    paths, _ = h.completed_command_reads(command, self.root, self.root, output, True)
                    self.assertEqual(paths, [str(path.resolve())] if output == path.read_text() else [])

    def test_final_report_overrides_and_must_agree_with_earlier_marker(self):
        fixture = json.loads((HERE / 'fixtures/selection/contradictory-final-report.json').read_text())
        case = next(case for case in CASES if case['id'] == 96)
        for report in fixture['final_reports'] + [fixture['matching_final_report']]:
            events = transcript(case, self.root)
            events[-2]['message']['content'][0]['text'] = fixture['earlier_report']
            events.insert(-1, dict(type='assistant', message={'content': [dict(type='text', text=report)]}))
            with self.subTest(report=report):
                result = self.grade(events, case)
                self.assertEqual(result['pass'], report == fixture['matching_final_report'], result['failures'])
                # A marker and contradicting labels within the final message also fail.
                if report != fixture['matching_final_report'] and report != 'Stopped.':
                    events[-3]['message']['content'][0]['text'] = fixture['earlier_report'] + '\n' + report
                    del events[-2]
                    self.assertFalse(self.grade(events, case)['pass'])

    def test_labeled_history_is_single_line_and_must_agree_with_marker(self):
        case = next(case for case in CASES if case['id'] == 95)
        histories = ['[2]', '[\n  2\n]', '\n  - 2',
                     '\n  - Step 1 does not need re-checking.\n  - Step 2 needs re-checking.']
        for history in histories:
            report = 'Delivery owner: retrospective\nHistory to recheck: ' + history
            for marked_history in (None, [2], []):
                events = transcript(case, self.root)
                if marked_history is None:
                    events[-2]['message']['content'][0]['text'] = report
                else:
                    events[-2]['message']['content'][0]['text'] = 'EVAL_SELECTION ' + json.dumps(
                        dict(delivery_owner='retrospective', history_to_recheck=marked_history))
                    events.insert(-1, dict(type='assistant', message={'content': [dict(type='text', text=report)]}))
                with self.subTest(history=history, marker=marked_history):
                    result = self.grade(events, case)
                    self.assertEqual(result['pass'], history == '[2]' and marked_history != [], result['failures'])
                    if history == '[2]':
                        self.assertEqual(result['evidence']['selection']['history_to_recheck'], [2])
                    if history == '[2]' and marked_history == []:
                        self.assertIn('contradictory selection reports: history_to_recheck', result['failures'])

    def test_empty_history_words_normalize_and_must_agree_with_marker(self):
        case = next(case for case in CASES if case['id'] == 96)
        for history in ('nothing', 'none', '[]'):
            report = 'Delivery owner: software-change\nHistory to recheck: ' + history
            for marked_history in (None, [], [2]):
                events = transcript(case, self.root)
                if marked_history is None:
                    events[-2]['message']['content'][0]['text'] = report
                else:
                    events[-2]['message']['content'][0]['text'] = 'EVAL_SELECTION ' + json.dumps(
                        dict(delivery_owner='software-change', history_to_recheck=marked_history))
                    events.insert(-1, dict(type='assistant', message={'content': [dict(type='text', text=report)]}))
                with self.subTest(history=history, marker=marked_history):
                    result = self.grade(events, case)
                    self.assertEqual(result['pass'], marked_history != [2], result['failures'])
                    self.assertEqual(result['evidence']['selection']['history_to_recheck'], [])
                    if marked_history == [2]:
                        self.assertIn('contradictory selection reports: history_to_recheck', result['failures'])

    def test_owner_field_accepts_only_exact_allowed_tokens(self):
        case = next(case for case in CASES if case['id'] == 93)
        owners = [('software-change', True),
                  ('software-change (hillclimb supplies attempts)', False),
                  ('the hillclimb playbook says that when it is combined with software-change, '
                   'software-change is the only delivery owner', False),
                  ('the software-change playbook alone', False),
                  ('software-change and hillclimb', False),
                  ('software-change (or hillclimb)', False),
                  ('software-change is the only delivery owner and hillclimb is the only delivery owner', False),
                  ('hillclimb (software-change supplies attempts)', False)]
        for owner, accepted in owners:
            report = 'Delivery owner: ' + owner + '\nHistory to recheck: []'
            for mode in ('prose', 'earlier-marker', 'same-message-marker'):
                events = transcript(case, self.root)
                if mode == 'prose':
                    events[-2]['message']['content'][0]['text'] = report
                elif mode == 'earlier-marker':
                    events.insert(-1, dict(type='assistant', message={'content': [dict(type='text', text=report)]}))
                else:
                    events[-2]['message']['content'][0]['text'] += '\n' + report
                with self.subTest(owner=owner, mode=mode):
                    result = self.grade(events, case)
                    self.assertEqual(result['pass'], accepted, result['failures'])
                    if accepted:
                        self.assertEqual(result['evidence']['selection']['delivery_owner'], 'software-change')

    def test_shell_work_and_added_or_changed_unlisted_project_files_breach_selection(self):
        fixture = json.loads((HERE / 'fixtures/selection/shell-boundary-mutations.json').read_text())
        for command in fixture['commands']:
            events = transcript(self.case, self.root)
            events[-2:-2] = [tool('Bash', {'command': command}, 'work'),
                            dict(type='user', message={'content': [dict(
                                type='tool_result', tool_use_id='work', content='', is_error=False)]})]
            with self.subTest(command=command):
                result = self.grade(events)
                self.assertFalse(result['pass'])
                self.assertIn('continued beyond selection boundary', result['failures'])
                evidence = h.observe_transcript(encode(transcript(self.case, self.root)), self.root, 'claude')
                evidence['tool_calls'].append(dict(name='command_execution', input=dict(command=command)))
                self.assertFalse(h.score_case(self.case, evidence)['pass'])

        class Child:
            returncode = 0
            def wait(self, timeout=None):
                return 0

        for relative in (fixture['added_file'], fixture['changed_file']):
            with self.subTest(file=relative):
                root = self.root / relative.removesuffix('.txt')
                root.mkdir()
                (root / fixture['changed_file']).write_text('original project content')

                def fake_child(cmd, stdout, stderr, cwd, env):
                    stdout.write(encode(transcript(self.case, root)))
                    (root / relative).write_text('implemented outside selection')
                    return Child()

                with patch.object(h.subprocess, 'Popen', side_effect=fake_child):
                    result = h.run_query(root, self.case, '', 'claude', self.root)
                self.assertFalse(result['pass'])
                self.assertEqual(result['evidence']['fixture_changes'], [relative])

    def test_denied_unfinished_and_unproven_shell_commands_do_not_credit_compound_reads(self):
        path = self.root / 'plan.md'
        path.write_text('Actual saved plan contents.\n')
        call = tool('Bash', {'command': 'ls; cat plan.md'}, 'shell')
        result = dict(type='user', message={'content': [dict(type='tool_result', tool_use_id='shell',
                      content=path.read_text())]})
        denial = dict(type='system', subtype='permission_denied', message='Denied',
                      tool_name='Bash', tool_use_id='shell')
        for middle in [[], [denial], [denial, result]]:
            events = [init_event(), call] + middle + [dict(type='result', subtype='success', is_error=False)]
            with self.subTest(middle=middle):
                self.assertEqual(h.observe_transcript(encode(events), self.root, 'claude')['reads'], [])
        result['message']['content'][0]['content'] = 'plan.md'
        self.assertEqual(h.observe_transcript(encode([init_event(), call, result]), self.root, 'claude')['reads'], [])

    def test_none_comparison_ignores_only_allowlisted_builtins_and_keeps_actual_picks(self):
        case = next(case for case in CASES if case['expected'] == 'none')
        for name in sorted(h.BUILTIN_SKILLS):
            events = transcript(case, self.root)
            events.insert(1, tool('Skill', {'skill': name}, 'builtin'))
            with self.subTest(name=name):
                result = self.grade(events, case)
                self.assertTrue(result['pass'], result['failures'])
                self.assertEqual(result['got'], 'none')
                self.assertEqual(result['actual_picks'], [name])
                self.assertFalse(self.grade(events, self.case)['pass'])
        # Built-ins cannot hide a Mentor pick, even when they were selected first.
        events = transcript(case, self.root)
        events[1:1] = [tool('Skill', {'skill': 'code-review'}, 'builtin'),
                       tool('Skill', {'skill': 'planning'}, 'mentor')]
        result = self.grade(events, case)
        self.assertFalse(result['pass'])
        self.assertEqual(result['got'], 'planning')
        self.assertEqual(result['actual_picks'], ['code-review', 'planning'])
        # A clean init cannot mask a competitor that only appears in a Skill call.
        for name in ('foreign-skill', 'foreign:code-review', 'code-review-extra'):
            with self.subTest(competitor=name):
                events[2] = tool('Skill', {'skill': name}, 'foreign')
                result = self.grade(events, case)
                self.assertFalse(result['pass'])
                self.assertIn('incomplete (contaminated)', ' '.join(result['failures']))

    def test_permission_denied_validates_its_own_shape_and_never_proves_a_read(self):
        denial = next(entry['event'] for f in LIVE_FAILURES for entry in f['events']
                      if entry['event'].get('subtype') == 'permission_denied')
        for key, value in [('message', None), ('message', {}), ('message', []),
                           ('tool_name', ''), ('tool_use_id', None)]:
            events = transcript(self.case, self.root)
            malformed = dict(denial, **{key: value})
            result = self.grade(events[:-1] + [malformed] + events[-1:])
            with self.subTest(key=key, value=value):
                self.assertFalse(result['pass'])
                self.assertIn('malformed permission_denied', ' '.join(result['failures']))
        for name in ('Read', 'Bash'):
            events = transcript(self.case, self.root)
            path = str(self.root / '.claude/skills' / self.case['expected_reads'][0])
            events[2] = tool(name, {'file_path': path} if name == 'Read' else {'command': f'cat {path}'}, 'read-0')
            events[3:3] = [dict(denial, tool_name=name, tool_use_id='read-0')]
            # Even an inconsistent later success result must not credit the denied read.
            for include_result in (True, False):
                variant = events if include_result else events[:4] + events[5:]
                result = self.grade(variant)
                with self.subTest(tool=name, result=include_result):
                    self.assertFalse(result['pass'])
                    self.assertEqual(result['evidence']['errors'], [])
                    self.assertNotIn(self.case['expected_reads'][0], result['read_paths'])
        for kind in ('assistant', 'user'):
            events = transcript(self.case, self.root)
            result = self.grade(events[:-1] + [dict(type=kind, message=denial['message'])] + events[-1:])
            self.assertIn('malformed message', ' '.join(result['failures']))

    def test_owner_normalization_accepts_known_names_only_and_preserves_report(self):
        fixture = next(f for f in LIVE_FAILURES if f['id'] == 84)
        case = next(case for case in CASES if case['id'] == 84)
        original = [entry['event'] for entry in fixture['events']]
        for owner, accepted in [('general', True), ('general flow', True),
                                 (' General  Flow ', False), ('none', False), ('software-change', False),
                                 ('general flow plus software-change', False),
                                 ('the general flow', False), ('general, retrospective', False),
                                 (['general'], False), (None, False)]:
            events = copy.deepcopy(original)
            marker = next(block for event in events if event['type'] == 'assistant'
                          for block in event['message']['content']
                          if block.get('type') == 'text' and 'EVAL_SELECTION ' in block['text'])
            marker['text'] = 'EVAL_SELECTION ' + json.dumps(dict(delivery_owner=owner, history_to_recheck=[]))
            evidence = h.observe_transcript(encode(events), Path(fixture['root']), 'claude')
            result = h.score_case(case, evidence)
            with self.subTest(owner=owner):
                self.assertEqual(result['pass'], accepted, result['failures'])
                self.assertEqual(result['evidence']['selection']['delivery_owner'], owner)

    def test_init_guard_rejects_each_inventory_and_missing_init(self):
        for key, value in [('skills', 'foreign:skill'), ('agents', 'foreign-agent'), ('plugins', {'name': 'cc-plugin-foreign'}), ('mcp_servers', {'name': 'foreign-mcp'})]:
            events = transcript(self.case, self.root)
            events[0][key].append(value)
            result = self.grade(events)
            self.assertFalse(result['pass'])
            self.assertIn('incomplete (contaminated)', ' '.join(result['failures']))
            self.assertIn(key, result['evidence']['contamination'])
        events = transcript(self.case, self.root)
        self.assertFalse(self.grade(events[1:])['pass'])
        del events[0]['skills']
        self.assertFalse(self.grade(events)['pass'])

    def test_allowlist_matches_saved_real_probe_not_the_session_being_graded(self):
        probe = json.loads((HERE / 'fixtures/selection/claude-isolated-init.json').read_text())
        event = probe['event']
        self.assertEqual(set(event['skills']) - set(probe['staged_skills']), h.BUILTIN_SKILLS)
        self.assertEqual(set(event['agents']), h.BUILTIN_AGENTS)
        self.assertEqual({p['name'] for p in event['plugins']}, h.MANAGED_PLUGINS)
        self.assertEqual(h.init_contamination(event, probe['staged_skills']), {})
        # Reusing a managed name from a user-installed plugin is still contamination.
        event['plugins'][0]['path'] = '/user/plugin'
        self.assertIn('plugins', h.init_contamination(event, probe['staged_skills']))

    def test_prose_mentions_do_not_prove_reads_or_skill_selection(self):
        events = transcript(self.case, self.root)
        events = [events[0], dict(type='assistant', message={'content': [dict(type='text', text='selected the `planning` skill, read ' + ', '.join(self.case['expected_reads']))]})] + events[-2:]
        self.assertFalse(self.grade(events)['pass'])

    def test_multiple_owners_and_supported_history_recheck_fail(self):
        for owner in (['software-change', 'hillclimb'], 'hillclimb', None):
            events = transcript(self.case, self.root)
            events[-2]['message']['content'][0]['text'] = 'EVAL_SELECTION ' + json.dumps({'delivery_owner': owner})
            self.assertFalse(self.grade(events)['pass'])
        case = next(case for case in CASES if case['id'] == 96)
        events = transcript(case, self.root)
        events[-2]['message']['content'][0]['text'] = 'EVAL_SELECTION ' + json.dumps(dict(delivery_owner='software-change', history_to_recheck=[1, 2]))
        self.assertFalse(self.grade(events, case)['pass'])

    def test_timeout_nonzero_exit_missing_completion_and_unfinished_read_fail(self):
        events = transcript(self.case, self.root)
        self.assertFalse(self.grade(events, timed_out=True)['pass'])
        self.assertFalse(self.grade(events, returncode=1)['pass'])
        self.assertFalse(self.grade(events[:-1])['pass'])
        self.assertFalse(self.grade(events[:-1] + [tool('Read', {'file_path': '/unfinished.md'}, 'unfinished')] + events[-1:])['pass'])
        self.assertFalse(self.grade(events + [None])['pass'])
        self.assertFalse(self.grade(events + [init_event()])['pass'])

    def test_selection_does_not_approve_write_or_delegate(self):
        events = transcript(self.case, self.root)
        for name in ('Write', 'Edit', 'Agent', 'Task'):
            self.assertFalse(self.grade(events[:-1] + [tool(name, {}, 'work')] + events[-1:])['pass'])
        evidence = h.observe_transcript(encode(events), self.root, 'claude')
        evidence['fixture_changes'] = ['.mentor/plans/eval-resume/plan.md']
        self.assertFalse(h.score_case(self.case, evidence)['pass'])

    def test_selection_stages_real_bodies_references_and_fresh_fixtures(self):
        descriptions = {skill: 'test description' for skill in h.SKILLS}
        for case in (self.case, next(case for case in CASES if case['id'] == 96)):
            root = self.root / str(case['id'])
            h.stage_project(root, descriptions, 'claude', case)
            for skill in h.SKILLS:
                for original in (h.REPO_SKILLS / skill).rglob('*'):
                    if original.is_file():
                        staged = root / '.claude/skills' / skill / original.relative_to(h.REPO_SKILLS / skill)
                        self.assertEqual(staged.read_bytes(), original.read_bytes())
            self.assertFalse((root / 'CLAUDE.md').exists())
            self.assertTrue((root / '.mentor/plans/user-onboarding/plan.md').exists())
            for relative, content in case.get('fixture_files', {}).items():
                self.assertEqual((root / relative).read_text(), content)

    def test_child_isolation_is_forced_without_mutating_caller_env(self):
        with patch.dict(os.environ, {'CLAUDECODE': '1', 'CLAUDE_CODE_DISABLE_CLAUDE_MDS': '0', 'CLAUDE_CODE_DISABLE_AUTO_MEMORY': '0'}):
            cmd, env = h.child_command('request', '', 'claude', True)
            self.assertEqual(cmd[cmd.index('--setting-sources') + 1], 'project,local')
            self.assertIn('--strict-mcp-config', cmd)
            self.assertEqual(cmd[cmd.index('--disallowedTools') + 1], 'mcp__*')
            self.assertNotIn('--model', cmd)
            self.assertNotIn('CLAUDECODE', env)
            self.assertEqual(env['CLAUDE_CODE_DISABLE_CLAUDE_MDS'], '1')
            self.assertEqual(env['CLAUDE_CODE_DISABLE_AUTO_MEMORY'], '1')
            self.assertEqual(os.environ['CLAUDE_CODE_DISABLE_AUTO_MEMORY'], '0')
            for banned in ('--bare', '--safe-mode', '--disable-slash-commands'):
                self.assertNotIn(banned, cmd)

    def test_codex_completed_literal_file_reads_score_without_prose_fallback(self):
        events = []
        for i, relative in enumerate(['planning/SKILL.md'] + self.case['expected_reads']):
            path = self.root / '.agents/skills' / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('The complete contents of ' + relative + '\n')
            events.append(dict(type='item.completed', item=dict(id=str(i), type='command_execution', command=f'cat {path}', aggregated_output=path.read_text(), exit_code=0)))
        events.extend([dict(type='item.completed', item=dict(type='agent_message', text='EVAL_SELECTION {"delivery_owner":"software-change","history_to_recheck":[]}')), dict(type='turn.completed')])
        result = h.score_case(self.case, h.observe_transcript(encode(events), self.root, 'codex'))
        self.assertTrue(result['pass'], result['failures'])
        self.assertEqual(h.command_reads("rg 'software-change.md' .agents/skills"), [])
        self.assertEqual(h.command_reads("echo planning/references/playbooks.md"), [])

    def test_mirrored_behaviour_cases_and_preserved_routing_cases(self):
        behaviour = json.loads((HERE / 'behaviour.json').read_text())['evals']
        selection = {case['id'] for case in CASES if 'expected_reads' in case}
        self.assertEqual(selection, set(range(83, 97)))
        self.assertEqual(selection, {case['routing_case_id'] for case in behaviour if 'routing_case_id' in case})
        self.assertEqual(len(CASES), 62)
        self.assertEqual(len(h.SKILLS), 7)

    def test_positional_cli_help_and_invalid_args_never_start_a_child(self):
        for args, expected in [(['--help'], 0), (['--unsupported'], 2), (['claude', '', '0'], 2)]:
            completed = subprocess.run([sys.executable, str(HERE / 'harness.py')] + args, capture_output=True)
            self.assertEqual(completed.returncode, expected)

    def test_main_returns_nonzero_for_any_failed_case(self):
        def fake_run(root, case, model, host, directory):
            return dict(got=case['expected'], **{'pass': case['id'] != 83},
                        secs=0, failures=['deliberate fixture failure'] if case['id'] == 83 else [])
        with patch.dict(os.environ, {'MENTOR_EVAL_WORKDIR': str(self.root)}), \
             patch.object(sys, 'argv', ['harness.py', 'claude', '', '1']), \
             patch.object(h, 'run_query', side_effect=fake_run), \
             patch.object(h, 'stage_project'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(h.main(), 1)
        results = json.loads((self.root / 'results-claude.json').read_text())
        self.assertEqual(len(results), 62)
        self.assertEqual(sum(not r['pass'] for r in results), 1)

    def test_run_preserves_transcript_reads_and_rejects_fixture_mutation(self):
        case = next(case for case in CASES if case['id'] == 96)
        root = self.root / 'project'
        h.stage_project(root, {skill: 'description' for skill in h.SKILLS}, 'claude', case)

        class Child:
            returncode = 0
            def wait(self, timeout=None):
                return 0

        def fake_child(cmd, stdout, stderr, cwd, env):
            stdout.write(encode(transcript(case, root)))
            (root / '.mentor/plans/eval-resume/plan.md').write_text('rewritten saved plan')
            return Child()

        with patch.object(h.subprocess, 'Popen', side_effect=fake_child):
            result = h.run_query(root, case, '', 'claude', self.root)
        self.assertFalse(result['pass'])
        self.assertIn('saved fixture changed', ' '.join(result['failures']))
        self.assertTrue((self.root / 'transcript.jsonl').read_text())
        self.assertEqual(json.loads((self.root / 'reads.json').read_text()), result['evidence']['reads'])
        self.assertEqual(json.loads((self.root / 'score.json').read_text()), result)


if __name__ == '__main__':
    unittest.main()

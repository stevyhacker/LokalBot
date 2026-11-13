import copy
import json
from pathlib import Path
import unittest

from visible_context_replay import VARIANTS, contains_fact, replay_input, score


class VisibleContextReplayTests(unittest.TestCase):
    def setUp(self):
        self.corpus = json.loads(Path(__file__).with_name('visible-context-cases.json').read_text())
        self.cases = self.corpus['cases']

    def test_reference_and_selection_labels_never_enter_model_input(self):
        for variant in VARIANTS:
            payload = replay_input(self.corpus, self.cases, variant)
            for case in payload['cases']:
                self.assertTrue(set(case).isdisjoint({'expected', 'stale', 'split', 'kind', 'expectedVisibleIDs',
                                                     'expectedMemoryIDs', 'permittedTextReadIDs'}))
                self.assertNotIn('promptOverride', case)
            self.assertEqual(len(payload['cases']), len(self.cases))

    def test_context_grants_are_independent(self):
        for variant, (visible, memory) in VARIANTS.items():
            payload = replay_input(self.corpus, self.cases, variant)
            self.assertEqual(payload['useVisibleContext'], visible)
            self.assertEqual(payload['useMeetingMemory'], memory)
            self.assertFalse(payload['useScreenMemory'])

    def test_split_has_no_shared_topics_and_covers_conflicts_and_controls(self):
        dev = {c['windowTitle'] for c in self.cases if c['split'] == 'development'}
        held = [c for c in self.cases if c['split'] == 'heldout']
        self.assertTrue(dev.isdisjoint({c['windowTitle'] for c in held}))
        self.assertGreaterEqual(sum(c['kind'] == 'conflict' for c in held), 4)
        self.assertGreaterEqual(sum(c['kind'] == 'control' for c in held), 10)
        self.assertEqual(len({c['id'] for c in self.cases}), len(self.cases))

    def test_fact_scoring_requires_complete_words(self):
        self.assertTrue(contains_fact('next Thursday.', 'Thursday'))
        self.assertFalse(contains_fact('Thurs', 'Thursday'))
        self.assertFalse(contains_fact('the Lisbonese office', 'Lisbon'))
        self.assertTrue(contains_fact('Baru.', 'Baru'))
        self.assertFalse(contains_fact('', None))

    def output(self, cases):
        return {variant: [dict(id=c['id'], text='', prompt='ordinary', latencyMs=1, usedPromptOverride=False,
                               visibleIDs=c['expectedVisibleIDs'] if visible else [],
                               memoryIDs=c['expectedMemoryIDs'] if memory else [],
                               visibleTextReadIDs=c['permittedTextReadIDs'] if visible else []) for c in cases]
                for variant, (visible, memory) in VARIANTS.items()}

    def test_incomplete_duplicate_reordered_and_override_runs_rejected(self):
        cases = self.cases[:2]
        mutations = [lambda r: r['both'].pop(), lambda r: r['both'].reverse(),
                     lambda r: r['both'].__setitem__(1, copy.deepcopy(r['both'][0])),
                     lambda r: r['both'][0].update(usedPromptOverride=True)]
        for mutate in mutations:
            result = self.output(cases)
            mutate(result)
            with self.assertRaises(ValueError):
                score(cases, result)

    def test_selection_and_forbidden_reads_are_scored_even_on_correct_answer(self):
        cases = self.cases[:1]
        result = self.output(cases)
        result['both'][0].update(text=cases[0]['expected'], visibleTextReadIDs=['sidebar'], visibleIDs=['sidebar'])
        report = score(cases, result)
        row = next(r for r in report['cases'] if r['variant'] == 'both')
        self.assertTrue(row['correct'])
        self.assertFalse(row['visibleSelectionCorrect'])
        self.assertEqual(row['forbiddenReads'], ['sidebar'])

    def test_memory_query_can_depend_on_visible_context_without_leaking_scoring_labels(self):
        corpus = json.loads(Path(__file__).with_name('visible-memory-link-cases.json').read_text())
        cases = corpus['cases']
        result = self.output(cases)
        for row in result['memory']:
            row['memoryIDs'] = []
        report = score(cases, result)
        self.assertTrue(all(row['memorySelectionCorrect'] for row in report['cases']))
        for variant in VARIANTS:
            for case in replay_input(corpus, cases, variant)['cases']:
                self.assertNotIn('memoryRequiresVisibleContext', case)

    def test_controls_require_identical_prompt_and_text(self):
        cases = [next(c for c in self.cases if c['kind'] == 'control')]
        result = self.output(cases)
        self.assertTrue(score(cases, result)['controls'][0]['unchanged'])
        result['visible'][0]['prompt'] += ' private fact'
        self.assertFalse(score(cases, result)['controls'][0]['unchanged'])


if __name__ == '__main__':
    unittest.main()

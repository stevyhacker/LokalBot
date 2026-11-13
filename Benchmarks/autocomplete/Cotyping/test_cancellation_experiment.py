"""Guard against crediting cancellation speed while hiding replacement work."""
import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import cancellation_experiment as experiment


class CancellationAnalysisTests(unittest.TestCase):
    def test_bootstrap_keeps_correlated_repeats_in_their_source_group(self):
        result = experiment.paired({1: [(10, 11)] * 100, 2: [(10, 9)] * 100})
        self.assertEqual(result['scenarioCount'], 2)
        self.assertEqual(result['default']['n'], 200)
        self.assertEqual(result['deltaMs'], 0)
        self.assertEqual(result['delta95CI'], [-1, 1])

    def test_replacement_window_includes_cleanup_and_does_not_credit_undelivered_timers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            meta = {}
            for arm in ['default', 'test']:
                for dataset in ['fresh', 'long', 'dynamic']:
                    rows = []
                    for language in ['en', 'sr_latn']:
                        identifier = dataset + '-' + language
                        meta[identifier] = dict(scenario=1, language=language, kind='normal')
                        rows.append(dict(id=identifier, prompt='synthetic', text=' result', cancelled=False,
                                         latencyMs=10 if arm == 'default' else 9))
                    self.save_run(root, dataset, arm, rows)
                rows = []
                for event, delivered in [('delivered', True), ('finishedBeforeTimer', False)]:
                    for action in ['cancel', 'replacement', 'cold']:
                        identifier = event + '-' + action
                        meta[identifier] = dict(scenario=1, language='en', kind=action, delay=5)
                        row = dict(id=identifier, prompt='synthetic', text=' result', cancelled=False,
                                   latencyMs=50, replayCompletedAtMs=200 if arm == 'default' else 205)
                        if action == 'cancel':
                            row.update(cancelled=delivered, text='' if delivered else ' result',
                                       latencyMs=20 if arm == 'default' else 15, generationStartedAtMs=100)
                            if delivered:
                                row['cancellationRequestedAfterMs'] = 5
                        rows.append(row)
                self.save_run(root, 'cancellation', arm, rows)
            experiment.write(root / 'case-meta.json', meta)
            with contextlib.redirect_stdout(io.StringIO()):
                experiment.analyze(root, 'confirmation', 'test', [1])
            result = experiment.read(root / 'confirmation-test-analysis.json')
            self.assertEqual(result['cancellationReturn']['deltaMs'], -5)
            # Faster cancellation return still produced a slower replacement.
            self.assertEqual(result['cancellationThroughReplacement']['default']['mean'], 95)
            self.assertEqual(result['cancellationThroughReplacement']['candidate']['mean'], 100)
            self.assertEqual(result['cancellationThroughReplacement']['default']['n'], 1)
            self.assertEqual(result['interruptionCounts']['default'], dict(attempted=2, issued=1, cancelled=1))
            self.assertFalse(result['passesAdoptionGate'])
            self.assertTrue(result['passesQuality'])

    @staticmethod
    def save_run(root, dataset, arm, rows):
        folder = root / 'runs' / f'confirmation-{dataset}-{arm}-1'
        folder.mkdir(parents=True)
        raw = folder / 'raw.jsonl'
        raw.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        experiment.write(folder / 'receipt.json', {'rawSHA256': experiment.sha(raw)})


if __name__ == '__main__':
    unittest.main()

"""Checks for evaluation mistakes that can change a quantization decision."""
from pathlib import Path
import unittest

import quantization_experiment as study
import quantization_analysis as analysis


def traced(text, probability, fallback=0., one_word='', eligible=True):
    return dict(text=text, oneWordText=one_word, cache=dict(confidenceGateEligible=eligible,
        firstWordProbability=probability, hybridFallbackProbability=fallback))


class QuantizationEvaluationTests(unittest.TestCase):
    def test_equal_frequency_retains_ungated_midword_and_shortens_fallback(self):
        fragment = traced('štaj', 0., eligible=False)
        self.assertEqual(study.candidate(fragment, 1., 1.), 'štaj')
        self.assertEqual(study.candidate(traced('done tomorrow', .09, .4, 'done'), .1, .31), 'done')
        self.assertEqual(study.candidate(traced('done tomorrow', .09, .3, 'done'), .1, .31), '')

    def test_matching_uses_fallback_mass_not_only_selected_probability(self):
        rows = [traced('a long tail', .01, .9, 'a'), traced('best path', .2, 0., 'best'),
                traced('weak path', .1, 0., 'weak')]
        thresholds = study.cutoff(rows, 1)
        self.assertEqual([study.candidate(r, **thresholds) for r in rows], ['a', '', ''])

    def test_unmatchable_tie_fails_instead_of_changing_frequency(self):
        with self.assertRaisesRegex(AssertionError, 'confidence tie'):
            study.cutoff([traced('a', .2, one_word='a'), traced('b', .2, one_word='b')], 1)

    def test_word_match_joins_fragment_without_counting_empty_as_a_completion(self):
        info = dict(typed='izve', referenceWord='izveštaj')
        self.assertTrue(analysis.reference_match('štaj sutra', info))
        self.assertFalse(analysis.reference_match('štaje sutra', info))
        self.assertFalse(analysis.reference_match('', dict(typed='izveštaj', referenceWord='izveštaj')))

    def test_quality_keeps_silence_in_denominator_and_clusters_repeated_checkpoints(self):
        cases = [dict(id=str(i), scenario=i//2, policies={'q4-production':'x' if i==0 else ''}) for i in range(4)]
        scores = {str(i):{'q4-production':dict(utility=2 if i==0 else 0, first_word=1, flags=[]),
                          'q6-production':dict(utility=0)} for i in range(4)}
        result = analysis.rate_subset(cases, scores, 'q4', 'production')
        self.assertEqual(result['meanUtility'], .5)
        self.assertEqual(result['shown'], 1)
        self.assertEqual(result['delta']['scenarioCount'], 2)

    def test_cancellation_uses_actual_issuance_and_excludes_unpaired_completion(self):
        metadata = {f'{i}-cancel':dict(kind='cancel', scenario=i) for i in range(2)}
        def data(second_cancelled):
            output = {}
            for i in range(2):
                output[f'{i}-cancel'] = dict(cancelled=i==0 or second_cancelled,
                    cancellationRequestedAfterMs=20, latencyMs=50, generationStartedAtMs=100)
                row = dict(text='ok', prompt='prefix', cancelled=False, replayCompletedAtMs=200)
                output[f'{i}-replacement'] = row.copy()
                output[f'{i}-cold'] = row.copy()
            return output
        base, candidate = data(True), data(False)
        candidate['1-replacement']['text'] = 'broken'
        returned, replacement, counts, recovery = analysis.paired_cancellation(base, candidate, metadata)
        self.assertEqual(dict(returned), {0:[(30,30)]})
        self.assertEqual(dict(replacement), {0:[(80,80)]})
        self.assertEqual(counts['candidate']['attempted'], 2)
        self.assertEqual(counts['candidate']['cancelled'], 1)
        self.assertEqual(recovery, [dict(arm='candidate', id='1-replacement')])


if __name__ == '__main__':
    unittest.main()

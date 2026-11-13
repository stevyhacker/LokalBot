import unittest

from confidence_calibration import candidate, cutoff, f32, make_cases, read, HERE


def row(identifier, p, b, text='word tail', one='word', eligible=True):
    return dict(id=identifier,text=text,oneWordText=one,cache=dict(confidenceGateEligible=eligible,
        firstWordProbability=p,hybridFallbackProbability=b))


class CalibrationTests(unittest.TestCase):
    def test_primary_wins_and_fallback_is_already_normalized(self):
        r=row('a',.2,.8)
        self.assertEqual(candidate(r,.1,.31),'word tail')
        self.assertEqual(candidate(r,.3,.31),'word')
        self.assertEqual(candidate(r,.3,.9),'')
        self.assertEqual(candidate(r,.3,.31,False),'')

    def test_midword_is_not_ranked_or_suppressed(self):
        self.assertEqual(candidate(row('m',0,0,eligible=False),1,1),'word tail')

    def test_normalization_suppression_is_preserved(self):
        self.assertEqual(candidate(row('empty',1,1,text='',one=''),.1,.1),'')

    def test_frequency_counts_actual_visible_candidates(self):
        rows=[row('a',.8,.9),row('b',.1,.7),row('c',.04,.1),row('d',.5,.9,text='',one='')]
        cuts=cutoff(rows,2,2)
        self.assertEqual(sum(bool(candidate(r,**cuts)) for r in rows),2)
        self.assertEqual(cuts['primary'],f32(cuts['primary']))

    def test_reject_ties_or_impossible_frequency(self):
        with self.assertRaisesRegex(ValueError,'tie'):
            cutoff([row('a',.5,.8),row('b',.5,.8)],3.1,1)
        with self.assertRaisesRegex(ValueError,'Insufficient'):
            cutoff([row('a',.5,.8)],3.1,1)

    def test_high_boundary_mass_can_disable_primary_branch(self):
        data=[row('a',.2,.9),row('b',.1,.6),row('c',.05,.1)]
        cuts=cutoff(data,.5,1)
        self.assertEqual(cuts['primary'],1)
        self.assertEqual(candidate(data[0],**cuts),'word')
        self.assertEqual(candidate(data[1],**cuts),'')

    def test_corpus_split_and_language_counts(self):
        corpus=read(HERE/'calibration-corpus.json')
        phrases=[]
        for split in ['development','confirmation']:
            cases,refs=make_cases(corpus,split)
            self.assertEqual(len(cases),192)
            self.assertEqual(len(set(c['id'] for c in cases)),192)
            for language in ['en','sr_latn']:
                self.assertEqual(sum(r['language']==language and r['kind']=='boundary' for r in refs.values()),64)
                self.assertEqual(sum(r['language']==language and r['kind']=='midword' for r in refs.values()),32)
                phrases.extend(corpus[f'{split}_{language}'])
        self.assertEqual(len(set(phrases)),128)


if __name__=='__main__':unittest.main()

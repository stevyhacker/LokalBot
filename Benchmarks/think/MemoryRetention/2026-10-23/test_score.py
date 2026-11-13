import json
import re
import unittest
from pathlib import Path
from score import parse,score_case,norm,aggregate

def raw(items,**kwargs):
    return dict(content=json.dumps({"items":items}),finish="stop",**kwargs)

class ScoreChecks(unittest.TestCase):
    def setUp(self):
        self.case=dict(id="test",pair="pair",category="ownership",language="en",expected=[dict(line="U2",kind="fact",text="I live in Riga.",anchors=["riga"])],excluded=["U1"])
        self.item=dict(line="U2",kind="fact",text="I live in Riga.")
    def test_correct(self):
        self.assertTrue(score_case(self.case,raw([self.item]))["perfect"])
    def test_wrong_handle(self):
        r=score_case(self.case,raw([dict(self.item,line="U1")]))
        self.assertEqual((r["recalled"],r["unwanted"],r["decision"]),(0,1,False))
    def test_duplicate(self):
        r=score_case(self.case,raw([self.item,self.item]))
        self.assertEqual((r["recalled"],r["unwanted"],r["decision"]),(1,1,False))
    def test_empty_does_not_imply_recall(self):
        self.assertEqual(score_case(self.case,raw([]))["recalled"],0)
    def test_error_never_clean_empty(self):
        self.case["expected"]=[]
        for reply in [dict(content="",finish="stop"),raw([],error="timeout"),dict(content='{"items":[]}',finish="length")]:
            r=score_case(self.case,reply)
            self.assertFalse(r["clean_empty"]);self.assertFalse(r["perfect"]);self.assertTrue(r["error"])
    def test_invalid_schema(self):
        self.assertIsNotNone(parse(raw([dict(self.item,text=42)]))[1])
    def test_negated_anchor_needs_review(self):
        reply=raw([dict(self.item,text="I do not live in Riga.")])
        self.assertEqual(score_case(self.case,reply)["recalled"],1)
        audit={"test:0":dict(match=None,unwanted=True,issue="contradiction",reason="Negates the source")}
        self.assertEqual(score_case(self.case,reply,audit)["recalled"],0)
    def test_mixed_exclusion_can_recall_and_fail(self):
        audit={"test:0":dict(match=0,unwanted=True,issue="excluded",reason="Adds sensitive content")}
        r=score_case(self.case,raw([self.item]),audit)
        self.assertEqual((r["recalled"],r["unwanted"],r["perfect"]),(1,1,False))
    def test_missing_review_fails(self):
        with self.assertRaises(ValueError):score_case(self.case,raw([self.item]),{})
    def test_invalid_review_source_fails(self):
        with self.assertRaises(AssertionError):score_case(self.case,raw([dict(self.item,line="U1")]),{"test:0":dict(match=0,unwanted=False)})
    def test_kind_error(self):
        r=score_case(self.case,raw([dict(self.item,kind="goal")]))
        self.assertEqual(r["recalled"],1);self.assertFalse(r["perfect"])
    def test_dataset(self):
        cases=json.loads((Path(__file__).parent/"cases.json").read_text())
        self.assertEqual(len(cases),120)
        self.assertEqual(len({c["pair"] for c in cases}),60)
        self.assertEqual(sum(len(c["expected"]) for c in cases),65)
        self.assertEqual(sum(c["language"]=="en" for c in cases),96)
        for c in cases:
            self.assertLessEqual(len(c["expected"]),1)
            for g in c["expected"]:
                self.assertTrue(all(re.search(a,norm(g["text"])) for a in g["anchors"]),(c["id"],g))

if __name__=="__main__":unittest.main()

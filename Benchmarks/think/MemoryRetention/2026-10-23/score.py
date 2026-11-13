"""Frozen mechanical scoring. Semantic review is an explicit, separate overlay."""
import json
import re
import unicodedata
from pathlib import Path

ROOT=Path(__file__).resolve().parent
CYR=dict(zip("абвгдђежзијклљмнњопрстћуфхцчџш",["a","b","v","g","d","dj","e","z","z","i","j","k","l","lj","m","n","nj","o","p","r","s","t","c","u","f","h","c","c","dz","s"]))

def norm(text):
    text="".join(CYR.get(c,c) for c in text.lower()).replace("đ","dj")
    return "".join(c for c in unicodedata.normalize("NFD",text) if not unicodedata.combining(c))

def parse(raw):
    if raw.get("error"): return None,"transport"
    if raw.get("finish")!="stop": return None,"finish"
    try:
        obj=json.loads(raw["content"])
        if not isinstance(obj,dict) or not isinstance(obj.get("items"),list): raise ValueError()
        for x in obj["items"]:
            if not isinstance(x,dict) or not all(isinstance(x.get(k),str) for k in ("line","kind","text")): raise ValueError()
            if x["kind"] not in ("fact","goal","preference") or not x["text"].strip(): raise ValueError()
        return obj["items"],None
    except (ValueError,KeyError,TypeError): return None,"schema"

def score_case(case,raw,review=None):
    items,error=parse(raw)
    result=dict(id=case["id"],pair=case["pair"],category=case["category"],language=case["language"],gold=len(case["expected"]),empty=not case["expected"],error=error,
        recalled=0,unwanted=0,proposals=len(items or []),decision=False,clean_empty=False,perfect=False,kind_errors=0,format_errors=0,items=[])
    if error: return result
    expected_handles=[g["line"] for g in case["expected"]]
    handles=[x["line"].strip().upper() for x in items]
    result["decision"]=sorted(handles)==sorted(expected_handles)
    result["clean_empty"]=not case["expected"] and not items
    seen=set()
    for i,x in enumerate(items):
        h=x["line"].strip().upper()
        matches=[j for j,g in enumerate(case["expected"]) if g["line"]==h and all(re.search(a,norm(x["text"])) for a in g["anchors"])]
        match=next((j for j in matches if j not in seen),None)
        verdict={"match":match,"unwanted":match is None,"issue":"none" if match is not None else ("excluded" if h in case["excluded"] else "content_or_provenance"),"reason":"Frozen handle and anchor matching"}
        if review is not None:
            key=f"{case['id']}:{i}"
            if key not in review: raise ValueError(f"Missing review {key}")
            verdict=review[key]
            match=verdict["match"]
            assert match is None or (isinstance(match,int) and 0<=match<len(case["expected"]) and case["expected"][match]["line"]==h)
            if match in seen: match=None;verdict=dict(verdict,match=None,unwanted=True,issue="duplicate")
        if match is not None:
            seen.add(match)
            result["kind_errors"]+=x["kind"]!=case["expected"][match]["kind"]
        result["unwanted"]+=bool(verdict["unwanted"])
        format_bad=len(x["text"])>=200
        # First-person/language fidelity is semantically audited in review, not guessed by regex.
        result["format_errors"]+=format_bad or bool(verdict.get("presentation_error"))
        result["items"].append(dict(index=i,**x,**verdict))
    result["recalled"]=len(seen)
    result["perfect"]=(len(seen)==len(case["expected"]) and result["unwanted"]==0 and result["decision"] and not result["kind_errors"] and not result["format_errors"])
    return result

def aggregate(rows):
    pair_ids={r["pair"] for r in rows}
    return {"cases":len(rows),"gold":sum(r["gold"] for r in rows),"recalled":sum(r["recalled"] for r in rows),
        "unwanted":sum(r["unwanted"] for r in rows),"proposals":sum(r["proposals"] for r in rows),
        "empty_cases":sum(r["empty"] for r in rows),"clean_empty":sum(r["clean_empty"] for r in rows),
        "decision_correct":sum(r["decision"] for r in rows),"perfect":sum(r["perfect"] for r in rows),
        "errors":sum(bool(r["error"]) for r in rows),"kind_errors":sum(r["kind_errors"] for r in rows),
        "format_errors":sum(r["format_errors"] for r in rows),"pairs":len(pair_ids),
        "pairs_perfect":sum(all(r["perfect"] for r in rows if r["pair"]==p) for p in pair_ids)}

def main():
    cases=json.loads((ROOT/"cases.json").read_text())
    all_review=json.loads((ROOT/"review.json").read_text()) if (ROOT/"review.json").exists() else None
    results={}
    details={}
    for path in sorted((ROOT/"results").glob("*.jsonl")):
        raw=[json.loads(l) for l in path.read_text().splitlines()]
        assert len(raw)==len(cases) and len({r["id"] for r in raw})==len(cases), f"Incomplete or duplicate {path}"
        byid={r["id"]:r for r in raw}
        for mode in ["automatic"]+(["reviewed"] if all_review and path.stem in all_review else []):
            review=all_review[path.stem] if mode=="reviewed" else None
            rows=[score_case(c,byid[c["id"]],review) for c in cases]
            key=f"{path.stem}/{mode}";details[key]=rows
            results[key]={k:aggregate([r for r in rows if test(r)]) for k,test in {
                "all":lambda r:True,"en":lambda r:r["language"]=="en","sr":lambda r:r["language"]!="en"}.items()}
    (ROOT/"scores.json").write_text(json.dumps(results,ensure_ascii=False,indent=2)+"\n")
    (ROOT/"details.json").write_text(json.dumps(details,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(results,indent=2))

if __name__=="__main__": main()

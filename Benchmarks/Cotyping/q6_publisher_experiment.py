"""Pinned E2B base Q6 publisher and calibration experiment; no product changes."""
import argparse
from pathlib import Path
import quantization_experiment as study

IDS = ['q6', 'static', 'local_static', 'english', 'bilingual', 'animateus', 'sporky']
ORDERS = [IDS, list(reversed(IDS))]
study.IDS = IDS
study.ORDERS = ORDERS

def prepare(root, app):
    study.prepare(root, app)
    plan = study.read(root/'plan.json')
    plan.update(experiment='Q6 publishers and equal-budget language calibration',
        wrapperSHA256=study.sha(__file__),
        calibration='FLORES-200 dev plus devtest, EN and deterministic SR Cyrillic-to-Latin transliteration. Same pinned BF16 source and quantizer for local static/English/bilingual arms. English: 64 chunks x512 tokens. Bilingual: 32 EN +32 SR Latin chunks x512, merged importance accumulators. Calibration corpus is separate from fresh fictional evaluation cases and is never sent to Claude.',
        timing='Two reverse-order production rounds over fresh/long/dynamic/cancellation. Two additional reverse-order warmed fresh rounds are predeclared, followed by confidence traces and two native matched-frequency rounds. Eight excluded warmups per process. Serial inference, no simultaneous conversion/download/build.',
        expectedProcesses=len(IDS)*13, expectedMeasuredObservations=len(IDS)*2592,
        decision='Report tradeoffs and retain installed E2B Q6. No source/default switch is part of this request. Highlight any positive overall and per-language quality evidence, poor counts, normal and cancellation latency, interval uncertainty, and judge repeat reliability.',
        provenance='All published arms must declare Google E2B base; inspect architecture/tokenizer/tensor compatibility. Local static and two calibrated arms share one BF16 file and quantizer, so their comparison isolates calibration. Cross-publisher comparisons may include converter/checkpoint-snapshot differences; document them.',
        exclusions='Unsloth/Bartowski/LM Studio IT and QAT files are different checkpoints and excluded from fixed-base comparisons. No personal writing, UI tests, app installs, or CI management.')
    study.write(root/'plan.json',plan)

def run(root, mode):
    plan=study.read(root/'plan.json')
    assert plan['wrapperSHA256']==study.sha(__file__)
    if mode=='steady':
        for number, order in zip([3,4], ORDERS):
            for arm in order: study.run_one(root, arm, 'production', number, 'fresh')
    else:
        study.run(root,mode)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('command',choices=['prepare','production','steady','trace','match','matched','judge-prepare'])
    parser.add_argument('--app',type=Path)
    args=parser.parse_args()
    if args.command=='prepare': prepare(args.root,args.app)
    elif args.command=='match': study.match(args.root)
    elif args.command=='judge-prepare': study.prepare_judge(args.root)
    else: run(args.root,args.command)

if __name__=='__main__': main()

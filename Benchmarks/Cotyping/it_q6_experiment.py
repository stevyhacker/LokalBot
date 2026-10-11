"""Frozen-prompt E2B base versus Unsloth and Bartowski IT Q6_K replay."""
import argparse
from pathlib import Path
import quantization_experiment as study

IDS = ['q6', 'unsloth', 'bartowski']
ORDERS = [IDS, list(reversed(IDS))]
study.IDS = IDS
study.ORDERS = ORDERS


def prepare(root, app):
    study.prepare(root, app)
    plan = study.read(root / 'plan.json')
    plan.update(
        experiment='E2B base Q6 versus Unsloth and Bartowski E2B IT Q6_K',
        wrapperSHA256=study.sha(__file__),
        expectedProcesses=len(IDS) * 13,
        expectedMeasuredObservations=len(IDS) * 2592,
        scope='Reuse the frozen 48 bilingual scenarios / 288 checkpoints from the preceding Q6 study. All models, including current Q6, are rerun; no previous timings or judge scores are pooled. This is a fixed-prompt IT substitution test, not an IT-specific chat-template evaluation.',
        primary='Hold the replay executable, continuation prompt, sampler, search, token budget, threads and production gates fixed. Change only the model artifact, with automatic input BOS aligned to current Q6 when necessary; preserve publisher weights and model stopping metadata.',
        timing='Two reverse-order production rounds over fresh/long/dynamic/cancellation, two predeclared additional warm fresh rounds, one confidence trace and two native matched-frequency rounds. Eight excluded warmups per process; all native processes serial.',
        matched='Per-language native boundary confidence cutoffs target current Q6 production shown counts. Preserve all native ungated midword outputs and fallback/primary ratio 3.1. If that rate is infeasible, use the greatest common feasible lower rate and explicitly report the reduction. Stop and document if native gates cannot realize any common rate; do not silently censor outputs or tune from quality labels.',
        judge='New blinded Claude Opus 5.5 ratings of all distinct production/matched suggestions, with silence zero. English and Serbian Latin only; no reference futures, models, timings, code or personal writing. 24 reversed-order repeats; scenario-cluster 5000-draw bootstrap.',
        decision='Keep the current installed model/default regardless of results. Report overall and per-language quality, poor counts, normal and cancellation latency, artifact precision/memory and uncertainty. No app installation, UI tests or CI management.',
        corpusHistory='The evaluation corpus was authored for the previous base-Q6 publisher study and has been seen by that judge. IT candidates and this fixed protocol were not selected or tuned on their outputs.')
    study.write(root / 'plan.json', plan)


def run(root, mode):
    assert study.read(root / 'plan.json')['wrapperSHA256'] == study.sha(__file__)
    if mode == 'steady':
        for number, order in zip([3, 4], ORDERS):
            for arm in order:
                study.run_one(root, arm, 'production', number, 'fresh')
    else:
        study.run(root, mode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('command', choices=['prepare', 'production', 'steady', 'trace', 'match', 'matched', 'judge-prepare'])
    parser.add_argument('--app', type=Path)
    args = parser.parse_args()
    if args.command == 'prepare':
        prepare(args.root, args.app)
    elif args.command == 'match':
        study.match(args.root)
    elif args.command == 'judge-prepare':
        study.prepare_judge(args.root)
    else:
        run(args.root, args.command)


if __name__ == '__main__':
    main()

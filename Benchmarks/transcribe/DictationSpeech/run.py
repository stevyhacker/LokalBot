"""Run LokalBot's dictation transcription on the prepared recordings, one model configuration at a time."""
import argparse
import json
import os
import platform
import subprocess
import time
import uuid
from pathlib import Path

CONFIGS = {
    'qwen-auto': ('qwen3-asr-1.7b', 'auto'),
    'qwen-en': ('qwen3-asr-1.7b', 'en'),
    'parakeet-v3': ('parakeet-v3', 'auto'),
    'parakeet-ultra': ('parakeet-ultra', 'auto'),
}
DEFAULT_ORDER = ['qwen-auto', 'parakeet-v3', 'parakeet-ultra', 'qwen-en', 'qwen-auto-last']
MODEL_FOLDERS = ['me.dotenv.LokalBot.dev/qwen3-asr-models', 'FluidAudio/Models']


def output(command):
    return subprocess.run(command, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True, help='a Debug build of LokalBot Dev.app')
    parser.add_argument('--cases', type=Path, required=True, help="prepare.py's cases.json")
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--root', type=Path, required=True, help='a disposable home for the app')
    parser.add_argument('--configs', nargs='+', default=DEFAULT_ORDER)
    parser.add_argument('--passes', type=int, default=3)
    args = parser.parse_args()
    home = args.root / 'home'
    support = home / 'Library' / 'Application Support'
    for folder in MODEL_FOLDERS:
        source, target = Path.home() / 'Library' / 'Application Support' / folder, support / folder
        if source.exists() and not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['cp', '-cR', str(source), str(target)], check=True)
    binary = args.app / 'Contents' / 'MacOS' / args.app.stem
    for name in args.configs:
        model, language = CONFIGS[name.removesuffix('-last')]
        folder = args.out / name
        folder.mkdir(parents=True, exist_ok=True)
        command = [str(binary), '--dictation-speech-replay', str(args.cases.resolve()), '--model', model,
                   '--language', language, '--passes', str(args.passes)]
        env = dict(os.environ, CFFIXED_USER_HOME=str(home), LOKALBOT_STORAGE_ROOT=str(args.root / 'storage'),
                   LOKALBOT_DEFAULTS_SUITE='me.dotenv.LokalBot.speech-replay.' + uuid.uuid4().hex)
        started = time.time()
        with open(folder / 'replay.jsonl', 'w') as stdout, open(folder / 'stderr.log', 'w') as stderr:
            status = subprocess.run(command, env=env, stdout=stdout, stderr=stderr).returncode
        (folder / 'manifest.json').write_text(json.dumps({
            'config': name, 'model': model, 'language': language, 'passes': args.passes, 'exit': status,
            'wallSeconds': round(time.time() - started, 1),
            'command': ['LokalBot Dev'] + command[1:2] + ['cases.json'] + command[3:],
            'commit': output(['git', '-C', str(Path(__file__).parent), 'rev-parse', 'HEAD']),
            'machine': {'model': output(['sysctl', '-n', 'hw.model']), 'chip': output(['sysctl', '-n', 'machdep.cpu.brand_string']),
                        'memoryBytes': int(output(['sysctl', '-n', 'hw.memsize']) or 0), 'macOS': platform.mac_ver()[0]},
        }, indent=1) + '\n')
        print(f'{name}: exit {status}, {time.time() - started:.0f} s', flush=True)


if __name__ == '__main__':
    main()

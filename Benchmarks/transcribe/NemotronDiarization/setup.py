"""Create isolated Swift packages; preserve the application's dependency pins."""
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path('/private/tmp/lokalbot-nemotron-bench')
SOURCE = pathlib.Path(__file__).resolve().parent
REVISIONS = {
    'FluidAudioBaseline': '87a39dfe4068fef0f1c69bfe704b2b3ef4fbc5bc',
    'FluidAudio': '5c51c5c93afff0d89594a2a93c3103e790ba648c',
    'references': '9527b7c64846fb38316a610f32e9d3466bd6d8b7',
}
ROOT.mkdir(parents=True, exist_ok=True)
for name, revision in REVISIONS.items():
    path = ROOT / name
    url = ('https://github.com/nttcslab-sp/diar-forced-alignment.git' if name == 'references'
        else 'https://github.com/FluidInference/FluidAudio.git')
    if not path.exists():
        subprocess.run(['git', 'init', str(path)], check=True)
        subprocess.run(['git', '-C', str(path), 'fetch', '--depth', '1', url, revision], check=True)
        subprocess.run(['git', '-C', str(path), 'checkout', '--detach', 'FETCH_HEAD'], check=True)
    actual = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
    assert actual == revision, (name, actual, revision)
for kind, dependency in [('baseline', 'FluidAudioBaseline'), ('nemotron', 'FluidAudio')]:
    path = ROOT / kind
    (path / 'Sources/DiarBench').mkdir(parents=True, exist_ok=True)
    shutil.copy(SOURCE / 'Bench.swift', path / 'Sources/DiarBench/Bench.swift')
    flags = ', swiftSettings: [.define("NEMOTRON")]' if kind == 'nemotron' else ''
    (path / 'Package.swift').write_text(f'''// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DiarBench", platforms: [.macOS(.v14)],
 dependencies: [.package(path: "../{dependency}", traits: [])],
 targets: [.executableTarget(name: "DiarBench", dependencies: [.product(name: "FluidAudio", package: "{dependency}")]{flags})])
''')
    subprocess.run(['swift', 'build', '-c', 'release', '--disable-sandbox', '--package-path', str(path),
        '--scratch-path', str(ROOT / f'build-{kind}'), '--cache-path', str(ROOT / 'spm-cache')], check=True)

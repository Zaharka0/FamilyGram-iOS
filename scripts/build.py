"""Build the entire Telegram app; package only successful fresh build output."""
import argparse
import json
import subprocess
import sys
from pathlib import Path
from common import ROOT, run
from preflight import check
from package_ipa import package


def build(source, config, output, number):
    source, config, output = source.resolve(), config.resolve(), output.resolve()
    check(source)
    sparse = subprocess.run(['git', '-C', str(source), 'config', '--get', 'core.sparseCheckout'], capture_output=True, text=True)
    if sparse.stdout.strip() == 'true':
        raise ValueError('A sparse source-check checkout cannot build an IPA; prepare a fresh full source directory')
    if not (source / '.familygram-patched').exists():
        raise ValueError('Run patch_source.py and icons.py before building')
    if not (source / 'Telegram/Telegram-iOS/FamilyGram.icon/icon.json').exists():
        raise ValueError('Run icons.py before building')
    if number < 1:
        raise ValueError('Build number must be positive')
    configuration = json.loads(config.read_text())
    # A separate artifacts path avoids accidentally packaging an older IPA.
    artifacts = ROOT / 'build' / f'artifacts-{number}'
    if artifacts.exists():
        raise ValueError('This build output directory already exists; choose a new build number')
    run([sys.executable, 'build-system/Make/Make.py', 'build',
         '--configurationPath', config, '--xcodeManagedCodesigning',
         '--familygramUnsigned', '--buildNumber', number, '--configuration', 'release_arm64',
         '--outputBuildArtifactsPath', artifacts], cwd=source)
    package(artifacts / 'Telegram.ipa', output, configuration['bundle_id'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=ROOT / 'source')
    parser.add_argument('--config', type=Path, default=ROOT / 'build/configuration.json')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/FamilyGram.ipa')
    parser.add_argument('--build-number', type=int, required=True)
    args = parser.parse_args()
    build(args.source, args.config, args.output, args.build_number)

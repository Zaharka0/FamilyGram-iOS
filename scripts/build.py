"""Build the entire Telegram app; package only successful fresh build output."""
import argparse
import json
import subprocess
import sys
from pathlib import Path
from common import ROOT, run
from preflight import check
from package_ipa import package
from package_simulator import package_simulator
from patch_rules import GUARD, RULES_PATH, RULE_FILE


def build(source, config, output, number, target="device"):
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
    if GUARD not in (source / RULES_PATH / RULE_FILE).read_text():
        raise ValueError('Run patch_rules.py before building the unsigned device IPA')
    configuration = json.loads(config.read_text())
    # A separate artifacts path avoids accidentally packaging an older IPA.
    artifacts = ROOT / 'build' / f'artifacts-{target}-{number}'
    if artifacts.exists():
        raise ValueError('This build output directory already exists; choose a new build number')
    run([sys.executable, 'build-system/Make/Make.py', 'build',
         '--configurationPath', config, '--xcodeManagedCodesigning',
         '--familygramUnsigned', '--buildNumber', number, '--configuration', 'release_sim_arm64' if target == 'simulator' else 'release_arm64',
         '--outputBuildArtifactsPath', artifacts], cwd=source)
    packager = package_simulator if target == 'simulator' else package
    packager(artifacts / 'Telegram.ipa', output, configuration['bundle_id'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=ROOT / 'source')
    parser.add_argument('--config', type=Path, default=ROOT / 'build/configuration.json')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--target', choices=['device', 'simulator'], default='device')
    parser.add_argument('--build-number', type=int, required=True)
    args = parser.parse_args()
    output = args.output or ROOT / ('dist/FamilyGram-Simulator-arm64.zip' if args.target == 'simulator' else 'dist/FamilyGram.ipa')
    build(args.source, args.config, output, args.build_number, args.target)

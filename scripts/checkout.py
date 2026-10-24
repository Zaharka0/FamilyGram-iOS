"""Fetch exactly the reviewed upstream revision. Never reset a developer checkout."""
import argparse
import subprocess
from pathlib import Path
from common import ROOT, MANIFEST, run


def checkout(destination, submodules=True, sparse=False):
    destination = Path(destination).resolve()
    if destination.exists() and any(destination.iterdir()):
        head = subprocess.check_output(['git', '-C', str(destination), 'rev-parse', 'HEAD'], text=True).strip()
        if head != MANIFEST['commit']:
            raise ValueError('Source HEAD differs from upstream.json; use a new empty directory')
        print('Using existing pinned checkout; no files reset.')
    else:
        destination.mkdir(parents=True, exist_ok=True)
        run(['git', 'init', destination])
        run(['git', 'remote', 'add', 'origin', MANIFEST['repository']], cwd=destination)
        run(['git', 'fetch', '--depth=1', '--filter=blob:none', 'origin', MANIFEST['commit']], cwd=destination)
        if sparse:
            run(['git', 'sparse-checkout', 'init', '--no-cone'], cwd=destination)
            run(['git', 'sparse-checkout', 'set', '/versions.json', '/Telegram/BUILD',
                 '/Telegram/Telegram-iOS/*.lproj/InfoPlist.strings',
                 '/submodules/TelegramUI/Sources/AppDelegate.swift',
                 '/submodules/SettingsUI/Sources/Themes/ThemeSettingsAppIconItem.swift',
                 '/build-system/Make/Make.py'], cwd=destination)
        run(['git', 'checkout', '--detach', 'FETCH_HEAD'], cwd=destination)
    if submodules:
        run(['git', 'submodule', 'sync', '--recursive'], cwd=destination)
        run(['git', 'submodule', 'update', '--init', '--recursive', '--depth=1', '--jobs=4'], cwd=destination)
    actual = __import__('json').loads((destination / 'versions.json').read_text())
    for key in ('app', 'xcode', 'macos'):
        if actual[key] != MANIFEST[key]:
            raise ValueError('Unexpected upstream toolchain: ' + key)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=ROOT / 'source')
    parser.add_argument('--no-submodules', action='store_true', help='Source checks only; not sufficient to build')
    parser.add_argument('--sparse-check', action='store_true', help='Fetch only files needed for portable source checks')
    args = parser.parse_args()
    if args.sparse_check and not args.no_submodules:
        parser.error('--sparse-check requires --no-submodules')
    checkout(args.source, not args.no_submodules, args.sparse_check)

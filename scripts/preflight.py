import argparse
import platform
import re
import shutil
import subprocess
from pathlib import Path
from common import ROOT, MANIFEST


def check(source):
    if platform.system() != 'Darwin':
        raise ValueError('IPA compilation requires macOS; use the iOS IPA GitHub workflow')
    if not shutil.which('xcodebuild'):
        raise ValueError('Install full Xcode, not only Command Line Tools')
    version = subprocess.check_output(['xcodebuild', '-version'], text=True)
    match = re.search(r'^Xcode (\S+)', version, re.M)
    if not match or match[1] != MANIFEST['xcode']:
        raise ValueError(f"Select Xcode {MANIFEST['xcode']} using DEVELOPER_DIR; version overrides are not used")
    if int(platform.mac_ver()[0].split('.')[0]) < int(MANIFEST['macos']):
        raise ValueError(f"macOS {MANIFEST['macos']} or newer is required")
    if shutil.disk_usage(Path(source).parent).free < 25 * 1024 ** 3:
        raise ValueError('At least 25 GiB of free disk space is required before the initial source/build')
    print('macOS/Xcode/disk preflight passed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=ROOT / 'source')
    check(parser.parse_args().source)

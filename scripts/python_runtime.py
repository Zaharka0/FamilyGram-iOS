"""Fetch a pinned BeeWare CPython framework and package PEP 730 extensions."""
import hashlib
import json
import plistlib
import shutil
import tarfile
import urllib.request
from pathlib import Path
from common import ROOT

MANIFEST = json.loads((ROOT / 'python-runtime.json').read_text())
CACHE = ROOT / 'build/python-support'


def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    archive = CACHE / 'python-ios.tar.gz'
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != MANIFEST['sha256']:
        with urllib.request.urlopen(MANIFEST['url'], timeout=120) as response, archive.open('wb') as output:
            shutil.copyfileobj(response, output)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != MANIFEST['sha256']:
        raise ValueError('CPython download checksum mismatch')
    destination = CACHE / 'Python.xcframework'
    if not destination.exists():
        # Python 3.11 supports the security extraction filter on its maintained releases.
        with tarfile.open(archive) as handle:
            handle.extractall(CACHE, filter='data')
    return destination


def install(app, simulator=False):
    framework = CACHE / 'Python.xcframework'
    if not framework.exists():
        raise ValueError('Run scripts/python_runtime.py before packaging')
    app = Path(app)
    slice_name = 'ios-arm64_x86_64-simulator' if simulator else 'ios-arm64'
    selected = framework / slice_name
    frameworks = app / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    destination = frameworks / 'Python.framework'
    if destination.exists(): shutil.rmtree(destination)
    shutil.copytree(selected / 'Python.framework', destination, symlinks=True,
                    ignore=shutil.ignore_patterns('Headers', 'Modules', '_CodeSignature'))
    python = app / 'FamilyPython'
    lib = python / 'lib'
    ignore = shutil.ignore_patterns('__pycache__', 'test', 'tests', 'tkinter', 'turtledemo', 'idlelib', 'libpython*.dylib')
    shutil.copytree(framework / 'lib', lib, dirs_exist_ok=True, ignore=ignore)
    shutil.copytree(selected / 'lib-arm64', lib, dirs_exist_ok=True, ignore=ignore)
    shutil.copytree(ROOT / 'python_sdk', app / 'FamilyPythonSDK', dirs_exist_ok=True, ignore=ignore)
    stdlib = lib / 'python3.11'
    bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
    template = plistlib.loads((framework / 'build/iOS-dylib-Info-template.plist').read_bytes())
    for binary in list(stdlib.rglob('*.so')):
        # Same .fwork/.origin mapping as BeeWare's support-package build/utils.sh.
        relative = binary.relative_to(stdlib / 'lib-dynload')
        module = str(relative).split('.')[0].replace('/', '.')
        folder = frameworks / (module + '.framework'); folder.mkdir(exist_ok=True)
        target = folder / module
        shutil.move(binary, target)
        info = dict(template, CFBundleExecutable=module, CFBundleIdentifier=(bundle + '.' + module).replace('_', '-'))
        (folder / 'Info.plist').write_bytes(plistlib.dumps(info))
        marker = binary.with_suffix('.fwork')
        marker.write_text(str(target.relative_to(app)) + '\n')
        (folder / (module + '.origin')).write_text(str(marker.relative_to(app)) + '\n')
    print('Embedded CPython', MANIFEST['version'], 'and SDK 1 for', slice_name)


if __name__ == '__main__':
    prepare()
    print('Pinned CPython support package verified.')

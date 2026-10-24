"""Verify branding, layout and the requested device/simulator Mach-O platform."""
import argparse
import plistlib
import re
import struct
import zipfile
from pathlib import PurePosixPath, Path


def arm64_platform(data, expected_platform):
    # Both outputs are arm64; LC_BUILD_VERSION distinguishes device from simulator.
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin arm64 Mach-O executable')
    _, cpu, _, filetype, count, commands_size, _, _ = struct.unpack_from('<8I', data)
    if cpu != 0x0100000c or filetype != 2 or count > 10000 or 32 + commands_size > len(data):
        raise ValueError('Wrong or truncated executable')
    offset = 32
    platform_id = None
    for _ in range(count):
        if offset + 8 > 32 + commands_size:
            raise ValueError('Truncated Mach-O load commands')
        cmd, size = struct.unpack_from('<II', data, offset)
        if size < 8 or offset + size > 32 + commands_size:
            raise ValueError('Invalid Mach-O command')
        if cmd == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError('Invalid build version')
            platform_id = struct.unpack_from('<I', data, offset + 8)[0]
        if cmd == 0x2c:  # LC_ENCRYPTION_INFO_64
            if size < 24 or struct.unpack_from('<I', data, offset + 16)[0] != 0:
                raise ValueError('Encrypted App Store executable cannot be re-signed')
        offset += size
    if platform_id != expected_platform:
        raise ValueError(f'Expected Mach-O platform {expected_platform}; received {platform_id}')


def device_arm64(data):
    arm64_platform(data, 2)


def inspect(path, bundle_id='org.familygram.ios', simulator=False, app_zip=False):
    if app_zip and not simulator:
        raise ValueError('Root .app ZIP is reserved for simulator builds')
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError('Duplicate ZIP entries')
        for name in names:
            p = PurePosixPath(name)
            if p.is_absolute() or '..' in p.parts or '\\' in name:
                raise ValueError('Unsafe IPA archive path')
        pattern = r'[^/]+\.app/Info.plist' if app_zip else r'Payload/[^/]+\.app/Info.plist'
        plists = [n for n in names if re.fullmatch(pattern, n)]
        if len(plists) != 1:
            raise ValueError('Expected exactly one main app')
        root = plists[0].rsplit('/', 1)[0] + '/'
        info = plistlib.loads(archive.read(plists[0]))
        if info.get('CFBundleIdentifier') != bundle_id or info.get('CFBundleDisplayName') != 'FamilyGram':
            raise ValueError('Wrong application identity')
        executable = info.get('CFBundleExecutable', '')
        if not executable or '/' in executable or executable in ('.', '..'):
            raise ValueError('Invalid executable name')
        expected = 'iPhoneSimulator' if simulator else 'iPhoneOS'
        if info.get('CFBundleSupportedPlatforms') != [expected]:
            raise ValueError(f'Expected {expected} archive')
        if any(n.startswith(root + 'PlugIns/') or n.startswith(root + 'Watch/') for n in names):
            raise ValueError('The initial AltStore build must not include app extensions or Watch apps')
        for icons_key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
            icons = info.get(icons_key, {})
            if not icons.get('CFBundlePrimaryIcon'):
                raise ValueError('Missing primary icon')
            alternate = icons.get('CFBundleAlternateIcons', {})
            if set(alternate) != {f'Family{i}' for i in range(1, 6)}:
                raise ValueError('Missing FamilyGram alternate icons')
        arm64_platform(archive.read(root + executable), 7 if simulator else 2)
        if archive.testzip() is not None:
            raise ValueError('Corrupt IPA archive')
        return {'bundle_id': bundle_id, 'version': info.get('CFBundleShortVersionString'),
                'build': info.get('CFBundleVersion'), 'minimum_ios': info.get('MinimumOSVersion'),
                'alternate_icons': 5, 'device_arm64': not simulator, 'simulator_arm64': simulator}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--bundle-id', default='org.familygram.ios')
    args = parser.parse_args()
    print(inspect(args.ipa, args.bundle_id))

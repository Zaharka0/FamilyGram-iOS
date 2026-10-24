import hashlib
import json
import os
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from common import replace_once
from configure import configuration
from icons import artwork, generate
from verify_ipa import device_arm64, inspect


def binary(platform=2, encrypted=0):
    commands = struct.pack('<6I', 0x32, 24, platform, 0, 0, 0)
    commands += struct.pack('<6I', 0x2c, 24, 0, 0, encrypted, 0)
    return struct.pack('<8I', 0xfeedfacf, 0x0100000c, 0, 2, 2, len(commands), 0, 0) + commands


class BuildToolsTests(unittest.TestCase):
    def test_configuration_validation(self):
        config = configuration('123456', 'a' * 32, 'org.familygram.ios')
        self.assertEqual(config['app_specific_url_scheme'], 'familygram')
        self.assertFalse(config['enable_icloud'])
        self.assertFalse(config['enable_siri'])
        for api_id, api_hash, bundle in [('', 'a'*32, 'org.fg.ios'), ('-1', 'a'*32, 'org.fg.ios'),
                ('2147483648', 'a'*32, 'org.fg.ios'), ('1', 'bad', 'org.fg.ios'),
                ('1', 'a'*32, 'bad"; print(secret)'), ('1', 'a'*32, '../file')]:
            with self.assertRaises(ValueError):
                configuration(api_id, api_hash, bundle)

    def test_patch_rejects_changed_or_duplicate_anchor(self):
        self.assertEqual(replace_once('before anchor after', 'anchor', 'new'), 'before new after')
        for value in ('absent', 'anchor anchor'):
            with self.assertRaises(ValueError):
                replace_once(value, 'anchor', 'new')

    def test_machine_code_rejects_simulator_and_encrypted_binary(self):
        device_arm64(binary())
        for data in (binary(platform=7), binary(encrypted=1), binary()[:20], b'not Mach-O'):
            with self.assertRaises(ValueError):
                device_arm64(data)

    def make_ipa(self, path, platform=2, name='FamilyGram', extensions=False, unsafe=False):
        icons = {'CFBundlePrimaryIcon': {'CFBundleIconName': 'FamilyGram'},
                 'CFBundleAlternateIcons': {f'Family{i}': {'CFBundleIconFiles': [f'Family{i}']} for i in range(1, 6)}}
        info = dict(CFBundleIdentifier='org.familygram.ios', CFBundleDisplayName=name,
                    CFBundleExecutable='Telegram', CFBundleSupportedPlatforms=['iPhoneOS'],
                    CFBundleIcons=icons, **{'CFBundleIcons~ipad': icons})
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('Payload/Telegram.app/Info.plist', plistlib.dumps(info))
            archive.writestr('Payload/Telegram.app/Telegram', binary(platform))
            if extensions:
                archive.writestr('Payload/Telegram.app/PlugIns/Widget.appex/Info.plist', b'')
            if unsafe:
                archive.writestr('../outside', b'')

    def test_ipa_identity_and_archive_guards(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'test.ipa'
            self.make_ipa(path)
            self.assertTrue(inspect(path)['device_arm64'])
            for params in ({'platform':7}, {'name':'Telegram'}, {'extensions':True}, {'unsafe':True}):
                self.make_ipa(path, **params)
                with self.assertRaises(ValueError):
                    inspect(path)

    def test_icons_verify_checksums_before_conversion(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'icon.jpg').write_bytes(b'incorrect image')
            with self.assertRaises(ValueError):
                artwork({'path':'icon.jpg', 'sha256':'0'*64}, {}, root)

    def test_all_icon_sizes_and_primary_metadata(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            image = Image.new('RGB', (512, 512), 'pink')
            with patch('icons.artwork', return_value=image):
                generate(root)
            base = root / 'Telegram/Telegram-iOS'
            self.assertEqual(len(list(base.glob('Family*.alticon'))), 5)
            self.assertEqual(len(list(base.glob('Icons.xcassets/Family*.imageset'))), 6)
            for folder in base.glob('Family*.alticon'):
                widths = []
                for path in folder.glob('*.png'):
                    with Image.open(path) as opened:
                        widths.append(opened.width)
                self.assertEqual(sorted(widths), [76,120,152,167,180])
            with Image.open(base / 'FamilyGram.icon/Assets/FamilyGram.png') as opened:
                self.assertEqual(opened.mode, 'RGB')
            primary = json.loads((base / 'FamilyGram.icon/icon.json').read_text())
            self.assertEqual(primary['groups'][0]['layers'][0]['image-name'], 'FamilyGram.png')


if __name__ == '__main__':
    unittest.main()

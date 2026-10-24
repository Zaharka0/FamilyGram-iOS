"""Portable source/resource checks, not an iOS compiler or device test."""
import ast
import json
from pathlib import Path
from PIL import Image
from common import ROOT


def check(source):
    source = Path(source)
    build = (source / 'Telegram/BUILD').read_text()
    assert 'composer_icon_folders = ["FamilyGram"]' in build
    assert 'alternate_icon_folders = ["Family1", "Family2", "Family3", "Family4", "Family5"]' in build
    assert '<key>CFBundleDisplayName</key>\n    <string>Telegram</string>' not in build
    delegate = (source / 'submodules/TelegramUI/Sources/AppDelegate.swift').read_text()
    section = delegate.split('getAvailableAlternateIcons: {', 1)[1].split('getAlternateIconName:', 1)[0]
    assert section.count('PresentationAppIcon(') == 6
    assert section.count('isDefault: true') == 1 and 'isPremium: true' not in section
    make = (source / 'build-system/Make/Make.py').read_text()
    ast.parse(make)
    assert '--familygramUnsigned' in make and '--features=disable_legacy_signing' in make
    base = source / 'Telegram/Telegram-iOS'
    for i in range(1, 7):
        preview = base / f'Icons.xcassets/Family{i}.imageset'
        assert Image.open(preview / 'icon.png').size == (180, 180)
        json.loads((preview / 'Contents.json').read_text())
        if i < 6:
            for suffix, size in [('@2x', 120), ('@3x', 180), ('Ipad', 76), ('Ipad@2x', 152), ('LargeIpad@2x', 167)]:
                image = Image.open(base / f'Family{i}.alticon/Family{i}{suffix}.png')
                assert image.size == (size, size) and image.mode == 'RGB'
    assert Image.open(base / 'FamilyGram.icon/Assets/FamilyGram.png').size == (1024, 1024)
    for path in base.glob('*.lproj/InfoPlist.strings'):
        assert '"CFBundleDisplayName" = "FamilyGram";' in path.read_text()
    print('Prepared source and six icon choices checked; no iOS compilation/device test claimed.')


if __name__ == '__main__':
    check(ROOT / 'source')

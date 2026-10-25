"""Apply the published FamilyGram delta to the pinned Telegram source."""
import argparse
import json
import re
import subprocess
from pathlib import Path
from common import ROOT, MANIFEST, replace_once
from family_port import integrate


def patched_files(source):
    source = Path(source)
    versions = json.loads((source / 'versions.json').read_text())
    if versions['app'] != MANIFEST['app'] or versions['xcode'] != MANIFEST['xcode']:
        raise ValueError('Wrong upstream version')
    changes = {}
    build_path = Path('Telegram/BUILD')
    build = (source / build_path).read_text()
    build = replace_once(build, 'composer_icon_folders = ["Telegram"]', 'composer_icon_folders = ["FamilyGram"]')
    start = build.index('alternate_icon_folders = [')
    end = build.index('\n]', start) + 2
    build = build[:start] + 'alternate_icon_folders = ["Family1", "Family2", "Family3", "Family4", "Family5"]' + build[end:]
    for key in ('CFBundleDisplayName', 'CFBundleName'):
        build = build.replace(f'<key>{key}</key>\n    <string>Telegram</string>',
                              f'<key>{key}</key>\n    <string>FamilyGram</string>')
    changes[build_path] = build
    delegate_path = Path('submodules/TelegramUI/Sources/AppDelegate.swift')
    delegate = (source / delegate_path).read_text()
    start = delegate.index('                var icons = [', delegate.index('getAvailableAlternateIcons: {'))
    end = delegate.index('                return icons', start)
    icons = '                let icons = [\n'
    icons += '                    PresentationAppIcon(name: "Family6", imageName: "Family6", isDefault: true),\n'
    icons += ',\n'.join(f'                    PresentationAppIcon(name: "Family{i}", imageName: "Family{i}")' for i in range(1, 6))
    icons += '\n                ]\n\n'
    changes[delegate_path] = delegate[:start] + icons + delegate[end:]
    labels_path = Path('submodules/SettingsUI/Sources/Themes/ThemeSettingsAppIconItem.swift')
    labels = (source / labels_path).read_text()
    names = [('Kiss', 'Поцелуй'), ('Smile', 'Улыбка'), ('Together', 'Вместе'), ('Tenderness', 'Нежность'), ('Fun', 'Смешной кадр'), ('FamilyGram', 'Сердце')]
    cases = ''
    for i, (en, ru) in enumerate(names, 1):
        cases += f'                                case "Family{i}":\n'
        cases += f'                                    name = item.strings.baseLanguageCode.hasPrefix("ru") ? "{ru}" : "{en}"\n'
    labels = replace_once(labels, '                            switch icon.name {', '                            switch icon.name {\n' + cases.rstrip())
    changes[labels_path] = labels
    # --bazelArguments in this upstream wrapper is declared but not forwarded. Add
    # one explicit, tested mode instead of silently relying on that unused option.
    make_path = Path('build-system/Make/Make.py')
    make = (source / make_path).read_text()
    anchor = '    bazel_command_line.set_configuration(arguments.configuration)\n'
    make = replace_once(make, anchor, anchor + '''    if arguments.familygramUnsigned:
        bazel_command_line.set_disable_provisioning_profiles()
        bazel_command_line.common_build_args += [
            '--//Telegram:disableExtensions',
            '--features=disable_legacy_signing',
            '--features=familygram.altstore_unsigned',
        ]
''')
    make = replace_once(make, "    add_project_and_build_common_arguments(buildParser)", """    buildParser.add_argument('--familygramUnsigned', action='store_true', default=False,
        help='Build a device IPA for subsequent local AltStore signing, without Apple certificates or extensions.')
    add_project_and_build_common_arguments(buildParser)""")
    changes[make_path] = make
    for path in (source / 'Telegram/Telegram-iOS').glob('*.lproj/InfoPlist.strings'):
        # Localized CFBundleDisplayName overrides the main Info.plist.
        text = path.read_text(encoding='utf-8')
        text = re.sub(r'"CFBundleDisplayName"\s*=\s*"[^"]*";', '', text)
        text += '\n"CFBundleDisplayName" = "FamilyGram";\n'
        changes[path.relative_to(source)] = text
    return integrate(source, changes)


def apply(source):
    source = Path(source).resolve()
    head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if head != MANIFEST['commit']:
        raise ValueError('Refusing to patch an unreviewed source revision')
    marker = source / '.familygram-patched'
    if marker.exists():
        raise ValueError('Already patched; use a fresh source directory rather than applying twice')
    targets = ['Telegram/BUILD', 'submodules/TelegramUI/Sources/AppDelegate.swift',
               'submodules/SettingsUI/Sources/Themes/ThemeSettingsAppIconItem.swift',
               'build-system/Make/Make.py', 'Telegram/Telegram-iOS']
    if subprocess.run(['git', '-C', str(source), 'diff', '--quiet', 'HEAD', '--', *targets]).returncode:
        raise ValueError('Source contains local changes in patch targets; use a fresh directory')
    # Calculate every replacement before writing; a changed anchor leaves files intact.
    changes = patched_files(source)
    for path, content in changes.items():
        (source / path).parent.mkdir(parents=True, exist_ok=True)
        (source / path).write_text(content)
    marker.write_text(MANIFEST['commit'] + '\n')
    print(f'Patched {len(changes)} source/resource files.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=ROOT / 'source')
    apply(parser.parse_args().source)

"""Allow profile-free packaging only in the explicit unsigned AltStore app mode."""
import argparse
import subprocess
from pathlib import Path
from common import ROOT, replace_once

RULES_COMMIT = '485016eb5b0948cc17307064e7977a6d68e94046'
RULES_PATH = Path('build-system/bazel-rules/rules_apple')
RULE_FILE = Path('apple/internal/ios_rules.bzl')
GUARD = '''    if platform_prerequisites.platform.is_device and not (
        "familygram.altstore_unsigned" in features and
        "disable_legacy_signing" in features and
        not provisioning_profile
    ):
        processor_partials.append(
            partials.provisioning_profile_partial('''


def patched_rules(text):
    # Only ios_application: do not relax extensions, tests, signing or other rules.
    start = text.index('def _ios_application_impl(')
    end = text.index('\ndef ', start + 1)
    app = text[start:end]
    anchor = '''    if platform_prerequisites.platform.is_device:
        processor_partials.append(
            partials.provisioning_profile_partial('''
    app = replace_once(app, anchor, GUARD)
    return text[:start] + app + text[end:]


def apply(source):
    rules = Path(source).resolve() / RULES_PATH
    head = subprocess.check_output(['git', '-C', str(rules), 'rev-parse', 'HEAD'], text=True).strip()
    if head != RULES_COMMIT:
        raise ValueError('Unexpected rules_apple revision; initialize the pinned submodule')
    if subprocess.run(['git', '-C', str(rules), 'diff', '--quiet', 'HEAD', '--', str(RULE_FILE)]).returncode:
        raise ValueError('rules_apple has local changes; use a fresh checkout')
    target = rules / RULE_FILE
    target.write_text(patched_rules(target.read_text()))
    print('Patched ios_application profile embedding for explicit unsigned AltStore builds only.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=ROOT / 'source')
    apply(parser.parse_args().source)

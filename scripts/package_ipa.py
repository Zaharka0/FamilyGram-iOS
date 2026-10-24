"""Ad-hoc sign for entitlement discovery; AltStore supplies the real device signature."""
import argparse
import hashlib
import json
import platform
import shutil
import plistlib
import tempfile
from pathlib import Path
from common import ROOT, MANIFEST, run
from verify_ipa import inspect


def package(input_path, output, bundle_id='org.familygram.ios'):
    if platform.system() != 'Darwin':
        raise ValueError('Packaging/signing requires macOS codesign and ditto')
    metadata = inspect(input_path, bundle_id)
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='familygram-ipa-') as temporary:
        stage = Path(temporary)
        run(['/usr/bin/ditto', '-x', '-k', input_path, stage])
        app = next((stage / 'Payload').glob('*.app'))
        # Keep the app group: Telegram requires it for its database and passcode store.
        # AltStore reads this ad-hoc signature and replaces IDs/profiles when installing.
        entitlements = {
            'application-identifier': f'0000000000.{bundle_id}',
            'com.apple.developer.team-identifier': '0000000000',
            'com.apple.security.application-groups': [f'group.{bundle_id}'],
            'keychain-access-groups': [f'0000000000.{bundle_id}'],
        }
        entitlement_path = stage / 'FamilyGram.entitlements'
        entitlement_path.write_bytes(plistlib.dumps(entitlements))
        # Sign leaf code before enclosing frameworks and the main bundle.
        nested = list(app.rglob('*.dylib')) + [p for p in app.rglob('*.framework') if p.is_dir()]
        for binary in sorted(nested, key=lambda p: len(p.parts), reverse=True):
            run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', binary])
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
             '--entitlements', entitlement_path, app])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        candidate = stage / 'FamilyGram.ipa'
        run(['/usr/bin/ditto', '-c', '-k', '--keepParent', stage / 'Payload', candidate])
        inspect(candidate, bundle_id)
        staging_output = output.with_suffix('.ipa.tmp')
        shutil.copyfile(candidate, staging_output)
        staging_output.replace(output)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.ipa.sha256').write_text(f'{digest}  {output.name}\n')
    metadata.update(upstream_commit=MANIFEST['commit'], sha256=digest,
                    signing='ad-hoc; must be re-signed by AltStore',
                    family_features_ported=False, tested_on_iphone=False)
    output.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('FamilyGram.ipa packaged and structurally verified; iPhone installation test is still required.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/FamilyGram.ipa')
    parser.add_argument('--bundle-id', default='org.familygram.ios')
    args = parser.parse_args()
    package(args.input, args.output, args.bundle_id)

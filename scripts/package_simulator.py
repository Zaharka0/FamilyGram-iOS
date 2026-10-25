"""Package a genuine iOS Simulator arm64 app at the ZIP root for Appetize."""
import hashlib
import json
import platform
import plistlib
import shutil
import tempfile
from pathlib import Path
from common import MANIFEST, run
from verify_ipa import inspect
from python_runtime import install as install_python


def package_simulator(input_path, output, bundle_id='org.familygram.ios'):
    if platform.system() != 'Darwin':
        raise ValueError('Simulator packaging requires macOS codesign and ditto')
    metadata = inspect(input_path, bundle_id, simulator=True)
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='familygram-simulator-') as temporary:
        stage = Path(temporary)
        run(['/usr/bin/ditto', '-x', '-k', input_path, stage])
        original = next((stage / 'Payload').glob('*.app'))
        app = stage / 'FamilyGram.app'
        original.rename(app)
        install_python(app, simulator=True)
        entitlements = stage / 'Simulator.entitlements'
        entitlements.write_bytes(plistlib.dumps({
            'com.apple.security.application-groups': [f'group.{bundle_id}'],
            'get-task-allow': True,
        }))
        nested = list(app.rglob('*.dylib')) + [p for p in app.rglob('*.framework') if p.is_dir()]
        for binary in sorted(nested, key=lambda p: len(p.parts), reverse=True):
            run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', binary])
        for extension in app.glob('PlugIns/*.appex'):
            info = plistlib.loads((extension / 'Info.plist').read_bytes())
            widget_entitlements = {'com.apple.security.application-groups': [f'group.{bundle_id}']}
            widget_file = stage / 'FamilyWidget.entitlements'
            widget_file.write_bytes(plistlib.dumps(widget_entitlements))
            run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', '--entitlements', widget_file, extension])
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none',
             '--entitlements', entitlements, app])
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app])
        candidate = stage / 'FamilyGram-Simulator-arm64.zip'
        # Exactly FamilyGram.app/... at the ZIP root, without Payload or an outer ZIP.
        run(['/usr/bin/ditto', '-c', '-k', '--keepParent', app, candidate])
        inspect(candidate, bundle_id, simulator=True, app_zip=True)
        staging_output = output.with_suffix('.zip.tmp')
        shutil.copyfile(candidate, staging_output)
        staging_output.replace(output)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix('.zip.sha256').write_text(f'{digest}  {output.name}\n')
    metadata.update(upstream_commit=MANIFEST['commit'], sha256=digest,
                    signing='ad-hoc simulator signature; no Apple ID or AltStore required',
                    archive_layout='FamilyGram.app at ZIP root', tested_on_simulator=False)
    output.with_suffix('.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Simulator ZIP structurally verified; launch testing is still required.')

"""Convert the existing approved FamilyGram artwork to iOS assets."""
import argparse
import hashlib
import io
import json
import urllib.request
from pathlib import Path
from PIL import Image
from common import ROOT


def artwork(asset, manifest, local=None):
    if local is not None:
        data = (Path(local) / asset['path']).read_bytes()
    else:
        url = f"https://raw.githubusercontent.com/{manifest['source_repository']}/{manifest['source_commit']}/{asset['path']}"
        with urllib.request.urlopen(url, timeout=90) as response:
            data = response.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024 or hashlib.sha256(data).hexdigest() != asset['sha256']:
        raise ValueError('Icon download checksum mismatch')
    image = Image.open(io.BytesIO(data))
    image.load()
    return image.convert('RGB')


def generate(source, local=None):
    manifest = json.loads((ROOT / 'icons.json').read_text())
    base = Path(source) / 'Telegram/Telegram-iOS'
    for asset in manifest['icons']:
        i = asset['index']
        image = artwork(asset, manifest, local)
        # Previews use the same UIImage(named:in:) resource path as upstream.
        preview = base / f'Icons.xcassets/Family{i}.imageset'
        preview.mkdir(parents=True, exist_ok=True)
        image.resize((180, 180), Image.Resampling.LANCZOS).save(preview / 'icon.png')
        (preview / 'Contents.json').write_text(json.dumps(dict(
            images=[dict(idiom='universal', filename='icon.png', scale='3x')],
            info=dict(version=1, author='xcode')), indent=2))
        if i == 6:
            primary = base / 'FamilyGram.icon'
            (primary / 'Assets').mkdir(parents=True, exist_ok=True)
            image.resize((1024, 1024), Image.Resampling.LANCZOS).save(primary / 'Assets/FamilyGram.png')
            # A single opaque layer keeps the artwork identical in light/dark modes.
            icon = dict(fill='system-light', groups=[{
                'blend-mode': 'normal', 'layers': [{'image-name': 'FamilyGram.png',
                'name': 'FamilyGram', 'glass': False}], 'lighting': 'combined',
                'shadow': {'kind': 'layer-color', 'opacity': 0}, 'specular': False,
                'translucency': {'enabled': False, 'value': 0}}],
                **{'supported-platforms': {'squares': 'shared'}})
            (primary / 'icon.json').write_text(json.dumps(icon, indent=2))
        else:
            alt = base / f'Family{i}.alticon'
            alt.mkdir(parents=True, exist_ok=True)
            for suffix, size in [('@2x', 120), ('@3x', 180), ('Ipad', 76), ('Ipad@2x', 152), ('LargeIpad@2x', 167)]:
                image.resize((size, size), Image.Resampling.LANCZOS).save(alt / f'Family{i}{suffix}.png')
    print('Generated primary heart icon, five alternate photo icons and six previews.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, default=ROOT / 'source')
    parser.add_argument('--local-assets', type=Path, help='Optional existing checkout of the pinned Android source')
    args = parser.parse_args()
    generate(args.source, args.local_assets)

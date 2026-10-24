from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = json.loads((ROOT / 'upstream.json').read_text())


def run(args, cwd=None):
    return subprocess.run([str(x) for x in args], cwd=cwd, check=True)


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Upstream changed: expected one patch anchor: ' + old[:100])
    return text.replace(old, new, 1)

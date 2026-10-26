"""Run the real pinned Android reducer; Swift must match its complete output."""
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
COMMIT = '0124c31333d96f88b630b3102e999c3dc5b771dc'
BLOB_SHA = '2679ca888fce302c28fba306aed19bb8aced687c'
URL = 'https://raw.githubusercontent.com/Zaharka0/FamilyGram-Android/' + COMMIT + '/TMessagesProj/src/main/java/org/telegram/messenger/family/FamilyCore.java'
target = ROOT / 'build/android-reference'
target.mkdir(parents=True, exist_ok=True)
with urllib.request.urlopen(URL, timeout=60) as response:
    data = response.read()
actual = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
if actual != BLOB_SHA:
    raise ValueError('Android reference Git blob checksum mismatch')
source = target / 'FamilyCore.java'
source.write_bytes(data)
subprocess.run(['javac', '-encoding', 'UTF-8', '-d', str(target), str(source), str(ROOT / 'tests/fixtures/FGAndroidExport.java')], check=True)
output = subprocess.check_output(['java', '-cp', str(target), 'FGAndroidExport'], text=True, encoding='utf-8')
entries, expected = [], {}
for line in output.splitlines():
    fields = line.split('\t')
    if fields[0] == 'EVENT':
        entries.append(dict(id=int(fields[1]), date=int(fields[2]), actor=int(fields[3]), wire=fields[4]))
    elif fields[0] == 'STATE':
        _, entity, key, value = fields
        expected.setdefault(entity, {})[key] = base64.b64decode(value).decode('utf-8')
destination = ROOT / 'tests/fixtures/fg1-android-ledger.json'
destination.write_text(json.dumps(dict(android_commit=COMMIT, entries=entries, expected=expected), ensure_ascii=False, indent=2), encoding='utf-8')
print('Android reference exported', len(entries), 'events and', len(expected), 'cards')

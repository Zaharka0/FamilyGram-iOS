"""Prepare a release only from the successfully packaged, checksummed IPA artifact."""
import hashlib
import json
import os
import re
from pathlib import Path

root = Path(__file__).resolve().parent.parent
dist = root / "dist"
ipa = dist / "FamilyGram.ipa"
metadata = json.loads((dist / "FamilyGram.json").read_text())
digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
checksum = (dist / "FamilyGram.ipa.sha256").read_text().split()
if not checksum or checksum[0] != digest or metadata.get("sha256") != digest:
    raise SystemExit("IPA checksum mismatch")
if metadata.get("family_features_ported") is not True:
    raise SystemExit("This workflow publishes only the FamilyGram port")
source = (root / "overlay/TelegramUI/FamilyUpdates.swift").read_text()
match = re.search(r'static let version = "([0-9]+\.[0-9]+\.[0-9]+)"', source)
build = os.environ["FAMILYGRAM_BUILD_NUMBER"]
if not match or not re.fullmatch(r"[1-9][0-9]*", build):
    raise SystemExit("Invalid FamilyGram version/build")
tag = f"familygram-{match[1]}-b{build}"
(dist / "release-tag.txt").write_text(tag + "\n")
notes = root / "RELEASE-NOTES.md"
(dist / "release-notes.md").write_text(notes.read_text())
print(tag)

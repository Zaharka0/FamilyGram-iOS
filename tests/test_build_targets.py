import importlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
builder = importlib.import_module('build')
from patch_rules import GUARD, RULES_PATH, RULE_FILE


class BuildTargetTests(unittest.TestCase):
    def test_each_target_builds_its_own_platform_and_uses_its_own_packager(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            (source / '.familygram-patched').touch()
            icon = source / 'Telegram/Telegram-iOS/FamilyGram.icon/icon.json'
            icon.parent.mkdir(parents=True)
            icon.write_text('{}')
            rules = source / RULES_PATH / RULE_FILE
            rules.parent.mkdir(parents=True)
            rules.write_text(GUARD)
            config = root / 'configuration.json'
            config.write_text(json.dumps({'bundle_id': 'org.familygram.ios'}))
            for target, expected in [('device', 'release_arm64'), ('simulator', 'release_sim_arm64')]:
                with patch.object(builder, 'ROOT', root), patch.object(builder, 'check'), \
                     patch.object(builder.subprocess, 'run', return_value=SimpleNamespace(stdout='')), \
                     patch.object(builder, 'run') as command, \
                     patch.object(builder, 'package') as device, \
                     patch.object(builder, 'package_simulator') as simulator:
                    builder.build(source, config, root / 'output', 1, target)
                    arguments = command.call_args.args[0]
                    self.assertEqual(arguments[arguments.index('--configuration') + 1], expected)
                    chosen, other = (device, simulator) if target == 'device' else (simulator, device)
                    chosen.assert_called_once()
                    other.assert_not_called()

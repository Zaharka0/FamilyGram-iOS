import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python_sdk'))
import family_ios_host as ios
import family_plugin_host as host

EXAMPLE = (Path(__file__).resolve().parents[1] / 'python_sdk/heart_signature.plugin').read_text()

class IOSPluginTests(unittest.TestCase):
    def tearDown(self):
        for uid, plugin in list(host._instances):
            host.unload(uid, plugin)
    def request(self, account=10, **extra):
        value = dict(action='send', account=account, partner=20, id='heart_signature', source=EXAMPLE, settings={'active':True}, text='Hello', peer=20)
        value.update(extra)
        return ios.safe_handle(value)
    def test_python_sdk_partner_hook_and_account_isolation(self):
        self.assertEqual(self.request()['text'], 'Hello ❤️')
        self.assertEqual(self.request(peer=30)['text'], 'Hello')
        self.assertEqual(self.request(text='Hello ❤️')['text'], 'Hello ❤️')
        self.assertEqual(self.request(account=11, settings={'active':False})['text'], 'Hello')
        self.assertEqual(set(host._instances), {(10,'heart_signature'),(11,'heart_signature')})
    def test_metadata_does_not_execute_imported_source(self):
        result = ios.safe_handle(dict(action='metadata', source=EXAMPLE+'\nraise RuntimeError("must not execute")'))
        self.assertEqual(result['metadata']['id'], 'heart_signature')
    def test_settings_rows_match_android_sdk(self):
        result = self.request(action='settings')
        self.assertEqual([r['type'] for r in result['rows']], ['header','switch','input'])
        self.assertTrue(result['rows'][1]['value'])
    def test_unsupported_dependency_and_execution_error(self):
        self.assertIn('error', ios.safe_handle(dict(action='metadata', source=EXAMPLE+'\n__requirements__=["numpy"]')))
        result = self.request(source=EXAMPLE+'\nraise ValueError("bad plugin")')
        self.assertIn('bad plugin', result['error'])
        self.assertNotIn((10,'heart_signature'), host._instances)

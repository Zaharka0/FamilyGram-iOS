"""FamilyGram Python SDK 1. Not a drop-in replacement for the exteraGram/Xposed SDK."""
from enum import Enum

class HookStrategy(Enum):
    DEFAULT = 0
    CANCEL = 1
    MODIFY = 2

class HookResult:
    def __init__(self, strategy=HookStrategy.DEFAULT, params=None):
        self.strategy, self.params = strategy, params

class BasePlugin:
    def __init__(self):
        self._bridge = None
        self._send_hooks = []
        self._receive_hooks = []
    def on_plugin_load(self): pass
    def on_plugin_unload(self): pass
    def create_settings(self): return []
    def get_setting(self, key, default=None):
        import json
        raw = self._bridge.getSetting(str(key))
        return default if raw is None else json.loads(str(raw))
    def set_setting(self, key, value, reload_settings=False):
        import json
        self._bridge.setSetting(str(key), json.dumps(value, ensure_ascii=False))
    def add_on_send_message_hook(self, callback=None):
        self._send_hooks.append(callback or self.on_send_message_hook)
    def add_on_receive_message_hook(self, callback): self._receive_hooks.append(callback)
    def on_send_message_hook(self, account, params): return HookResult()
    def log(self, message): self._bridge.log(str(message))
    def hook_method(self, *args, **kwargs):
        raise NotImplementedError('Xposed method hooks require the exteraGram engine; FamilyGram SDK 1 does not implement them')

"""JSON adapter around the same FamilyGram SDK 1 host used by Android."""
import json
import pathlib
import types
import family_plugin_host as host

class Bridge:
    def __init__(self, account, partner, settings):
        self.account, self.partner, self.settings = account, partner, settings
        self.logs = []
    def getSetting(self, key):
        return json.dumps(self.settings[key], ensure_ascii=False) if key in self.settings else None
    def setSetting(self, key, value): self.settings[key] = json.loads(value)
    def getPartner(self): return self.partner
    def getAccount(self): return self.account
    def log(self, message): self.logs.append(str(message)[:2000])


def handle(request):
    operation = request['action']
    if operation == 'metadata': return {'metadata': json.loads(host.metadata(request['source']))}
    uid, plugin_id = int(request['account']), request['id']
    key = (uid, plugin_id)
    if operation == 'unload':
        host.unload(uid, plugin_id)
        return {'ok': True}
    settings = request.get('settings', {})
    bridge = Bridge(uid, int(request.get('partner', 0)), settings)
    if key not in host._instances:
        host.load(uid, request['source'], bridge)
    else:
        host._instances[key][0]._bridge = bridge
    try:
        result = {'settings': bridge.settings, 'logs': bridge.logs}
        if operation == 'settings': result['rows'] = json.loads(host.settings(uid, plugin_id))
        elif operation == 'send':
            params = types.SimpleNamespace(message=request['text'], peer=int(request['peer']))
            result['allowed'] = host.send(uid, plugin_id, uid, params)
            if not isinstance(params.message, str) or len(params.message.encode('utf-16-le')) // 2 > 4096:
                raise ValueError('Plugin returned an invalid message')
            result['text'] = params.message
        elif operation == 'receive':
            message = types.SimpleNamespace(message=request['text'], peer=int(request['peer']), text=request['text'])
            host.receive(uid, plugin_id, uid, message)
        else: raise ValueError('Unknown iOS plugin action')
        return result
    except BaseException:
        host.unload(uid, plugin_id)
        raise


def safe_handle(request):
    try: return handle(request)
    except BaseException as error: return {'error': type(error).__name__ + ': ' + str(error)[:1000]}

"""Account-scoped, explicit opt-in Python plugin lifecycle and event dispatch."""
import ast
import inspect
import json
import re
import sys
import types
import functools
import time
import threading
_context = threading.local()

def current_bridge():
    bridge=getattr(_context,"bridge",None)
    if bridge is None: raise RuntimeError("No active plugin callback")
    return bridge

def limited(function):
    @functools.wraps(function)
    def run(*args,**kwargs):
        deadline=time.monotonic()+1.0
        previous=sys.gettrace()
        def trace(frame,event,arg):
            if time.monotonic()>deadline: raise TimeoutError("Plugin callback exceeded one second")
            return trace
        sys.settrace(trace)
        try: return function(*args,**kwargs)
        finally: sys.settrace(previous)
    return run

from base_plugin import BasePlugin, HookResult, HookStrategy

_instances = {}
_MAX_SOURCE = 262144

def metadata(source):
    if len(source.encode('utf-8')) > _MAX_SOURCE:
        raise ValueError('Plugin file is larger than 256 KB')
    tree = ast.parse(source)
    fields = {}
    for node in tree.body:
        if isinstance(node, ast.Assign):
            for name in node.targets:
                if isinstance(name, ast.Name) and name.id in {'__id__', '__name__', '__description__', '__author__', '__version__', '__requirements__', '__familygram_sdk__'}:
                    fields[name.id] = ast.literal_eval(node.value)
    plugin_id, name = fields.get('__id__'), fields.get('__name__')
    if not isinstance(plugin_id, str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{1,31}', plugin_id):
        raise ValueError('Plugin needs a valid __id__ (2–32 characters)')
    if not isinstance(name, str) or not name.strip() or len(name) > 100:
        raise ValueError('Plugin needs a nonempty __name__ (up to 100 characters)')
    if fields.get('__requirements__'):
        raise ValueError('External pip dependencies are not supported by FamilyGram SDK 1')
    if fields.get('__familygram_sdk__', 1) != 1:
        raise ValueError('Unsupported FamilyGram SDK version')
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and (node.module or '').startswith(('hook_utils', 'com.exteragram', 'de.robv')):
            raise ValueError('This plugin requires the exteraGram/Xposed engine and must be adapted for FamilyGram')
        if isinstance(node, ast.Import) and any(n.name.startswith(('hook_utils', 'com.exteragram', 'de.robv')) for n in node.names):
            raise ValueError('Unsupported exteraGram/Xposed import')
        if isinstance(node, ast.Attribute) and node.attr in {'hook_method', 'hook_all_methods', 'hook_all_constructors'}:
            raise ValueError('Xposed method hooks are not supported by FamilyGram SDK 1')
    for key in ('__description__', '__author__', '__version__'):
        if not isinstance(fields.get(key, ''), str) or len(fields.get(key, '')) > 2000:
            raise ValueError('Invalid plugin metadata: ' + key)
    return json.dumps(dict(id=plugin_id, name=name, description=fields.get('__description__', ''), author=fields.get('__author__', ''), version=fields.get('__version__', '1.0')), ensure_ascii=False)

def _key(uid, plugin_id): return (int(uid), str(plugin_id))

@limited
def unload(uid, plugin_id):
    item = _instances.pop(_key(uid, plugin_id), None)
    if item:
        _context.bridge=item[0]._bridge
        try: item[0].on_plugin_unload()
        finally: sys.modules.pop(item[1], None)

@limited
def load(uid, source, bridge):
    info = json.loads(metadata(source))
    key = _key(uid, info['id'])
    unload(*key)
    module_name = '_family_plugin_' + str(uid) + '_' + info['id'].replace('-', '_')
    module = types.ModuleType(module_name)
    module.__file__ = '<FamilyGram plugin ' + info['id'] + '>'
    sys.modules[module_name] = module
    _context.bridge=bridge
    try:
        exec(compile(source, module.__file__, 'exec'), module.__dict__)
        declared = {node.name for node in ast.parse(source).body if isinstance(node, ast.ClassDef)}
        classes = [v for name,v in module.__dict__.items() if name in declared and inspect.isclass(v) and v is not BasePlugin and issubclass(v, BasePlugin)]
        if len(classes) != 1: raise ValueError('Plugin must declare exactly one BasePlugin subclass')
        instance = classes[0]()
        instance._bridge = bridge
        instance.on_plugin_load()
        _instances[key] = (instance, module_name)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise

@limited
def settings(uid, plugin_id):
    instance = _instances[_key(uid, plugin_id)][0]
    _context.bridge=instance._bridge
    rows = []
    for row in instance.create_settings()[:100]:
        data = dict(row.data)
        if data.get('type') in ('switch', 'input'):
            data['value'] = instance.get_setting(data['key'], data.get('default'))
        rows.append(data)
    return json.dumps(rows, ensure_ascii=False)

@limited
def send(uid, plugin_id, account, params):
    instance = _instances[_key(uid, plugin_id)][0]
    _context.bridge=instance._bridge
    for callback in list(instance._send_hooks):
        result = callback(account, params)
        if isinstance(result, HookResult) and result.strategy == HookStrategy.CANCEL: return False
        if isinstance(result, HookResult) and result.strategy == HookStrategy.MODIFY and result.params is not None and result.params is not params:
            raise ValueError('Modify fields of the original SendMessageParams; replacing it is not supported')
    return True

@limited
def receive(uid, plugin_id, account, message):
    instance = _instances[_key(uid, plugin_id)][0]
    _context.bridge=instance._bridge
    for callback in list(instance._receive_hooks): callback(account, message)

@limited
def ui(uid, plugin_id, callback):
    instance = _instances[_key(uid, plugin_id)][0]
    _context.bridge = instance._bridge
    return callback()

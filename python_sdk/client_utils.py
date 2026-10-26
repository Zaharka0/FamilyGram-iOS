"""Platform-neutral subset of FamilyGram SDK 1. Android Java controllers are unavailable on iOS."""
def get_partner():
    from family_plugin_host import current_bridge
    return current_bridge().getPartner()
def get_account_instance():
    from types import SimpleNamespace
    from family_plugin_host import current_bridge
    bridge = current_bridge()
    return SimpleNamespace(account_id=bridge.getAccount(), partner_id=bridge.getPartner())
def get_messages_controller(): raise NotImplementedError('Android Java controllers are not available on iOS')
def get_user_config(): return get_account_instance()
def get_send_messages_helper(): raise NotImplementedError('Use FamilyGram send hooks; Android SendMessagesHelper is unavailable on iOS')
def get_last_fragment(): return None

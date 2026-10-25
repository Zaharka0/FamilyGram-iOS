class Header:
    def __init__(self, text): self.data = dict(type='header', text=str(text))
class Divider:
    def __init__(self, text=''): self.data = dict(type='text', text=str(text))
class Text:
    def __init__(self, text, subtext='', **kwargs): self.data = dict(type='text', text=str(text), description=str(subtext))
class Switch:
    def __init__(self, key, text, default=False, subtext='', **kwargs):
        self.data = dict(type='switch', key=str(key), text=str(text), default=bool(default), description=str(subtext))
class Input:
    def __init__(self, key, text, default='', subtext='', **kwargs):
        self.data = dict(type='input', key=str(key), text=str(text), default=str(default), description=str(subtext))

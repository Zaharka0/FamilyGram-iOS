"""Write private build configuration; never print API credentials."""
import argparse
import json
import os
import re
from pathlib import Path
from common import ROOT


def configuration(api_id, api_hash, bundle_id):
    if not re.fullmatch(r'[1-9][0-9]{0,9}', api_id or '') or int(api_id) > 2147483647:
        raise ValueError('Set repository secret API_ID to your Telegram api_id')
    if not re.fullmatch(r'[0-9a-fA-F]{32}', api_hash or ''):
        raise ValueError('Set repository secret API_HASH to your Telegram api_hash')
    if not re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+){2,}', bundle_id):
        raise ValueError('Invalid bundle identifier')
    # No Apple credentials or signing identities are used for the AltStore input IPA.
    return dict(bundle_id=bundle_id, api_id=api_id, api_hash=api_hash.lower(),
                team_id='0000000000', app_center_id='0', is_internal_build='false',
                is_appstore_build='false', appstore_id='0', app_specific_url_scheme='familygram',
                premium_iap_product_id='', enable_siri=False, enable_icloud=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'build/configuration.json')
    parser.add_argument('--bundle-id', default='org.familygram.ios')
    args = parser.parse_args()
    config = configuration(os.environ.get('API_ID'), os.environ.get('API_HASH'), args.bundle_id)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Existing files must also lose broad permissions.
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w') as stream:
            json.dump(config, stream, indent=2)
    except BaseException:
        args.output.unlink(missing_ok=True)
        raise
    print('Private configuration written.')

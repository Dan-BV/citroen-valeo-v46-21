#!/usr/bin/env python3
"""Write the AltStore/SideStore source manifest for the unsigned iOS build.

SideStore is fully compatible with AltStore sources, so pointing it at the
manifest published beside the ipa turns every CI build into a one-tap update on
the phone instead of a download-and-open dance.

Both shapes are emitted on purpose: the modern `versions` array and the legacy
app-level `version`/`downloadURL` fields, so older SideStore builds still see
the release.

    python tools/ios/make_source.py --ipa valeo-ios.ipa --version 1.0.7 \
        --commit a1b2c3d --repo Dan-BV/citroen-valeo-v46-21 --out source.json
"""

import argparse
import json
import os
from datetime import datetime, timezone

ICON_PATH = 'ios/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png'

DESCRIPTION = (
    'Live data for a Citroen/Peugeot Valeo V46.21 engine ECU over an ELM327 '
    'BLE adapter: the 118 parameters of the ten official Diagbox measurement '
    'pages, scalable graphs, fault codes, ECU identification and CSV drive '
    'logs.\n\n'
    'Unsigned build - SideStore signs it on the device with your own free '
    'Apple ID.'
)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ipa', required=True, help='the built ipa, read for its size')
    ap.add_argument('--version', required=True)
    ap.add_argument('--commit', required=True)
    ap.add_argument('--repo', required=True, help='owner/name')
    ap.add_argument('--tag', default='ios-latest')
    ap.add_argument('--out', required=True)
    a = ap.parse_args()

    owner, name = a.repo.split('/', 1)
    releases = 'https://github.com/%s/releases/download/%s' % (a.repo, a.tag)
    pages = 'https://%s.github.io/%s' % (owner.lower(), name)

    version = {
        'version': a.version,
        'date': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'localizedDescription': 'Built from commit %s.' % a.commit,
        'downloadURL': '%s/%s' % (releases, os.path.basename(a.ipa)),
        'size': os.path.getsize(a.ipa),
        'minOSVersion': '17.0',
    }

    app = {
        'name': 'Valeo V46.21',
        'bundleIdentifier': 'com.fap.modern',
        'developerName': owner,
        'subtitle': 'Citroen Valeo V46.21 live data',
        'localizedDescription': DESCRIPTION,
        'iconURL': '%s/%s' % (pages, ICON_PATH),
        'tintColor': '4FA8E8',
        'category': 'utilities',
        'versions': [version],
        # Legacy fields, for SideStore builds that predate `versions`.
        'version': version['version'],
        'versionDate': version['date'],
        'versionDescription': version['localizedDescription'],
        'downloadURL': version['downloadURL'],
        'size': version['size'],
    }

    source = {
        'name': 'Citroen Valeo V46.21',
        'identifier': 'com.fap.modern.source',
        'sourceURL': '%s/source.json' % releases,
        'iconURL': app['iconURL'],
        'tintColor': app['tintColor'],
        'apps': [app],
        'news': [],
    }

    with open(a.out, 'w', encoding='utf-8', newline='\n') as fh:
        json.dump(source, fh, ensure_ascii=False, indent=2)
        fh.write('\n')
    print('wrote %s: %s, %.1f MB' % (a.out, a.version, version['size'] / 1048576))


if __name__ == '__main__':
    main()

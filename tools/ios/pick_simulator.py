#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime.

`xcodebuild test` needs a concrete destination, and the device list on the
GitHub macOS runners changes with every Xcode release, so it is discovered
rather than pinned. The UDID and not the name, because the runners carry
several iOS runtimes at once and a name like "iPhone 17" exists in all of them -
an ambiguous destination makes xcodebuild dump every device it knows and exit
70.
"""

import json
import re
import subprocess
import sys


def runtime_version(identifier):
    """`...SimRuntime.iOS-26-4-1` -> (26, 4, 1); anything else sorts first."""
    m = re.search(r'iOS-([\d-]+)$', identifier)
    if not m:
        return ()
    return tuple(int(p) for p in m.group(1).split('-'))


def main():
    listing = subprocess.run(
        ['xcrun', 'simctl', 'list', 'devices', 'available', '-j'],
        capture_output=True, text=True, check=True).stdout
    devices = json.loads(listing)['devices']

    best = None  # (runtime version, name, udid)
    for identifier, group in devices.items():
        if 'iOS' not in identifier:
            continue
        version = runtime_version(identifier)
        for device in group:
            if not device.get('isAvailable') or 'iPhone' not in device['name']:
                continue
            if best is None or version > best[0]:
                best = (version, device['name'], device['udid'])

    if best is None:
        print('no available iPhone simulator', file=sys.stderr)
        return 1

    version, name, udid = best
    print('%s on iOS %s' % (name, '.'.join(str(p) for p in version)),
          file=sys.stderr)
    print(udid)
    return 0


if __name__ == '__main__':
    sys.exit(main())

#!/usr/bin/env python3
"""Print the name of an available iPhone simulator.

`xcodebuild test` needs a concrete destination, and the device list on the
GitHub macOS runners changes with every Xcode release, so the name is
discovered instead of pinned.
"""

import json
import subprocess
import sys


def main():
    out = subprocess.run(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'],
                         capture_output=True, text=True, check=True).stdout
    best = None
    for runtime, devices in json.loads(out)['devices'].items():
        if 'iOS' not in runtime:
            continue
        for device in devices:
            if device.get('isAvailable') and 'iPhone' in device['name']:
                # The list is ordered oldest runtime first, so the last hit is
                # the newest iPhone available.
                best = device['name']
    if not best:
        print('no available iPhone simulator', file=sys.stderr)
        return 1
    print(best)
    return 0


if __name__ == '__main__':
    sys.exit(main())

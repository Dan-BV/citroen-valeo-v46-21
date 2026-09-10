#!/usr/bin/env python3
"""List BLE devices, and dump one device's GATT services and characteristics.

Written for the ThinkDiag Mini, whose GATT layout we need before the iOS app
can talk to it: the Android capture only showed the classic-SPP path, because
that is what the Android ThinkDiag app chooses. The adapter is dual-mode and
advertises LE under its serial number (`9TFD…`), which is the link iOS uses.

Needs `pip install bleak`. Requires the adapter to be powered and in range -
plugged into the OBD port with the ignition on, near the machine.

    python tools/ble/enumerate.py                 # scan and list
    python tools/ble/enumerate.py 9TFD            # match by name, dump GATT
    python tools/ble/enumerate.py DC:0D:30:51:4E:36
"""
import asyncio
import sys

from bleak import BleakClient, BleakScanner

SCAN_SECONDS = 15.0


async def scan():
    print(f"scanning {SCAN_SECONDS:.0f} s ...")
    found = await BleakScanner.discover(timeout=SCAN_SECONDS, return_adv=True)
    rows = []
    for addr, (dev, adv) in found.items():
        rows.append((adv.rssi, addr, dev.name or adv.local_name or "(no name)",
                     list(adv.service_uuids)))
    rows.sort(reverse=True)
    print(f"found {len(rows)} devices")
    for rssi, addr, name, uuids in rows:
        print(f"  {addr}  rssi={rssi:4d}  {name}")
        if uuids:
            print(f"        advertised services: {uuids}")
    return rows


async def dump(target):
    """Connect to the first device whose address or name contains `target`."""
    rows = await scan()
    up = target.upper()
    hit = next((r for r in rows if up in r[1].upper() or up in r[2].upper()), None)
    if hit is None:
        print(f"\n{target}: not in range. Power the adapter and try again.")
        return 1
    _, addr, name, _ = hit
    print(f"\nconnecting to {addr} ({name}) ...")
    async with BleakClient(addr, timeout=20.0) as client:
        print(f"connected, mtu={client.mtu_size}\n")
        for service in client.services:
            print(f"service {service.uuid}  {service.description}")
            for ch in service.characteristics:
                props = ",".join(ch.properties)
                print(f"    char {ch.uuid}  [{props}]  {ch.description}")
    return 0


def main():
    if len(sys.argv) > 1:
        return asyncio.run(dump(sys.argv[1]))
    asyncio.run(scan())
    print("\nPass a name fragment or address to dump its GATT, e.g. 9TFD")
    return 0


if __name__ == "__main__":
    sys.exit(main())

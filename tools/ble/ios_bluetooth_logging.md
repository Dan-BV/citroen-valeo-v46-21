# Capturing a Bluetooth trace on the iPhone

Why: the Android capture showed the ThinkDiag adapter over classic SPP, because
that is the link the Android app chose. The iPhone reaches the same adapter over
BLE, and how the `55aa` protocol is framed over GATT — which characteristic, what
MTU, how a 40-70 byte page is chunked — can only be seen from the iPhone side.
This is the iOS equivalent of `pull_btsnoop.ps1`.

Apple's Bluetooth logging profile makes iOS write a PacketLogger trace, which a
sysdiagnose then packages up. Wireshark reads that format natively, so the whole
analysis happens on this machine — no Mac needed.

## 1. Install the logging profile

Profile `iOSBluetoothLogging.mobileconfig`, from Apple's Profiles and Logs page:
<https://developer.apple.com/bug-reporting/profiles-and-logs/> (pick "Bluetooth"
for iOS/iPadOS). The download redirects to an Apple ID sign-in.

Open the downloaded file on the iPhone, then finish installation in
Settings → General → VPN & Device Management. Logging starts as soon as the
profile is installed. If the capture later turns out empty, reboot the phone and
repeat — some of Apple's logging profiles only take effect after a restart.

Third-party mirrors of this profile exist. Prefer Apple's own copy: a
configuration profile changes how the device behaves, and is not something to
take from an unverified source.

## 2. Reproduce the session

1. Toggle Bluetooth off and on. As on Android, this gives a clean trace that
   starts at the connection instead of mid-stream.
2. Open the **official ThinkDiag app** — this capture is about how *it* talks to
   the adapter — and drive a CITROEN session: connect, read the engine data
   stream, let it run a minute or two.
3. Keep it short. The trace is a rolling buffer, and a long session pushes the
   interesting connection setup out of it.

## 3. Trigger the sysdiagnose

Press and hold **both volume buttons and the side button together for about
1-1.5 seconds**, then let go. A short vibration confirms it. Holding longer
brings up the power-off slider instead, so it is a brief squeeze, not a long
press.

Then wait — generation takes up to ten minutes.

## 4. Get the archive off the phone

Settings → Privacy & Security → Analytics & Improvements → **Analytics Data**.
The list is long; search for `sysdiagnose` and pick the newest by timestamp.
Share it to this machine any way that carries a few hundred megabytes — Files,
iCloud Drive, or a USB copy.

**The archive holds broad device data**, the same concern as an Android
bugreport: installed apps, identifiers, system logs. It is gitignored, and it
stays local.

## 5. Extract the Bluetooth trace

    tar -xzf sysdiagnose_*.tar.gz --wildcards '*/logs/Bluetooth/*'

The `logs/Bluetooth` folder holds the PacketLogger trace (`.pklg`). Open it
straight in Wireshark, which registers the format as "macOS PacketLogger" and
auto-detects it — no conversion, no Mac.

## 6. Remove the profile

Settings → General → VPN & Device Management → Bluetooth Logging for iOS →
Remove Profile. Leave it installed and it keeps writing traces, costing battery
and storage for nothing.

## What to look for in the trace

- The GATT service and the characteristic pair the ThinkDiag app writes to and
  subscribes on — the UUIDs our `BleTransport` would need to prefer.
- The negotiated ATT MTU, and how many notifications one `21xx8001` page costs.
  This is the number that decides whether ThinkDiag is worth building at all:
  compare it against the baseline measured with `LinkStats` on the current
  adapter.
- Whether the `55aa` framing over GATT matches the RFCOMM form documented in
  `out/thinkdiag_protocol.md`, and whether the licence exchange and the link
  handles (`2905` engine) are the same over this link.

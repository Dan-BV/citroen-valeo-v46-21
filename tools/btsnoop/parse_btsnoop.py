#!/usr/bin/env python3
"""
parse_btsnoop.py — extract the ELM327 request/response transcript from an Android
Bluetooth HCI snoop log of an OBD app session (e.g. the FAP app).

Handles:
  - input = an `adb bugreport` .zip  (auto-finds FS/data/misc/bluetooth/logs/BT_HCI_*/btsnoop*)
  - input = a raw btsnoop file (standard "btsnoop\\0" magic; MTK ".cfa.curf" is standard inside)
Transport assumed: classic RFCOMM/SPP ELM327 (DLCI 2, UIH frames, 2-byte length).
For BLE (ATT) adapters this would need a different link layer — not implemented (FAP used SPP).

Output: transcript.json = [{"t": unix_seconds, "cmd": "21CB8001", "hex": "61FF04.."}, ...]
where `hex` is the reassembled multiframe response payload (length-verified).

Usage:
  python parse_btsnoop.py <bugreport.zip | btsnoop_file> [out_transcript.json]

Background & full method: ../../out/fap_calib_from_btsnoop.md
"""
import sys, os, re, json, struct, zipfile

BTSNOOP_EPOCH = 0x00dcddb30f2f8000  # microseconds between 0000-01-01 and 1970-01-01

def load_snoop_bytes(path):
    if zipfile.is_zipfile(path):
        zf = zipfile.ZipFile(path)
        cands = [e for e in zf.namelist()
                 if 'bluetooth/logs/' in e and ('BT_HCI' in e or 'btsnoop' in e or e.endswith('.curf'))]
        if not cands:
            raise SystemExit("no btsnoop file found inside zip (looked in bluetooth/logs/)")
        # pick the largest (the active session log)
        cands.sort(key=lambda e: zf.getinfo(e).file_size, reverse=True)
        print(f"[zip] using {cands[0]} ({zf.getinfo(cands[0]).file_size} bytes)")
        return zf.read(cands[0])
    return open(path, 'rb').read()

def parse_rfcomm(pdu):
    """pdu = one complete L2CAP payload (len:2 LE, cid:2 LE, body). Return (dlci, info_bytes) for UIH frames."""
    if len(pdu) < 4:
        return None
    ln, cid = struct.unpack('<HH', pdu[:4])
    b = pdu[4:4 + ln]
    if cid == 0x0001 or len(b) < 4:   # 0x0001 = L2CAP signaling
        return None
    addr, ctrl = b[0], b[1]
    dlci = addr >> 2
    if ctrl not in (0xEF, 0xFF):      # UIH frame (P/F 0 / 1)
        return None
    if b[2] & 1:                       # EA bit set -> 1-byte length
        length, hdr = b[2] >> 1, 3
    else:                              # 2-byte length
        length, hdr = (b[2] >> 1) | (b[3] << 7), 4
    if ctrl & 0x10:                    # P/F set -> credit octet present
        hdr += 1
    return dlci, b[hdr:hdr + length]

def extract_frames(data):
    """Walk btsnoop records, reassemble L2CAP, return time-sorted DLCI-2 UIH frames."""
    if data[:8] != b'btsnoop\x00':
        raise SystemExit("not a btsnoop file (bad magic)")
    ver, dlt = struct.unpack('>II', data[8:16])
    print(f"[snoop] version={ver} datalink={dlt} (1002=HCI-UART/H4)")
    off = 16
    buf = {}
    frames = []
    while off + 24 <= len(data):
        ol, il, flags, drops = struct.unpack('>IIII', data[off:off + 16])
        ts, = struct.unpack('>Q', data[off + 16:off + 24])
        off += 24
        pkt = data[off:off + il]
        off += il
        if not il or pkt[0] != 2:      # ACL packets only (H4 type 0x02)
            continue
        acl = pkt[1:]
        if len(acl) < 4:
            continue
        h, tot = struct.unpack('<HH', acl[:4])
        handle, pb = h & 0x0FFF, (h >> 12) & 3
        adata = acl[4:4 + tot]
        direction = 'recv' if (flags & 1) else 'sent'
        key = (handle, direction)
        if pb in (2, 0):               # first fragment
            buf[key] = bytearray(adata)
        elif pb == 1:                  # continuation
            buf.setdefault(key, bytearray()).extend(adata)
        b = buf.get(key)
        if b and len(b) >= 4:
            ln, cid = struct.unpack('<HH', bytes(b[:4]))
            if len(b) >= 4 + ln:
                r = parse_rfcomm(bytes(b[:4 + ln]))
                if r and r[0] == 2 and r[1]:
                    frames.append((ts, direction, bytes(r[1])))
                del buf[key]
    frames.sort(key=lambda x: x[0])
    return frames

def reassemble(resp):
    """Rebuild the byte payload from an ELM CAN multiframe text response.
    Format: optional length line ("03B"), then "N:<hex>" frames; a frame's tail
    may arrive as a bare hex line (no "N:") -> treat as continuation."""
    lines = [l.replace('>', '').strip() for l in re.split(r'[\r\n]+', resp)]
    lines = [l for l in lines if l]
    has_marker = any(re.match(r'^[0-9A-Fa-f]:', l) for l in lines)
    idx, length = 0, None
    if has_marker and lines and re.fullmatch(r'[0-9A-Fa-f]{2,3}', lines[0]):
        length = int(lines[0], 16)
        idx = 1
    out = ''
    for l in lines[idx:]:
        m = re.match(r'^([0-9A-Fa-f]):(.*)$', l)
        out += m.group(2) if m else l
    out = re.sub(r'[^0-9A-Fa-f]', '', out).upper()
    if length is not None:
        out = out[:length * 2]
    return out

def build_transcript(frames):
    """State machine over the ELM serial stream: pair each command (sent, \\r-terminated)
    with the response text collected until the next '>' prompt."""
    ts_unix = lambda ts: (ts - BTSNOOP_EPOCH) / 1e6
    pairs = []
    cur = cur_ts = None
    resp = sent = ""
    for ts, d, info in frames:
        txt = info.decode('latin1')
        if d == 'sent':
            sent += txt
            while '\r' in sent:
                line, sent = sent.split('\r', 1)
                line = line.strip()
                if line:
                    if cur is not None:
                        pairs.append((ts_unix(cur_ts), cur, resp))
                    cur, cur_ts, resp = line, ts, ""
        else:
            resp += txt
            if '>' in txt and cur is not None:
                pairs.append((ts_unix(cur_ts), cur, resp))
                cur, resp = None, ""
    if cur is not None:
        pairs.append((ts_unix(cur_ts), cur, resp))
    return [{'t': t, 'cmd': cmd, 'hex': reassemble(r)} for t, cmd, r in pairs]

def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    inp = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else 'transcript.json'
    data = load_snoop_bytes(inp)
    frames = extract_frames(data)
    print(f"[rfcomm] {len(frames)} DLCI-2 UIH frames")
    tr = build_transcript(frames)
    json.dump(tr, open(out, 'w'))
    # quick summary of proprietary pages
    from collections import Counter
    c = Counter(e['cmd'] for e in tr if re.match(r'^21C[0-9A-F]8001$', e['cmd']))
    print(f"[transcript] {len(tr)} request/response pairs -> {out}")
    print("[pages] " + ", ".join(f"{k}:{v}" for k, v in sorted(c.items())))

if __name__ == '__main__':
    main()

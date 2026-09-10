#!/usr/bin/env python3
"""Read a technical log and say where the cycle time goes.

The question it answers: four proprietary pages cost 600-700 ms per cycle while
the small torque page alone costs 20 ms, and the Android app over classic
Bluetooth shows the same 468-812 ms on the same pages - so the radio is not the
main cost. What is left is proportional to the size of the reply, which points
at the ELM327 printing ASCII hex over a slow serial link inside the adapter.

That is a hypothesis with two rivals, and they have different answers:

  * cost per character dominates -> a slow link inside the adapter; a different
    adapter, or a ThinkDiag-class dongle speaking binary, would fix it;
  * a large fixed cost per exchange dominates -> the adapter's firmware, and a
    faster link buys little;
  * every piece the same small size -> a notification-size ceiling.

So this fits `ms = fixed + per_char * reply_chars` by least squares, reports how
much of each page's time each term explains, and prints what the numbers imply.

Several files are welcome, and usually necessary: the mode cannot be switched
while a session runs, so a drive that samples both the proprietary pages and the
standard set produces one file each.

    python tools/tech/analyse_tech.py fap_tech_*.csv
"""

import argparse
import collections
import csv
import os
import statistics
import sys


def fit(points):
    """Least squares for ms = a + b * chars. Returns (a, b, r2) or None."""
    if len(points) < 3:
        return None
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    n = len(xs)
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    if sxx == 0:
        return None
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sxx
    a = my - b * mx
    sst = sum((y - my) ** 2 for y in ys)
    ssr = sum((y - (a + b * x)) ** 2 for x, y in zip(xs, ys))
    r2 = 1 - ssr / sst if sst else 1.0
    return a, b, r2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('logs', nargs='+',
                    help='fap_tech_*.csv files written by the iOS app')
    ap.add_argument('--top', type=int, default=12,
                    help='how many commands to list')
    a = ap.parse_args()

    rows = []
    for path in a.logs:
        before = len(rows)
        with open(path, encoding='utf-8', newline='') as fh:
            for row in csv.DictReader(fh):
                try:
                    rows.append({
                        'mode': row['mode'],
                        'command': row['command'],
                        'chars': int(row['reply_chars']),
                        'notifications': int(row['notifications']),
                        'bytes': int(row['link_bytes']),
                        'largest': int(row['largest']),
                        'ms': int(row['ms']),
                        'ok': row['ok'] == '1',
                        'note': row['note'],
                        # Added after the first drive; older files lack it.
                        'reply': row.get('reply', ''),
                    })
                except (KeyError, ValueError):
                    continue
        print('%-40s %d rows' % (os.path.basename(path), len(rows) - before))

    if not rows:
        print('no usable rows in %s' % ', '.join(a.logs))
        return 1

    good = [r for r in rows if r['ok'] and r['ms'] >= 0]
    print('%d exchanges, %d answered' % (len(rows), len(good)))
    modes = collections.Counter(r['mode'] for r in rows)
    print('modes: %s' % ', '.join('%s=%d' % kv for kv in modes.items()))

    refused = [r for r in rows if 'multipid' in r['note']]
    print()
    print('MULTI-PID: %s' % (
        'refused by the ECU - %d marked rows, so the standard set falls back to '
        'one PID per request' % len(refused) if refused else
        'accepted (no refusal rows)'))

    if refused:
        print('  the answers that were refused, so the shape can be read off:')
        for r in refused[:4]:
            print('    %-16s %s' % (r['command'], r['reply'] or '(not recorded)'))

    # --- dead requests, which cost a full timeout each --------------------
    dead = [r for r in rows if not r['ok'] and r['ms'] > 0]
    if dead:
        by_command = collections.Counter(r['command'] for r in dead)
        wasted = statistics.median(r['ms'] for r in dead)
        print()
        print('UNANSWERED: %d exchanges, median %d ms each - a full adapter timeout'
              % (len(dead), wasted))
        print('  %d distinct requests: %s'
              % (len(by_command), ' '.join(sorted(by_command))))
        print('  -> %d ms per cycle spent waiting for nothing'
              % (len(by_command) * wasted))

    # --- the link itself -------------------------------------------------
    sizes = collections.Counter(r['largest'] for r in good if r['largest'])
    print()
    print('BLE pieces (largest seen per reply):')
    for size, count in sorted(sizes.items()):
        print('  %4d bytes  x%d' % (size, count))
    if sizes:
        mtu = max(sizes)
        print('  -> the adapter never sent more than %d bytes at once' % mtu)
        if mtu <= 23:
            print('     which is the default ATT MTU: notification size is the ceiling')
        else:
            print('     larger than the default MTU, so notification size is not the ceiling')

    # --- where the time goes ---------------------------------------------
    model = fit([(r['chars'], r['ms']) for r in good])
    print()
    if model is None:
        print('not enough spread in reply length to fit a model')
        return 0
    fixed, per_char, r2 = model
    print('ms = %.1f + %.3f * reply_chars   (R2 = %.2f)' % (fixed, per_char, r2))
    if per_char > 0:
        print('  -> %.0f baud equivalent for the serial link inside the adapter'
              % (10 / per_char * 1000))

    for mode in sorted({r['mode'] for r in good}):
        subset = [(r['chars'], r['ms']) for r in good if r['mode'] == mode]
        per_mode = fit(subset)
        if per_mode:
            print('  %-6s ms = %.1f + %.3f * chars  (R2 = %.2f, n = %d)'
                  % (mode, per_mode[0], per_mode[1], per_mode[2], len(subset)))

    biggest = max(good, key=lambda r: r['chars'])
    share = per_char * biggest['chars']
    print()
    print('the longest answer seen: %s, %d chars, %d ms'
          % (biggest['command'], biggest['chars'], biggest['ms']))
    print('  fixed part      %6.0f ms' % fixed)
    print('  per-character   %6.0f ms' % share)
    if share + fixed > 0:
        print('  -> %.0f%% of it is the length of the answer'
              % (100 * share / (share + fixed)))

    print()
    if per_char <= 0 or share < fixed:
        print('VERDICT: the fixed cost per exchange dominates. That is the')
        print('adapter firmware or the request/answer turnaround, not the link,')
        print('so a faster adapter would buy little - fewer requests would.')
    else:
        floor = fixed
        print('VERDICT: the answer length dominates. An adapter that speaks')
        print('binary instead of ASCII hex halves the characters outright, and')
        print('one without a slow internal link removes the slope: a page would')
        print('cost about %.0f ms instead of %d.' % (floor, biggest['ms']))

    # --- per command ------------------------------------------------------
    by_command = collections.defaultdict(list)
    for r in good:
        by_command[r['command']].append(r)
    print()
    print('%-14s %5s %7s %7s %7s' % ('command', 'n', 'chars', 'ms med', 'ms/char'))
    ranked = sorted(by_command.items(),
                    key=lambda kv: -statistics.median(r['ms'] for r in kv[1]))
    for command, group in ranked[:a.top]:
        chars = statistics.median(r['chars'] for r in group)
        ms = statistics.median(r['ms'] for r in group)
        rate = ms / chars if chars else 0
        print('%-14s %5d %7.0f %7.0f %7.2f' % (command, len(group), chars, ms, rate))

    return 0


if __name__ == '__main__':
    sys.exit(main())

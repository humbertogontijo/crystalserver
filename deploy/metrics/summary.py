#!/usr/bin/env python3
"""Top dispatcher costs from the crystalserver Prometheus exporter.

Usage: summary.py [URL|FILE] [--top N] [--save FILE] [--diff BASELINE_FILE]

Counters are cumulative since server start, so --diff subtracts a saved snapshot
to isolate one test run (save before, play, diff after).
"""

import argparse
import re
import sys
import urllib.request

SLOW_US = 50000
LINE = re.compile(r'^(\w+)_microseconds_(sum|count|bucket)\{([^}]*)\} (\S+)$')
LABEL = re.compile(r'(\w+)="((?:[^"\\]|\\.)*)"')
GROUP_LABEL = {
    "task_latency": "task",
    "lua_latency": "scope",
    "query_latency": "truncated_query",
    "method_latency": "method",
    "lock_latency": "scope",
}


def load(source):
    if re.match(r'^https?://', source):
        with urllib.request.urlopen(source, timeout=5) as resp:
            return resp.read().decode()
    with open(source) as fh:
        return fh.read()


def parse(text):
    stats = {}
    for line in text.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        metric, kind, raw, value = m.groups()
        if metric not in GROUP_LABEL:
            continue
        labels = dict(LABEL.findall(raw))
        key = (metric, labels.get(GROUP_LABEL[metric], "?"))
        entry = stats.setdefault(key, {"sum": 0.0, "count": 0.0, "fast": 0.0})
        if kind == "bucket":
            if labels.get("le") == str(SLOW_US):
                entry["fast"] += float(value)
        else:
            entry[kind] += float(value)
    return stats


def subtract(after, before):
    out = {}
    for key, a in after.items():
        b = before.get(key, {"sum": 0.0, "count": 0.0, "fast": 0.0})
        d = {k: a[k] - b[k] for k in a}
        if d["count"] > 0:
            out[key] = d
    return out


def report(stats, top):
    for metric in GROUP_LABEL:
        rows = [(name, e) for (m, name), e in stats.items() if m == metric and e["count"] > 0]
        if not rows:
            continue
        rows.sort(key=lambda r: r[1]["sum"], reverse=True)
        print(f"\n== {metric} (top {top} by total time) ==")
        print(f"{'total ms':>10} {'calls':>8} {'avg ms':>8} {'>50ms':>6}  name")
        for name, e in rows[:top]:
            slow = int(e["count"] - e["fast"])
            print(f"{e['sum'] / 1000:>10.0f} {int(e['count']):>8} {e['sum'] / e['count'] / 1000:>8.2f} {slow:>6}  {name[:110]}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", nargs="?", default="http://127.0.0.1:9464/metrics")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--save", help="write the raw scrape to this file")
    parser.add_argument("--diff", help="subtract this saved scrape (baseline)")
    args = parser.parse_args()

    try:
        text = load(args.source)
    except OSError as err:
        sys.exit(f"[metrics] cannot read {args.source}: {err} (server built with METRICS=1 and metricsEnablePrometheus = true?)")
    if args.save:
        with open(args.save, "w") as fh:
            fh.write(text)
        print(f"[metrics] snapshot saved to {args.save}")
    stats = parse(text)
    if args.diff:
        stats = subtract(stats, parse(load(args.diff)))
    report(stats, args.top)


if __name__ == "__main__":
    main()

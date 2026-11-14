#!/usr/bin/env python3
"""Reprice R114 probe output on Rootstock's schedule and diff two builds.

usage: reprice_r114.py <label-a> <log-a> <label-b> <log-b> [<label-c> <log-c>]

Foundry gas (Cancun) = compute/memory/logs/value-transfer + access charges.
Rootstock gas         = the same compute/memory/logs/value-transfer + Rootstock access charges.
Access charges on each side come from the recorded account/storage access list
(docs/relaunch/ROOTSTOCK-GAS-SCHEDULE.md): SLOAD 200, CALL-family 700, EXTCODESIZE 700,
BALANCE/EXTCODEHASH 400, SSTORE SET 20,000 / RESET 5,000 / CLEAR 5,000 (+15,000 refund).
"""
import re
import sys


def parse(path):
    gas, acc = {}, {}
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line.startswith("R114GAS|") or line.startswith("R114ACC|"):
            parts = line.split("|")
            label = parts[1]
            fields = {k: int(v) for k, v in (p.split("=") for p in parts[2:])}
            (gas if parts[0] == "R114GAS" else acc)[label] = fields
    out = {}
    for label, g in gas.items():
        a = acc[label]
        rsk_access = (
            700 * a["calls"]
            + 700 * a["ext700"]
            + 400 * a["ext400"]
            + 200 * a["sloads"]
            + 20000 * a["sset"]
            + 5000 * (a["sclear"] + a["sreset"] + a["ssame"])
        )
        other = g["foundryGas"] - a["foundryAccessGas"]
        out[label] = dict(
            rows=g["rows"],
            buyers=g["buyers"],
            foundry=g["foundryGas"],
            other=other,
            rsk=other + rsk_access,
            rsk_refund=15000 * a["sclear"],
            **{k: a[k] for k in a if k not in ("rows", "buyers", "foundryAccessGas")},
        )
    return out


def order_key(label):
    m = re.search(r"N=(\d+)", label)
    return (label.split("/")[0], label.split("/")[1], int(re.search(r"k=(\d+)", label).group(1)) if "k=" in label else 0, int(m.group(1)) if m else 0)


def main():
    args = sys.argv[1:]
    builds = [(args[i], parse(args[i + 1])) for i in range(0, len(args), 2)]
    base_name, base = builds[0]
    labels = sorted(base, key=order_key)

    print(f"{'scenario':30} {'rows':>4} {'buy':>3} | " + " | ".join(f"{n+' fdry':>13} {n+' RSK':>12}" for n, _ in builds))
    for label in labels:
        row = f"{label:30} {base[label]['rows']:>4} {base[label]['buyers']:>3} | "
        row += " | ".join(f"{b[label]['foundry']:>13,} {b[label]['rsk']:>12,}" for _, b in builds)
        print(row)

    for name, other in builds[1:]:
        print(f"\n== {name} minus {base_name} ==")
        print(f"{'scenario':30} {'dFoundry':>10} {'dCompute':>9} {'dRSK':>9} {'dRSK/row':>9} {'dRSK %':>7} | {'dCalls':>6} {'dSLOAD':>6} {'dSSTORE':>7} {'dLogs':>5}")
        for label in labels:
            a, b = base[label], other[label]
            d_f = b["foundry"] - a["foundry"]
            d_o = b["other"] - a["other"]
            d_r = b["rsk"] - a["rsk"]
            d_ss = (b["sset"] + b["sclear"] + b["sreset"] + b["ssame"]) - (a["sset"] + a["sclear"] + a["sreset"] + a["ssame"])
            print(
                f"{label:30} {d_f:>+10,} {d_o:>+9,} {d_r:>+9,} {d_r / a['rows']:>+9,.0f} {100 * d_r / a['rsk']:>+6.1f}% | "
                f"{b['calls'] - a['calls']:>+6} {b['sloads'] - a['sloads']:>+6} {d_ss:>+7} {b['logs'] - a['logs']:>+5}"
            )

    print("\nper-account access counts (calls into manager/admin/handler, SLOADs in manager/admin/handler, SSTOREs in handler)")
    for name, b in builds:
        for label in labels:
            x = b[label]
            print(
                f"{name:6} {label:30} calls {x['callsIntoManager']:>3}/{x['callsIntoAdmin']:>3}/{x['callsIntoHandler']:>2}"
                f"  sloads {x['sloadsManager']:>4}/{x['sloadsAdmin']:>3}/{x['sloadsHandler']:>3}  sstoresHandler {x['sstoresHandler']:>3}  logs {x['logs']:>3}"
            )


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Samples CPU usage and RSS of a process from /proc until SIGTERM, then writes JSON.

Usage: sample_proc.py <pid> <output.json> [interval-seconds]

CPU percent is relative to one core (200% = two cores fully busy). Peak RSS is taken
from VmHWM after resetting it at start (via /proc/<pid>/clear_refs), so it covers only
this measurement window; if the reset is not permitted, the sampled maximum is used.
"""

import json
import os
import signal
import sys
import time

CLK_TCK = os.sysconf("SC_CLK_TCK")


def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        # Skip past the command name, which may contain spaces.
        fields = f.read().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])  # utime + stime


def memory_kb(pid):
    values = {}
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            key, _, rest = line.partition(":")
            if key in ("VmRSS", "VmHWM"):
                values[key] = int(rest.split()[0])
    return values.get("VmRSS", 0), values.get("VmHWM", 0)


def main():
    pid = int(sys.argv[1])
    out = sys.argv[2]
    interval = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5

    stop = False

    def handle(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)

    try:
        with open(f"/proc/{pid}/clear_refs", "w") as f:
            f.write("5")
        hwm_reset = True
    except OSError:
        hwm_reset = False

    start_time = time.monotonic()
    start_ticks = cpu_ticks(pid)
    cpu_samples, rss_samples = [], []
    last_time, last_ticks = start_time, start_ticks
    hwm = 0

    while not stop:
        time.sleep(interval)
        try:
            now, ticks = time.monotonic(), cpu_ticks(pid)
            rss, hwm = memory_kb(pid)
        except OSError:
            break
        cpu_samples.append((ticks - last_ticks) / CLK_TCK / (now - last_time) * 100)
        rss_samples.append(rss)
        last_time, last_ticks = now, ticks

    elapsed = last_time - start_time
    result = {
        "samples": len(cpu_samples),
        "cpu_percent_avg": ((last_ticks - start_ticks) / CLK_TCK / elapsed * 100) if elapsed > 0 else None,
        "cpu_percent_max": max(cpu_samples, default=None),
        "rss_kb_avg": (sum(rss_samples) / len(rss_samples)) if rss_samples else None,
        "rss_kb_max_sampled": max(rss_samples, default=None),
        "peak_rss_kb": max(hwm, max(rss_samples, default=0)) if hwm_reset else max(rss_samples, default=None),
        "peak_rss_window_reset": hwm_reset,
    }
    with open(out, "w") as f:
        json.dump(result, f, indent=2)


if __name__ == "__main__":
    main()

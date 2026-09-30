#!/usr/bin/env python3
"""Summarizes scripts/profile.sh output into profile/summary.json and a Markdown report.

Usage: summarize_profile.py [results-dir]   (Markdown is written to stdout)

perf stat counters are divided by the number of requests oha completed in the same window, so
variants with different throughput can be compared per request.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARIANT_ORDER = ["glibc", "glibc-noble", "glibc-noble-2.39", "glibc-noble-2.39-jemalloc", "musl-sdk", "musl-mimalloc-v3"]
ENDPOINT_ORDER = ["plaintext", "json", "string", "array", "array-reserved", "allocation", "parallel-allocation"]

# (column label, perf event, scale). task-clock is reported in msec; shown as µs per request.
STAT_COLUMNS = [
    ("CPU µs/req", "task-clock", 1000),
    ("instructions/req", "instructions", 1),
    ("ctx switches/req", "context-switches", 1),
    ("wakeups/req", "sched:sched_wakeup", 1),
    ("futex/req", "syscalls:sys_enter_futex", 1),
    ("epoll_wait/req", ("syscalls:sys_enter_epoll_wait", "syscalls:sys_enter_epoll_pwait"), 1),
    ("read+write/req", ("syscalls:sys_enter_read", "syscalls:sys_enter_write", "syscalls:sys_enter_readv",
                        "syscalls:sys_enter_writev", "syscalls:sys_enter_recvfrom", "syscalls:sys_enter_sendto",
                        "syscalls:sys_enter_recvmsg", "syscalls:sys_enter_sendmsg"), 1),
    ("mmap+munmap+madvise/req", ("syscalls:sys_enter_mmap", "syscalls:sys_enter_munmap",
                                 "syscalls:sys_enter_madvise", "syscalls:sys_enter_mprotect",
                                 "syscalls:sys_enter_brk"), 1),
    ("page faults/req", "page-faults", 1),
]

# Symbols counted as allocator or memory-copy work in the CPU share table. musl variants link libc
# (and mimalloc) into the executable, so their share can only be seen by symbol, not by DSO.
ALLOCATOR_DSOS = ("libjemalloc.so.2",)
ALLOCATOR_SYMBOL = re.compile(
    r"^(malloc|free|cfree|calloc|realloc|reallocarray|posix_memalign|aligned_alloc|memalign|valloc"
    r"|malloc_usable_size|sdallocx|__libc_(malloc|free|calloc|realloc)|_int_(malloc|free|realloc)\w*"
    r"|malloc_consolidate|tcache\w*|unlink_chunk|arena_get2|_?mi_\w+|je_\w+|operator (new|delete)\b.*)"
)
MEMORY_SYMBOL = re.compile(r"^_*(memcpy|memmove|memset|memcmp|bcmp)\w*")

PERCENT_LINE = re.compile(r"^\s*([0-9.]+)%\s+(\S+)(?:\s+\[[.k]\]\s+(.*))?$")


def sort_key(order):
    return lambda name: (order.index(name) if name in order else len(order), name)


def parse_stat(path):
    counters = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split(",")
        if len(fields) < 3:
            continue
        try:
            counters[fields[2]] = float(fields[0])
        except ValueError:  # "<not supported>" / "<not counted>"
            continue
    return counters


def requests(path):
    oha = json.loads(path.read_text())
    return sum(oha.get("statusCodeDistribution", {}).values())


def parse_report(path, limit):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        match = PERCENT_LINE.match(line.rstrip())
        if match:
            percent, dso, symbol = match.groups()
            rows.append({"percent": float(percent), "dso": dso, "symbol": symbol})
        if len(rows) >= limit:
            break
    return rows


def cpu_share(symbols, dsos):
    """Percent of CPU samples in allocator functions, memory-copy functions, and the kernel."""
    allocator = sum(r["percent"] for r in symbols
                    if r["dso"] in ALLOCATOR_DSOS or ALLOCATOR_SYMBOL.match(r["symbol"] or ""))
    memory = sum(r["percent"] for r in symbols
                 if r["dso"] not in ALLOCATOR_DSOS and MEMORY_SYMBOL.match(r["symbol"] or ""))
    kernel = sum(r["percent"] for r in dsos if r["dso"].startswith("["))
    # Samples in libc.so.6 that perf could not name (internal functions of a stripped libc,
    # mostly malloc internals in allocation-heavy endpoints).
    libc_unnamed = sum(r["percent"] for r in symbols
                       if r["dso"] == "libc.so.6" and (r["symbol"] or "").startswith("0x"))
    return {"allocator": allocator, "memory": memory, "libc_unnamed": libc_unnamed, "kernel": kernel}


def per_request(counters, event, scale, reqs):
    events = event if isinstance(event, tuple) else (event,)
    values = [counters[e] for e in events if e in counters]
    if not values or not reqs:
        return None
    return sum(values) * scale / reqs


def fmt(value):
    if value is None:
        return "–"
    if value >= 100:
        return f"{value:,.0f}"
    if value >= 1:
        return f"{value:.2f}"
    return f"{value:.3f}"


def main():
    results_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "results")
    profile_dir = results_dir / "profile"
    config_path = profile_dir / "config.json"
    config = json.loads(config_path.read_text()) if config_path.exists() else {}
    environment_path = results_dir / "environment.json"
    environment = json.loads(environment_path.read_text()) if environment_path.exists() else {}

    entries = []
    for stat_path in sorted(profile_dir.glob("*/*/stat.csv")):
        variant, endpoint = stat_path.parts[-3], stat_path.parts[-2]
        directory = stat_path.parent
        counters = parse_stat(stat_path)
        reqs = requests(directory / "oha-stat.json")
        entries.append(
            {
                "variant": variant,
                "endpoint": endpoint,
                "requests": reqs,
                "rps": reqs / config["duration_seconds"] if config.get("duration_seconds") else None,
                "counters": counters,
                "per_request": {label: per_request(counters, event, scale, reqs) for label, event, scale in STAT_COLUMNS},
                "dso": parse_report(directory / "dso.txt", 8),
                "symbols": parse_report(directory / "symbols.txt", 20),
                "share": cpu_share(parse_report(directory / "symbols.txt", 10_000),
                                   parse_report(directory / "dso.txt", 100)),
            }
        )
    (profile_dir / "summary.json").write_text(
        json.dumps({"environment": environment, "config": config, "results": entries}, indent=2) + "\n"
    )

    variants = sorted({e["variant"] for e in entries}, key=sort_key(VARIANT_ORDER))
    endpoints = sorted({e["endpoint"] for e in entries}, key=sort_key(ENDPOINT_ORDER))
    index = {(e["variant"], e["endpoint"]): e for e in entries}

    lines = ["# Swift static Linux benchmark: perf profile", ""]
    if environment:
        lines.append(
            f"**Runner:** {environment.get('cpu_model')} · {environment.get('cpu_count')} vCPU · "
            f"{environment.get('lscpu', {}).get('Architecture')} · kernel {environment.get('kernel')}"
        )
    if config:
        lines.append(
            f"**Method:** c={config.get('concurrency')}, {config.get('duration_seconds')}s per perf pass, "
            f"server CPUs `{config.get('server_cpus')}`, client CPUs `{config.get('client_cpus')}`, "
            f"`{config.get('perf_version')}`. Counters are per completed request."
        )
    lines.append("")

    for endpoint in endpoints:
        lines += [f"## /{endpoint}", ""]
        header = ["variant", "req/s"] + [label for label, _, _ in STAT_COLUMNS]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|---|" + "|".join(["---:"] * (len(header) - 1)) + "|")
        for variant in variants:
            e = index.get((variant, endpoint))
            if e is None:
                continue
            row = [variant, fmt(e["rps"])] + [fmt(e["per_request"][label]) for label, _, _ in STAT_COLUMNS]
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")

        lines.append("CPU share (% of samples):\n")
        lines.append("| variant | allocator | memcpy / memmove / memset | libc.so.6 without symbol name | kernel |")
        lines.append("|---|---:|---:|---:|---:|")
        for variant in variants:
            e = index.get((variant, endpoint))
            if e is None:
                continue
            share = e["share"]
            lines.append(f"| {variant} | {share['allocator']:.1f}% | {share['memory']:.1f}% | "
                         f"{share['libc_unnamed']:.1f}% | {share['kernel']:.1f}% |")
        lines.append("")

        lines.append("CPU time by shared object (% of samples):\n")
        lines.append("| variant | top shared objects |")
        lines.append("|---|---|")
        for variant in variants:
            e = index.get((variant, endpoint))
            if e is None:
                continue
            top = ", ".join(f"`{r['dso']}` {r['percent']:.1f}%" for r in e["dso"][:6])
            lines.append(f"| {variant} | {top} |")
        lines.append("")

        lines.append("<details><summary>top symbols</summary>\n")
        for variant in variants:
            e = index.get((variant, endpoint))
            if e is None:
                continue
            lines.append(f"**{variant}**\n")
            lines.append("| % | shared object | symbol |")
            lines.append("|---:|---|---|")
            for r in e["symbols"][:15]:
                symbol = (r["symbol"] or "").replace("|", "\\|")
                if len(symbol) > 120:
                    symbol = symbol[:117] + "..."
                lines.append(f"| {r['percent']:.2f} | `{r['dso']}` | `{symbol}` |")
            lines.append("")
        lines.append("</details>\n")

    print("\n".join(lines))


if __name__ == "__main__":
    main()

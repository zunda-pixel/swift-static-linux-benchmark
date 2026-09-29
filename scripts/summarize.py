#!/usr/bin/env python3
"""Aggregates raw oha/proc results into summary.json and a Markdown report.

Usage: summarize.py [results-dir]   (Markdown is written to stdout)

For every (variant, endpoint, concurrency), each metric is reduced across repetitions
with the median as the representative value; min/max/stdev are kept in summary.json.
"""

import json
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASELINE = "glibc"
VARIANT_ORDER = ["glibc", "glibc-noble", "glibc-noble-2.39", "glibc-noble-2.39-jemalloc", "musl-sdk", "musl-mimalloc-v3"]
ENDPOINT_ORDER = ["plaintext", "json", "string", "array", "array-reserved", "allocation", "parallel-allocation"]


def describe(values):
    values = [v for v in values if v is not None]
    if not values:
        return None
    return {
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else 0.0,
        "n": len(values),
    }


def ms(seconds):
    return seconds * 1000 if seconds is not None else None


def load_run(path):
    oha = json.loads(path.read_text())
    summary = oha.get("summary", {})
    percentiles = oha.get("latencyPercentiles", {})
    statuses = oha.get("statusCodeDistribution", {})
    # Requests in flight when `-z` expires are reported as errors; they are expected.
    errors = {k: n for k, n in oha.get("errorDistribution", {}).items() if "deadline" not in k}
    run = {
        "rps": summary.get("requestsPerSec"),
        "success_rate": summary.get("successRate"),
        "p50_ms": ms(percentiles.get("p50")),
        "p95_ms": ms(percentiles.get("p95")),
        "p99_ms": ms(percentiles.get("p99")),
        "non_2xx": sum(n for code, n in statuses.items() if not str(code).startswith("2")),
        "errors": errors,
    }
    proc_path = path.with_name(path.stem + ".proc.json")
    if proc_path.exists():
        proc = json.loads(proc_path.read_text())
        run["cpu_percent"] = proc.get("cpu_percent_avg")
        run["rss_mb"] = proc["rss_kb_avg"] / 1024 if proc.get("rss_kb_avg") is not None else None
        run["peak_rss_mb"] = proc["peak_rss_kb"] / 1024 if proc.get("peak_rss_kb") is not None else None
    return run


def sort_key(order):
    return lambda name: (order.index(name) if name in order else len(order), name)


def collect(results_dir):
    cells = {}
    for path in sorted(results_dir.glob("*/*/c*/rep*.json")):
        if path.name.endswith(".proc.json"):
            continue
        variant, endpoint, conc = path.parts[-4], path.parts[-3], int(path.parts[-2][1:])
        cells.setdefault((variant, endpoint, conc), []).append(load_run(path))

    summary = []
    for (variant, endpoint, conc), runs in cells.items():
        entry = {"variant": variant, "endpoint": endpoint, "concurrency": conc, "reps": len(runs)}
        for metric in ("rps", "p50_ms", "p95_ms", "p99_ms", "cpu_percent", "rss_mb"):
            entry[metric] = describe(r.get(metric) for r in runs)
        peaks = [r.get("peak_rss_mb") for r in runs if r.get("peak_rss_mb") is not None]
        entry["peak_rss_mb_max"] = max(peaks) if peaks else None
        entry["non_2xx_total"] = sum(r["non_2xx"] for r in runs)
        entry["errors_total"] = sum(sum(r["errors"].values()) for r in runs)
        summary.append(entry)
    summary.sort(key=lambda e: (sort_key(ENDPOINT_ORDER)(e["endpoint"]), e["concurrency"], sort_key(VARIANT_ORDER)(e["variant"])))
    return summary


def median(entry, metric):
    if entry is None or entry.get(metric) is None:
        return None
    return entry[metric]["median"]


def fmt(value, digits=0):
    if value is None:
        return "–"
    return f"{value:,.{digits}f}"


def delta(value, base):
    if value is None or not base:
        return "–"
    return f"{(value / base - 1) * 100:+.1f}%"


def markdown(summary, environment, config):
    variants = sorted({e["variant"] for e in summary}, key=sort_key(VARIANT_ORDER))
    endpoints = sorted({e["endpoint"] for e in summary}, key=sort_key(ENDPOINT_ORDER))
    index = {(e["variant"], e["endpoint"], e["concurrency"]): e for e in summary}
    others = [v for v in variants if v != BASELINE]

    lines = ["# Swift static Linux benchmark", ""]
    lines.append(
        "> Results are specific to this workload and runner configuration. They do not show that "
        "musl is generally slower or faster than glibc."
    )
    lines.append("")
    if environment:
        lines.append(
            f"**Runner:** {environment.get('cpu_model')} · {environment.get('cpu_count')} vCPU · "
            f"{fmt((environment.get('memory_total_bytes') or 0) / 2**30, 1)} GiB · kernel {environment.get('kernel')} · "
            f"{environment.get('oha_version')}"
        )
        swift = next((v.get("swift_version") for v in environment.get("variants", {}).values() if v.get("swift_version")), None)
        if swift:
            lines.append(f"**Swift:** `{swift.splitlines()[0]}`")
        for name, info in environment.get("variants", {}).items():
            runtime = f", runtime: {info['runtime_allocator']}" if info.get("runtime_allocator") else ""
            if info.get("build_image"):
                runtime += f", built on `{info['build_image']}`"
            lines.append(f"- `{name}`: {info.get('libc')} + {info.get('allocator')}{runtime} (`{info.get('build_flags')}`)")
    if config:
        lines.append(
            f"\n**Method:** {config.get('reps')} reps (variant order rotated per rep), "
            f"{config.get('warmup_seconds')}s warmup per endpoint, {config.get('duration_seconds')}s per measurement, "
            f"server CPUs `{config.get('server_cpus') or 'all'}`, client CPUs `{config.get('client_cpus') or 'all'}`. "
            "Values are medians across reps."
        )
    lines.append("")

    for endpoint in endpoints:
        concs = sorted({e["concurrency"] for e in summary if e["endpoint"] == endpoint})
        lines += [f"## /{endpoint}", ""]

        header = ["c"] + [f"{v} req/s" for v in variants] + [f"{v} vs {BASELINE}" for v in others]
        header += [f"{v} p99 ms" for v in variants]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "|".join(["---:"] * len(header)) + "|")
        for c in concs:
            base = median(index.get((BASELINE, endpoint, c)), "rps")
            row = [str(c)]
            row += [fmt(median(index.get((v, endpoint, c)), "rps")) for v in variants]
            row += [delta(median(index.get((v, endpoint, c)), "rps"), base) for v in others]
            row += [fmt(median(index.get((v, endpoint, c)), "p99_ms"), 2) for v in variants]
            lines.append("| " + " | ".join(row) + " |")
        lines.append("")

        details = ["c", "variant", "p50 ms", "p95 ms", "p99 ms", "rps stdev", "CPU %", "RSS MB", "peak RSS MB", "errors"]
        lines.append("<details><summary>latency / CPU / memory</summary>\n")
        lines.append("| " + " | ".join(details) + " |")
        lines.append("|" + "|".join(["---:"] * len(details)) + "|")
        for c in concs:
            for v in variants:
                e = index.get((v, endpoint, c))
                if e is None:
                    continue
                lines.append(
                    "| "
                    + " | ".join(
                        [
                            str(c),
                            v,
                            fmt(median(e, "p50_ms"), 2),
                            fmt(median(e, "p95_ms"), 2),
                            fmt(median(e, "p99_ms"), 2),
                            fmt(e["rps"]["stdev"] if e["rps"] else None),
                            fmt(median(e, "cpu_percent")),
                            fmt(median(e, "rss_mb"), 1),
                            fmt(e["peak_rss_mb_max"], 1),
                            str(e["errors_total"] + e["non_2xx_total"]),
                        ]
                    )
                    + " |"
                )
        lines.append("\n</details>\n")

    return "\n".join(lines)


def main():
    results_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "results")
    results_dir.mkdir(parents=True, exist_ok=True)
    summary = collect(results_dir)
    environment_path = results_dir / "environment.json"
    config_path = results_dir / "config.json"
    environment = json.loads(environment_path.read_text()) if environment_path.exists() else None
    config = json.loads(config_path.read_text()) if config_path.exists() else None

    (results_dir / "summary.json").write_text(
        json.dumps({"environment": environment, "config": config, "results": summary}, indent=2) + "\n"
    )
    print(markdown(summary, environment, config))


if __name__ == "__main__":
    main()

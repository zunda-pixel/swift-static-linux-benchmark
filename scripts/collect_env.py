#!/usr/bin/env python3
"""Records the machine and build environment to results/environment.json.

Usage: collect_env.py [results-dir] [bin-dir]
"""

import json
import os
import platform
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(*cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None


def read(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def lscpu():
    fields = {}
    for line in (run("lscpu") or "").splitlines():
        key, _, value = line.partition(":")
        fields[key.strip()] = value.strip()
    return fields


def meminfo_total_bytes():
    for line in (read("/proc/meminfo") or "").splitlines():
        if line.startswith("MemTotal:"):
            return int(line.split()[1]) * 1024
    return None


def package_pins():
    resolved = json.loads(read(ROOT / "Package.resolved") or "{}")
    return {
        pin["identity"]: pin["state"].get("version") or pin["state"].get("revision")
        for pin in resolved.get("pins", [])
    }


def main():
    results_dir = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "results")
    bin_dir = Path(sys.argv[2] if len(sys.argv) > 2 else ROOT / "bin")
    results_dir.mkdir(parents=True, exist_ok=True)

    cpu = lscpu()
    variants = {}
    for variant_dir in sorted(p for p in bin_dir.iterdir() if p.is_dir()):
        info = json.loads(read(variant_dir / "build-info.json") or "{}")
        info["swift_version"] = read(variant_dir / "swift-version.txt")
        info["swift_sdk"] = read(variant_dir / "swift-sdk.txt")
        info["file"] = run("file", "-b", str(variant_dir / "BenchmarkServer"))
        info["size_bytes"] = (variant_dir / "BenchmarkServer").stat().st_size
        variants[variant_dir.name] = info

    env = {
        "cpu_model": cpu.get("Model name"),
        "cpu_count": os.cpu_count(),
        "cpu_threads_per_core": cpu.get("Thread(s) per core"),
        "lscpu": cpu,
        "memory_total_bytes": meminfo_total_bytes(),
        "kernel": platform.release(),
        "uname": run("uname", "-a"),
        "os_release": read("/etc/os-release"),
        "glibc_host": run("ldd", "--version").splitlines()[0] if run("ldd", "--version") else None,
        "oha_version": run(os.environ.get("OHA", "oha"), "--version"),
        "packages": package_pins(),
        "variants": variants,
        "github": {
            key: os.environ.get(key)
            for key in ("GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "RUNNER_NAME", "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion")
        },
    }
    (results_dir / "environment.json").write_text(json.dumps(env, indent=2) + "\n")
    print(json.dumps({k: env[k] for k in ("cpu_model", "cpu_count", "memory_total_bytes", "kernel", "oha_version")}, indent=2))


if __name__ == "__main__":
    main()

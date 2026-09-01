#!/usr/bin/env python3

import argparse
import datetime
import hashlib
import json
import math
import pathlib
import re


def read_contract(path):
    values = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise ValueError(f"invalid contract line: {raw_line}")
        values[key] = value
    return values


def read_rates(path, expected_count):
    rates = [float(line) for line in path.read_text(encoding="utf-8").splitlines() if line]
    if len(rates) != expected_count or any(not math.isfinite(rate) or rate <= 0 for rate in rates):
        raise ValueError(f"invalid benchmark rates in {path}")
    return rates


def sha256_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--contract", type=pathlib.Path, required=True)
    parser.add_argument("--candidate-rates", type=pathlib.Path, required=True)
    parser.add_argument("--baseline-rates", type=pathlib.Path, required=True)
    parser.add_argument("--candidate-flake-lock", type=pathlib.Path, required=True)
    parser.add_argument("--baseline-flake-lock", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--git-ref", required=True)
    parser.add_argument("--candidate-sha", required=True)
    parser.add_argument("--baseline-sha", required=True)
    parser.add_argument("--workflow-run-url", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--run-attempt", type=int, required=True)
    parser.add_argument("--runner-os", required=True)
    parser.add_argument("--runner-architecture", required=True)
    parser.add_argument("--runner-name", required=True)
    parser.add_argument("--runner-image", required=True)
    parser.add_argument("--cpu-model", required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--zig-version", required=True)
    parser.add_argument("--nix-version", required=True)
    parser.add_argument("--wrk-version", required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    contract = read_contract(args.contract)
    sample_count = int(contract["WRK_SAMPLES"])
    if sample_count <= 0 or sample_count % 2 == 0:
        raise ValueError("benchmark sample count must be a positive odd number")
    candidate_rates = read_rates(args.candidate_rates, sample_count)
    baseline_rates = read_rates(args.baseline_rates, sample_count)
    candidate_median = sorted(candidate_rates)[sample_count // 2]
    baseline_median = sorted(baseline_rates)[sample_count // 2]
    minimum_ratio = float(contract["MINIMUM_BASELINE_RATIO"])
    if not 0 < minimum_ratio <= 1:
        raise ValueError("minimum baseline ratio must be in (0, 1]")
    threshold = baseline_median * minimum_ratio
    record_id = f"{args.run_id}-{args.run_attempt}-{args.candidate_sha[:12]}"
    recorded_at = datetime.datetime.now(datetime.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")

    record = {
        "schema_version": int(contract["SCHEMA_VERSION"]),
        "benchmark_id": contract["BENCHMARK_ID"],
        "record_id": record_id,
        "recorded_at": recorded_at,
        "guarantee": {
            "formula": "candidate_median_rps >= baseline_median_rps * minimum_baseline_ratio",
            "minimum_baseline_ratio": minimum_ratio,
            "threshold_rps": threshold,
            "passed": candidate_median >= threshold,
        },
        "methodology": {
            "contract_sha256": sha256_file(args.contract),
            "build_optimize": contract["BUILD_OPTIMIZE"],
            "server_binary": "hello_world",
            "execution_order": ["candidate", "baseline"],
            "wrk": {
                "threads": int(contract["WRK_THREADS"]),
                "connections": int(contract["WRK_CONNECTIONS"]),
                "duration_seconds": int(contract["WRK_DURATION_SECONDS"]),
                "samples": sample_count,
                "statistic": "median",
                "target_url": contract["TARGET_URL"],
            },
        },
        "provenance": {
            "repository": args.repository,
            "event_name": args.event_name,
            "git_ref": args.git_ref,
            "candidate_sha": args.candidate_sha,
            "baseline_sha": args.baseline_sha,
            "candidate_flake_lock_sha256": sha256_file(args.candidate_flake_lock),
            "baseline_flake_lock_sha256": sha256_file(args.baseline_flake_lock),
            "workflow_run_url": args.workflow_run_url,
            "run_id": args.run_id,
            "run_attempt": args.run_attempt,
        },
        "runner": {
            "os": args.runner_os,
            "architecture": args.runner_architecture,
            "name": args.runner_name,
            "image": args.runner_image,
            "cpu_model": args.cpu_model,
            "kernel": args.kernel,
        },
        "toolchain": {
            "zig_version": args.zig_version,
            "nix_version": args.nix_version,
            "wrk_version": args.wrk_version,
        },
        "results": {
            "candidate": {"samples_rps": candidate_rates, "median_rps": candidate_median},
            "baseline": {"samples_rps": baseline_rates, "median_rps": baseline_median},
            "candidate_to_baseline_ratio": candidate_median / baseline_median,
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()

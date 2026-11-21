#!/usr/bin/env python3
"""Validate and summarize retained SQL benchmark output without editing it."""

import csv
import json
import re
import statistics
import sys
from pathlib import Path


def quantile(values: list[int], percent: int, scale: int = 100) -> int:
    ordered = sorted(values)
    return ordered[(len(ordered) * percent + scale - 1) // scale - 1]


def resources(path: Path) -> dict:
    rows = [line.split() for line in path.read_text().splitlines()[1:] if line.strip()]
    if not rows:
        raise ValueError(f"{path.name}: no process resource samples")
    return {
        "interval_ms": 100,
        "samples": len(rows),
        "maximum_sampled_rss_kib": max(int(row[5]) for row in rows),
        "maximum_reported_lifetime_cpu_percent": max(float(row[4]) for row in rows),
    }


def summarize(directory: Path, samples: int, threshold: int) -> dict:
    cohort = dict(line.split("=", 1) for line in (directory / "cohort.env").read_text().splitlines())
    selected_routes = ("db",) if cohort["routes"] == "db" else ("db", "queries", "updates")
    routes = {}
    for route in selected_routes:
        runs = []
        for index in range(1, samples + 1):
            lines = (directory / f"{route}_{index}.log").read_text().splitlines()
            payloads = [json.loads(line.removeprefix("SQL_SAMPLE ")) for line in lines if line.startswith("SQL_SAMPLE ")]
            if len(payloads) != 1:
                raise ValueError(f"{route} sample {index}: missing unique wrk result")
            result = payloads[0]
            if result["requests"] <= 0 or result["duration_us"] <= 0:
                raise ValueError(f"{route} sample {index}: empty workload")
            errors = sum(value for key, value in result.items() if key.endswith("_errors"))
            if errors != 0:
                raise ValueError(f"{route} sample {index}: {errors} errors")
            result["rps"] = result["requests"] * 1_000_000 / result["duration_us"]
            runs.append(result)
        rates = [run["rps"] for run in runs]
        routes[route] = {
            "runs": runs,
            "median_rps": statistics.median(rates),
            "minimum_rps": min(rates),
            "maximum_rps": max(rates),
            "median_p50_us": statistics.median(run["p50_us"] for run in runs),
            "median_p99_us": statistics.median(run["p99_us"] for run in runs),
            "target_rps": threshold,
            "local_target_met": statistics.median(rates) > threshold,
        }

    probes = []
    for index in range(1, samples + 1):
        with (directory / f"probe_{index}.csv").open(newline="") as source:
            rows = list(csv.DictReader(source))
        if len(rows) != 16384 or [int(row["sample"]) for row in rows] != list(range(16384)):
            raise ValueError(f"probe {index}: incomplete or duplicate samples")
        latencies = [int(row["query_ns"]) for row in rows]
        waits = [int(row["pool_wait_ns"]) for row in rows]
        if any(wait < 0 or latency < wait for latency, wait in zip(latencies, waits)):
            raise ValueError(f"probe {index}: invalid clock/ownership order")
        summary = dict(re.findall(r"(\w+)=(\d+)", (directory / f"probe_{index}.log").read_text()))
        measured = {
            "query_p50_ns": quantile(latencies, 50),
            "query_p99_ns": quantile(latencies, 99),
            "query_p999_ns": quantile(latencies, 999, 1000),
            "query_max_ns": max(latencies),
            "pool_wait_p50_ns": quantile(waits, 50),
            "pool_wait_p99_ns": quantile(waits, 99),
            "pool_wait_p999_ns": quantile(waits, 999, 1000),
            "pool_wait_max_ns": max(waits),
        }
        if int(summary.get("errors", -1)) != 0:
            raise ValueError(f"probe {index}: query failures")
        for key, value in measured.items():
            if int(summary.get(key, -1)) != value:
                raise ValueError(f"probe {index}: summary disagrees with raw {key}")
        measured["duration_ns"] = int(summary["duration_ns"])
        measured["samples"] = len(rows)
        measured["process_resources"] = resources(directory / f"probe_{index}.resources.tsv")
        probes.append(measured)

    return {
        "benchmark": "sql-local-v1",
        "official_httparena_acceptance": False,
        "host_policy": "shared development host; no quiet-host claim",
        "http_cohort": {"workers": int(cohort["workers"]), "connections": int(cohort["connections"]), "threads": int(cohort["threads"])},
        "server_process_resources": resources(directory / "server.resources.tsv"),
        "routes": routes,
        "direct_query": {
            "workers": 1,
            "pool_connections": 8,
            "inflight": 16,
            "warmup_queries": 1024,
            "pool_wait_definition": "submission to assignment trace; includes admission and parameter-encoding overhead",
            "samples_per_run": 16384,
            "runs": probes,
        },
    }


def main() -> None:
    directory = Path(sys.argv[1])
    summary = summarize(directory, int(sys.argv[2]), int(sys.argv[3]))
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    for route, result in summary["routes"].items():
        print(f"{route}: median {result['median_rps']:.2f} RPS, p99 {result['median_p99_us']:.3f} us, target met={result['local_target_met']}")


if __name__ == "__main__":
    main()

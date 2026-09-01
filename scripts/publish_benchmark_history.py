#!/usr/bin/env python3

import argparse
import hashlib
import json
import pathlib
import re
import shutil


RAW_FILES = [
    "candidate-1.txt",
    "candidate-2.txt",
    "candidate-3.txt",
    "candidate-rates.txt",
    "candidate-server.log",
    "baseline-1.txt",
    "baseline-2.txt",
    "baseline-3.txt",
    "baseline-rates.txt",
    "baseline-server.log",
]


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def copy_immutable(source, destination):
    if destination.exists():
        if destination.read_bytes() != source.read_bytes():
            raise ValueError(f"published benchmark contract is immutable: {destination.name}")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", type=pathlib.Path, required=True)
    parser.add_argument("--results-directory", type=pathlib.Path, required=True)
    parser.add_argument("--history-directory", type=pathlib.Path, required=True)
    parser.add_argument("--schema", type=pathlib.Path, required=True)
    parser.add_argument("--contract", type=pathlib.Path, required=True)
    parser.add_argument("--contract-parameters", type=pathlib.Path, required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    record = json.loads(args.record.read_text(encoding="utf-8"))
    record_id = record["record_id"]
    if record.get("schema_version") != 1 or record.get("benchmark_id") != "http-throughput-v1":
        raise ValueError("unsupported benchmark record")
    contract_digest = hashlib.sha256(args.contract_parameters.read_bytes()).hexdigest()
    if record.get("methodology", {}).get("contract_sha256") != contract_digest:
        raise ValueError("benchmark record contract does not match publisher contract")
    schema = json.loads(args.schema.read_text(encoding="utf-8"))
    if schema.get("properties", {}).get("schema_version", {}).get("const") != 1:
        raise ValueError("publisher schema does not describe version 1")
    if not re.fullmatch(r"[0-9]+-[0-9]+-[0-9a-f]{12}", record_id):
        raise ValueError("invalid benchmark record ID")
    year = record["recorded_at"][:4]
    if not re.fullmatch(r"[0-9]{4}", year):
        raise ValueError("invalid benchmark timestamp")

    history = args.history_directory
    record_path = history / "records" / year / f"{record_id}.json"
    if record_path.exists():
        existing = json.loads(record_path.read_text(encoding="utf-8"))
        if existing != record:
            raise ValueError("benchmark record IDs are immutable")
    else:
        write_json(record_path, record)

    raw_directory = history / "raw" / year / record_id
    raw_directory.mkdir(parents=True, exist_ok=True)
    for name in RAW_FILES:
        source = args.results_directory / name
        if not source.is_file():
            raise ValueError(f"missing raw benchmark result: {name}")
        destination = raw_directory / name
        if destination.exists() and destination.read_bytes() != source.read_bytes():
            raise ValueError(f"raw benchmark result is immutable: {name}")
        shutil.copyfile(source, destination)

    index_path = history / "index.json"
    index = {"schema_version": 1, "benchmark_id": "http-throughput-v1", "records": []}
    if index_path.exists():
        index = json.loads(index_path.read_text(encoding="utf-8"))
    summary = {
        "record_id": record_id,
        "recorded_at": record["recorded_at"],
        "candidate_sha": record["provenance"]["candidate_sha"],
        "baseline_sha": record["provenance"]["baseline_sha"],
        "candidate_median_rps": record["results"]["candidate"]["median_rps"],
        "baseline_median_rps": record["results"]["baseline"]["median_rps"],
        "candidate_to_baseline_ratio": record["results"]["candidate_to_baseline_ratio"],
        "passed": record["guarantee"]["passed"],
        "record_path": record_path.relative_to(history).as_posix(),
    }
    index["records"] = [entry for entry in index["records"] if entry["record_id"] != record_id]
    index["records"].append(summary)
    index["records"].sort(key=lambda entry: (entry["recorded_at"], entry["record_id"]), reverse=True)
    write_json(index_path, index)
    write_json(history / "latest.json", record)

    copy_immutable(args.schema, history / "schema" / args.schema.name)
    copy_immutable(args.contract, history / "CONTRACT.md")
    copy_immutable(args.contract_parameters, history / args.contract_parameters.name)
    (history / ".nojekyll").touch()

    rows = []
    for entry in index["records"][:100]:
        result = "pass" if entry["passed"] else "fail"
        rows.append(
            f"| {entry['recorded_at']} | `{entry['candidate_sha'][:12]}` | "
            f"{entry['candidate_median_rps']:.2f} | {entry['baseline_median_rps']:.2f} | "
            f"{entry['candidate_to_baseline_ratio']:.4f} | {result} | "
            f"[record]({entry['record_path']}) |"
        )
    readme = """# uWebZockets benchmark history

This branch is the durable, machine-readable history for `http-throughput-v1`.
See [CONTRACT.md](CONTRACT.md) for the guarantee and reproduction procedure.
`index.json` retains the complete history; this table shows the latest 100 runs.

| Recorded UTC | Candidate | Candidate RPS | Baseline RPS | Ratio | Gate | Evidence |
| --- | --- | ---: | ---: | ---: | --- | --- |
""" + "\n".join(rows) + "\n"
    (history / "README.md").write_text(readme, encoding="utf-8")
    print(record_id)


if __name__ == "__main__":
    main()

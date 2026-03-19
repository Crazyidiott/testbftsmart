#!/usr/bin/env python3
"""Aggregate multiple steady-grid experiment results into one summary table.

Usage:
  python3 scripts/aggregate_steady_grid.py \
      asymmetric_timeout_benchmark_results/experiment_20260319_101010 \
      asymmetric_timeout_benchmark_results/experiment_20260319_121212 \
      asymmetric_timeout_benchmark_results/experiment_20260319_141414

Outputs:
  - asymmetric_timeout_benchmark_results/report/steady_grid_aggregate_<timestamp>.csv
  - asymmetric_timeout_benchmark_results/report/steady_grid_aggregate_<timestamp>.md
"""

from __future__ import annotations

import argparse
import csv
import math
import statistics
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Tuple


Key = Tuple[int, int]  # (leader_delay_ms, request_timeout)


def normalize_exp_dir(raw: str, repo_root: Path) -> Path:
    p = Path(raw)
    if not p.is_absolute():
        p = repo_root / p
    if p.name.startswith("experiment_"):
        return p
    maybe = repo_root / "asymmetric_timeout_benchmark_results" / raw
    if maybe.name.startswith("experiment_"):
        return maybe
    return p


def read_results_csv(results_csv: Path) -> Dict[Key, Dict[str, float]]:
    rows: Dict[Key, Dict[str, float]] = {}
    with results_csv.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            key: Key = (int(float(r["leader_delay_ms"])), int(float(r["request_timeout"])))
            rows[key] = {
                "avg_throughput": float(r["avg_throughput"]),
                "avg_latency_us": float(r["avg_latency_us"]),
                "sample_count": float(r["sample_count"]),
                "max_regency": float(r["max_regency"]),
                "view_change_log_entries": float(r["view_change_log_entries"]),
            }
    return rows


def safe_mean(vals: List[float]) -> float:
    return statistics.mean(vals) if vals else float("nan")


def safe_std(vals: List[float]) -> float:
    if len(vals) <= 1:
        return 0.0
    return statistics.stdev(vals)


def fmt(x: float, digits: int = 2) -> str:
    if math.isnan(x):
        return "NaN"
    return f"{x:.{digits}f}"


def main() -> None:
    parser = argparse.ArgumentParser(description="Aggregate steady grid experiment results")
    parser.add_argument("experiments", nargs="+", help="experiment directories (3 recommended)")
    parser.add_argument(
        "--output-prefix",
        default="steady_grid_aggregate",
        help="Output filename prefix under asymmetric_timeout_benchmark_results/report",
    )
    args = parser.parse_args()

    script_path = Path(__file__).resolve()
    repo_root = script_path.parents[1]

    exp_dirs: List[Path] = []
    for exp in args.experiments:
        p = normalize_exp_dir(exp, repo_root)
        if not p.exists():
            raise FileNotFoundError(f"Experiment directory not found: {p}")
        results_csv = p / "results.csv"
        if not results_csv.exists():
            raise FileNotFoundError(f"Missing results.csv in: {p}")
        exp_dirs.append(p)

    runs: List[Dict[Key, Dict[str, float]]] = [read_results_csv(d / "results.csv") for d in exp_dirs]

    all_keys = sorted(set().union(*[set(r.keys()) for r in runs]), key=lambda x: (x[0], x[1]))

    report_dir = repo_root / "asymmetric_timeout_benchmark_results" / "report"
    report_dir.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_csv = report_dir / f"{args.output_prefix}_{ts}.csv"
    out_md = report_dir / f"{args.output_prefix}_{ts}.md"

    header = [
        "leader_delay_ms",
        "request_timeout",
        "thr_mean",
        "thr_std",
        "lat_mean_us",
        "lat_std_us",
        "sample_count_mean",
        "max_regency_mean",
        "vc_entries_mean",
    ]

    run_thr_cols = [f"thr_run{i+1}" for i in range(len(runs))]
    run_lat_cols = [f"lat_run{i+1}_us" for i in range(len(runs))]
    run_n_cols = [f"samples_run{i+1}" for i in range(len(runs))]

    with out_csv.open("w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(header + run_thr_cols + run_lat_cols + run_n_cols)

        for key in all_keys:
            thr_vals: List[float] = []
            lat_vals: List[float] = []
            n_vals: List[float] = []
            reg_vals: List[float] = []
            vc_vals: List[float] = []

            per_run_thr: List[str] = []
            per_run_lat: List[str] = []
            per_run_n: List[str] = []

            for run in runs:
                row = run.get(key)
                if row is None:
                    per_run_thr.append("")
                    per_run_lat.append("")
                    per_run_n.append("")
                    continue

                thr = row["avg_throughput"]
                lat = row["avg_latency_us"]
                n = row["sample_count"]
                reg = row["max_regency"]
                vc = row["view_change_log_entries"]

                thr_vals.append(thr)
                lat_vals.append(lat)
                n_vals.append(n)
                reg_vals.append(reg)
                vc_vals.append(vc)

                per_run_thr.append(fmt(thr))
                per_run_lat.append(fmt(lat))
                per_run_n.append(str(int(n)))

            writer.writerow(
                [
                    key[0],
                    key[1],
                    fmt(safe_mean(thr_vals)),
                    fmt(safe_std(thr_vals)),
                    fmt(safe_mean(lat_vals)),
                    fmt(safe_std(lat_vals)),
                    fmt(safe_mean(n_vals)),
                    fmt(safe_mean(reg_vals)),
                    fmt(safe_mean(vc_vals)),
                ]
                + per_run_thr
                + per_run_lat
                + per_run_n
            )

    with out_md.open("w", encoding="utf-8") as f:
        f.write("# Steady Grid Aggregate Summary\n\n")
        f.write("## Input Experiments\n\n")
        for i, d in enumerate(exp_dirs, start=1):
            f.write(f"- Run {i}: {d.relative_to(repo_root)}\n")
        f.write("\n")

        f.write("## Aggregated Table\n\n")
        f.write("| leader_delay_ms | request_timeout | thr_mean | thr_std | lat_mean_us | lat_std_us | sample_count_mean | max_regency_mean | vc_entries_mean |\n")
        f.write("|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n")

        for key in all_keys:
            thr_vals = [r[key]["avg_throughput"] for r in runs if key in r]
            lat_vals = [r[key]["avg_latency_us"] for r in runs if key in r]
            n_vals = [r[key]["sample_count"] for r in runs if key in r]
            reg_vals = [r[key]["max_regency"] for r in runs if key in r]
            vc_vals = [r[key]["view_change_log_entries"] for r in runs if key in r]

            f.write(
                "| "
                + " | ".join(
                    [
                        str(key[0]),
                        str(key[1]),
                        fmt(safe_mean(thr_vals)),
                        fmt(safe_std(thr_vals)),
                        fmt(safe_mean(lat_vals)),
                        fmt(safe_std(lat_vals)),
                        fmt(safe_mean(n_vals)),
                        fmt(safe_mean(reg_vals)),
                        fmt(safe_mean(vc_vals)),
                    ]
                )
                + " |\n"
            )

        f.write("\n")
        f.write("## Notes\n\n")
        f.write("- High `thr_std` or `lat_std_us` indicates run-to-run sensitivity.\n")
        f.write("- Low `sample_count_mean` indicates unstable windows and lower confidence.\n")

    print(f"Generated CSV: {out_csv}")
    print(f"Generated MD : {out_md}")


if __name__ == "__main__":
    main()

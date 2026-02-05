#!/usr/bin/env python3
"""
plot_static.py

Generate heatmaps for static benchmark results.

Reads a `results.csv` produced by `run_static_benchmark.sh` and for each workload
generates a heatmap of a weighted, normalized score over the (batch_size, batch_timeout)
grid. The weights and which metrics to include are configurable via CLI.

Outputs PNG files into the same experiment directory.
"""
import argparse
import os
import sys
import math
import pandas as pd
import numpy as np
import seaborn as sns
import matplotlib.pyplot as plt


def normalize_series(s, higher_is_better=True):
    # Min-max normalize to [0,1]. If all values equal, return zeros.
    if s.size == 0:
        return s
    mn = s.min()
    mx = s.max()
    if math.isclose(mn, mx):
        return pd.Series(0.0, index=s.index)
    norm = (s - mn) / (mx - mn)
    return norm if higher_is_better else (1.0 - norm)


def make_score(df, weights):
    # df contains columns: avg_throughput, avg_latency_us, avg_msg_size_bytes, avg_arrival_rate
    comps = {}
    if weights.get('throughput', 0) > 0:
        comps['throughput'] = normalize_series(df['avg_throughput'].astype(float), higher_is_better=True)
    if weights.get('latency', 0) > 0:
        # lower latency is better
        comps['latency'] = normalize_series(df['avg_latency_us'].astype(float), higher_is_better=False)
    if weights.get('size', 0) > 0 and 'avg_msg_size_bytes' in df.columns:
        comps['size'] = normalize_series(df['avg_msg_size_bytes'].astype(float), higher_is_better=True)
    if weights.get('arrival', 0) > 0 and 'avg_arrival_rate' in df.columns:
        comps['arrival'] = normalize_series(df['avg_arrival_rate'].astype(float), higher_is_better=True)

    # Weighted sum
    score = pd.Series(0.0, index=df.index)
    total_w = 0.0
    for k, comp in comps.items():
        w = weights.get(k, 0)
        score += comp.fillna(0.0) * w
        total_w += w

    if total_w > 0:
        score = score / total_w

    return score


def plot_heatmap(grid_df, xs, ys, title, outpath, cmap='viridis'):
    plt.figure(figsize=(10, 8))
    # seaborn expects rows=y, cols=x
    ax = sns.heatmap(grid_df, xticklabels=xs, yticklabels=ys, cmap=cmap, cbar_kws={'label': 'score'})
    ax.set_xlabel('batch_size')
    ax.set_ylabel('batch_timeout')
    ax.set_title(title)
    plt.tight_layout()
    plt.savefig(outpath)
    plt.close()


def main():
    parser = argparse.ArgumentParser(description='Plot static benchmark heatmaps')
    parser.add_argument('results_csv', help='Path to static experiment results.csv')
    parser.add_argument('--workload-id', help='Workload id to plot (default: all workloads)', default=None)
    parser.add_argument('--weights', help='Weights as throughput,latency,size,arrival (comma list). Use empty to skip.', default='1.0,0.0,0.0,0.0')
    parser.add_argument('--out-dir', help='Output directory (default: same folder as CSV)', default=None)
    parser.add_argument('--cmap', help='Matplotlib colormap', default='viridis')

    args = parser.parse_args()

    if not os.path.isfile(args.results_csv):
        print('results.csv not found:', args.results_csv, file=sys.stderr)
        sys.exit(2)

    df = pd.read_csv(args.results_csv)
    if args.out_dir is None:
        out_dir = os.path.dirname(os.path.abspath(args.results_csv))
    else:
        out_dir = args.out_dir
    os.makedirs(out_dir, exist_ok=True)

    w_vals = [float(x) if x != '' else 0.0 for x in args.weights.split(',')]
    weights = {'throughput': w_vals[0] if len(w_vals) > 0 else 0.0,
               'latency': w_vals[1] if len(w_vals) > 1 else 0.0,
               'size': w_vals[2] if len(w_vals) > 2 else 0.0,
               'arrival': w_vals[3] if len(w_vals) > 3 else 0.0}

    workloads = df['workload_id'].unique()
    if args.workload_id is not None:
        workloads = [str(args.workload_id)]

    for wid in workloads:
        sub = df[df['workload_id'].astype(str) == str(wid)].copy()
        if sub.empty:
            print(f'No data for workload {wid}, skipping')
            continue

        # Build score
        sub['score'] = make_score(sub, weights)

        # Pivot to grid: rows=batch_timeout, cols=batch_size
        try:
            pivot = sub.pivot_table(index='batch_timeout', columns='batch_size', values='score', aggfunc='mean')
        except Exception as e:
            print('Failed to pivot data for workload', wid, e)
            continue

        xs = [str(x) for x in pivot.columns.tolist()]
        ys = [str(y) for y in pivot.index.tolist()]

        title = f'Workload {wid} heatmap (weights: {weights})'
        outpath = os.path.join(out_dir, f'workload_{wid}_heatmap.png')
        plot_heatmap(pivot, xs, ys, title, outpath, cmap=args.cmap)
        print('Saved heatmap:', outpath)


if __name__ == '__main__':
    main()

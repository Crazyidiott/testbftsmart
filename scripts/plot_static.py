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
    """
    Compute weighted score from throughput and latency.
    - throughput: higher is better
    - latency: lower is better
    - Failed experiments (throughput=0 or latency=0) get NaN score
    """
    # Mark failed experiments (throughput <= 0 or latency <= 0) as NaN
    thr = df['avg_throughput'].astype(float)
    lat = df['avg_latency_us'].astype(float)
    failed_mask = (thr <= 0) | (lat <= 0)
    
    # Only normalize on valid (non-failed) data
    valid_df = df[~failed_mask]
    
    if valid_df.empty:
        # All experiments failed
        return pd.Series(np.nan, index=df.index)
    
    comps = {}
    if weights.get('throughput', 0) > 0:
        # Normalize only valid values
        norm_thr = normalize_series(valid_df['avg_throughput'].astype(float), higher_is_better=True)
        full_thr = pd.Series(np.nan, index=df.index)
        full_thr.loc[norm_thr.index] = norm_thr
        comps['throughput'] = full_thr
    if weights.get('latency', 0) > 0:
        # lower latency is better
        norm_lat = normalize_series(valid_df['avg_latency_us'].astype(float), higher_is_better=False)
        full_lat = pd.Series(np.nan, index=df.index)
        full_lat.loc[norm_lat.index] = norm_lat
        comps['latency'] = full_lat

    # Weighted sum
    score = pd.Series(0.0, index=df.index)
    total_w = 0.0
    for k, comp in comps.items():
        w = weights.get(k, 0)
        score += comp.fillna(0.0) * w
        total_w += w

    if total_w > 0:
        score = score / total_w

    # Set failed experiments to NaN (will show as distinct color in heatmap)
    score[failed_mask] = np.nan

    return score


def plot_heatmap(grid_df, xs, ys, title, outpath, cmap='viridis'):
    plt.figure(figsize=(10, 8))
    # Create a masked array for NaN values (failed experiments)
    # NaN cells will be shown in gray
    mask = grid_df.isna()
    
    # seaborn expects rows=y, cols=x
    ax = sns.heatmap(grid_df, xticklabels=xs, yticklabels=ys, cmap=cmap, 
                     cbar_kws={'label': 'score'}, mask=mask,
                     vmin=0, vmax=1)  # Fixed scale 0-1 for normalized scores
    
    # Fill NaN cells with gray color to indicate failed experiments
    for i in range(len(ys)):
        for j in range(len(xs)):
            if mask.iloc[i, j]:
                ax.add_patch(plt.Rectangle((j, i), 1, 1, fill=True, 
                            facecolor='lightgray', edgecolor='white', lw=0.5))
    
    ax.set_xlabel('batch_size')
    ax.set_ylabel('batch_timeout')
    ax.set_title(title + '\n(gray = failed experiment)')
    plt.tight_layout()
    plt.savefig(outpath)
    plt.close()


def main():
    parser = argparse.ArgumentParser(description='Plot static benchmark heatmaps')
    parser.add_argument('results_csv', help='Path to static experiment results.csv')
    parser.add_argument('--workload-id', help='Workload id to plot (default: all workloads)', default=None)
    parser.add_argument('--weights', help='Weights as throughput,latency (comma list)', default='1.0,1.0')
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
    weights = {'throughput': w_vals[0] if len(w_vals) > 0 else 1.0,
               'latency': w_vals[1] if len(w_vals) > 1 else 1.0}

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

        title = f'Workload {wid} heatmap (thr_w={weights["throughput"]}, lat_w={weights["latency"]})'
        outpath = os.path.join(out_dir, f'workload_{wid}_heatmap.png')
        plot_heatmap(pivot, xs, ys, title, outpath, cmap=args.cmap)
        print('Saved heatmap:', outpath)


if __name__ == '__main__':
    main()

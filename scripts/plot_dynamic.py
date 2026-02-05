#!/usr/bin/env python3
"""
plot_dynamic.py

Generate comparison plots for dynamic benchmark results.

Reads a `results.csv` and `phase_results.csv` produced by `run_dynamic_benchmark.sh`.
Produces:
 - overall comparison bar chart (throughput and latency)
 - per-phase grouped bar chart comparing configs
 - time-series style plot of per-phase throughput/latency (uses phase ordering)

Outputs PNG files into the experiment directory.
"""
import argparse
import os
import sys
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import seaborn as sns


def plot_overall(results_df, out_dir):
    plt.figure(figsize=(10, 5))
    # Throughput
    ax1 = plt.subplot(1, 2, 1)
    sns.barplot(data=results_df, x='algorithm', y='avg_throughput', ax=ax1)
    ax1.set_title('Overall Throughput by Config')
    ax1.set_ylabel('avg_throughput (ops/s)')

    ax2 = plt.subplot(1, 2, 2)
    sns.barplot(data=results_df, x='algorithm', y='avg_latency_us', ax=ax2)
    ax2.set_title('Overall Latency by Config')
    ax2.set_ylabel('avg_latency_us (us)')

    plt.tight_layout()
    out = os.path.join(out_dir, 'dynamic_overall.png')
    plt.savefig(out)
    plt.close()
    print('Saved overall comparison:', out)


def plot_phase_grouped(phase_df, out_dir):
    # Create a label for config
    phase_df = phase_df.copy()
    phase_df['config'] = phase_df.apply(lambda r: r['algorithm'] if r['algorithm'] != 'STATIC' else f"STATIC({r['batch_size']},{r['batch_timeout']})", axis=1)

    for phase in sorted(phase_df['phase'].astype(int).unique()):
        sub = phase_df[phase_df['phase'].astype(int) == phase]
        if sub.empty:
            continue
        plt.figure(figsize=(8, 4))
        ax = sns.barplot(data=sub, x='config', y='avg_throughput')
        ax.set_xticklabels(ax.get_xticklabels(), rotation=30, ha='right')
        ax.set_title(f'Phase {phase} Throughput Comparison')
        plt.tight_layout()
        out = os.path.join(out_dir, f'phase_{phase}_throughput.png')
        plt.savefig(out)
        plt.close()
        print('Saved phase throughput:', out)

        plt.figure(figsize=(8, 4))
        ax = sns.barplot(data=sub, x='config', y='avg_latency_us')
        ax.set_xticklabels(ax.get_xticklabels(), rotation=30, ha='right')
        ax.set_title(f'Phase {phase} Latency Comparison')
        plt.tight_layout()
        out = os.path.join(out_dir, f'phase_{phase}_latency.png')
        plt.savefig(out)
        plt.close()
        print('Saved phase latency:', out)


def main():
    parser = argparse.ArgumentParser(description='Plot dynamic benchmark results')
    parser.add_argument('results_csv', help='Path to dynamic results.csv')
    parser.add_argument('phase_csv', help='Path to dynamic phase_results.csv')
    parser.add_argument('--out-dir', help='Output directory (default: same folder as CSV)', default=None)
    args = parser.parse_args()

    if not os.path.isfile(args.results_csv) or not os.path.isfile(args.phase_csv):
        print('results.csv or phase_results.csv not found', file=sys.stderr)
        sys.exit(2)

    results_df = pd.read_csv(args.results_csv)
    phase_df = pd.read_csv(args.phase_csv)

    if args.out_dir is None:
        out_dir = os.path.dirname(os.path.abspath(args.results_csv))
    else:
        out_dir = args.out_dir

    os.makedirs(out_dir, exist_ok=True)

    plot_overall(results_df, out_dir)
    plot_phase_grouped(phase_df, out_dir)


if __name__ == '__main__':
    main()

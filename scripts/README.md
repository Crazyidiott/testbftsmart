# Plotting utilities for benchmark results

This folder contains simple plotting scripts to visualize static and dynamic benchmark results produced by the `run_static_benchmark.sh` and `run_dynamic_benchmark.sh` scripts.

Files:
- `plot_static.py` - generate heatmaps per workload. Input: `static_benchmark_results/experiment_*/results.csv`.
- `plot_dynamic.py` - generate overall and per-phase comparison plots. Input: `dynamic_benchmark_results/experiment_*/results.csv` and `phase_results.csv`.

Dependencies:
- Python 3.8+
- pandas
- numpy
- matplotlib
- seaborn

Install dependencies (example):
```bash
python3 -m pip install pandas numpy matplotlib seaborn
```

Usage examples:

Static heatmap:
```bash
# --weights throughput,latency (default 1.0,1.0)
python3 scripts/plot_static.py static_benchmark_results/experiment_*/results.csv --weights 1.0,1.0
```

Dynamic plots:
```bash
python3 scripts/plot_dynamic.py dynamic_benchmark_results/experiment_*/results.csv dynamic_benchmark_results/experiment_*/phase_results.csv
```

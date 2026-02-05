#!/bin/bash
# ==============================================================================
# run_dynamic_benchmark.sh - 动态负载基准测试脚本
# ==============================================================================
# 
# 功能：
#   在动态变化的 workload (dynamic_workload.config) 下，
#   依次测试 BAYESIAN、PPO 和多个静态配置的表现。
#
# 前置条件：
#   - 预先训练好的模型文件：
#     - server_agent/bo_model.pkl (Bayesian Optimization)
#     - server_agent/ppo_model.pth (PPO)
#
# 使用方式：
#   ./run_dynamic_benchmark.sh [SkipBuild] [ResumeDir]
#   例如：
#     ./run_dynamic_benchmark.sh                    # 首次运行（需要编译）
#     ./run_dynamic_benchmark.sh true               # 跳过编译
#     ./run_dynamic_benchmark.sh true experiment_20260205_150000  # 续跑
#
# 输出：
#   - dynamic_benchmark_results/results.csv   : 汇总结果表格
#   - dynamic_benchmark_results/logs/         : 每次实验的详细日志
#
# ==============================================================================

set -e  # 出错时退出

# ============= 配置参数 =============

# 要测试的算法列表
ALGORITHMS=("BAYESIAN" "PPO")

# 要测试的静态配置列表 (batch_size, batch_timeout)
# 你可以根据静态实验的结果，选择一些有代表性的配置
STATIC_CONFIGS=(
    "100,50"      # 小 batch, 短 timeout (低延迟配置)
    "500,100"     # 中等配置
    "1000,150"    # 大 batch, 中等 timeout
    "2000,200"    # 大 batch, 长 timeout (高吞吐配置)
    "300,80"      # 另一个中等配置
)

# 是否跳过编译
SKIP_BUILD="${1:-false}"

# 断点续跑：指定之前的实验目录名
RESUME_DIR="${2:-}"

# 动态负载配置文件
WORKLOAD_CONFIG="dynamic_workload.config"

# 结果目录
RESULTS_DIR="dynamic_benchmark_results"

# 判断是否续跑
if [[ -n "$RESUME_DIR" ]]; then
    EXPERIMENT_DIR="${RESULTS_DIR}/${RESUME_DIR}"
    if [[ ! -d "$EXPERIMENT_DIR" ]]; then
        echo "ERROR: Resume directory not found: ${EXPERIMENT_DIR}"
        echo "Available experiment directories:"
        ls -d ${RESULTS_DIR}/experiment_* 2>/dev/null || echo "  (none)"
        exit 1
    fi
    RESUME_MODE=true
    echo ">>> RESUME MODE: Continuing from ${EXPERIMENT_DIR}"
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    EXPERIMENT_DIR="${RESULTS_DIR}/experiment_${TIMESTAMP}"
    RESUME_MODE=false
fi

# 进度文件
PROGRESS_FILE="${EXPERIMENT_DIR}/progress.txt"

# ============= 辅助函数 =============

# 检查实验是否已完成
is_experiment_done() {
    local exp_key=$1
    if [[ -f "$PROGRESS_FILE" ]] && grep -q "^${exp_key}$" "$PROGRESS_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 标记实验完成
mark_experiment_done() {
    local exp_key=$1
    echo "$exp_key" >> "$PROGRESS_FILE"
}

# 解析 server log 提取 metrics
# 输入: log_file, output_file
# 输出格式: avg_thr,avg_lat,avg_size,avg_arrival,avg_mem_used,avg_mem_max,avg_mem_pct,sample_count
parse_server_log() {
    local log_file=$1
    local output_file=$2
    
    python3 << EOF
import re
import sys

log_file = "$log_file"
output_file = "$output_file"

# Metrics pattern from RLAgentConnector
pattern = r'thr=([0-9.]+), lat=([0-9.]+) us \| avgSize=([0-9.]+) bytes, arrivalRate=([0-9.]+) req/s \| Memory: ([0-9]+)MB/([0-9]+)MB \(([0-9.]+)%\)'

throughputs = []
latencies = []
avg_sizes = []
arrival_rates = []
mem_used = []
mem_max = []
mem_percent = []

try:
    with open(log_file, 'r') as f:
        for line in f:
            match = re.search(pattern, line)
            if match:
                throughputs.append(float(match.group(1)))
                latencies.append(float(match.group(2)))
                avg_sizes.append(float(match.group(3)))
                arrival_rates.append(float(match.group(4)))
                mem_used.append(int(match.group(5)))
                mem_max.append(int(match.group(6)))
                mem_percent.append(float(match.group(7)))
except Exception as e:
    print(f"Error parsing {log_file}: {e}", file=sys.stderr)

n = len(throughputs)
if n > 0:
    # 跳过前10个样本（预热期，动态负载下预热更长）
    skip = min(10, n // 4)
    throughputs = throughputs[skip:]
    latencies = latencies[skip:]
    avg_sizes = avg_sizes[skip:]
    arrival_rates = arrival_rates[skip:]
    mem_used = mem_used[skip:]
    mem_max = mem_max[skip:]
    mem_percent = mem_percent[skip:]
    
    n = len(throughputs)
    if n > 0:
        avg_thr = sum(throughputs) / n
        avg_lat = sum(latencies) / n
        avg_size = sum(avg_sizes) / n
        avg_arrival = sum(arrival_rates) / n
        avg_mem_used = sum(mem_used) / n
        avg_mem_max = sum(mem_max) / n
        avg_mem_pct = sum(mem_percent) / n
        
        with open(output_file, 'w') as f:
            f.write(f"{avg_thr:.2f},{avg_lat:.2f},{avg_size:.2f},{avg_arrival:.2f},{avg_mem_used:.0f},{avg_mem_max:.0f},{avg_mem_pct:.1f},{n}\n")
        print(f"Parsed {n} samples: thr={avg_thr:.2f}, lat={avg_lat:.2f}")
    else:
        with open(output_file, 'w') as f:
            f.write("0,0,0,0,0,0,0,0\n")
        print("No valid samples after warmup skip")
else:
    with open(output_file, 'w') as f:
        f.write("0,0,0,0,0,0,0,0\n")
    print("No metrics found in log")
EOF
}

# 解析 server log 按 workload 阶段分段统计
# 输出: 每个 workload 阶段的 metrics
parse_server_log_by_phase() {
    local log_file=$1
    local output_file=$2
    local workload_config=$3
    
    python3 << EOF
import re
import sys

log_file = "$log_file"
output_file = "$output_file"
workload_config = "$workload_config"

# 读取 workload 配置
phases = []
with open(f"config/workloads/{workload_config}", 'r') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split(',')]
        if len(parts) >= 3:
            duration = int(parts[0])
            rate = int(parts[1])
            size = int(parts[2])
            phases.append({'duration': duration, 'rate': rate, 'size': size})

print(f"Workload phases: {phases}")

# Metrics pattern
pattern = r'thr=([0-9.]+), lat=([0-9.]+) us \| avgSize=([0-9.]+) bytes, arrivalRate=([0-9.]+) req/s \| Memory: ([0-9]+)MB/([0-9]+)MB \(([0-9.]+)%\)'

# 读取所有 metrics
all_metrics = []
try:
    with open(log_file, 'r') as f:
        for line in f:
            match = re.search(pattern, line)
            if match:
                all_metrics.append({
                    'thr': float(match.group(1)),
                    'lat': float(match.group(2)),
                    'size': float(match.group(3)),
                    'arrival': float(match.group(4)),
                    'mem_used': int(match.group(5)),
                    'mem_max': int(match.group(6)),
                    'mem_pct': float(match.group(7))
                })
except Exception as e:
    print(f"Error: {e}", file=sys.stderr)

print(f"Total metrics samples: {len(all_metrics)}")

# 按阶段分割（每秒一个样本，根据 duration 划分）
results = []
sample_idx = 0
warmup_skip = 10  # 跳过开始的预热样本

for phase_idx, phase in enumerate(phases):
    duration = phase['duration']
    # 计算该阶段应有的样本范围
    phase_start = sample_idx
    phase_end = sample_idx + duration
    
    # 提取该阶段的样本（跳过阶段开始的几个预热样本）
    phase_skip = min(5, duration // 3)
    phase_metrics = all_metrics[phase_start + phase_skip : phase_end] if phase_start + phase_skip < len(all_metrics) else []
    
    if phase_metrics:
        avg_thr = sum(m['thr'] for m in phase_metrics) / len(phase_metrics)
        avg_lat = sum(m['lat'] for m in phase_metrics) / len(phase_metrics)
        avg_size = sum(m['size'] for m in phase_metrics) / len(phase_metrics)
        avg_arrival = sum(m['arrival'] for m in phase_metrics) / len(phase_metrics)
        avg_mem_used = sum(m['mem_used'] for m in phase_metrics) / len(phase_metrics)
        avg_mem_max = sum(m['mem_max'] for m in phase_metrics) / len(phase_metrics)
        avg_mem_pct = sum(m['mem_pct'] for m in phase_metrics) / len(phase_metrics)
        
        results.append({
            'phase': phase_idx + 1,
            'rate': phase['rate'],
            'size': phase['size'],
            'duration': duration,
            'thr': avg_thr,
            'lat': avg_lat,
            'avg_size': avg_size,
            'arrival': avg_arrival,
            'mem_used': avg_mem_used,
            'mem_max': avg_mem_max,
            'mem_pct': avg_mem_pct,
            'samples': len(phase_metrics)
        })
    
    sample_idx = phase_end

# 写入结果
with open(output_file, 'w') as f:
    for r in results:
        f.write(f"{r['phase']},{r['rate']},{r['size']},{r['duration']},{r['thr']:.2f},{r['lat']:.2f},{r['avg_size']:.2f},{r['arrival']:.2f},{r['mem_used']:.0f},{r['mem_max']:.0f},{r['mem_pct']:.1f},{r['samples']}\n")

print(f"Parsed {len(results)} phases")
EOF
}

# ============= 主逻辑 =============

echo "============================================================"
echo "          Dynamic Workload Benchmark Suite"
echo "============================================================"
echo "Results will be saved to: ${EXPERIMENT_DIR}"
echo "Skip Build: ${SKIP_BUILD}"
echo "Resume Mode: ${RESUME_MODE}"
echo "Workload Config: ${WORKLOAD_CONFIG}"
echo ""

# 创建结果目录
mkdir -p "${EXPERIMENT_DIR}/logs"

# 初始化结果 CSV（总体统计）
RESULTS_CSV="${EXPERIMENT_DIR}/results.csv"
if [[ "$RESUME_MODE" == false ]] || [[ ! -f "$RESULTS_CSV" ]]; then
    echo "experiment_id,algorithm,batch_size,batch_timeout,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count" > "$RESULTS_CSV"
fi

# 初始化分阶段结果 CSV
PHASE_RESULTS_CSV="${EXPERIMENT_DIR}/phase_results.csv"
if [[ "$RESUME_MODE" == false ]] || [[ ! -f "$PHASE_RESULTS_CSV" ]]; then
    echo "experiment_id,algorithm,batch_size,batch_timeout,phase,workload_rate,workload_size,phase_duration,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count" > "$PHASE_RESULTS_CSV"
fi

# 显示续跑进度
if [[ "$RESUME_MODE" == true ]] && [[ -f "$PROGRESS_FILE" ]]; then
    COMPLETED_COUNT=$(wc -l < "$PROGRESS_FILE" 2>/dev/null || echo "0")
    echo ">>> Resume mode: ${COMPLETED_COUNT} experiments already completed"
fi

# 计算总实验数
TOTAL_ALGORITHMS=${#ALGORITHMS[@]}
TOTAL_STATIC_CONFIGS=${#STATIC_CONFIGS[@]}
TOTAL_EXPERIMENTS=$((TOTAL_ALGORITHMS + TOTAL_STATIC_CONFIGS))

echo ""
echo ">>> Experiment Plan:"
echo "    Dynamic Algorithms: ${ALGORITHMS[*]}"
echo "    Static Configs: ${#STATIC_CONFIGS[@]} configurations"
echo "    Total experiments: ${TOTAL_EXPERIMENTS}"
echo ""

# 显示静态配置
echo ">>> Static configurations to test:"
for i in "${!STATIC_CONFIGS[@]}"; do
    IFS=',' read -r bs bt <<< "${STATIC_CONFIGS[$i]}"
    echo "    [$((i+1))] batch_size=${bs}, batch_timeout=${bt}"
done
echo ""

read -p "Press Enter to start, or Ctrl+C to abort..."

# ============= 运行实验 =============

EXPERIMENT_COUNT=0
SKIPPED_COUNT=0

# --- Part 1: 测试动态算法 (BAYESIAN, PPO) ---
echo ""
echo "============================================================"
echo ">>> Part 1: Testing Dynamic Algorithms"
echo "============================================================"

for alg in "${ALGORITHMS[@]}"; do
    EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
    EXP_KEY="ALG_${alg}"
    
    # 检查是否已完成
    if is_experiment_done "$EXP_KEY"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo "  [SKIP] Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: ${alg} (already completed)"
        continue
    fi
    
    echo ""
    echo "--- Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: ${alg} ---"
    
    # 运行实验
    # lan_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [ALGORITHM] [WORKLOAD_CONFIG]
    # 对于动态算法，BatchSize 和 Timeout 由算法动态调整，这里设置初始值
    echo "  Running lan_deploy.sh with ${alg}..."
    
    ./lan_deploy.sh 500 100 -1 "$SKIP_BUILD" "$alg" "$WORKLOAD_CONFIG" > "${EXPERIMENT_DIR}/logs/exp_${alg}.log" 2>&1 || {
        echo "  WARNING: lan_deploy.sh failed for ${alg}"
        echo "${EXPERIMENT_COUNT},${alg},dynamic,dynamic,0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
        mark_experiment_done "$EXP_KEY"
        continue
    }
    
    # 解析总体 metrics
    SERVER_LOG="results/server_0.log"
    METRICS_TMP="${EXPERIMENT_DIR}/logs/metrics_${alg}.tmp"
    
    echo "  Parsing overall metrics..."
    parse_server_log "$SERVER_LOG" "$METRICS_TMP"
    
    if [[ -f "$METRICS_TMP" ]]; then
        METRICS=$(cat "$METRICS_TMP")
        echo "${EXPERIMENT_COUNT},${alg},dynamic,dynamic,${METRICS}" >> "$RESULTS_CSV"
        rm -f "$METRICS_TMP"
    else
        echo "${EXPERIMENT_COUNT},${alg},dynamic,dynamic,0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
    fi
    
    # 解析分阶段 metrics
    PHASE_TMP="${EXPERIMENT_DIR}/logs/phase_${alg}.tmp"
    echo "  Parsing per-phase metrics..."
    parse_server_log_by_phase "$SERVER_LOG" "$PHASE_TMP" "$WORKLOAD_CONFIG"
    
    if [[ -f "$PHASE_TMP" ]]; then
        while IFS=',' read -r phase rate size duration thr lat avg_size arrival mem_used mem_max mem_pct samples; do
            echo "${EXPERIMENT_COUNT},${alg},dynamic,dynamic,${phase},${rate},${size},${duration},${thr},${lat},${avg_size},${arrival},${mem_used},${mem_max},${mem_pct},${samples}" >> "$PHASE_RESULTS_CSV"
        done < "$PHASE_TMP"
        rm -f "$PHASE_TMP"
    fi
    
    # 保存日志
    cp "results/server_0.log" "${EXPERIMENT_DIR}/logs/server_${alg}.log" 2>/dev/null || true
    cp "results/agent_0.log" "${EXPERIMENT_DIR}/logs/agent_${alg}.log" 2>/dev/null || true
    cp "results/client.log" "${EXPERIMENT_DIR}/logs/client_${alg}.log" 2>/dev/null || true
    
    # 标记完成
    mark_experiment_done "$EXP_KEY"
    
    # 后续跳过编译
    SKIP_BUILD="true"
    
    echo "  Done."
done

# --- Part 2: 测试静态配置 ---
echo ""
echo "============================================================"
echo ">>> Part 2: Testing Static Configurations"
echo "============================================================"

for i in "${!STATIC_CONFIGS[@]}"; do
    IFS=',' read -r bs bt <<< "${STATIC_CONFIGS[$i]}"
    
    EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
    EXP_KEY="STATIC_${bs}_${bt}"
    
    # 检查是否已完成
    if is_experiment_done "$EXP_KEY"; then
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        echo "  [SKIP] Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: STATIC(${bs},${bt}) (already completed)"
        continue
    fi
    
    echo ""
    echo "--- Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: STATIC (bs=${bs}, bt=${bt}) ---"
    
    # 运行实验
    echo "  Running lan_deploy.sh with STATIC (bs=${bs}, bt=${bt})..."
    
    ./lan_deploy.sh "$bs" "$bt" -1 "$SKIP_BUILD" "STATIC" "$WORKLOAD_CONFIG" > "${EXPERIMENT_DIR}/logs/exp_STATIC_${bs}_${bt}.log" 2>&1 || {
        echo "  WARNING: lan_deploy.sh failed for STATIC(${bs},${bt})"
        echo "${EXPERIMENT_COUNT},STATIC,${bs},${bt},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
        mark_experiment_done "$EXP_KEY"
        continue
    }
    
    # 解析总体 metrics
    SERVER_LOG="results/server_0.log"
    METRICS_TMP="${EXPERIMENT_DIR}/logs/metrics_STATIC_${bs}_${bt}.tmp"
    
    echo "  Parsing overall metrics..."
    parse_server_log "$SERVER_LOG" "$METRICS_TMP"
    
    if [[ -f "$METRICS_TMP" ]]; then
        METRICS=$(cat "$METRICS_TMP")
        echo "${EXPERIMENT_COUNT},STATIC,${bs},${bt},${METRICS}" >> "$RESULTS_CSV"
        rm -f "$METRICS_TMP"
    else
        echo "${EXPERIMENT_COUNT},STATIC,${bs},${bt},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
    fi
    
    # 解析分阶段 metrics
    PHASE_TMP="${EXPERIMENT_DIR}/logs/phase_STATIC_${bs}_${bt}.tmp"
    echo "  Parsing per-phase metrics..."
    parse_server_log_by_phase "$SERVER_LOG" "$PHASE_TMP" "$WORKLOAD_CONFIG"
    
    if [[ -f "$PHASE_TMP" ]]; then
        while IFS=',' read -r phase rate size duration thr lat avg_size arrival mem_used mem_max mem_pct samples; do
            echo "${EXPERIMENT_COUNT},STATIC,${bs},${bt},${phase},${rate},${size},${duration},${thr},${lat},${avg_size},${arrival},${mem_used},${mem_max},${mem_pct},${samples}" >> "$PHASE_RESULTS_CSV"
        done < "$PHASE_TMP"
        rm -f "$PHASE_TMP"
    fi
    
    # 保存日志
    cp "results/server_0.log" "${EXPERIMENT_DIR}/logs/server_STATIC_${bs}_${bt}.log" 2>/dev/null || true
    cp "results/agent_0.log" "${EXPERIMENT_DIR}/logs/agent_STATIC_${bs}_${bt}.log" 2>/dev/null || true
    cp "results/client.log" "${EXPERIMENT_DIR}/logs/client_STATIC_${bs}_${bt}.log" 2>/dev/null || true
    
    # 标记完成
    mark_experiment_done "$EXP_KEY"
    
    # 后续跳过编译
    SKIP_BUILD="true"
    
    echo "  Done."
done

# ============= 生成汇总报告 =============

echo ""
echo "============================================================"
echo "          Benchmark Complete!"
echo "============================================================"
echo "Results saved to:"
echo "  - Overall: ${RESULTS_CSV}"
echo "  - Per-phase: ${PHASE_RESULTS_CSV}"
echo "Total experiments: ${EXPERIMENT_COUNT}"
echo "Skipped (already done): ${SKIPPED_COUNT}"
echo "Actually run: $((EXPERIMENT_COUNT - SKIPPED_COUNT))"
echo ""

echo ">>> Generating summary report..."

python3 << EOF
import csv
import os

results_csv = "${RESULTS_CSV}"
phase_csv = "${PHASE_RESULTS_CSV}"
summary_file = "${EXPERIMENT_DIR}/summary.txt"

try:
    # 读取总体结果
    with open(results_csv, 'r') as f:
        reader = csv.DictReader(f)
        overall_results = list(reader)
    
    # 读取分阶段结果
    with open(phase_csv, 'r') as f:
        reader = csv.DictReader(f)
        phase_results = list(reader)
    
    with open(summary_file, 'w') as f:
        f.write("=" * 70 + "\n")
        f.write("Dynamic Workload Benchmark Summary\n")
        f.write("=" * 70 + "\n\n")
        
        # ===== 总体性能对比 =====
        f.write("=" * 70 + "\n")
        f.write("1. OVERALL PERFORMANCE COMPARISON\n")
        f.write("=" * 70 + "\n\n")
        
        f.write(f"{'Algorithm':<15} {'Config':<15} {'Throughput':>12} {'Latency':>12} {'Samples':>8}\n")
        f.write("-" * 70 + "\n")
        
        for row in overall_results:
            alg = row['algorithm']
            if alg == 'STATIC':
                config = f"({row['batch_size']},{row['batch_timeout']})"
            else:
                config = "dynamic"
            
            try:
                thr = float(row['avg_throughput'])
                lat = float(row['avg_latency_us'])
                samples = int(row['sample_count'])
                f.write(f"{alg:<15} {config:<15} {thr:>12.2f} {lat:>12.2f} {samples:>8}\n")
            except:
                f.write(f"{alg:<15} {config:<15} {'N/A':>12} {'N/A':>12} {'N/A':>8}\n")
        
        f.write("\n")
        
        # ===== 找出最佳配置 =====
        valid_results = []
        for row in overall_results:
            try:
                thr = float(row['avg_throughput'])
                lat = float(row['avg_latency_us'])
                if thr > 0:
                    valid_results.append({
                        'alg': row['algorithm'],
                        'bs': row['batch_size'],
                        'bt': row['batch_timeout'],
                        'thr': thr,
                        'lat': lat
                    })
            except:
                pass
        
        if valid_results:
            best_thr = max(valid_results, key=lambda x: x['thr'])
            best_lat = min(valid_results, key=lambda x: x['lat'])
            
            f.write("=" * 70 + "\n")
            f.write("2. BEST CONFIGURATIONS\n")
            f.write("=" * 70 + "\n\n")
            
            f.write(f"Best Throughput: {best_thr['thr']:.2f} ops/s\n")
            f.write(f"  Algorithm: {best_thr['alg']}\n")
            if best_thr['alg'] == 'STATIC':
                f.write(f"  Config: batch_size={best_thr['bs']}, batch_timeout={best_thr['bt']}\n")
            f.write(f"  Latency: {best_thr['lat']:.2f} us\n\n")
            
            f.write(f"Lowest Latency: {best_lat['lat']:.2f} us\n")
            f.write(f"  Algorithm: {best_lat['alg']}\n")
            if best_lat['alg'] == 'STATIC':
                f.write(f"  Config: batch_size={best_lat['bs']}, batch_timeout={best_lat['bt']}\n")
            f.write(f"  Throughput: {best_lat['thr']:.2f} ops/s\n\n")
        
        # ===== 分阶段性能对比 =====
        f.write("=" * 70 + "\n")
        f.write("3. PER-PHASE PERFORMANCE (by workload)\n")
        f.write("=" * 70 + "\n\n")
        
        # 按 phase 分组
        phases = {}
        for row in phase_results:
            try:
                phase_key = (row['phase'], row['workload_rate'], row['workload_size'])
                if phase_key not in phases:
                    phases[phase_key] = []
                
                alg = row['algorithm']
                if alg == 'STATIC':
                    config = f"STATIC({row['batch_size']},{row['batch_timeout']})"
                else:
                    config = alg
                
                phases[phase_key].append({
                    'config': config,
                    'thr': float(row['avg_throughput']),
                    'lat': float(row['avg_latency_us'])
                })
            except:
                pass
        
        for (phase, rate, size), configs in sorted(phases.items()):
            f.write(f"Phase {phase}: rate={rate} ops/s, size={size} bytes\n")
            f.write("-" * 50 + "\n")
            f.write(f"  {'Config':<30} {'Throughput':>10} {'Latency':>10}\n")
            
            for c in sorted(configs, key=lambda x: -x['thr']):
                f.write(f"  {c['config']:<30} {c['thr']:>10.2f} {c['lat']:>10.2f}\n")
            f.write("\n")
        
        f.write("=" * 70 + "\n")
    
    print(f"Summary written to: {summary_file}")
    
    # 打印到控制台
    with open(summary_file, 'r') as f:
        print(f.read())

except Exception as e:
    print(f"Error generating summary: {e}")
    import traceback
    traceback.print_exc()
EOF

echo ""
echo "Done!"

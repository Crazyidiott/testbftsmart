#!/bin/bash
# ==============================================================================
# run_static_benchmark.sh - 静态配置基准测试脚本
# ==============================================================================
# 
# 功能：
#   针对 dynamic_workload.config 中定义的每种 workload 模式，
#   遍历所有可能的 (batch_size, batch_timeout) 配置组合，
#   测量每个组合的静态性能表现。
#
# 使用方式：
#   ./run_static_benchmark.sh [SkipBuild]
#   例如：
#     ./run_static_benchmark.sh          # 首次运行（需要编译）
#     ./run_static_benchmark.sh true     # 跳过编译（加快测试）
#
# 输出：
#   - static_benchmark_results/results.csv   : 汇总结果表格
#   - static_benchmark_results/logs/         : 每次实验的详细日志
#
# ==============================================================================

set -e  # 出错时退出

# ============= 配置参数 =============

# 从 trainer.py 中提取的动作空间
# BatchSize: 100-2000, 步长100 -> [100, 200, 300, ..., 2000] (20个值)
# BatchTimeout: 50-200, 步长10 -> [50, 60, 70, ..., 200] (16个值)
BATCH_SIZE_MIN=100
BATCH_SIZE_MAX=2000
BATCH_SIZE_STEP=200

BATCH_TIMEOUT_MIN=50
BATCH_TIMEOUT_MAX=200
BATCH_TIMEOUT_STEP=30

# 是否跳过编译
SKIP_BUILD="${1:-false}"

# 每个配置的运行时间（秒）- 与 dynamic_workload.config 保持一致
RUN_DURATION=30

# 结果目录
RESULTS_DIR="static_benchmark_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXPERIMENT_DIR="${RESULTS_DIR}/experiment_${TIMESTAMP}"

# 临时 workload 配置文件
TEMP_WORKLOAD_CONFIG="config/workloads/temp_static_workload.config"

# ============= 辅助函数 =============

# 创建单一 workload 的临时配置文件
create_single_workload_config() {
    local duration=$1
    local rate=$2
    local request_size=$3
    
    echo "# Duration(s), Rate(ops/sec per thread), RequestSize(bytes)" > "$TEMP_WORKLOAD_CONFIG"
    echo "${duration}, ${rate}, ${request_size}" >> "$TEMP_WORKLOAD_CONFIG"
}

# 解析 agent log 提取 metrics 平均值
# 格式: [Metrics] window=1000ms, ops=XXX, latSum=XXX, latSamples=XXX => thr=XXX, lat=XXX us | avgSize=XXX bytes, arrivalRate=XXX req/s | Memory: XXXMB/XXXMB (XX.X%)
parse_agent_log() {
    local log_file=$1
    local output_file=$2
    
    # 使用 Python 解析日志（更精确）
    python3 << EOF
import re
import sys

log_file = "$log_file"
output_file = "$output_file"

# Metrics pattern
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

# 计算平均值
n = len(throughputs)
if n > 0:
    # 跳过前5个样本（预热期）
    skip = min(5, n // 3)
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

# ============= 主逻辑 =============

echo "============================================================"
echo "          Static Benchmark Suite"
echo "============================================================"
echo "Timestamp: ${TIMESTAMP}"
echo "Results will be saved to: ${EXPERIMENT_DIR}"
echo "Skip Build: ${SKIP_BUILD}"
echo ""

# 创建结果目录
mkdir -p "${EXPERIMENT_DIR}/logs"

# 初始化结果 CSV
RESULTS_CSV="${EXPERIMENT_DIR}/results.csv"
echo "workload_id,rate,request_size,batch_size,batch_timeout,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count" > "$RESULTS_CSV"

# 读取 dynamic_workload.config 中的唯一 workload 模式
WORKLOAD_CONFIG="config/workloads/dynamic_workload.config"

echo ">>> Reading workload configurations from ${WORKLOAD_CONFIG}..."

# 提取唯一的 workload 模式 (rate, request_size)
declare -A UNIQUE_WORKLOADS
WORKLOAD_ID=0

while IFS=',' read -r duration rate request_size || [ -n "$duration" ]; do
    # 跳过注释和空行
    [[ "$duration" =~ ^#.*$ ]] && continue
    [[ -z "$duration" ]] && continue
    
    # 去除空格
    rate=$(echo "$rate" | tr -d ' ')
    request_size=$(echo "$request_size" | tr -d ' ')
    
    key="${rate}_${request_size}"
    
    if [[ -z "${UNIQUE_WORKLOADS[$key]}" ]]; then
        UNIQUE_WORKLOADS[$key]="$rate,$request_size"
        echo "  Found unique workload: rate=${rate} ops/s, size=${request_size} bytes"
    fi
done < "$WORKLOAD_CONFIG"

echo ""
echo "Total unique workloads: ${#UNIQUE_WORKLOADS[@]}"

# 生成配置组合
echo ""
echo ">>> Generating batch size values..."
BATCH_SIZES=()
for ((bs=BATCH_SIZE_MIN; bs<=BATCH_SIZE_MAX; bs+=BATCH_SIZE_STEP)); do
    BATCH_SIZES+=($bs)
done
echo "  Batch sizes: ${BATCH_SIZES[*]}"
echo "  Total: ${#BATCH_SIZES[@]} values"

echo ""
echo ">>> Generating batch timeout values..."
BATCH_TIMEOUTS=()
for ((bt=BATCH_TIMEOUT_MIN; bt<=BATCH_TIMEOUT_MAX; bt+=BATCH_TIMEOUT_STEP)); do
    BATCH_TIMEOUTS+=($bt)
done
echo "  Batch timeouts: ${BATCH_TIMEOUTS[*]}"
echo "  Total: ${#BATCH_TIMEOUTS[@]} values"

# 计算总实验数
TOTAL_WORKLOADS=${#UNIQUE_WORKLOADS[@]}
TOTAL_CONFIGS=$((${#BATCH_SIZES[@]} * ${#BATCH_TIMEOUTS[@]}))
TOTAL_EXPERIMENTS=$((TOTAL_WORKLOADS * TOTAL_CONFIGS))

echo ""
echo "============================================================"
echo "Total experiments to run: ${TOTAL_EXPERIMENTS}"
echo "  (${TOTAL_WORKLOADS} workloads × ${TOTAL_CONFIGS} configurations)"
echo "Estimated time: $((TOTAL_EXPERIMENTS * (RUN_DURATION + 40) / 60)) minutes"
echo "  (${RUN_DURATION}s run + ~40s setup/teardown per experiment)"
echo "============================================================"
echo ""

read -p "Press Enter to start, or Ctrl+C to abort..."

# 主循环
EXPERIMENT_COUNT=0
WORKLOAD_ID=0

for key in "${!UNIQUE_WORKLOADS[@]}"; do
    IFS=',' read -r rate request_size <<< "${UNIQUE_WORKLOADS[$key]}"
    WORKLOAD_ID=$((WORKLOAD_ID + 1))
    
    echo ""
    echo "============================================================"
    echo ">>> Workload ${WORKLOAD_ID}/${TOTAL_WORKLOADS}: rate=${rate}, size=${request_size}"
    echo "============================================================"
    
    # 创建单一 workload 的临时配置
    create_single_workload_config "$RUN_DURATION" "$rate" "$request_size"
    echo "  Created temp workload config: ${TEMP_WORKLOAD_CONFIG}"
    
    for bs in "${BATCH_SIZES[@]}"; do
        for bt in "${BATCH_TIMEOUTS[@]}"; do
            EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
            
            echo ""
            echo "--- Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS} ---"
            echo "  Workload: rate=${rate}, size=${request_size}"
            echo "  Config: batch_size=${bs}, batch_timeout=${bt}"
            
            # 运行实验 (使用 STATIC 模式)
            # lan_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [ALGORITHM] [WORKLOAD_CONFIG]
            echo "  Running lan_deploy.sh..."
            
            ./lan_deploy.sh "$bs" "$bt" -1 "$SKIP_BUILD" "STATIC" "temp_static_workload.config" > "${EXPERIMENT_DIR}/logs/exp_${EXPERIMENT_COUNT}.log" 2>&1 || {
                echo "  WARNING: lan_deploy.sh failed for this experiment"
                echo "${WORKLOAD_ID},${rate},${request_size},${bs},${bt},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
                continue
            }
            
            # 解析 server log (RLAgentConnector 的 metrics 输出在 server_*.log 中)
            # 使用 node 0 的日志作为主要数据源
            SERVER_LOG="results/server_0.log"
            METRICS_TMP="${EXPERIMENT_DIR}/logs/metrics_${EXPERIMENT_COUNT}.tmp"
            
            echo "  Parsing metrics from ${SERVER_LOG}..."
            parse_agent_log "$SERVER_LOG" "$METRICS_TMP"
            
            # 读取解析结果并追加到 CSV
            if [[ -f "$METRICS_TMP" ]]; then
                METRICS=$(cat "$METRICS_TMP")
                echo "${WORKLOAD_ID},${rate},${request_size},${bs},${bt},${METRICS}" >> "$RESULTS_CSV"
                rm -f "$METRICS_TMP"
            else
                echo "  WARNING: Failed to parse metrics"
                echo "${WORKLOAD_ID},${rate},${request_size},${bs},${bt},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
            fi
            
            # 保存原始日志副本 (server log + agent log + deploy log)
            cp "results/server_0.log" "${EXPERIMENT_DIR}/logs/server_w${WORKLOAD_ID}_bs${bs}_bt${bt}.log" 2>/dev/null || true
            cp "results/agent_0.log" "${EXPERIMENT_DIR}/logs/agent_w${WORKLOAD_ID}_bs${bs}_bt${bt}.log" 2>/dev/null || true
            cp "results/client.log" "${EXPERIMENT_DIR}/logs/client_w${WORKLOAD_ID}_bs${bs}_bt${bt}.log" 2>/dev/null || true
            
            # 第一次实验后跳过编译
            SKIP_BUILD="true"
            
            echo "  Done."
        done
    done
done

# 清理临时文件
rm -f "$TEMP_WORKLOAD_CONFIG"

echo ""
echo "============================================================"
echo "          Benchmark Complete!"
echo "============================================================"
echo "Results saved to: ${RESULTS_CSV}"
echo "Total experiments run: ${EXPERIMENT_COUNT}"
echo ""

# 生成简单的汇总统计
echo ">>> Generating summary..."

python3 << EOF
import csv
import os

csv_file = "${RESULTS_CSV}"
summary_file = "${EXPERIMENT_DIR}/summary.txt"

try:
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    
    if not rows:
        print("No data to summarize")
        exit()
    
    with open(summary_file, 'w') as f:
        f.write("=" * 60 + "\n")
        f.write("Static Benchmark Summary\n")
        f.write("=" * 60 + "\n\n")
        
        # 按 workload 分组
        workloads = {}
        for row in rows:
            wid = row['workload_id']
            if wid not in workloads:
                workloads[wid] = {
                    'rate': row['rate'],
                    'request_size': row['request_size'],
                    'configs': []
                }
            
            try:
                thr = float(row['avg_throughput'])
                lat = float(row['avg_latency_us'])
                if thr > 0:
                    workloads[wid]['configs'].append({
                        'bs': int(row['batch_size']),
                        'bt': int(row['batch_timeout']),
                        'thr': thr,
                        'lat': lat
                    })
            except:
                pass
        
        for wid, wdata in sorted(workloads.items(), key=lambda x: int(x[0])):
            f.write(f"Workload {wid}: rate={wdata['rate']}, size={wdata['request_size']}\n")
            f.write("-" * 40 + "\n")
            
            if wdata['configs']:
                # 找最佳吞吐量配置
                best_thr = max(wdata['configs'], key=lambda x: x['thr'])
                f.write(f"  Best Throughput: {best_thr['thr']:.2f} ops/s\n")
                f.write(f"    Config: batch_size={best_thr['bs']}, batch_timeout={best_thr['bt']}\n")
                f.write(f"    Latency: {best_thr['lat']:.2f} us\n")
                
                # 找最低延迟配置（在吞吐量 > 0 的前提下）
                valid_configs = [c for c in wdata['configs'] if c['thr'] > 0]
                if valid_configs:
                    best_lat = min(valid_configs, key=lambda x: x['lat'])
                    f.write(f"  Lowest Latency: {best_lat['lat']:.2f} us\n")
                    f.write(f"    Config: batch_size={best_lat['bs']}, batch_timeout={best_lat['bt']}\n")
                    f.write(f"    Throughput: {best_lat['thr']:.2f} ops/s\n")
            else:
                f.write("  No valid data\n")
            
            f.write("\n")
        
        f.write("=" * 60 + "\n")
    
    print(f"Summary written to: {summary_file}")
    
    # 也打印到控制台
    with open(summary_file, 'r') as f:
        print(f.read())

except Exception as e:
    print(f"Error generating summary: {e}")
EOF

echo ""
echo "Done!"

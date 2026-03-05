#!/bin/bash
# ==============================================================================
# run_request_timeout_benchmark.sh - RequestTimeout 对吞吐/延迟影响的基准测试
# ==============================================================================
#
# 功能：
#   固定 batchSize=500, batchTimeout=100，遍历不同的 requestTimeout 值，
#   在多种 workload 下测试其对吞吐量和延迟的影响。
#   requestTimeout 控制 view change 的触发时限，本脚本用于验证：
#   不同的 requestTimeout 是否能通过调节 view change 时限改变系统表现。
#
# 使用方式：
#   ./run_request_timeout_benchmark.sh [SkipBuild] [ResumeDir]
#   例如：
#     ./run_request_timeout_benchmark.sh                    # 首次运行
#     ./run_request_timeout_benchmark.sh true               # 跳过编译
#     ./run_request_timeout_benchmark.sh true experiment_20260305_120000  # 续跑
#
# 输出：
#   - request_timeout_benchmark_results/<experiment>/results.csv
#   - request_timeout_benchmark_results/<experiment>/logs/
#
# ==============================================================================

set -e

# ============= 配置参数 =============

# 固定的 batchSize 和 batchTimeout
FIXED_BATCH_SIZE=500
FIXED_BATCH_TIMEOUT=100

# 要测试的 requestTimeout 值列表（单位：ms）
# requestTimeout 必须大于 batchTimeout，否则会不断触发 view change
REQUEST_TIMEOUTS=(200 500 1000 2000 5000 10000 20000)

# 是否跳过编译
SKIP_BUILD="${1:-false}"

# 断点续跑
RESUME_DIR="${2:-}"

# 每个配置的运行时间（秒）
RUN_DURATION=60

# 结果目录
RESULTS_DIR="request_timeout_benchmark_results"

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

# 临时 workload 配置文件
TEMP_WORKLOAD_CONFIG="config/workloads/temp_reqtimeout_workload.config"

# 进度文件
PROGRESS_FILE="${EXPERIMENT_DIR}/progress.txt"

# ============= 辅助函数 =============

is_experiment_done() {
    local exp_key=$1
    if [[ -f "$PROGRESS_FILE" ]] && grep -q "^${exp_key}$" "$PROGRESS_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

mark_experiment_done() {
    local exp_key=$1
    echo "$exp_key" >> "$PROGRESS_FILE"
}

# 创建单一 workload 的临时配置文件
create_single_workload_config() {
    local duration=$1
    local rate=$2
    local request_size=$3

    echo "# Duration(s), Rate(ops/sec per thread), RequestSize(bytes)" > "$TEMP_WORKLOAD_CONFIG"
    echo "${duration}, ${rate}, ${request_size}" >> "$TEMP_WORKLOAD_CONFIG"
}

# 修改 system.config 中的 requestTimeout
update_request_timeout() {
    local timeout_val=$1
    local config_file="config/system.config"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s/system.totalordermulticast.timeout = .*/system.totalordermulticast.timeout = ${timeout_val}/g" "$config_file"
    else
        sed -i "s/system.totalordermulticast.timeout = .*/system.totalordermulticast.timeout = ${timeout_val}/g" "$config_file"
    fi
}

# 解析 server log 提取 metrics
parse_agent_log() {
    local log_file=$1
    local output_file=$2

    python3 << PYEOF
import re
import sys

log_file = "$log_file"
output_file = "$output_file"

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
    # 去除尾部连续 thr=0 的样本
    while len(throughputs) > 5 and throughputs[-1] == 0.0:
        throughputs.pop()
        latencies.pop()
        avg_sizes.pop()
        arrival_rates.pop()
        mem_used.pop()
        mem_max.pop()
        mem_percent.pop()

    n = len(throughputs)
    # 跳过前5个预热样本
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
PYEOF
}

# ============= 主逻辑 =============

echo "============================================================"
echo "     RequestTimeout Benchmark Suite"
echo "============================================================"
echo "Fixed: batchSize=${FIXED_BATCH_SIZE}, batchTimeout=${FIXED_BATCH_TIMEOUT}"
echo "RequestTimeout values: ${REQUEST_TIMEOUTS[*]}"
echo "Results will be saved to: ${EXPERIMENT_DIR}"
echo "Skip Build: ${SKIP_BUILD}"
echo "Resume Mode: ${RESUME_MODE}"
echo ""

# 创建结果目录
mkdir -p "${EXPERIMENT_DIR}/logs"

# 初始化结果 CSV
RESULTS_CSV="${EXPERIMENT_DIR}/results.csv"
if [[ "$RESUME_MODE" == false ]] || [[ ! -f "$RESULTS_CSV" ]]; then
    echo "workload_id,rate,request_size,request_timeout,batch_size,batch_timeout,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count" > "$RESULTS_CSV"
fi

# 读取 workload 配置（复用 dynamic_workload.config 中的唯一 workload 模式）
WORKLOAD_CONFIG="config/workloads/dynamic_workload.config"
echo ">>> Reading workload configurations from ${WORKLOAD_CONFIG}..."

declare -A UNIQUE_WORKLOADS
while IFS=',' read -r duration rate request_size || [ -n "$duration" ]; do
    [[ "$duration" =~ ^#.*$ ]] && continue
    [[ -z "$duration" ]] && continue

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

# 显示续跑进度
if [[ "$RESUME_MODE" == true ]] && [[ -f "$PROGRESS_FILE" ]]; then
    COMPLETED_COUNT=$(wc -l < "$PROGRESS_FILE" 2>/dev/null || echo "0")
    echo ">>> Resume mode: ${COMPLETED_COUNT} experiments already completed"
fi

# 计算总实验数
TOTAL_WORKLOADS=${#UNIQUE_WORKLOADS[@]}
TOTAL_TIMEOUTS=${#REQUEST_TIMEOUTS[@]}
TOTAL_EXPERIMENTS=$((TOTAL_WORKLOADS * TOTAL_TIMEOUTS))

echo ""
echo "============================================================"
echo "Total experiments to run: ${TOTAL_EXPERIMENTS}"
echo "  (${TOTAL_WORKLOADS} workloads × ${TOTAL_TIMEOUTS} requestTimeout values)"
echo ""
echo ">>> RequestTimeout values to test:"
for rt in "${REQUEST_TIMEOUTS[@]}"; do
    echo "    - ${rt} ms"
done
echo ""

read -p "Press Enter to start, or Ctrl+C to abort..."

# ============= 运行实验 =============

EXPERIMENT_COUNT=0
SKIPPED_COUNT=0
WORKLOAD_ID=0
ORIGINAL_TIMEOUT=$(grep 'system.totalordermulticast.timeout' config/system.config | awk -F'=' '{print $2}' | tr -d ' ')

for key in "${!UNIQUE_WORKLOADS[@]}"; do
    IFS=',' read -r rate request_size <<< "${UNIQUE_WORKLOADS[$key]}"
    WORKLOAD_ID=$((WORKLOAD_ID + 1))

    WORKLOAD_KEY="${rate}_${request_size}"

    echo ""
    echo "============================================================"
    echo ">>> Workload ${WORKLOAD_ID}/${TOTAL_WORKLOADS}: rate=${rate}, size=${request_size}"
    echo "============================================================"

    # 创建单一 workload 的临时配置
    create_single_workload_config "$RUN_DURATION" "$rate" "$request_size"
    echo "  Created temp workload config: ${TEMP_WORKLOAD_CONFIG}"

    for rt in "${REQUEST_TIMEOUTS[@]}"; do
        EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
        EXP_KEY="${WORKLOAD_KEY}_rt${rt}"

        # 检查是否已完成
        if is_experiment_done "$EXP_KEY"; then
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            echo "  [SKIP] Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: already completed (rt=${rt})"
            continue
        fi

        echo ""
        echo "--- Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS} ---"
        echo "  Workload: rate=${rate}, size=${request_size}"
        echo "  Config: batchSize=${FIXED_BATCH_SIZE}, batchTimeout=${FIXED_BATCH_TIMEOUT}, requestTimeout=${rt}"

        # 修改 system.config 中的 requestTimeout
        update_request_timeout "$rt"
        echo "  Updated system.config: requestTimeout=${rt}"

        # 运行实验 (使用 STATIC 模式，固定 batchSize 和 batchTimeout)
        LOG_PREFIX="w${WORKLOAD_ID}_rt${rt}"

        echo "  Running lan_deploy.sh..."
        ./lan_deploy.sh "$FIXED_BATCH_SIZE" "$FIXED_BATCH_TIMEOUT" -1 "$SKIP_BUILD" "STATIC" "temp_reqtimeout_workload.config" > "${EXPERIMENT_DIR}/logs/deploy_${LOG_PREFIX}.log" 2>&1 || {
            echo "  WARNING: lan_deploy.sh failed for this experiment"
            echo "${WORKLOAD_ID},${rate},${request_size},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
            mark_experiment_done "$EXP_KEY"
            continue
        }

        # 解析 server log
        SERVER_LOG="results/server_0.log"
        METRICS_TMP="${EXPERIMENT_DIR}/logs/metrics_${LOG_PREFIX}.tmp"

        echo "  Parsing metrics from ${SERVER_LOG}..."
        parse_agent_log "$SERVER_LOG" "$METRICS_TMP"

        if [[ -f "$METRICS_TMP" ]]; then
            METRICS=$(cat "$METRICS_TMP")
            echo "${WORKLOAD_ID},${rate},${request_size},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},${METRICS}" >> "$RESULTS_CSV"
            rm -f "$METRICS_TMP"
        else
            echo "  WARNING: Failed to parse metrics"
            echo "${WORKLOAD_ID},${rate},${request_size},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
        fi

        # 保存原始日志
        cp "results/server_0.log" "${EXPERIMENT_DIR}/logs/server_${LOG_PREFIX}.log" 2>/dev/null || true
        cp "results/agent_0.log" "${EXPERIMENT_DIR}/logs/agent_${LOG_PREFIX}.log" 2>/dev/null || true
        cp "results/client.log" "${EXPERIMENT_DIR}/logs/client_${LOG_PREFIX}.log" 2>/dev/null || true

        mark_experiment_done "$EXP_KEY"

        # 第一次实验后跳过编译
        SKIP_BUILD="true"

        echo "  Done."
    done
done

# 恢复原始 requestTimeout
update_request_timeout "$ORIGINAL_TIMEOUT"
echo ">>> Restored original requestTimeout=${ORIGINAL_TIMEOUT}"

# 清理临时文件
rm -f "$TEMP_WORKLOAD_CONFIG"

echo ""
echo "============================================================"
echo "          Benchmark Complete!"
echo "============================================================"
echo "Results saved to: ${RESULTS_CSV}"
echo "Total experiments: ${EXPERIMENT_COUNT}"
echo "Skipped (already done): ${SKIPPED_COUNT}"
echo "Actually run: $((EXPERIMENT_COUNT - SKIPPED_COUNT))"
echo ""

# 生成汇总
echo ">>> Generating summary..."

python3 << PYEOF
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
        f.write("=" * 70 + "\n")
        f.write("RequestTimeout Benchmark Summary\n")
        f.write(f"Fixed: batchSize=500, batchTimeout=100\n")
        f.write("=" * 70 + "\n\n")

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
                rt = int(row['request_timeout'])
                workloads[wid]['configs'].append({
                    'rt': rt,
                    'thr': thr,
                    'lat': lat
                })
            except:
                pass

        for wid, wdata in sorted(workloads.items(), key=lambda x: int(x[0])):
            f.write(f"Workload {wid}: rate={wdata['rate']}, size={wdata['request_size']}\n")
            f.write("-" * 50 + "\n")
            f.write(f"  {'RequestTimeout(ms)':>20s}  {'Throughput(ops/s)':>18s}  {'Latency(us)':>14s}\n")
            f.write(f"  {'─'*20}  {'─'*18}  {'─'*14}\n")

            for c in sorted(wdata['configs'], key=lambda x: x['rt']):
                f.write(f"  {c['rt']:>20d}  {c['thr']:>18.2f}  {c['lat']:>14.2f}\n")

            if wdata['configs']:
                valid = [c for c in wdata['configs'] if c['thr'] > 0]
                if valid:
                    best_thr = max(valid, key=lambda x: x['thr'])
                    best_lat = min(valid, key=lambda x: x['lat'])
                    f.write(f"\n  Best Throughput: {best_thr['thr']:.2f} ops/s @ rt={best_thr['rt']}ms\n")
                    f.write(f"  Best Latency:    {best_lat['lat']:.2f} us   @ rt={best_lat['rt']}ms\n")
            f.write("\n")

    print(f"Summary saved to {summary_file}")

    # 也打印到终端
    with open(summary_file, 'r') as f:
        print(f.read())

except Exception as e:
    print(f"Error generating summary: {e}")
PYEOF

echo "Done."

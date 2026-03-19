#!/bin/bash
# ==============================================================================
# run_network_timeout_benchmark.sh - 网络延迟 × RequestTimeout 交叉基准测试
# ==============================================================================
#
# 功能：
#   在不同的人工网络延迟条件下，固定 batchSize 和 batchTimeout，
#   遍历不同的 requestTimeout 值，测试其对吞吐量和延迟的影响。
#   用于验证：网络延迟波动是否能让 requestTimeout 的调参产生显著效果。
#
# 原理：
#   requestTimeout 控制 view change 触发时限。在 LAN（<1ms 延迟）环境下，
#   请求处理总耗时远低于任何合理的 requestTimeout，因此调参无效。
#   通过 tc netem 注入人工延迟，模拟 WAN / 网络抖动场景，
#   使得 requestTimeout 的选择成为影响系统稳定性的关键因素。
#
# 实验矩阵：
#   网络延迟 × requestTimeout × workload = N 组实验
#   每组实验固定 batchSize、batchTimeout，运行一段时间后收集 metrics。
#
# 使用方式：
#   ./run_network_timeout_benchmark.sh [SkipBuild] [ResumeDir]
#   例如：
#     ./run_network_timeout_benchmark.sh                    # 首次运行
#     ./run_network_timeout_benchmark.sh true               # 跳过编译
#     ./run_network_timeout_benchmark.sh true experiment_20260305_120000  # 续跑
#
# 前置条件：
#   - 节点上已安装 iproute2 (tc 命令)
#   - 当前用户有 sudo 权限（用于 tc netem）
#   - lan_config.sh 正确配置
#
# 输出：
#   - network_timeout_benchmark_results/<experiment>/results.csv
#   - network_timeout_benchmark_results/<experiment>/summary.txt
#   - network_timeout_benchmark_results/<experiment>/logs/
#
# ==============================================================================

set -e

# ============= 配置参数 =============

# 固定的 batchSize 和 batchTimeout
FIXED_BATCH_SIZE=200
FIXED_BATCH_TIMEOUT=50

# 要测试的网络延迟值（单位：ms）
# 0 = 无延迟 (LAN baseline)
# 10-50 = 同区域跨可用区
# 100-200 = 跨区域 WAN
# 500 = 极端延迟 / 跨洲际
NETWORK_DELAYS=(0 10 50 100 200 500)

# 要测试的 requestTimeout 值列表（单位：ms）
REQUEST_TIMEOUTS=(200 500 1000 2000 5000 10000)

# 要测试的 workload 列表: "rate,request_size"
WORKLOADS=(
    "2000, 512"   
    "400, 512"   
    "50, 512"     
)

# 是否跳过编译
SKIP_BUILD="${1:-false}"

# 断点续跑
RESUME_DIR="${2:-}"

# 每个配置的运行时间（秒）
RUN_DURATION=60

# 结果目录
RESULTS_DIR="network_timeout_benchmark_results"

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
TEMP_WORKLOAD_CONFIG="config/workloads/temp_net_timeout_workload.config"

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

# 设置网络延迟（调用 set_latency.sh）
set_network_delay() {
    local delay_ms=$1
    echo "  Setting network delay to ${delay_ms}ms on all nodes..."
    ./set_latency.sh "$delay_ms"
}

# 解析 server log 提取 metrics
parse_server_log() {
    local log_file=$1
    local output_file=$2

    python3 << PYEOF
import re
import sys

log_file = "$log_file"
output_file = "$output_file"

pattern = r'thr=([0-9.]+), lat=([0-9.]+) us(?:, consLat=[0-9.]+ us)? \| avgSize=([0-9.]+) bytes, arrivalRate=([0-9.]+) req/s \| Memory: ([0-9]+)MB/([0-9]+)MB \(([0-9.]+)%\)'

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
    # 去除尾部连续 thr=0 的样本（Client 停止后的拖尾）
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
echo "  Network Latency × RequestTimeout Benchmark Suite"
echo "============================================================"
echo "Fixed: batchSize=${FIXED_BATCH_SIZE}, batchTimeout=${FIXED_BATCH_TIMEOUT}"
echo "Network Delays: ${NETWORK_DELAYS[*]} ms"
echo "RequestTimeout values: ${REQUEST_TIMEOUTS[*]} ms"
echo "Workloads: ${#WORKLOADS[@]}"
echo "Results will be saved to: ${EXPERIMENT_DIR}"
echo "Skip Build: ${SKIP_BUILD}"
echo "Resume Mode: ${RESUME_MODE}"
echo ""

# 创建结果目录
mkdir -p "${EXPERIMENT_DIR}/logs"

# 初始化结果 CSV
RESULTS_CSV="${EXPERIMENT_DIR}/results.csv"
if [[ "$RESUME_MODE" == false ]] || [[ ! -f "$RESULTS_CSV" ]]; then
    echo "workload_id,rate,request_size,network_delay_ms,request_timeout,batch_size,batch_timeout,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count" > "$RESULTS_CSV"
fi

# 显示续跑进度
if [[ "$RESUME_MODE" == true ]] && [[ -f "$PROGRESS_FILE" ]]; then
    COMPLETED_COUNT=$(wc -l < "$PROGRESS_FILE" 2>/dev/null || echo "0")
    echo ">>> Resume mode: ${COMPLETED_COUNT} experiments already completed"
fi

# 计算总实验数
TOTAL_WORKLOADS=${#WORKLOADS[@]}
TOTAL_DELAYS=${#NETWORK_DELAYS[@]}
TOTAL_TIMEOUTS=${#REQUEST_TIMEOUTS[@]}
TOTAL_EXPERIMENTS=$((TOTAL_WORKLOADS * TOTAL_DELAYS * TOTAL_TIMEOUTS))

echo ""
echo "============================================================"
echo "Total experiments to run: ${TOTAL_EXPERIMENTS}"
echo "  (${TOTAL_WORKLOADS} workloads × ${TOTAL_DELAYS} delays × ${TOTAL_TIMEOUTS} timeouts)"
echo ""
echo ">>> Workloads:"
for i in "${!WORKLOADS[@]}"; do
    IFS=',' read -r r s <<< "${WORKLOADS[$i]}"
    echo "    [$((i+1))] rate=${r} ops/s, size=${s} bytes"
done
echo ""
echo ">>> Network delays to test:"
for d in "${NETWORK_DELAYS[@]}"; do
    echo "    - ${d} ms"
done
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
ORIGINAL_TIMEOUT=$(grep 'system.totalordermulticast.timeout' config/system.config | awk -F'=' '{print $2}' | tr -d ' ')

# 外层按网络延迟分组（减少 tc netem 切换次数）
for delay in "${NETWORK_DELAYS[@]}"; do
    echo ""
    echo "============================================================"
    echo ">>> Network Delay: ${delay}ms"
    echo "============================================================"

    # 设置网络延迟
    set_network_delay "$delay"

    # 等待网络条件稳定
    sleep 3

    WORKLOAD_ID=0
    for wl in "${WORKLOADS[@]}"; do
        IFS=',' read -r rate request_size <<< "$wl"
        WORKLOAD_ID=$((WORKLOAD_ID + 1))

        echo ""
        echo "  --- Workload ${WORKLOAD_ID}/${TOTAL_WORKLOADS}: rate=${rate}, size=${request_size} ---"

        # 创建临时 workload 配置
        create_single_workload_config "$RUN_DURATION" "$rate" "$request_size"

        for rt in "${REQUEST_TIMEOUTS[@]}"; do
            EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
            EXP_KEY="d${delay}_w${rate}_${request_size}_rt${rt}"

            # 检查是否已完成
            if is_experiment_done "$EXP_KEY"; then
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                echo "  [SKIP] ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: delay=${delay}ms, rt=${rt}ms (already done)"
                continue
            fi

            echo ""
            echo "  --- Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS} ---"
            echo "    Network: delay=${delay}ms"
            echo "    Workload: rate=${rate}, size=${request_size}"
            echo "    Config: bs=${FIXED_BATCH_SIZE}, bt=${FIXED_BATCH_TIMEOUT}, rt=${rt}"

            # 更新 requestTimeout
            update_request_timeout "$rt"

            # 运行实验
            LOG_PREFIX="d${delay}_w${WORKLOAD_ID}_rt${rt}"

            echo "    Running lan_deploy.sh..."
            ./lan_deploy.sh "$FIXED_BATCH_SIZE" "$FIXED_BATCH_TIMEOUT" -1 "$SKIP_BUILD" "STATIC" "temp_net_timeout_workload.config" > "${EXPERIMENT_DIR}/logs/deploy_${LOG_PREFIX}.log" 2>&1 || {
                echo "    WARNING: lan_deploy.sh failed"
                echo "${WORKLOAD_ID},${rate},${request_size},${delay},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
                mark_experiment_done "$EXP_KEY"
                continue
            }

            # 解析 metrics
            SERVER_LOG="results/server_0.log"
            METRICS_TMP="${EXPERIMENT_DIR}/logs/metrics_${LOG_PREFIX}.tmp"

            echo "    Parsing metrics..."
            parse_server_log "$SERVER_LOG" "$METRICS_TMP"

            if [[ -f "$METRICS_TMP" ]]; then
                METRICS=$(cat "$METRICS_TMP")
                echo "${WORKLOAD_ID},${rate},${request_size},${delay},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},${METRICS}" >> "$RESULTS_CSV"
                rm -f "$METRICS_TMP"
            else
                echo "    WARNING: Failed to parse metrics"
                echo "${WORKLOAD_ID},${rate},${request_size},${delay},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
            fi

            # 保存日志
            cp "results/server_0.log" "${EXPERIMENT_DIR}/logs/server_${LOG_PREFIX}.log" 2>/dev/null || true
            cp "results/agent_0.log" "${EXPERIMENT_DIR}/logs/agent_${LOG_PREFIX}.log" 2>/dev/null || true
            cp "results/client.log" "${EXPERIMENT_DIR}/logs/client_${LOG_PREFIX}.log" 2>/dev/null || true

            mark_experiment_done "$EXP_KEY"

            # 后续跳过编译
            SKIP_BUILD="true"

            echo "    Done."
        done
    done
done

# ============= 清理 =============

# 恢复网络（移除人工延迟）
echo ""
echo ">>> Restoring network (removing artificial delay)..."
set_network_delay 0

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

# ============= 生成汇总报告 =============

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
        f.write("=" * 80 + "\n")
        f.write("Network Latency × RequestTimeout Benchmark Summary\n")
        f.write(f"Fixed: batchSize=${FIXED_BATCH_SIZE}, batchTimeout=${FIXED_BATCH_TIMEOUT}\n")
        f.write("=" * 80 + "\n\n")

        # —— 按 (workload, network_delay) 分组展示 ——
        groups = {}
        for row in rows:
            try:
                wid = row['workload_id']
                rate = row['rate']
                req_size = row['request_size']
                delay = int(row['network_delay_ms'])
                rt = int(row['request_timeout'])
                thr = float(row['avg_throughput'])
                lat = float(row['avg_latency_us'])

                group_key = (wid, rate, req_size, delay)
                if group_key not in groups:
                    groups[group_key] = []
                groups[group_key].append({'rt': rt, 'thr': thr, 'lat': lat})
            except Exception:
                pass

        for (wid, rate, req_size, delay), configs in sorted(groups.items(), key=lambda x: (x[0][0], x[0][3])):
            f.write(f"Workload {wid}: rate={rate} ops/s, size={req_size} bytes | Network Delay: {delay}ms\n")
            f.write("-" * 70 + "\n")
            f.write(f"  {'RequestTimeout(ms)':>20s}  {'Throughput(ops/s)':>18s}  {'Latency(us)':>14s}\n")
            f.write(f"  {'─' * 20}  {'─' * 18}  {'─' * 14}\n")

            for c in sorted(configs, key=lambda x: x['rt']):
                f.write(f"  {c['rt']:>20d}  {c['thr']:>18.2f}  {c['lat']:>14.2f}\n")

            valid = [c for c in configs if c['thr'] > 0]
            if valid:
                best_thr = max(valid, key=lambda x: x['thr'])
                best_lat = min(valid, key=lambda x: x['lat'])
                f.write(f"\n  Best Throughput: {best_thr['thr']:.2f} ops/s @ rt={best_thr['rt']}ms\n")
                f.write(f"  Best Latency:    {best_lat['lat']:.2f} us   @ rt={best_lat['rt']}ms\n")
            f.write("\n")

        # —— 跨延迟对比：同一 workload 下，不同延迟对最优 requestTimeout 的影响 ——
        f.write("=" * 80 + "\n")
        f.write("CROSS-DELAY COMPARISON: Best RequestTimeout per Network Delay\n")
        f.write("=" * 80 + "\n\n")

        # 按 workload 分组
        wl_groups = {}
        for (wid, rate, req_size, delay), configs in groups.items():
            wl_key = (wid, rate, req_size)
            if wl_key not in wl_groups:
                wl_groups[wl_key] = {}
            valid = [c for c in configs if c['thr'] > 0]
            if valid:
                best = max(valid, key=lambda x: x['thr'])
                wl_groups[wl_key][delay] = best

        for (wid, rate, req_size), delay_map in sorted(wl_groups.items()):
            f.write(f"Workload {wid}: rate={rate} ops/s, size={req_size} bytes\n")
            f.write("-" * 70 + "\n")
            f.write(f"  {'Delay(ms)':>12s}  {'Best RT(ms)':>12s}  {'Throughput':>14s}  {'Latency(us)':>14s}\n")
            f.write(f"  {'─' * 12}  {'─' * 12}  {'─' * 14}  {'─' * 14}\n")

            for delay in sorted(delay_map.keys()):
                best = delay_map[delay]
                f.write(f"  {delay:>12d}  {best['rt']:>12d}  {best['thr']:>14.2f}  {best['lat']:>14.2f}\n")

            # 检查 requestTimeout 是否因延迟变化而变化
            best_rts = [delay_map[d]['rt'] for d in sorted(delay_map.keys())]
            if len(set(best_rts)) > 1:
                f.write(f"\n  >>> FINDING: Best requestTimeout VARIES with network delay!\n")
                f.write(f"      Values: {best_rts}\n")
                f.write(f"      This confirms requestTimeout tuning IS effective under network variation.\n")
            else:
                f.write(f"\n  >>> FINDING: Best requestTimeout is constant ({best_rts[0]}ms) across delays.\n")
                f.write(f"      requestTimeout may not need dynamic tuning for this workload.\n")
            f.write("\n")

        # —— 关键发现总结 ——
        f.write("=" * 80 + "\n")
        f.write("KEY FINDINGS\n")
        f.write("=" * 80 + "\n\n")

        # 检测 requestTimeout 过小导致吞吐崩溃的案例
        crash_cases = []
        for (wid, rate, req_size, delay), configs in groups.items():
            for c in configs:
                if c['thr'] == 0 and c['rt'] < delay * 4:
                    crash_cases.append({
                        'wid': wid, 'rate': rate, 'delay': delay,
                        'rt': c['rt']
                    })

        if crash_cases:
            f.write("1. TIMEOUT TOO SMALL → System Crash Cases:\n")
            for cc in crash_cases:
                f.write(f"   - Workload {cc['wid']} (rate={cc['rate']}), delay={cc['delay']}ms, rt={cc['rt']}ms → thr=0\n")
            f.write(f"   Conclusion: requestTimeout < ~4× network_delay causes view change storms.\n\n")
        else:
            f.write("1. No system crash cases detected (all configs produced non-zero throughput).\n\n")

        # 检测延迟对吞吐的总体影响
        f.write("2. Network Delay Impact on Throughput (best config per delay):\n")
        for (wid, rate, req_size), delay_map in sorted(wl_groups.items()):
            delays_sorted = sorted(delay_map.keys())
            if len(delays_sorted) >= 2 and 0 in delay_map:
                baseline_thr = delay_map[0]['thr']
                if baseline_thr > 0:
                    f.write(f"   Workload {wid} (rate={rate}):\n")
                    for d in delays_sorted:
                        ratio = delay_map[d]['thr'] / baseline_thr * 100
                        f.write(f"     delay={d}ms: {delay_map[d]['thr']:.0f} ops/s ({ratio:.1f}% of baseline)\n")
            f.write("\n")

        f.write("=" * 80 + "\n")

    print(f"Summary saved to {summary_file}")

    # 打印到终端
    with open(summary_file, 'r') as f:
        print(f.read())

except Exception as e:
    print(f"Error generating summary: {e}")
    import traceback
    traceback.print_exc()
PYEOF

echo ""
echo "Done!"

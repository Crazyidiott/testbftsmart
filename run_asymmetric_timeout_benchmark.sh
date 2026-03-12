#!/bin/bash
# ==============================================================================
# run_asymmetric_timeout_benchmark.sh - 非对称延迟 × RequestTimeout 基准测试
# ==============================================================================
#
# 功能：
#   只对 leader (Node 0) 注入高延迟，其他 replica (Node 1/2/3) 保持低延迟。
#   固定 batchSize 和 batchTimeout，遍历不同的 requestTimeout 值，
#   验证：当旧 leader 网络慢时，较小的 requestTimeout 能触发 view change
#   切换到快节点，从而用 3/4 节点(f=1,n=4)快速达成共识。
#
# 核心假设：
#   - Node 0 = 初始 leader
#   - Node 0 延迟高 → 整体共识慢（PROPOSE/WRITE 消息延迟高）
#   - 小 requestTimeout → 触发 view change → leader 切换到 Node 1
#   - Node 1/2/3 之间低延迟 → 共识只需 3 节点 → 吞吐恢复
#   - 大 requestTimeout → 不触发 view change → 忍受高延迟
#
# 实验矩阵：
#   leader 延迟 × requestTimeout = N 组实验（固定单一 workload）
#
# 使用方式：
#   ./run_asymmetric_timeout_benchmark.sh [SkipBuild] [ResumeDir]
#
# 输出：
#   - asymmetric_timeout_benchmark_results/<experiment>/results.csv
#   - asymmetric_timeout_benchmark_results/<experiment>/summary.txt
#   - asymmetric_timeout_benchmark_results/<experiment>/logs/
#
# ==============================================================================

set -e

# ============= 配置参数 =============

# 固定的 batchSize 和 batchTimeout
FIXED_BATCH_SIZE=500
FIXED_BATCH_TIMEOUT=100

# 只对 leader (Node 0) 注入的延迟值（ms）
# 其他 replica 节点保持 0ms 延迟
LEADER_DELAYS=(0 50 100 200 500)

# 要测试的 requestTimeout 值列表（ms）
REQUEST_TIMEOUTS=(500 1000 2000 5000 10000)

# 固定的 workload: "rate, request_size"
# 使用中等负载以清晰观测 view change 的效果
WORKLOAD_RATE=1000
WORKLOAD_SIZE=512

# 是否跳过编译
SKIP_BUILD="${1:-false}"

# 断点续跑
RESUME_DIR="${2:-}"

# 每个配置的运行时间（秒）
RUN_DURATION=90

# 结果目录
RESULTS_DIR="asymmetric_timeout_benchmark_results"

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
TEMP_WORKLOAD_CONFIG="config/workloads/temp_asymmetric_workload.config"

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

# 设置非对称延迟：只对 Node 0 注入延迟
set_asymmetric_delay() {
    local leader_delay=$1
    echo "  Setting asymmetric delay: Node 0=${leader_delay}ms, Node 1/2/3=0ms..."
    ./set_asymmetric_latency.sh "$leader_delay" 0 0 0
}

# 从 server log 提取 metrics
parse_server_log() {
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
    while len(throughputs) > 5 and throughputs[-1] == 0.0:
        throughputs.pop()
        latencies.pop()
        avg_sizes.pop()
        arrival_rates.pop()
        mem_used.pop()
        mem_max.pop()
        mem_percent.pop()

    n = len(throughputs)
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

# 从 server log 提取 view change 统计
parse_view_changes() {
    local log_dir=$1
    local output_file=$2

    python3 << PYEOF
import re
import os

log_dir = "$log_dir"
output_file = "$output_file"

# Scan all 4 server logs for view change events
total_view_changes = 0
view_change_starts = []
regency_installs = []

for i in range(4):
    log_file = os.path.join(log_dir, f"server_{i}.log")
    if not os.path.exists(log_file):
        continue

    try:
        with open(log_file, 'r') as f:
            for line in f:
                # View change initiated
                if 'View Change STARTED' in line:
                    total_view_changes += 1
                    # Extract timestamp if available
                    m = re.search(r'View Change STARTED at (\d+)', line)
                    if m:
                        view_change_starts.append(int(m.group(1)))

                # Regency installed (view change completed)
                if 'Sending STOP message to install regency' in line:
                    m = re.search(r'install regency (\d+)', line)
                    if m:
                        regency_installs.append(int(m.group(1)))

    except Exception as e:
        print(f"Error scanning {log_file}: {e}")

# Deduplicate: each view change is seen by multiple replicas
# The real count is the max regency reached
if regency_installs:
    max_regency = max(regency_installs)
else:
    max_regency = 0

with open(output_file, 'w') as f:
    f.write(f"{total_view_changes},{max_regency}\n")

print(f"View change events: {total_view_changes} total log entries, max regency={max_regency}")
PYEOF
}

# ============= 主逻辑 =============

echo "============================================================"
echo "  Asymmetric Latency × RequestTimeout Benchmark Suite"
echo "============================================================"
echo "Fixed: batchSize=${FIXED_BATCH_SIZE}, batchTimeout=${FIXED_BATCH_TIMEOUT}"
echo "Workload: rate=${WORKLOAD_RATE} ops/s, size=${WORKLOAD_SIZE} bytes"
echo "Leader (Node 0) delays: ${LEADER_DELAYS[*]} ms"
echo "RequestTimeout values: ${REQUEST_TIMEOUTS[*]} ms"
echo "Run duration per experiment: ${RUN_DURATION}s"
echo "Results will be saved to: ${EXPERIMENT_DIR}"
echo "Skip Build: ${SKIP_BUILD}"
echo "Resume Mode: ${RESUME_MODE}"
echo ""

# 创建结果目录
mkdir -p "${EXPERIMENT_DIR}/logs"

# 初始化结果 CSV
RESULTS_CSV="${EXPERIMENT_DIR}/results.csv"
if [[ "$RESUME_MODE" == false ]] || [[ ! -f "$RESULTS_CSV" ]]; then
    echo "leader_delay_ms,request_timeout,batch_size,batch_timeout,workload_rate,workload_size,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count,view_change_log_entries,max_regency" > "$RESULTS_CSV"
fi

# 显示续跑进度
if [[ "$RESUME_MODE" == true ]] && [[ -f "$PROGRESS_FILE" ]]; then
    COMPLETED_COUNT=$(wc -l < "$PROGRESS_FILE" 2>/dev/null || echo "0")
    echo ">>> Resume mode: ${COMPLETED_COUNT} experiments already completed"
fi

# 计算总实验数
TOTAL_DELAYS=${#LEADER_DELAYS[@]}
TOTAL_TIMEOUTS=${#REQUEST_TIMEOUTS[@]}
TOTAL_EXPERIMENTS=$((TOTAL_DELAYS * TOTAL_TIMEOUTS))

echo ""
echo "============================================================"
echo "Total experiments to run: ${TOTAL_EXPERIMENTS}"
echo "  (${TOTAL_DELAYS} leader delays × ${TOTAL_TIMEOUTS} requestTimeout values)"
echo ""
echo ">>> Leader (Node 0) delays to test:"
for d in "${LEADER_DELAYS[@]}"; do
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

# 创建固定的 workload 配置
create_single_workload_config "$RUN_DURATION" "$WORKLOAD_RATE" "$WORKLOAD_SIZE"
echo ">>> Created workload config: rate=${WORKLOAD_RATE}, size=${WORKLOAD_SIZE}, duration=${RUN_DURATION}s"

EXPERIMENT_COUNT=0
SKIPPED_COUNT=0
ORIGINAL_TIMEOUT=$(grep 'system.totalordermulticast.timeout' config/system.config | awk -F'=' '{print $2}' | tr -d ' ')

# 外层按 leader 延迟分组（减少 tc netem 切换次数）
for leader_delay in "${LEADER_DELAYS[@]}"; do
    echo ""
    echo "============================================================"
    echo ">>> Leader Delay: ${leader_delay}ms (Node 1/2/3 = 0ms)"
    echo "============================================================"

    # 设置非对称延迟
    set_asymmetric_delay "$leader_delay"

    # 等待网络条件稳定
    sleep 3

    for rt in "${REQUEST_TIMEOUTS[@]}"; do
        EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
        EXP_KEY="ld${leader_delay}_rt${rt}"

        # 检查是否已完成
        if is_experiment_done "$EXP_KEY"; then
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            echo "  [SKIP] ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: leader_delay=${leader_delay}ms, rt=${rt}ms (already done)"
            continue
        fi

        echo ""
        echo "  --- Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS} ---"
        echo "    Leader delay: ${leader_delay}ms"
        echo "    Config: bs=${FIXED_BATCH_SIZE}, bt=${FIXED_BATCH_TIMEOUT}, rt=${rt}ms"
        echo "    Workload: rate=${WORKLOAD_RATE}, size=${WORKLOAD_SIZE}"

        # 更新 requestTimeout
        update_request_timeout "$rt"

        # 运行实验
        LOG_PREFIX="ld${leader_delay}_rt${rt}"

        echo "    Running lan_deploy.sh..."
        ./lan_deploy.sh "$FIXED_BATCH_SIZE" "$FIXED_BATCH_TIMEOUT" -1 "$SKIP_BUILD" "STATIC" "temp_asymmetric_workload.config" > "${EXPERIMENT_DIR}/logs/deploy_${LOG_PREFIX}.log" 2>&1 || {
            echo "    WARNING: lan_deploy.sh failed"
            echo "${leader_delay},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},${WORKLOAD_RATE},${WORKLOAD_SIZE},0,0,0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
            mark_experiment_done "$EXP_KEY"
            continue
        }

        # 保存所有 server 日志（用于 view change 分析）
        for sid in 0 1 2 3; do
            cp "results/server_${sid}.log" "${EXPERIMENT_DIR}/logs/server_${sid}_${LOG_PREFIX}.log" 2>/dev/null || true
        done
        cp "results/agent_0.log" "${EXPERIMENT_DIR}/logs/agent_${LOG_PREFIX}.log" 2>/dev/null || true
        cp "results/client.log" "${EXPERIMENT_DIR}/logs/client_${LOG_PREFIX}.log" 2>/dev/null || true

        # 解析主 metrics（从 server_0 / leader 的 agent log）
        SERVER_LOG="results/server_0.log"
        METRICS_TMP="${EXPERIMENT_DIR}/logs/metrics_${LOG_PREFIX}.tmp"
        echo "    Parsing metrics..."
        parse_server_log "$SERVER_LOG" "$METRICS_TMP"

        # 解析 view change 统计（扫描所有 server logs）
        VC_TMP="${EXPERIMENT_DIR}/logs/vc_${LOG_PREFIX}.tmp"
        # Create a temporary directory with symlinks for the parse function
        VC_LOG_DIR="${EXPERIMENT_DIR}/logs/vc_scan_${LOG_PREFIX}"
        mkdir -p "$VC_LOG_DIR"
        for sid in 0 1 2 3; do
            if [[ -f "${EXPERIMENT_DIR}/logs/server_${sid}_${LOG_PREFIX}.log" ]]; then
                ln -sf "$(realpath "${EXPERIMENT_DIR}/logs/server_${sid}_${LOG_PREFIX}.log")" "${VC_LOG_DIR}/server_${sid}.log"
            fi
        done
        parse_view_changes "$VC_LOG_DIR" "$VC_TMP"
        rm -rf "$VC_LOG_DIR"

        # 合并到 CSV
        if [[ -f "$METRICS_TMP" ]] && [[ -f "$VC_TMP" ]]; then
            METRICS=$(cat "$METRICS_TMP")
            VC_DATA=$(cat "$VC_TMP")
            echo "${leader_delay},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},${WORKLOAD_RATE},${WORKLOAD_SIZE},${METRICS},${VC_DATA}" >> "$RESULTS_CSV"
            rm -f "$METRICS_TMP" "$VC_TMP"
        else
            echo "    WARNING: Failed to parse metrics or view changes"
            echo "${leader_delay},${rt},${FIXED_BATCH_SIZE},${FIXED_BATCH_TIMEOUT},${WORKLOAD_RATE},${WORKLOAD_SIZE},0,0,0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
            rm -f "$METRICS_TMP" "$VC_TMP"
        fi

        mark_experiment_done "$EXP_KEY"

        # 后续跳过编译
        SKIP_BUILD="true"

        echo "    Done."
    done
done

# ============= 清理 =============

# 恢复网络
echo ""
echo ">>> Restoring network (removing asymmetric delay)..."
set_asymmetric_delay 0

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
        f.write("Asymmetric Latency × RequestTimeout Benchmark Summary\n")
        f.write(f"Fixed: batchSize=${FIXED_BATCH_SIZE}, batchTimeout=${FIXED_BATCH_TIMEOUT}\n")
        f.write(f"Workload: rate=${WORKLOAD_RATE} ops/s, size=${WORKLOAD_SIZE} bytes\n")
        f.write(f"Duration per experiment: ${RUN_DURATION}s\n")
        f.write("Topology: Node 0 (leader) has extra delay, Node 1/2/3 have 0ms delay\n")
        f.write("=" * 80 + "\n\n")

        # ── 按 leader_delay 分组展示 ──
        groups = {}
        for row in rows:
            try:
                ld = int(row['leader_delay_ms'])
                rt = int(row['request_timeout'])
                thr = float(row['avg_throughput'])
                lat = float(row['avg_latency_us'])
                vc_entries = int(row['view_change_log_entries'])
                max_reg = int(row['max_regency'])

                if ld not in groups:
                    groups[ld] = []
                groups[ld].append({
                    'rt': rt, 'thr': thr, 'lat': lat,
                    'vc_entries': vc_entries, 'max_reg': max_reg
                })
            except Exception:
                pass

        for ld in sorted(groups.keys()):
            configs = groups[ld]
            f.write(f"Leader Delay: {ld}ms (Node 0 only)\n")
            f.write("-" * 75 + "\n")
            f.write(f"  {'RT(ms)':>8s}  {'Throughput':>14s}  {'Latency(us)':>14s}  {'VCLogEntries':>12s}  {'MaxRegency':>10s}\n")
            f.write(f"  {'─'*8}  {'─'*14}  {'─'*14}  {'─'*12}  {'─'*10}\n")

            for c in sorted(configs, key=lambda x: x['rt']):
                f.write(f"  {c['rt']:>8d}  {c['thr']:>14.2f}  {c['lat']:>14.2f}  {c['vc_entries']:>12d}  {c['max_reg']:>10d}\n")

            valid = [c for c in configs if c['thr'] > 0]
            if valid:
                best_thr = max(valid, key=lambda x: x['thr'])
                best_lat = min(valid, key=lambda x: x['lat'])
                f.write(f"\n  Best Throughput: {best_thr['thr']:.2f} ops/s @ rt={best_thr['rt']}ms (view changes={best_thr['max_reg']})\n")
                f.write(f"  Best Latency:    {best_lat['lat']:.2f} us   @ rt={best_lat['rt']}ms (view changes={best_lat['max_reg']})\n")
            f.write("\n")

        # ── 关键分析：View Change 触发的影响 ──
        f.write("=" * 80 + "\n")
        f.write("KEY ANALYSIS: View Change Impact\n")
        f.write("=" * 80 + "\n\n")

        # 对每个 leader_delay > 0，比较触发 VC 和未触发 VC 的性能差异
        baseline_thr = None
        baseline_lat = None
        if 0 in groups:
            valid_baseline = [c for c in groups[0] if c['thr'] > 0]
            if valid_baseline:
                # Use the largest RT (most stable) as baseline
                baseline_entry = max(valid_baseline, key=lambda x: x['rt'])
                baseline_thr = baseline_entry['thr']
                baseline_lat = baseline_entry['lat']
                f.write(f"Baseline (0ms delay, rt={baseline_entry['rt']}ms): "
                        f"thr={baseline_thr:.2f}, lat={baseline_lat:.2f} us\n\n")

        for ld in sorted(groups.keys()):
            if ld == 0:
                continue

            configs = groups[ld]
            valid = [c for c in configs if c['thr'] > 0]
            if not valid:
                continue

            vc_configs = [c for c in valid if c['max_reg'] > 0]
            no_vc_configs = [c for c in valid if c['max_reg'] == 0]

            f.write(f"Leader Delay = {ld}ms:\n")

            if no_vc_configs:
                best_no_vc = max(no_vc_configs, key=lambda x: x['thr'])
                f.write(f"  Without View Change (best): rt={best_no_vc['rt']}ms → "
                        f"thr={best_no_vc['thr']:.2f}, lat={best_no_vc['lat']:.2f} us\n")

            if vc_configs:
                best_vc = max(vc_configs, key=lambda x: x['thr'])
                f.write(f"  With View Change (best):    rt={best_vc['rt']}ms → "
                        f"thr={best_vc['thr']:.2f}, lat={best_vc['lat']:.2f} us "
                        f"(regency={best_vc['max_reg']})\n")

                if no_vc_configs:
                    thr_gain = best_vc['thr'] - best_no_vc['thr']
                    lat_gain = best_no_vc['lat'] - best_vc['lat']
                    f.write(f"  >>> Throughput gain from VC: {thr_gain:+.2f} ops/s "
                            f"({thr_gain/best_no_vc['thr']*100 if best_no_vc['thr'] > 0 else 0:+.1f}%)\n")
                    f.write(f"  >>> Latency reduction from VC: {lat_gain:+.2f} us "
                            f"({lat_gain/best_no_vc['lat']*100 if best_no_vc['lat'] > 0 else 0:+.1f}%)\n")

            # Detect excessive view changes (too small RT)
            excessive_vc = [c for c in valid if c['max_reg'] > 2]
            if excessive_vc:
                worst = min(excessive_vc, key=lambda x: x['thr'])
                f.write(f"  >>> WARNING: Excessive view changes at rt={worst['rt']}ms "
                        f"(regency={worst['max_reg']}), thr={worst['thr']:.2f} "
                        f"- requestTimeout too small!\n")

            f.write("\n")

        # ── 最佳 requestTimeout 选择总结 ──
        f.write("=" * 80 + "\n")
        f.write("OPTIMAL requestTimeout per Leader Delay\n")
        f.write("=" * 80 + "\n\n")
        f.write(f"  {'LeaderDelay':>12s}  {'BestRT(ms)':>12s}  {'Throughput':>14s}  {'Latency(us)':>14s}  {'ViewChanges':>12s}\n")
        f.write(f"  {'─'*12}  {'─'*12}  {'─'*14}  {'─'*14}  {'─'*12}\n")

        best_rts = []
        for ld in sorted(groups.keys()):
            valid = [c for c in groups[ld] if c['thr'] > 0]
            if valid:
                best = max(valid, key=lambda x: x['thr'])
                best_rts.append(best['rt'])
                f.write(f"  {ld:>12d}  {best['rt']:>12d}  {best['thr']:>14.2f}  {best['lat']:>14.2f}  {best['max_reg']:>12d}\n")

        f.write("\n")
        if len(set(best_rts)) > 1:
            f.write(">>> CONCLUSION: Optimal requestTimeout VARIES with leader network delay!\n")
            f.write("    This confirms dynamic requestTimeout tuning can improve performance\n")
            f.write("    when network conditions are asymmetric.\n")
        elif best_rts:
            f.write(f">>> CONCLUSION: Optimal requestTimeout is constant ({best_rts[0]}ms)\n")
            f.write("    across all tested leader delays.\n")

        f.write("\n")

        # ── 判断 view change 是否有益 ──
        f.write("=" * 80 + "\n")
        f.write("VIEW CHANGE BENEFIT ANALYSIS\n")
        f.write("=" * 80 + "\n\n")

        for ld in sorted(groups.keys()):
            if ld == 0:
                continue
            configs = groups[ld]
            valid = [c for c in configs if c['thr'] > 0]
            if not valid:
                continue

            f.write(f"Leader Delay = {ld}ms:\n")
            for c in sorted(valid, key=lambda x: x['rt']):
                vc_label = "VC" if c['max_reg'] > 0 else "NO-VC"
                bar_len = int(c['thr'] / max(cc['thr'] for cc in valid) * 40) if max(cc['thr'] for cc in valid) > 0 else 0
                bar = '█' * bar_len
                f.write(f"  rt={c['rt']:>6d}ms [{vc_label:>5s}] thr={c['thr']:>8.2f}  {bar}\n")
            f.write("\n")

        f.write("=" * 80 + "\n")

    print(f"Summary saved to {summary_file}")

    with open(summary_file, 'r') as f:
        print(f.read())

except Exception as e:
    print(f"Error generating summary: {e}")
    import traceback
    traceback.print_exc()
PYEOF

echo "Done."

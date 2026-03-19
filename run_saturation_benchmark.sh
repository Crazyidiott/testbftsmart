#!/bin/bash
# ==============================================================================
# run_saturation_benchmark.sh - 饱和吞吐量测试脚本
# ==============================================================================
#
# 功能：
#   通过逐步提高客户端发送速率，找到系统在不同配置下的饱和吞吐量。
#   饱和吞吐定义：系统实际吞吐无法跟上客户端到达速率的临界点。
#
# 原理：
#   在低负载时，系统吞吐 ≈ 到达速率（系统未饱和）。
#   随着到达速率增加，系统吞吐在某个点开始无法跟上，出现处理积压，
#   延迟急剧上升——该点即为饱和吞吐量。
#
#   检测标准：当 avg_throughput / target_rate < SATURATION_THRESHOLD 时，
#   认为系统在该速率下已饱和。
#
# 使用方式：
#   ./run_saturation_benchmark.sh [SkipBuild] [ResumeDir]
#   例如：
#     ./run_saturation_benchmark.sh                    # 首次运行
#     ./run_saturation_benchmark.sh true               # 跳过编译
#     ./run_saturation_benchmark.sh true experiment_20260312_150000  # 续跑
#
# 输出：
#   - saturation_benchmark_results/<experiment>/results.csv
#   - saturation_benchmark_results/<experiment>/saturation_summary.txt
#   - saturation_benchmark_results/<experiment>/logs/
#
# ==============================================================================

set -e

source ./lan_connection.sh

# ============= 配置参数 =============

# 要测试的 (batchSize, batchTimeout) 配置列表
BATCH_CONFIGS=(
    "100,50"      # 小批次短超时
    "500,100"     # 中等配置（常用基准）
    "1000,100"    # 大批次中等超时
)

# 要测试的消息大小 (bytes)
MESSAGE_SIZES=(512 1024)

# 逐步递增的目标发送速率 (ops/s，必须升序排列)
RATES=(2000 3000 4000 5000 6000 7000 8000 9000 10000)

# 饱和检测阈值：当 throughput / target_rate < 此值时认为已饱和
SATURATION_THRESHOLD=0.85

# 连续多少次达到饱和后提前终止该配置的测试 (0 = 不提前终止，跑完所有速率)
EARLY_STOP_COUNT=2

# 预热时间 (秒) - 让客户端连接建立并达到目标速率
WARMUP_DURATION=15

# 每个配置的测量时间 (秒)
RUN_DURATION=30

# 是否跳过编译
SKIP_BUILD="${1:-false}"

# 断点续跑
RESUME_DIR="${2:-}"

# 结果目录
RESULTS_DIR="saturation_benchmark_results"

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
TEMP_WORKLOAD_CONFIG="config/workloads/temp_saturation_workload.config"

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

# 标记某个 (bs, bt, size) 配置已饱和，后续速率全部跳过
mark_config_saturated() {
    local config_key=$1
    echo "SATURATED_${config_key}" >> "$PROGRESS_FILE"
}

is_config_saturated() {
    local config_key=$1
    if [[ -f "$PROGRESS_FILE" ]] && grep -q "^SATURATED_${config_key}$" "$PROGRESS_FILE" 2>/dev/null; then
        return 0
    fi
    return 1
}

# 创建单一 workload 的临时配置文件
create_single_workload_config() {
    local warmup=$1
    local duration=$2
    local rate=$3
    local request_size=$4
    local num_threads=20
    local rate_warmup=10  # 预热阶段使用较低速率，帮助系统稳定连接和状态
    local rate_per_thread=$((rate / num_threads))

    echo "# Duration(s), Rate(ops/sec per thread), RequestSize(bytes)" > "$TEMP_WORKLOAD_CONFIG"
    echo "# Phase 1: warmup" >> "$TEMP_WORKLOAD_CONFIG"
    echo "${warmup}, ${rate_warmup}, ${request_size}" >> "$TEMP_WORKLOAD_CONFIG"
    echo "# Phase 2: measurement" >> "$TEMP_WORKLOAD_CONFIG"
    echo "${duration}, ${rate_per_thread}, ${request_size}" >> "$TEMP_WORKLOAD_CONFIG"
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
    # 跳过预热阶段的样本 (WARMUP_DURATION秒 + 5个额外缓冲)
    warmup_duration = int("${WARMUP_DURATION}")
    skip = min(warmup_duration + 5, n // 2)
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
        print(f"Parsed {n} samples: thr={avg_thr:.2f}, lat={avg_lat:.2f}, arrival={avg_arrival:.2f}")
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

# 解析 client log 提取 Phase 2 发送速率统计
parse_client_log_phase2() {
    local log_file=$1
    local output_file=$2

    python3 << PYEOF
import re
import sys

log_file = "$log_file"
output_file = "$output_file"

phase2_started = False
rates = []
final_avg_send_rate = 0.0

throughput_pattern = re.compile(r'\[Total Client Throughput\]\s+([0-9]+)\s+ops/sec')
final_avg_pattern = re.compile(r'\[Client Workload\] Average send rate:\s+([0-9.]+)\s+ops/sec')

try:
    with open(log_file, 'r') as f:
        for raw_line in f:
            line = raw_line.strip()

            m_final = final_avg_pattern.search(line)
            if m_final:
                final_avg_send_rate = float(m_final.group(1))

            if 'Starting Phase 2:' in line:
                phase2_started = True
                continue

            if '[Client Workload] FINAL STATISTICS' in line:
                break

            if phase2_started:
                m_thr = throughput_pattern.search(line)
                if m_thr:
                    rates.append(float(m_thr.group(1)))
except Exception as e:
    print(f"Error parsing {log_file}: {e}", file=sys.stderr)

if rates:
    avg_rate = sum(rates) / len(rates)
    min_rate = min(rates)
    max_rate = max(rates)
    with open(output_file, 'w') as f:
        f.write(f"{avg_rate:.2f},{min_rate:.0f},{max_rate:.0f},{len(rates)},{final_avg_send_rate:.2f}\n")
    print(f"Parsed client phase2 rates: avg={avg_rate:.2f}, min={min_rate:.0f}, max={max_rate:.0f}, samples={len(rates)}")
else:
    with open(output_file, 'w') as f:
        f.write(f"0,0,0,0,{final_avg_send_rate:.2f}\n")
    print("No phase2 throughput samples found in client log")
PYEOF
}

# ============= 主逻辑 =============

echo "============================================================"
echo "       Saturation Throughput Benchmark Suite"
echo "============================================================"
echo "Results will be saved to: ${EXPERIMENT_DIR}"
echo "Skip Build: ${SKIP_BUILD}"
echo "Resume Mode: ${RESUME_MODE}"
echo "Saturation Threshold: ${SATURATION_THRESHOLD}"
echo "Early Stop Count: ${EARLY_STOP_COUNT} (0=disabled)"
echo "Warmup Duration: ${WARMUP_DURATION}s"
echo ""

# 创建结果目录
mkdir -p "${EXPERIMENT_DIR}/logs"

# 初始化结果 CSV
RESULTS_CSV="${EXPERIMENT_DIR}/results.csv"
if [[ "$RESUME_MODE" == false ]] || [[ ! -f "$RESULTS_CSV" ]]; then
    echo "batch_size,batch_timeout,message_size,target_rate,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count,client_phase2_avg_send_rate,client_phase2_min_send_rate,client_phase2_max_send_rate,client_phase2_sample_count,client_final_avg_send_rate" > "$RESULTS_CSV"
fi

# 显示续跑进度
if [[ "$RESUME_MODE" == true ]] && [[ -f "$PROGRESS_FILE" ]]; then
    COMPLETED_COUNT=$(grep -cv '^SATURATED_' "$PROGRESS_FILE" 2>/dev/null || echo "0")
    echo ">>> Resume mode: ${COMPLETED_COUNT} experiments already completed"
fi

# 计算总实验数（上限，实际可能因提前终止而减少）
TOTAL_CONFIGS=${#BATCH_CONFIGS[@]}
TOTAL_SIZES=${#MESSAGE_SIZES[@]}
TOTAL_RATES=${#RATES[@]}
TOTAL_EXPERIMENTS=$((TOTAL_CONFIGS * TOTAL_SIZES * TOTAL_RATES))

echo ""
echo ">>> Experiment Plan:"
echo "    Batch configs: ${#BATCH_CONFIGS[@]}"
for i in "${!BATCH_CONFIGS[@]}"; do
    IFS=',' read -r bs bt <<< "${BATCH_CONFIGS[$i]}"
    echo "      [$((i+1))] batch_size=${bs}, batch_timeout=${bt}"
done
echo "    Message sizes: ${MESSAGE_SIZES[*]} bytes"
echo "    Rate sweep: ${RATES[*]} ops/s"
echo "    Max experiments: ${TOTAL_EXPERIMENTS}"
echo "      (${TOTAL_CONFIGS} configs × ${TOTAL_SIZES} sizes × ${TOTAL_RATES} rates)"
echo "    Warmup: ${WARMUP_DURATION}s + Measurement: ${RUN_DURATION}s per experiment"
echo ""

read -p "Press Enter to start, or Ctrl+C to abort..."

# ============= 运行实验 =============

EXPERIMENT_COUNT=0
SKIPPED_COUNT=0

for msg_size in "${MESSAGE_SIZES[@]}"; do
    echo ""
    echo "============================================================"
    echo ">>> Message Size: ${msg_size} bytes"
    echo "============================================================"

    for cfg in "${BATCH_CONFIGS[@]}"; do
        IFS=',' read -r bs bt <<< "$cfg"

        CONFIG_KEY="bs${bs}_bt${bt}_sz${msg_size}"

        echo ""
        echo "  --- Config: batch_size=${bs}, batch_timeout=${bt}, msg_size=${msg_size} ---"

        # 检查该配置是否已因饱和而被提前终止过（续跑时跳过）
        if is_config_saturated "$CONFIG_KEY"; then
            # 计算该配置剩余的实验数并计入跳过
            for rate in "${RATES[@]}"; do
                EXP_KEY="${CONFIG_KEY}_r${rate}"
                if ! is_experiment_done "$EXP_KEY"; then
                    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                fi
                EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
            done
            echo "    [SKIP] Config already marked as saturated in previous run"
            continue
        fi

        CONSECUTIVE_SATURATED=0

        for rate in "${RATES[@]}"; do
            EXPERIMENT_COUNT=$((EXPERIMENT_COUNT + 1))
            EXP_KEY="${CONFIG_KEY}_r${rate}"

            # 检查是否已完成
            if is_experiment_done "$EXP_KEY"; then
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                echo "    [SKIP] ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: rate=${rate} (already done)"
                continue
            fi

            # 检查是否已因提前终止而需跳过
            if [[ "$EARLY_STOP_COUNT" -gt 0 ]] && [[ "$CONSECUTIVE_SATURATED" -ge "$EARLY_STOP_COUNT" ]]; then
                SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                echo "    [EARLY_STOP] ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS}: rate=${rate} (saturated at lower rate)"
                mark_experiment_done "$EXP_KEY"
                continue
            fi

            echo ""
            echo "    --- Experiment ${EXPERIMENT_COUNT}/${TOTAL_EXPERIMENTS} ---"
            echo "      Config: bs=${bs}, bt=${bt}, msg_size=${msg_size}"
            echo "      Target rate: ${rate} ops/s"

            # 创建临时 workload 配置（预热 + 测量两阶段）
            create_single_workload_config "$WARMUP_DURATION" "$RUN_DURATION" "$rate" "$msg_size"

            # 日志文件命名
            LOG_PREFIX="${CONFIG_KEY}_r${rate}"

            # 运行实验 (STATIC 模式)
            echo "      Running lan_deploy.sh..."
            ./lan_deploy.sh "$bs" "$bt" -1 "$SKIP_BUILD" "STATIC" "temp_saturation_workload.config" > "${EXPERIMENT_DIR}/logs/deploy_${LOG_PREFIX}.log" 2>&1 || {
                echo "      WARNING: lan_deploy.sh failed for this experiment"
                echo "${bs},${bt},${msg_size},${rate},0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
                mark_experiment_done "$EXP_KEY"
                continue
            }

            # 解析 server log
            SERVER_LOG="results/server_0.log"
            METRICS_TMP="${EXPERIMENT_DIR}/logs/metrics_${LOG_PREFIX}.tmp"

            echo "      Parsing metrics..."
            parse_server_log "$SERVER_LOG" "$METRICS_TMP"

            # 读取解析结果
            if [[ -f "$METRICS_TMP" ]]; then
                METRICS=$(cat "$METRICS_TMP")

                # 解析 client phase2 发送速率（避免被warmup与尾部收尾影响）
                CLIENT_LOG="results/client.log"
                CLIENT_METRICS_TMP="${EXPERIMENT_DIR}/logs/client_metrics_${LOG_PREFIX}.tmp"
                parse_client_log_phase2 "$CLIENT_LOG" "$CLIENT_METRICS_TMP"

                CLIENT_METRICS="0,0,0,0,0"
                if [[ -f "$CLIENT_METRICS_TMP" ]]; then
                    CLIENT_METRICS=$(cat "$CLIENT_METRICS_TMP")
                    rm -f "$CLIENT_METRICS_TMP"
                fi

                echo "${bs},${bt},${msg_size},${rate},${METRICS},${CLIENT_METRICS}" >> "$RESULTS_CSV"

                # 提取 avg_throughput 和 avg_arrival_rate 用于饱和检测
                AVG_THR=$(echo "$METRICS" | cut -d',' -f1)
                AVG_ARRIVAL=$(echo "$METRICS" | cut -d',' -f4)
                # 计算饱和比率
                SAT_RATIO=$(python3 -c "
thr = float('${AVG_THR}')
rate = float('${rate}')
ratio = thr / rate if rate > 0 else 0
print(f'{ratio:.4f}')
")
                # 检测客户端是否达到了目标速率 (arrival_rate vs target_rate)
                CLIENT_RATIO=$(python3 -c "
arrival = float('${AVG_ARRIVAL}')
rate = float('${rate}')
ratio = arrival / rate if rate > 0 else 0
print(f'{ratio:.4f}')
")
                echo "      Saturation ratio: ${SAT_RATIO} (threshold: ${SATURATION_THRESHOLD})"
                echo "      Client delivery ratio: ${CLIENT_RATIO} (arrival_rate/target_rate)"

                # 检测是否饱和：需要区分真饱和 vs 客户端瓶颈
                IS_SATURATED=$(python3 -c "
sat_ratio = float('${SAT_RATIO}')
client_ratio = float('${CLIENT_RATIO}')
threshold = float('${SATURATION_THRESHOLD}')
if sat_ratio < threshold:
    if client_ratio < threshold:
        # 客户端自身也达不到目标速率，不算真饱和
        print('client_bottleneck')
    else:
        # 客户端发够了但服务端跟不上，真饱和
        print('yes')
else:
    print('no')
")

                if [[ "$IS_SATURATED" == "yes" ]]; then
                    CONSECUTIVE_SATURATED=$((CONSECUTIVE_SATURATED + 1))
                    echo "      >>> SATURATED (${CONSECUTIVE_SATURATED}/${EARLY_STOP_COUNT})"
                elif [[ "$IS_SATURATED" == "client_bottleneck" ]]; then
                    CONSECUTIVE_SATURATED=$((CONSECUTIVE_SATURATED + 1))
                    echo "      >>> CLIENT BOTTLENECK - client can't reach target rate (${CONSECUTIVE_SATURATED}/${EARLY_STOP_COUNT})"
                else
                    CONSECUTIVE_SATURATED=0
                fi

                rm -f "$METRICS_TMP"
            else
                echo "      WARNING: Failed to parse metrics"
                echo "${bs},${bt},${msg_size},${rate},0,0,0,0,0,0,0,0,0,0,0,0,0" >> "$RESULTS_CSV"
            fi

            # 保存日志
            cp "results/server_0.log" "${EXPERIMENT_DIR}/logs/server_${LOG_PREFIX}.log" 2>/dev/null || true
            cp "results/agent_0.log" "${EXPERIMENT_DIR}/logs/agent_${LOG_PREFIX}.log" 2>/dev/null || true
            cp "results/client.log" "${EXPERIMENT_DIR}/logs/client_${LOG_PREFIX}.log" 2>/dev/null || true

            mark_experiment_done "$EXP_KEY"

            # 第一次实验后跳过编译
            SKIP_BUILD="true"

            echo "      Done."
        done

        # 如果因提前终止跳出，标记该配置
        if [[ "$EARLY_STOP_COUNT" -gt 0 ]] && [[ "$CONSECUTIVE_SATURATED" -ge "$EARLY_STOP_COUNT" ]]; then
            mark_config_saturated "$CONFIG_KEY"
            echo "    >>> Config ${CONFIG_KEY} marked as saturated (early stop triggered)"
        fi
    done
done

# 清理临时文件
rm -f "$TEMP_WORKLOAD_CONFIG"

echo ""
echo "============================================================"
echo "          Benchmark Complete!"
echo "============================================================"
echo "Results saved to: ${RESULTS_CSV}"
echo "Total experiments: ${EXPERIMENT_COUNT}"
echo "Skipped (done/early-stop): ${SKIPPED_COUNT}"
echo "Actually run: $((EXPERIMENT_COUNT - SKIPPED_COUNT))"
echo ""

# ============= 生成饱和吞吐汇总 =============

echo ">>> Generating saturation summary..."

python3 << PYEOF
import csv
import os
import sys

csv_file = "${RESULTS_CSV}"
summary_file = "${EXPERIMENT_DIR}/saturation_summary.txt"
threshold = float("${SATURATION_THRESHOLD}")

try:
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        rows = list(reader)

    if not rows:
        print("No data to summarize")
        sys.exit()

    # Group by (batch_size, batch_timeout, message_size)
    configs = {}
    for row in rows:
        key = (row['batch_size'], row['batch_timeout'], row['message_size'])
        if key not in configs:
            configs[key] = []
        try:
            thr = float(row['avg_throughput'])
            lat = float(row['avg_latency_us'])
            arrival = float(row['avg_arrival_rate'])
            target = float(row['target_rate'])
            configs[key].append({
                'target_rate': target,
                'throughput': thr,
                'latency': lat,
                'arrival_rate': arrival,
            })
        except (ValueError, KeyError):
            pass

    with open(summary_file, 'w') as f:
        f.write("=" * 70 + "\n")
        f.write("  Saturation Throughput Summary\n")
        f.write(f"  Threshold: throughput/target_rate < {threshold}\n")
        f.write("=" * 70 + "\n\n")

        summary_rows = []

        for key in sorted(configs.keys(), key=lambda k: (int(k[2]), int(k[0]), int(k[1]))):
            bs, bt, sz = key
            data = sorted(configs[key], key=lambda x: x['target_rate'])

            f.write(f"Config: batch_size={bs}, batch_timeout={bt}, msg_size={sz}\n")
            f.write("-" * 50 + "\n")
            f.write(f"  {'Rate':>8s}  {'Throughput':>12s}  {'Latency':>12s}  {'Ratio':>8s}  {'Status'}\n")

            peak_thr = 0
            peak_rate = 0
            saturation_rate = None
            last_good_rate = 0
            last_good_thr = 0

            for d in data:
                ratio = d['throughput'] / d['target_rate'] if d['target_rate'] > 0 else 0
                status = "OK" if ratio >= threshold else "SATURATED"

                if d['throughput'] > 0:
                    f.write(f"  {d['target_rate']:>8.0f}  {d['throughput']:>12.2f}  {d['latency']:>12.2f}  {ratio:>8.4f}  {status}\n")

                if d['throughput'] > peak_thr:
                    peak_thr = d['throughput']
                    peak_rate = d['target_rate']

                if ratio >= threshold and d['throughput'] > 0:
                    last_good_rate = d['target_rate']
                    last_good_thr = d['throughput']

                if saturation_rate is None and ratio < threshold and d['throughput'] > 0:
                    saturation_rate = d['target_rate']

            f.write("\n")
            f.write(f"  Peak throughput:      {peak_thr:.2f} ops/s (at target rate {peak_rate:.0f})\n")

            if saturation_rate is not None:
                f.write(f"  Saturation begins at: target_rate = {saturation_rate:.0f} ops/s\n")
                f.write(f"  Last unsaturated:     target_rate = {last_good_rate:.0f}, thr = {last_good_thr:.2f}\n")
            else:
                f.write(f"  Saturation: NOT REACHED (system handled all tested rates)\n")

            f.write("\n")

            summary_rows.append({
                'bs': bs, 'bt': bt, 'sz': sz,
                'peak_thr': peak_thr,
                'saturation_rate': saturation_rate if saturation_rate else 'N/A',
                'last_good_rate': last_good_rate,
                'last_good_thr': last_good_thr,
            })

        # Compact comparison table
        f.write("=" * 70 + "\n")
        f.write("  Comparison Table\n")
        f.write("=" * 70 + "\n")
        f.write(f"  {'BS':>6s}  {'BT':>6s}  {'Size':>6s}  {'PeakThr':>10s}  {'SatRate':>10s}  {'LastGoodRate':>12s}  {'LastGoodThr':>12s}\n")
        f.write("-" * 70 + "\n")
        for r in summary_rows:
            sat = f"{r['saturation_rate']:>10}" if isinstance(r['saturation_rate'], (int, float)) else f"{'N/A':>10}"
            f.write(f"  {r['bs']:>6s}  {r['bt']:>6s}  {r['sz']:>6s}  {r['peak_thr']:>10.2f}  {sat}  {r['last_good_rate']:>12.0f}  {r['last_good_thr']:>12.2f}\n")
        f.write("\n")

    print(f"Summary written to: {summary_file}")

    with open(summary_file, 'r') as f:
        print(f.read())

except Exception as e:
    print(f"Error generating summary: {e}")
    import traceback
    traceback.print_exc()
PYEOF

echo ""
echo "Done!"

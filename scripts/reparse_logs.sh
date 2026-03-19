#!/bin/bash
# ==============================================================================
# reparse_logs.sh - 重新解析实验日志
# ==============================================================================
#
# 功能：
#   扫描指定的实验目录中的日志文件，使用最新的解析逻辑（去除尾部0值）
#   重新计算 metrics 并覆盖原有的 results.csv。
#   支持 static 和 dynamic 两种类型的实验目录。
#
# 使用方式：
#   ./scripts/reparse_logs.sh <ExperimentDir> <Type>
#   例如：
#     ./scripts/reparse_logs.sh static_benchmark_results/experiment_20260205_150000 static
#     ./scripts/reparse_logs.sh dynamic_benchmark_results/experiment_20260205_160000 dynamic
#
# ==============================================================================

set -e

EXPERIMENT_DIR="$1"
TYPE="$2"

if [[ -z "$EXPERIMENT_DIR" ]] || [[ -z "$TYPE" ]]; then
    echo "Usage: $0 <ExperimentDir> <Type>"
    echo "  Type: 'static' or 'dynamic'"
    exit 1
fi

if [[ ! -d "$EXPERIMENT_DIR" ]]; then
    echo "Error: Directory $EXPERIMENT_DIR not found"
    exit 1
fi

LOGS_DIR="${EXPERIMENT_DIR}/logs"
RESULTS_CSV="${EXPERIMENT_DIR}/results.csv"  # 将会被覆盖
BACKUP_CSV="${EXPERIMENT_DIR}/results_backup_$(date +%Y%m%d%H%M%S).csv"

echo ">>> Reparsing logs in ${EXPERIMENT_DIR} (Type: ${TYPE})"
echo ">>> Logs directory: ${LOGS_DIR}"

# 备份旧 CSV
if [[ -f "$RESULTS_CSV" ]]; then
    cp "$RESULTS_CSV" "$BACKUP_CSV"
    echo ">>> Backup created: ${BACKUP_CSV}"
fi

# 初始化 CSV
if [[ "$TYPE" == "static" ]]; then
    echo "workload_id,rate,request_size,batch_size,batch_timeout,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count" > "$RESULTS_CSV"
elif [[ "$TYPE" == "dynamic" ]]; then
    echo "experiment_id,algorithm,batch_size,batch_timeout,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count" > "$RESULTS_CSV"
    
    # 动态实验还需要处理 phase results（暂时简化只处理主 CSV，若需要 phase 也可加）
    PHASE_CSV="${EXPERIMENT_DIR}/phase_results.csv"
    if [[ -f "$PHASE_CSV" ]]; then
        cp "$PHASE_CSV" "${EXPERIMENT_DIR}/phase_results_backup.csv"
        echo "experiment_id,algorithm,batch_size,batch_timeout,phase,workload_rate,workload_size,phase_duration,avg_throughput,avg_latency_us,avg_msg_size_bytes,avg_arrival_rate,avg_mem_used_mb,avg_mem_max_mb,avg_mem_percent,sample_count" > "$PHASE_CSV"
    fi
else
    echo "Error: Unknown type '$TYPE'. Use 'static' or 'dynamic'."
    exit 1
fi

# Python 解析脚本（内嵌）
parse_log_metrics() {
    local log_file=$1
    local output_file=$2
    
    python3 << EOF
import re
import sys

log_file = "$log_file"
output_file = "$output_file"

# Metrics pattern
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
    # silent fail for empty/bad logs
    pass

n = len(throughputs)
if n > 0:
    # 策略改进：
    # 1. 静态实验：跳过前5个样本（预热）；动态实验：跳过前10个
    # 2. 从后往前扫描，去除结尾连续的 thr=0 的样本（冷却/Client停止）
    
    # 去除尾部 0 值
    while len(throughputs) > 5 and throughputs[-1] == 0.0:
         throughputs.pop()
         latencies.pop()
         avg_sizes.pop()
         arrival_rates.pop()
         mem_used.pop()
         mem_max.pop()
         mem_percent.pop()
    
    n = len(throughputs)
    
    # 区分预热逻辑
    is_dynamic = ("$TYPE" == "dynamic")
    warmup = 10 if is_dynamic else 5
    
    skip = min(warmup, n // 3)
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
    else:
        with open(output_file, 'w') as f:
            f.write("0,0,0,0,0,0,0,0\n")
else:
    with open(output_file, 'w') as f:
        f.write("0,0,0,0,0,0,0,0\n")
EOF
}

# Python Phase 解析脚本 (针对 dynamic)
parse_phase_metrics() {
    local log_file=$1
    local output_file=$2
    # 注意：这里需要传入 dynamic_workload 配置，通常脚本会硬编码或也需要尝试读取 config
    # 简化起见，这里假设使用 logs 目录下的 workload config 备份，如果没有，则尝试默认的
    local config_file="$EXPERIMENT_DIR/dynamic_workload_test.config" # 假设复制到了实验目录，或者用默认
    if [[ ! -f "$config_file" ]]; then
        config_file="config/workloads/dynamic_workload_test.config"
    fi
    
    python3 << EOF
import re
import sys
import os

log_file = "$log_file"
output_file = "$output_file"
config_file = "$config_file"

if not os.path.exists(config_file):
    with open(output_file, 'w') as f:
        pass # empty
    sys.exit(0)

phases = []
with open(config_file, 'r') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = [p.strip() for p in line.split(',')]
        if len(parts) >= 3:
            phases.append({'duration': int(parts[0]), 'rate': int(parts[1]), 'size': int(parts[2])})

pattern = r'thr=([0-9.]+), lat=([0-9.]+) us(?:, consLat=[0-9.]+ us)? \| avgSize=([0-9.]+) bytes, arrivalRate=([0-9.]+) req/s \| Memory: ([0-9]+)MB/([0-9]+)MB \(([0-9.]+)%\)'
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
except:
    pass

# 去除尾部 0 值
while len(all_metrics) > 10 and all_metrics[-1]['thr'] == 0.0:
    all_metrics.pop()

results = []
sample_idx = 0
for phase_idx, phase in enumerate(phases):
    duration = phase['duration']
    phase_end = sample_idx + duration
    phase_skip = min(5, duration // 3)
    
    phase_samples = all_metrics[sample_idx + phase_skip : phase_end] if sample_idx + phase_skip < len(all_metrics) else []
    
    if phase_samples:
        avg_thr = sum(m['thr'] for m in phase_samples) / len(phase_samples)
        avg_lat = sum(m['lat'] for m in phase_samples) / len(phase_samples)
        avg_size = sum(m['size'] for m in phase_samples) / len(phase_samples)
        avg_arrival = sum(m['arrival'] for m in phase_samples) / len(phase_samples)
        avg_mem_used = sum(m['mem_used'] for m in phase_samples) / len(phase_samples)
        avg_mem_max = sum(m['mem_max'] for m in phase_samples) / len(phase_samples)
        avg_mem_pct = sum(m['mem_pct'] for m in phase_samples) / len(phase_samples)
        
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
            'samples': len(phase_samples)
        })
    sample_idx = phase_end

with open(output_file, 'w') as f:
    for r in results:
        f.write(f"{r['phase']},{r['rate']},{r['size']},{r['duration']},{r['thr']:.2f},{r['lat']:.2f},{r['avg_size']:.2f},{r['arrival']:.2f},{r['mem_used']:.0f},{r['mem_max']:.0f},{r['mem_pct']:.1f},{r['samples']}\n")
EOF
}

# ================= 静态实验处理 =================
if [[ "$TYPE" == "static" ]]; then
    # 查找所有 server_*.log 并提取参数
    # 文件名格式：server_w1_bs100_bt50.log
    for log_file in ${LOGS_DIR}/server_w*.log; do
        [ -e "$log_file" ] || continue
        
        fname=$(basename "$log_file")
        # 提取参数: w{id}_bs{bs}_bt{bt}.log
        if [[ "$fname" =~ server_w([0-9]+)_bs([0-9]+)_bt([0-9]+).log ]]; then
            wid="${BASH_REMATCH[1]}"
            bs="${BASH_REMATCH[2]}"
            bt="${BASH_REMATCH[3]}"
            
            # 这里的 rate 和 request_size 需要从 results_backup.csv 中反查，或者从 workload ID 映射
            # 简化做法：从 backup csv 中 grep 这一行获取元数据
            meta_line=$(grep "^$wid," "$BACKUP_CSV" | grep ",$bs,$bt," | head -n 1)
            if [[ -n "$meta_line" ]]; then
                rate=$(echo "$meta_line" | cut -d, -f2)
                size=$(echo "$meta_line" | cut -d, -f3)
                
                # 解析 metrics
                tmp_out="${LOGS_DIR}/reparse_tmp.csv"
                parse_log_metrics "$log_file" "$tmp_out"
                metrics=$(cat "$tmp_out")
                rm -f "$tmp_out"
                
                echo "$wid,$rate,$size,$bs,$bt,$metrics" >> "$RESULTS_CSV"
                echo "Processed Static: w=$wid bs=$bs bt=$bt"
            else
                echo "Warning: No metadata found for $fname in backup CSV, skipping."
            fi
        fi
    done

# ================= 动态实验处理 =================
elif [[ "$TYPE" == "dynamic" ]]; then
    
    # 1. 动态算法 (server_BAYESIAN.log, server_PPO.log)
    for alg in BAYESIAN PPO; do
        log_file="${LOGS_DIR}/server_${alg}.log"
        if [[ -f "$log_file" ]]; then
            # Overall
            tmp_out="${LOGS_DIR}/reparse_tmp.csv"
            parse_log_metrics "$log_file" "$tmp_out"
            metrics=$(cat "$tmp_out")
            echo "1,${alg},dynamic,dynamic,$metrics" >> "$RESULTS_CSV" # exp_id 假定无序或重排
            
            # Phase
            phase_out="${LOGS_DIR}/reparse_phase_tmp.csv"
            parse_phase_metrics "$log_file" "$phase_out"
            if [[ -f "$phase_out" ]]; then
                 while IFS=',' read -r phase rate size duration thr lat avg_size arrival mem_used mem_max mem_pct samples; do
                    echo "1,${alg},dynamic,dynamic,${phase},${rate},${size},${duration},${thr},${lat},${avg_size},${arrival},${mem_used},${mem_max},${mem_pct},${samples}" >> "$PHASE_CSV"
                done < "$phase_out"
                rm -f "$phase_out"
            fi
            echo "Processed Dynamic Alg: $alg"
            rm -f "$tmp_out"
        fi
    done
    
    # 2. 静态配置 (server_STATIC_100_50.log)
    for log_file in ${LOGS_DIR}/server_STATIC_*.log; do
        [ -e "$log_file" ] || continue
        fname=$(basename "$log_file")
        if [[ "$fname" =~ server_STATIC_([0-9]+)_([0-9]+).log ]]; then
            bs="${BASH_REMATCH[1]}"
            bt="${BASH_REMATCH[2]}"
            
            # Overall
            tmp_out="${LOGS_DIR}/reparse_tmp.csv"
            parse_log_metrics "$log_file" "$tmp_out"
            metrics=$(cat "$tmp_out")
            echo "1,STATIC,$bs,$bt,$metrics" >> "$RESULTS_CSV"
            
            # Phase
            phase_out="${LOGS_DIR}/reparse_phase_tmp.csv"
            parse_phase_metrics "$log_file" "$phase_out"
             if [[ -f "$phase_out" ]]; then
                 while IFS=',' read -r phase rate size duration thr lat avg_size arrival mem_used mem_max mem_pct samples; do
                    echo "1,STATIC,$bs,$bt,${phase},${rate},${size},${duration},${thr},${lat},${avg_size},${arrival},${mem_used},${mem_max},${mem_pct},${samples}" >> "$PHASE_CSV"
                done < "$phase_out"
                rm -f "$phase_out"
            fi
            
            echo "Processed Dynamic Static: bs=$bs bt=$bt"
            rm -f "$tmp_out"
        fi
    done
fi

echo ">>> Done! Reparsed results saved to ${RESULTS_CSV}"
echo ">>> Old results backup: ${BACKUP_CSV}"

# ================= Generate Summary =================
SUMMARY_FILE="${EXPERIMENT_DIR}/reparse_summary.txt"
echo ">>> Generating summary to ${SUMMARY_FILE}..."

{
    echo "============================================================"
    echo "          Experiment Summary (Reparsed)"
    echo "============================================================"
    echo "Date: $(date)"
    echo "Experiment Dir: ${EXPERIMENT_DIR}"
    echo "Type: ${TYPE}"
    echo ""

    if [[ "$TYPE" == "static" ]]; then
        echo "Top 5 Throughput Configurations:"
        echo "------------------------------------------------------------"
        if [ -f "$RESULTS_CSV" ]; then
             # sort by throughput (col 6) desc
             head -n 1 "$RESULTS_CSV"
             tail -n +2 "$RESULTS_CSV" | sort -t, -k6 -nr | head -n 5
        fi
        echo ""
        
        echo "Top 5 Low-Latency Configurations:"
        echo "------------------------------------------------------------"
        if [ -f "$RESULTS_CSV" ]; then
             # sort by latency (col 7) asc
             head -n 1 "$RESULTS_CSV"
             tail -n +2 "$RESULTS_CSV" | sort -t, -k7 -n | head -n 5
        fi
        echo ""

        # Simplified view per workload
        echo "Best Configuration per Workload (Maximize Throughput/Latency Ratio):"
        echo "------------------------------------------------------------"
        python3 << EOF
import csv
import sys

csv_file = "$RESULTS_CSV"
best_configs = {}

try:
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                wid = row['workload_id']
                thr = float(row['avg_throughput'])
                lat = float(row['avg_latency_us'])
                rate = row['rate']
                size = row['request_size']
                
                if lat > 0:
                    score = thr / lat
                else:
                    score = 0
                
                if wid not in best_configs or score > best_configs[wid]['score']:
                    best_configs[wid] = {
                        'score': score,
                        'bs': row['batch_size'],
                        'bt': row['batch_timeout'],
                        'thr': thr,
                        'lat': lat,
                        'rate': rate,
                        'size': size
                    }
            except ValueError:
                continue

    for wid in sorted(best_configs.keys(), key=lambda x: int(x) if x.isdigit() else x):
        c = best_configs[wid]
        print(f"Workload {wid} (Rate={c['rate']}, Size={c['size']}): Best [BS={c['bs']}, BT={c['bt']}] -> Thr={c['thr']:.2f} req/s, Lat={c['lat']:.2f} us")

except Exception as e:
    print(f"Error generating summary: {e}")
EOF
    
    elif [[ "$TYPE" == "dynamic" ]]; then
        echo "Algorithm Performance Summary:"
        echo "------------------------------------------------------------"
        if [ -f "$RESULTS_CSV" ]; then
            head -n 1 "$RESULTS_CSV"
            tail -n +2 "$RESULTS_CSV"
        fi
        
        echo ""
        echo "Note: Check phase_results.csv for detailed performance per workload phase."
    fi

} > "$SUMMARY_FILE"

cat "$SUMMARY_FILE"

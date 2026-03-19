#!/bin/bash
# ==============================================================================
# run_request_timeout_closed_loop.sh - 闭环验证 requestTimeout 动态调节必要性
# ==============================================================================
#
# 目标：
#   通过两个场景构造“太小不好 + 太大不好”的闭环证据：
#   1) steady_degradation: 稳态慢链路，证明过小 timeout 易风暴
#   2) burst_recovery: 短时突发恶化，证明过大 timeout 恢复慢
#
# 用法：
#   ./run_request_timeout_closed_loop.sh [SkipBuild]
#
# 可选环境变量：
#   WORKLOAD_RATE_OVERRIDE (默认100，每线程)
#   RUN_DURATION_OVERRIDE (默认180秒)
#   REQUEST_TIMEOUTS_OVERRIDE (默认"150 250 350 500 800 1200 2000")
#
# ==============================================================================

set -e

SKIP_BUILD="${1:-false}"
RESULTS_ROOT="asymmetric_timeout_benchmark_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CLOSED_LOOP_DIR="${RESULTS_ROOT}/closed_loop_${TIMESTAMP}"
mkdir -p "${CLOSED_LOOP_DIR}"

REQ_TIMEOUTS="${REQUEST_TIMEOUTS_OVERRIDE:-150 250 350 500 800 1200 2000}"
RUN_DURATION="${RUN_DURATION_OVERRIDE:-180}"
WORKLOAD_RATE="${WORKLOAD_RATE_OVERRIDE:-100}"
WORKLOAD_SIZE="${WORKLOAD_SIZE_OVERRIDE:-512}"

echo "============================================================"
echo "  Closed-loop RequestTimeout Validation"
echo "============================================================"
echo "requestTimeout candidates: ${REQ_TIMEOUTS}"
echo "run duration: ${RUN_DURATION}s"
echo "workload rate per thread: ${WORKLOAD_RATE}"
echo "workload size: ${WORKLOAD_SIZE}"
echo "output dir: ${CLOSED_LOOP_DIR}"
echo ""

latest_experiment_dir() {
    ls -dt ${RESULTS_ROOT}/experiment_* 2>/dev/null | head -n1
}

run_one_scenario() {
    local scenario_name=$1
    local delays=$2
    local burst_mode=$3
    local burst_spike=$4
    local burst_normal=$5
    local burst_width=$6

    local before_dir
    before_dir=$(latest_experiment_dir || true)

    echo "------------------------------------------------------------"
    echo "Running scenario: ${scenario_name}"
    echo "  delays: ${delays}"
    echo "  burst mode: ${burst_mode}"
    if [[ "${burst_mode}" == "true" ]]; then
        echo "  burst profile: spike=${burst_spike}ms, normal=${burst_normal}s, width=${burst_width}s"
    fi
    echo "------------------------------------------------------------"

    AUTO_CONFIRM=true \
    LEADER_DELAYS_OVERRIDE="${delays}" \
    REQUEST_TIMEOUTS_OVERRIDE="${REQ_TIMEOUTS}" \
    RUN_DURATION_OVERRIDE="${RUN_DURATION}" \
    WORKLOAD_RATE_OVERRIDE="${WORKLOAD_RATE}" \
    WORKLOAD_SIZE_OVERRIDE="${WORKLOAD_SIZE}" \
    ENABLE_BURST_MODE="${burst_mode}" \
    BURST_SPIKE_DELAY_MS="${burst_spike}" \
    BURST_NORMAL_SEC="${burst_normal}" \
    BURST_SPIKE_SEC="${burst_width}" \
    ./run_asymmetric_timeout_benchmark.sh "${SKIP_BUILD}"

    local after_dir
    after_dir=$(latest_experiment_dir || true)

    if [[ -z "${after_dir}" ]] || [[ "${after_dir}" == "${before_dir}" ]]; then
        echo "ERROR: failed to detect generated experiment directory for ${scenario_name}"
        exit 1
    fi

    echo "${after_dir}"
}

STEADY_DIR=$(run_one_scenario "steady_degradation" "200" "false" "800" "20" "3" | tail -n1)
BURST_DIR=$(run_one_scenario "burst_recovery" "50" "true" "1200" "15" "5" | tail -n1)

cp "${STEADY_DIR}/results.csv" "${CLOSED_LOOP_DIR}/results_steady.csv"
cp "${BURST_DIR}/results.csv" "${CLOSED_LOOP_DIR}/results_burst.csv"

python3 << PYEOF
import csv
import os

steady_csv = "${CLOSED_LOOP_DIR}/results_steady.csv"
burst_csv = "${CLOSED_LOOP_DIR}/results_burst.csv"
summary_txt = "${CLOSED_LOOP_DIR}/closed_loop_summary.txt"
compare_csv = "${CLOSED_LOOP_DIR}/closed_loop_compare.csv"

def load_rows(path):
    with open(path, 'r') as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r['rt'] = int(r['request_timeout'])
        r['thr'] = float(r['avg_throughput'])
        r['lat'] = float(r['avg_latency_us'])
        r['n'] = int(r['sample_count'])
        r['reg'] = int(r['max_regency'])
    return rows

def pick_best(rows):
    stable = [r for r in rows if r['n'] >= 30 and r['thr'] > 0]
    if not stable:
        return None
    return max(stable, key=lambda x: x['thr'])

steady_rows = load_rows(steady_csv)
burst_rows = load_rows(burst_csv)

steady_best = pick_best(steady_rows)
burst_best = pick_best(burst_rows)

with open(compare_csv, 'w', newline='') as f:
    writer = csv.writer(f)
    writer.writerow(['scenario', 'request_timeout', 'avg_throughput', 'avg_latency_us', 'sample_count', 'max_regency'])
    for r in steady_rows:
        writer.writerow(['steady', r['rt'], f"{r['thr']:.2f}", f"{r['lat']:.2f}", r['n'], r['reg']])
    for r in burst_rows:
        writer.writerow(['burst', r['rt'], f"{r['thr']:.2f}", f"{r['lat']:.2f}", r['n'], r['reg']])

with open(summary_txt, 'w') as f:
    f.write('=' * 80 + '\n')
    f.write('Closed-loop RequestTimeout Validation Summary\n')
    f.write('=' * 80 + '\n\n')

    if steady_best:
        f.write(f"steady_degradation best: rt={steady_best['rt']}ms, thr={steady_best['thr']:.2f}, lat={steady_best['lat']:.2f} us, n={steady_best['n']}, reg={steady_best['reg']}\n")
    else:
        f.write('steady_degradation best: N/A (no stable samples)\n')

    if burst_best:
        f.write(f"burst_recovery best:    rt={burst_best['rt']}ms, thr={burst_best['thr']:.2f}, lat={burst_best['lat']:.2f} us, n={burst_best['n']}, reg={burst_best['reg']}\n")
    else:
        f.write('burst_recovery best:    N/A (no stable samples)\n')

    f.write('\n')

    if steady_best and burst_best:
        if steady_best['rt'] != burst_best['rt']:
            f.write('CONCLUSION: Best requestTimeout differs by scenario -> dynamic tuning is necessary.\n')
            steady_label = 'higher' if steady_best['rt'] > burst_best['rt'] else 'lower'
            burst_label  = 'higher' if burst_best['rt']  > steady_best['rt'] else 'lower'
            f.write(f"  Suggestion: use {steady_label} timeout (~{steady_best['rt']}ms) for steady degradation, ")
            f.write(f"and {burst_label} timeout (~{burst_best['rt']}ms) for burst recovery.\n")
        else:
            f.write('CONCLUSION: Both scenarios share the same best requestTimeout in this run.\n')
            f.write('  Consider increasing burst intensity or shortening burst interval to expose recovery lag at high timeout.\n')
    else:
        f.write('CONCLUSION: Insufficient stable data; please inspect logs and rerun with adjusted burst profile.\n')

print(f"Generated: {summary_txt}")
print(f"Generated: {compare_csv}")
PYEOF

echo ""
echo "Closed-loop results generated in: ${CLOSED_LOOP_DIR}"
echo "  - ${CLOSED_LOOP_DIR}/results_steady.csv"
echo "  - ${CLOSED_LOOP_DIR}/results_burst.csv"
echo "  - ${CLOSED_LOOP_DIR}/closed_loop_compare.csv"
echo "  - ${CLOSED_LOOP_DIR}/closed_loop_summary.txt"

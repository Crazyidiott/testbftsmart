RUNS=3
EXP_DIRS=()

for i in $(seq 1 $RUNS); do
  if [ "$i" -eq 1 ]; then SKIP=false; else SKIP=true; fi

  BEFORE=$(ls -dt asymmetric_timeout_benchmark_results/experiment_* 2>/dev/null | head -n1)

  AUTO_CONFIRM=true \
  ENABLE_BURST_MODE=false \
  LEADER_DELAYS_OVERRIDE="0 50 100 200" \
  REQUEST_TIMEOUTS_OVERRIDE="150 250 350 500 800 1200 2000" \
  RUN_DURATION_OVERRIDE=180 \
  WORKLOAD_RATE_OVERRIDE=100 \
  WORKLOAD_SIZE_OVERRIDE=512 \
  ./run_asymmetric_timeout_benchmark.sh "$SKIP"

  AFTER=$(ls -dt asymmetric_timeout_benchmark_results/experiment_* 2>/dev/null | head -n1)
  if [ -z "$AFTER" ] || [ "$AFTER" = "$BEFORE" ]; then
    echo "ERROR: Round $i did not produce a new experiment directory."
    exit 1
  fi

  EXP_DIRS+=("$AFTER")
  echo "Round $i done: $AFTER"
done

mkdir -p asymmetric_timeout_benchmark_results/report
printf "%s\n" "${EXP_DIRS[@]}" | tee asymmetric_timeout_benchmark_results/report/steady_3runs_experiments.txt

python3 scripts/aggregate_steady_grid.py "${EXP_DIRS[@]}"
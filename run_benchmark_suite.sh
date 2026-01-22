#!/bin/bash

# Configuration Arrays
# Matrix: (BatchSize, Timeout, ClientRatePerThread)

# 1. Low Load (Rate=200/thread * 10 = 2000 total)
# 2. Medium Load (Rate=1000/thread * 10 = 10000 total)
# 3. High/Saturation Load (Rate=2000/thread * 10 = 20000 total)

# Defining groups of experiments
# Group 1: Small Batch, Small Timeout (Baseline)
# Group 2: Small Batch, Large Timeout (Bad config)
# Group 3: Big Batch, Large Timeout (Classic Batching)
# Group 4: Big Batch, Small Timeout (Target Config)

BATCH_SIZES=(
    10 10 10
    10 10 10
    1000 1000 1000
    1000 1000 1000
)

# Replace -1 with explicit small values (e.g. 5ms) for "Small Timeout"
BATCH_TIMEOUTS=(
    5 5 5       # Group 1 (Small TO)
    50 50 50    # Group 2 (Large TO)
    50 50 50    # Group 3 (Large TO)
    5 5 5       # Group 4 (Small TO)
)

CLIENT_RATES=(
    200 1000 2000  # Low, Med, High for Grp 1
    200 1000 2000  # Low, Med, High for Grp 2
    200 1000 2000  # Low, Med, High for Grp 3
    200 1000 2000  # Low, Med, High for Grp 4
)

# Directory for aggregated results
RESULTS_DIR="benchmark_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "=========================================================="
echo "Starting Automated Benchmark Suite"
echo "Results will be saved in: $RESULTS_DIR"
echo "=========================================================="

# Header for summary output
SUMMARY_FILE="$RESULTS_DIR/summary.csv"
echo "BatchSize,Timeout,ClientRate,Client_Avg_Throughput(ops/s),Server_Avg_Throughput(ops/s),Server_Avg_Total_Latency(us)" > "$SUMMARY_FILE"

# Iterate through configurations
# Note: ${#BATCH_SIZES[@]} gets the length of the array
count=${#BATCH_SIZES[@]}

for ((i=0; i<$count; i++)); do
    BATCH_SIZE=${BATCH_SIZES[$i]}
    TIMEOUT=${BATCH_TIMEOUTS[$i]}
    RATE=${CLIENT_RATES[$i]}
    CONFIG_NAME="BS${BATCH_SIZE}_TO${TIMEOUT}_RATE${RATE}"
    
    echo ""
    echo "----------------------------------------------------------"
    echo "Running Experiment $((i+1))/$count: BatchSize=$BATCH_SIZE, Timeout=$TIMEOUT, Rate=${RATE}/th"
    echo "----------------------------------------------------------"

    # 1. Clean up previous results from lan_deploy logic (optional but good practice)
    rm -rf results/

    # 2. Run lan_deploy.sh with arguments including RATE
    # Ensure lan_deploy.sh is executable: chmod +x lan_deploy.sh
    ./lan_deploy.sh "$BATCH_SIZE" "$TIMEOUT" "$RATE"

    # 3. Wait a bit for file transfer to finish (lan_deploy usually does scp at the end)
    sleep 2

    # 4. Extract and Process Data
    echo "Processing results for config: $CONFIG_NAME..."

    # --- Client Analysis ---
    CLIENT_LOG="results/client.log"
    DEST_CLIENT_LOG="$RESULTS_DIR/client_${CONFIG_NAME}.log"
    
    if [ -f "$CLIENT_LOG" ]; then
        # Extract Lines: [Total Client Throughput] 12638 ops/sec
        grep "\[Total Client Throughput\]" "$CLIENT_LOG" > "$DEST_CLIENT_LOG"
        
        # Calculate Average Client Throughput
        # Extract number, filter out 0s (warmup), calculate average
        CLIENT_OPS_AVG=$(grep "\[Total Client Throughput\]" "$CLIENT_LOG" | awk '{print $4}' | awk '$1 > 1 { sum += $1; n++ } END { if (n > 0) print sum / n; else print 0; }')
    else
        echo "WARNING: Client log not found!"
        CLIENT_OPS_AVG=0
    fi

    # --- Server Analysis ---
    # Aggregate all server logs
    SERVER_OPS_SUM=0
    SERVER_LAT_SUM=0
    SERVER_COUNT=0

    for s in {0..3}; do
        SERVER_LOG="results/server_$s.log"
        DEST_SERVER_LOG="$RESULTS_DIR/server_${s}_${CONFIG_NAME}.log"
        
        if [ -f "$SERVER_LOG" ]; then
            # Extract Measurements block
            # Assuming output format:
            # Throughput = 1677.8523 operations/sec ...
            # Total latency = 2916.128009 (+/- 394) us
            
            # We grep the context of measurements to a file
            grep -A 10 "Measurements after" "$SERVER_LOG" > "$DEST_SERVER_LOG"
            
            # Extract AVG Throughput from this server (Taking the last measurement or average of all measurements)
            # Strategy: Average of all 'Throughput =' lines found in the file
            THIS_SERVER_TP=$(grep "Throughput =" "$SERVER_LOG" | awk '{print $3}' | awk '{ sum += $1; n++ } END { if (n > 0) print sum / n; else print 0; }')
            
            # Extract AVG Total Latency
            THIS_SERVER_LAT=$(grep "Total latency =" "$SERVER_LOG" | awk '{print $4}' | awk '{ sum += $1; n++ } END { if (n > 0) print sum / n; else print 0; }')

            SERVER_OPS_SUM=$(echo "$SERVER_OPS_SUM + $THIS_SERVER_TP" | bc)
            SERVER_LAT_SUM=$(echo "$SERVER_LAT_SUM + $THIS_SERVER_LAT" | bc)
            ((SERVER_COUNT++))
        fi
    done

    if [ "$SERVER_COUNT" -gt 0 ]; then
        # Calculate cluster averages
        # Note: Valid Throughput is usually avg of replicas (since they process same reqs)
        SERVER_OPS_AVG=$(echo "scale=2; $SERVER_OPS_SUM / $SERVER_COUNT" | bc)
        SERVER_LAT_AVG=$(echo "scale=2; $SERVER_LAT_SUM / $SERVER_COUNT" | bc)
    else
        SERVER_OPS_AVG=0
        SERVER_LAT_AVG=0
    fi

    # 5. Output Results
    echo ">>> Result Summary for $CONFIG_NAME <<<"
    echo "    Client Avg Throughput:  $CLIENT_OPS_AVG ops/sec"
    echo "    Server Avg Throughput:  $SERVER_OPS_AVG ops/sec"
    echo "    Server Avg Latency:     $SERVER_LAT_AVG us"
    
    # Save to file
    echo "Summary:" >> "$DEST_CLIENT_LOG"
    echo "Average Throughput: $CLIENT_OPS_AVG ops/sec" >> "$DEST_CLIENT_LOG"
    
    # Also append to the summary CSV
    echo "$BATCH_SIZE,$TIMEOUT,$RATE,$CLIENT_OPS_AVG,$SERVER_OPS_AVG,$SERVER_LAT_AVG" >> "$SUMMARY_FILE"

    echo "Finished Config $CONFIG_NAME"
    echo "Waiting 10s cooldown..."
    sleep 10
done

echo "=========================================================="
echo "All Experiments Completed."
echo "Final Summary Table:"
column -t -s, "$SUMMARY_FILE"
echo "=========================================================="

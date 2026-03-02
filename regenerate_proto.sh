#!/bin/bash
# Regenerate Python gRPC code from monitor.proto
# Run this whenever monitor.proto is modified.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTO_DIR="$SCRIPT_DIR/src/main/proto"
OUT_DIR="$SCRIPT_DIR/server_agent"

echo ">>> Regenerating Python gRPC stubs from monitor.proto ..."
echo "    Proto source : $PROTO_DIR/monitor.proto"
echo "    Output dir   : $OUT_DIR"

python3 -m grpc_tools.protoc \
    -I"$PROTO_DIR" \
    --python_out="$OUT_DIR" \
    --grpc_python_out="$OUT_DIR" \
    monitor.proto

echo ">>> Done. Generated files:"
echo "    $OUT_DIR/monitor_pb2.py"
echo "    $OUT_DIR/monitor_pb2_grpc.py"

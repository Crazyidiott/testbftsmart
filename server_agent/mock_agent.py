#!/usr/bin/env python3
"""
mock_agent.py - 模拟 RL Agent 用于测试 BFT-SMaRt 动态调参功能

功能：
1. 监听 gRPC 端口 45678
2. 响应 Connect 握手请求
3. 响应 SendMetrics 请求，返回随机但合理的 BatchSize 和 BatchTimeout

使用方法：
    python mock_agent.py [--port 45678] [--mode random|fixed|incremental]

模式说明：
    - random: 随机返回参数 (默认)
    - fixed: 返回固定参数 (用于基准测试)
    - incremental: 逐步增加参数 (用于观察系统响应)
"""

import grpc
from concurrent import futures
import argparse
import random
import time
import sys

import monitor_pb2
import monitor_pb2_grpc

# ============= 参数范围配置 =============
# 使用较保守的范围进行测试，避免极端值导致系统不稳定
BATCH_SIZE_MIN = 100
BATCH_SIZE_MAX = 2000
BATCH_SIZE_STEP = 100

BATCH_TIMEOUT_MIN = 10
BATCH_TIMEOUT_MAX = 200
BATCH_TIMEOUT_STEP = 10

# 预定义的合理参数组合
BATCH_SIZE_VALUES = list(range(BATCH_SIZE_MIN, BATCH_SIZE_MAX + 1, BATCH_SIZE_STEP))
BATCH_TIMEOUT_VALUES = list(range(BATCH_TIMEOUT_MIN, BATCH_TIMEOUT_MAX + 1, BATCH_TIMEOUT_STEP))


class MockAgentServicer(monitor_pb2_grpc.MetricsServiceServicer):
    """模拟 RL Agent 的 gRPC 服务"""
    
    def __init__(self, mode='random'):
        self.mode = mode
        self.request_count = 0
        self.start_time = time.time()
        
        # 固定模式的参数 - 使用保守值确保系统稳定
        self.fixed_batch_size = 500
        self.fixed_batch_timeout = 50
        
        # 增量模式的索引
        self.size_index = 0
        self.timeout_index = 0
        
        print(f"[MockAgent] 初始化完成，模式: {mode}")
        if mode == 'fixed':
            print(f"[MockAgent] 固定参数: BatchSize={self.fixed_batch_size}, BatchTimeout={self.fixed_batch_timeout}")
    
    def Connect(self, request, context):
        """处理握手请求"""
        client_time = request.timestamp
        server_time = int(time.time() * 1000)
        
        print(f"[MockAgent] 收到 Connect 握手请求")
        print(f"           Client timestamp: {client_time}")
        print(f"           Server timestamp: {server_time}")
        
        return monitor_pb2.Timestamp(timestamp=server_time)
    
    def SendMetrics(self, request, context):
        """处理性能指标请求，返回配置参数"""
        self.request_count += 1
        
        # 解析收到的指标
        throughput = request.throughput
        latency = request.latency
        option = request.option
        arrival_rate = request.arrival_rate
        
        elapsed = time.time() - self.start_time
        
        # 更详细的日志，包含所有字段
        print(f"\n[MockAgent] === 请求 #{self.request_count} (Agent运行 {elapsed:.1f}s) ===")
        print(f"           throughput={throughput} ops/s")
        print(f"           latency={latency} us")
        print(f"           size={request.size}, tot_thr={request.tot_thr}, tot_lat={request.tot_lat}")
        print(f"           option={option}, arrival_rate={arrival_rate}")
        
        # Log drop statistics
        flow_control_drops = getattr(request, 'flow_control_drops', 0)
        seq_gap_rejects = getattr(request, 'seq_gap_rejects', 0)
        in_queue_drops = getattr(request, 'in_queue_drops', 0)
        out_queue_drops = getattr(request, 'out_queue_drops', 0)
        oversized_drops = getattr(request, 'oversized_drops', 0)
        total_drops = flow_control_drops + seq_gap_rejects + in_queue_drops + out_queue_drops + oversized_drops
        print(f"           drops: fc={flow_control_drops} sg={seq_gap_rejects} "
              f"iq={in_queue_drops} oq={out_queue_drops} os={oversized_drops} total={total_drops}")
        
        # 根据模式生成参数
        if self.mode == 'fixed':
            batch_size = self.fixed_batch_size
            batch_timeout = self.fixed_batch_timeout
            
        elif self.mode == 'incremental':
            # 每次请求使用下一个参数组合
            batch_size = BATCH_SIZE_VALUES[self.size_index % len(BATCH_SIZE_VALUES)]
            batch_timeout = BATCH_TIMEOUT_VALUES[self.timeout_index % len(BATCH_TIMEOUT_VALUES)]
            
            # 每 5 次请求切换一次参数
            if self.request_count % 5 == 0:
                self.size_index += 1
            if self.request_count % 10 == 0:
                self.timeout_index += 1
                
        else:  # random 模式
            batch_size = random.choice(BATCH_SIZE_VALUES)
            batch_timeout = random.choice(BATCH_TIMEOUT_VALUES)
        
        print(f"           返回配置: BatchSize={batch_size}, BatchTimeout={batch_timeout}")
        
        return monitor_pb2.MetricsResponse(
            BatchSize=batch_size,
            BatchTimeout=batch_timeout
        )


def serve(port, mode):
    """启动 gRPC 服务器"""
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    servicer = MockAgentServicer(mode=mode)
    monitor_pb2_grpc.add_MetricsServiceServicer_to_server(servicer, server)
    
    listen_addr = f'[::]:{port}'
    server.add_insecure_port(listen_addr)
    server.start()
    
    print("=" * 60)
    print(f"[MockAgent] 模拟 RL Agent 已启动")
    print(f"[MockAgent] 监听地址: 0.0.0.0:{port}")
    print(f"[MockAgent] 运行模式: {mode}")
    print("=" * 60)
    print(f"\n参数范围:")
    print(f"  BatchSize:    {BATCH_SIZE_MIN} - {BATCH_SIZE_MAX} (步长 {BATCH_SIZE_STEP})")
    print(f"  BatchTimeout: {BATCH_TIMEOUT_MIN} - {BATCH_TIMEOUT_MAX} (步长 {BATCH_TIMEOUT_STEP})")
    print("\n等待 BFT-SMaRt 连接...\n")
    
    try:
        server.wait_for_termination()
    except KeyboardInterrupt:
        print("\n[MockAgent] 收到中断信号，正在关闭...")
        server.stop(grace=5)
        print("[MockAgent] 服务已停止")


def main():
    parser = argparse.ArgumentParser(
        description='模拟 RL Agent 用于测试 BFT-SMaRt 动态调参',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
模式说明:
  random      - 随机返回参数 (默认，用于测试系统稳定性)
  fixed       - 返回固定参数 (用于基准测试)
  incremental - 逐步变化参数 (用于观察系统对参数变化的响应)

示例:
  python mock_agent.py                    # 默认端口 45678，随机模式
  python mock_agent.py --port 50051       # 使用端口 50051
  python mock_agent.py --mode fixed       # 固定参数模式
  python mock_agent.py --mode incremental # 增量参数模式
        """
    )
    
    parser.add_argument(
        '--port', '-p',
        type=int,
        default=45678,
        help='gRPC 服务端口 (默认: 45678)'
    )
    
    parser.add_argument(
        '--mode', '-m',
        choices=['random', 'fixed', 'incremental'],
        default='random',
        help='参数生成模式 (默认: random)'
    )
    
    args = parser.parse_args()
    
    serve(args.port, args.mode)


if __name__ == '__main__':
    main()

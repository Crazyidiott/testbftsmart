"""
train.py - 重构版本
"""

import grpc
from concurrent import futures
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torch.optim as optim
from torch.distributions import Categorical
import monitor_pb2
import monitor_pb2_grpc
import os
import time
import threading
import re
from abc import ABC, abstractmethod
from sklearn.gaussian_process import GaussianProcessRegressor
from sklearn.gaussian_process.kernels import Matern
import warnings
import csv
from datetime import datetime
import json
import joblib 

warnings.filterwarnings('ignore')

# ============= 配置 =============
ALGORITHM = os.environ.get('OPT_ALGORITHM', 'BAYESIAN')  # PPO, BAYESIAN, SA

# ============= 从 lan_config.sh 读取节点地址 =============
def load_nodes_from_config(config_path=None):
    """
    从 lan_config.sh 读取节点 IP 地址
    
    Returns:
        dict: {node_id: "ip:port"} 格式的地址映射
    """
    if config_path is None:
        # 尝试多个可能的路径
        possible_paths = [
            os.path.join(os.path.dirname(__file__), '..', 'lan_config.sh'),
            '/home/ubuntu/work/testbftsmart/lan_config.sh',
            './lan_config.sh',
        ]
        for path in possible_paths:
            if os.path.exists(path):
                config_path = path
                break
    
    if config_path is None or not os.path.exists(config_path):
        print("[Config] Warning: lan_config.sh not found, using default addresses")
        return {
            0: '127.0.0.1:45678',
            1: '127.0.0.1:45678',
            2: '127.0.0.1:45678',
            3: '127.0.0.1:45678',
        }
    
    try:
        with open(config_path, 'r') as f:
            content = f.read()
        
        # 使用正则表达式匹配 NODES=("ip1" "ip2" ...) 格式
        match = re.search(r'NODES=\(([^)]+)\)', content)
        if match:
            nodes_str = match.group(1)
            # 提取所有 IP 地址
            ips = re.findall(r'"([^"]+)"', nodes_str)
            
            # 构建地址映射 (前4个是 replicas，端口 45678)
            addr = {}
            for i, ip in enumerate(ips[:4]):  # 只取前4个 replica 节点
                addr[i] = f'{ip}:45678'
            
            print(f"[Config] Loaded {len(addr)} node addresses from {config_path}")
            for node_id, address in addr.items():
                print(f"[Config]   Node {node_id}: {address}")
            
            return addr
        else:
            print("[Config] Warning: Could not parse NODES from lan_config.sh")
            return {0: '127.0.0.1:45678', 1: '127.0.0.1:45678', 2: '127.0.0.1:45678', 3: '127.0.0.1:45678'}
    
    except Exception as e:
        print(f"[Config] Error loading config: {e}")
        return {0: '127.0.0.1:45678', 1: '127.0.0.1:45678', 2: '127.0.0.1:45678', 3: '127.0.0.1:45678'}

# PPO 超参数
learning_rate = 0.0003    # 降低学习率，更稳定
gamma = 0.98
lmbda = 0.95
eps_clip = 0.1
K_epoch = 5               # 增加训练轮数，更充分利用数据
T_horizon = 20

# ============= 动作空间配置 =============
# 与 mock_agent.py 保持一致的保守范围，避免极端值导致系统不稳定
# BatchSize: 100-2000, 步长 200，一共 10 个值
# BatchTimeout: 50-200 ms, 步长 30 ，一共 6 个值 (最小值从10改为50，避免超时过短导致请求超时)
BATCH_SIZE_MIN = 100
BATCH_SIZE_MAX = 2000
BATCH_SIZE_STEP = 200

BATCH_TIMEOUT_MIN = 50  # 增大最小值，避免极端情况导致请求超时
BATCH_TIMEOUT_MAX = 200
BATCH_TIMEOUT_STEP = 30

A_values = torch.arange(BATCH_SIZE_MIN, BATCH_SIZE_MAX + 1, BATCH_SIZE_STEP)   # BatchSize: [100, 200, ..., 2000]
B_values = torch.arange(BATCH_TIMEOUT_MIN, BATCH_TIMEOUT_MAX + 1, BATCH_TIMEOUT_STEP)  # BatchTimeout: [10, 20, ..., 200]
C_values = torch.tensor([8, 16, 32, 64, 128, 256, 512, 1024])

# RequestTimeout: 1000-10000 ms, 步长 1000, 共 10 个值
# 这是 view change 的触发超时，调整频率比 batch 参数低（每 10 个监控周期一次）
REQUEST_TIMEOUT_MIN = 1000
REQUEST_TIMEOUT_MAX = 10000
REQUEST_TIMEOUT_STEP = 1000
REQUEST_TIMEOUT_UPDATE_INTERVAL = 10  # 每 10 个 modelUpdate 调用才重新决策一次 requestTimeout

D_values = torch.arange(REQUEST_TIMEOUT_MIN, REQUEST_TIMEOUT_MAX + 1, REQUEST_TIMEOUT_STEP)  # RequestTimeout: [1000, 2000, ..., 10000]

print(f"[Config] Action space:")
print(f"[Config]   BatchSize: {A_values.min().item()} - {A_values.max().item()}, {len(A_values)} values")
print(f"[Config]   BatchTimeout: {B_values.min().item()} - {B_values.max().item()}, {len(B_values)} values")
print(f"[Config]   RequestTimeout: {D_values.min().item()} - {D_values.max().item()}, {len(D_values)} values")

# ============= 缩放因子配置 =============
# 基于实际观测数据设置：
# - 吞吐量: 40,000 - 60,000 ops/s (正常运行时)
# - 延迟: 10,000 - 30,000 微秒 (10-30ms)
THROUGHPUT_SCALE = 10000.0   # 预期最大吞吐量约 10k ops/s
LATENCY_SCALE = 5000.0       # 预期最大延迟约 50ms = 50,000 微秒
REWARD_SCALE = 100000.0       # Reward 归一化因子

# Reward 权重 (吞吐量最大化，延迟最小化)
# 使用归一化后的值计算，权重更平衡
c_thr = 1.0       # 吞吐量权重
c_lat = -1.0      # 延迟权重 (使用归一化后的值，不需要 -100 这么大)

# ============= 节点地址配置 =============
# 从 lan_config.sh 动态读取
addr = load_nodes_from_config()
f = max(1, (len(addr) - 1) // 3)  # 容错节点数
QUORUM = 2 * f + 1

# 全局状态（仅用于通信协调）
action_pool = []
enough_action = threading.Condition()
action_lock = threading.Lock()
notify_counter = 0
max_notify_count = 3000
save_episode = 500

# ============= 工具函数 =============
def Normalized(state):
    """
    状态归一化 - 基于实际观测数据设置上限
    state: [throughput, latency, payload, tot_thr, tot_lat, tot_size, arrival_rate]
    """
    max_vals = np.array([
        THROUGHPUT_SCALE,    # throughput: 100k ops/s
        LATENCY_SCALE,       # latency: 50k 微秒 = 50ms  
        10000.0,             # payload: 10KB
        1e9,                 # tot_thr: 累计值，使用大值
        1e9,                 # tot_lat: 累计值，使用大值
        1e9,                 # tot_size: 累计值，使用大值
        THROUGHPUT_SCALE,    # arrival_rate: 与吞吐量同量级
    ])
    return state / (max_vals[:len(state)] + 1e-8)


# ============= 数据记录 =============
class DataLogger:
    """数据记录器"""
    
    def __init__(self, algorithm):
        self.algorithm = algorithm
        self.start_time = datetime.now()
        self.iteration_count = 0
        
        # 创建实验目录
        # Use relative path or workspace path instead of hardcoded ubuntu path
        # Ensure 'experiments' directory exists in the current working directory
        self.exp_dir = f"experiments/{algorithm}_{self.start_time.strftime('%Y%m%d_%H%M%S')}"
        os.makedirs(self.exp_dir, exist_ok=True)
        
        # 初始化 CSV 文件
        self.metrics_file = f"{self.exp_dir}/metrics.csv"
        self.params_file = f"{self.exp_dir}/parameters.csv"
        self.experiment_info_file = f"{self.exp_dir}/experiment_info.json"
        self.algorithm_state_file = f"{self.exp_dir}/algorithm_state.csv"
        
        # 写入实验信息
        exp_info = {
            "algorithm": algorithm,
            "start_time": self.start_time.isoformat(),
            "hyperparameters": {
                "learning_rate": learning_rate if algorithm == "PPO" else None,
                "gamma": gamma if algorithm == "PPO" else None,
                "c_thr": c_thr,
                "c_lat": c_lat,
                "A_values": A_values.tolist(),
                "B_values": B_values.tolist(),
                "C_values": C_values.tolist() if algorithm == "PPO" else None
            }
        }
        with open(self.experiment_info_file, 'w') as f:
            json.dump(exp_info, f, indent=2)
        
        # 初始化 CSV 表头
        with open(self.metrics_file, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(['timestamp', 'iteration', 'throughput', 'latency', 
                           'avg_latency', 'payload', 'reward'])
        
        with open(self.params_file, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(['timestamp', 'iteration', 'batch_size', 'batch_timeout', 
                           'c_parameter', 'option', 'request_timeout'])
        
        # 初始化算法状态CSV
        with open(self.algorithm_state_file, 'w', newline='') as f:
            writer = csv.writer(f)
            if algorithm == "BAYESIAN":
                writer.writerow(['timestamp', 'iteration', 'exploration_weight', 
                               'regime_id', 'regime_0_samples', 'regime_1_samples',
                               'regime_2_samples', 'regime_3_samples'])
            elif algorithm == "SA":
                # 修复5：添加额外有用的字段
                writer.writerow(['timestamp', 'iteration', 'temperature', 
                               'best_score', 'current_score', 'no_improvement_count',
                               'ref_thr', 'ref_lat', 'reheat_count', 'accepted_worse'])
            elif algorithm == "PPO":
                writer.writerow(['timestamp', 'iteration', 'data_buffer_size'])
            elif algorithm == "CYCLIC":
                writer.writerow(['timestamp', 'iteration', 'config_index', 
                            'switch_count', 'elapsed_since_start', 'elapsed_since_switch',
                            'current_batch_size', 'current_batch_timeout'])
    
    def log_metrics(self, throughput, latency, payload, reward=None):
        """记录性能指标"""
        self.iteration_count += 1
        timestamp = datetime.now().isoformat()
        avg_latency = latency / throughput if throughput > 0 else 0
        
        with open(self.metrics_file, 'a', newline='') as f:
            writer = csv.writer(f)
            writer.writerow([timestamp, self.iteration_count, throughput, latency, 
                           avg_latency, payload, reward if reward else 0])
    
    def log_parameters(self, batch_size, batch_timeout, c_param, option, request_timeout=0):
        """记录参数调整"""
        timestamp = datetime.now().isoformat()
        
        with open(self.params_file, 'a', newline='') as f:
            writer = csv.writer(f)
            writer.writerow([timestamp, self.iteration_count, batch_size, 
                           batch_timeout, c_param, option, request_timeout])
    
    def log_algorithm_state(self, state_dict):
        """记录算法内部状态"""
        timestamp = datetime.now().isoformat()
        
        with open(self.algorithm_state_file, 'a', newline='') as f:
            writer = csv.writer(f)
            row = [timestamp, self.iteration_count]
            
            # 根据算法类型添加对应字段
            if self.algorithm == "BAYESIAN":
                row.extend([
                    state_dict.get('exploration_weight', 0),
                    state_dict.get('regime_id', 0),
                    state_dict.get('regime_0_samples', 0),
                    state_dict.get('regime_1_samples', 0),
                    state_dict.get('regime_2_samples', 0),
                    state_dict.get('regime_3_samples', 0)
                ])
            elif self.algorithm == "SA":
                # 修复5：匹配新的字段定义
                row.extend([
                    state_dict.get('temperature', 0),
                    state_dict.get('best_score', 0),
                    state_dict.get('current_score', 0),
                    state_dict.get('no_improvement_count', 0),
                    state_dict.get('ref_thr', 0),
                    state_dict.get('ref_lat', 0),
                    state_dict.get('reheat_count', 0),
                    state_dict.get('accepted_worse', 0)
                ])
            elif self.algorithm == "PPO":
                row.extend([state_dict.get('data_buffer_size', 0)])
            elif self.algorithm == "CYCLIC":
                row.extend([
                    state_dict.get('config_index', 0),
                    state_dict.get('switch_count', 0),
                    state_dict.get('elapsed_since_start', 0),
                    state_dict.get('elapsed_since_switch', 0),
                    state_dict.get('current_batch_size', 0),
                    state_dict.get('current_batch_timeout', 0)
                ])
            
            writer.writerow(row)
    
    def get_summary(self):
        """生成摘要统计"""
        summary = {
            "algorithm": self.algorithm,
            "total_iterations": self.iteration_count,
            "duration": str(datetime.now() - self.start_time),
            "experiment_dir": self.exp_dir
        }
        return summary

# ============= 优化器基类 =============
class OptimizerBase(ABC):
    """优化器基类（与 optimizer_lib.py 一致的风格）"""
    
    def __init__(self):
        # 实例变量（替代全局变量）
        self.old_state = []
        self.score = 0
        self.lastA = 0
        self.lastB = 0
        self.lastC = 0
        self.lastD = 0  # requestTimeout (view change timeout)
        self.lastO = 0
        self.iteration = 0
        self.shift_interval_iters = 10  # 每10s发生一次workload shift
        
        # 双频率调参：requestTimeout 每 REQUEST_TIMEOUT_UPDATE_INTERVAL 步决策一次
        self.timeout_iteration = 0  # requestTimeout 的独立迭代计数器
        self.timeout_reward_accumulator = 0.0  # 累积 reward（10 步平均）
        self.timeout_reward_count = 0

    
    @abstractmethod
    def modelUpdate(self, batch_state, option):
        """
        主更新函数
        
        返回三元组：
        - option == 1: (batch_size, batch_timeout, request_timeout)
        - option == 2: (c_parameter, 0, request_timeout)
        
        request_timeout <= 0 表示本轮不更新 requestTimeout
        """
        pass
    
    def _enforce_timeout_constraint(self, request_timeout, batch_timeout):
        """
        强制执行 requestTimeout >= batchTimeout * 5 的安全约束。
        防止 requestTimeout 过短导致频繁触发 view change。
        """
        min_allowed = max(int(batch_timeout * 5), REQUEST_TIMEOUT_MIN)
        return max(request_timeout, min_allowed)
    
    def save_model(self):
        """保存模型（可选实现）"""
        pass
    
    def load_model(self):
        """加载模型（可选实现）"""
        pass
    
    def reset(self):
        """重置优化器状态"""
        self.old_state = []
        self.score = 0
        self.lastA = 0
        self.lastB = 0
        self.lastC = 0
        self.lastD = 0
        self.lastO = 0
        self.timeout_iteration = 0
        self.timeout_reward_accumulator = 0.0
        self.timeout_reward_count = 0

class BayesianOptimizer(OptimizerBase):
    """
    Sliding Window Contextual Bayesian Optimizer (Dual-GP Version)
    
    Features:
    1. GP1: Batch params (batchSize, batchTimeout) - updated every call (1s)
    2. GP2: RequestTimeout - updated every REQUEST_TIMEOUT_UPDATE_INTERVAL calls (10s)
       - GP2 takes current_batchTimeout as context input to learn coupling
    3. Safety constraint: requestTimeout >= max(batchTimeout * 5, 1000ms)
    4. Reward: Fixed-Max Normalization (0.5/-0.5 weights)
    """
    
    def __init__(self):
        super().__init__()
        
        # ============ 1. GP1 核函数配置 (Batch params) ============
        self.gp_kernel = Matern(
            nu=2.5,
            length_scale=[1.0] * 5,
            length_scale_bounds=(0.1, 100.0) 
        )
        
        self.gp_alpha = 1e-5
        self.gp_n_restarts = 5 
        
        # ============ 2. GP2 核函数配置 (RequestTimeout) ============
        self.gp_timeout_kernel = Matern(
            nu=2.5,
            length_scale=[1.0] * 3,  # 3维: arrival_rate, batchTimeout, requestTimeout
            length_scale_bounds=(0.1, 100.0)
        )
        
        # ============ 3. 探索-利用参数 ============
        # GP1 探索参数
        self.exploration_weight = 1.5
        self.exploration_decay = 0.995
        self.min_exploration_weight = 0.2
        
        # GP2 探索参数（独立衰减）
        self.timeout_exploration_weight = 2.0     # 初始探索更高（样本少）
        self.timeout_exploration_decay = 0.98      # 衰减更快（每10s才更新一次）
        self.min_timeout_exploration_weight = 0.3
        
        # ============ 4. 滑动窗口配置 ============
        self.window_size = 200          # GP1 窗口
        self.timeout_window_size = 50   # GP2 窗口（更新频率低，窗口小）
        
        # GP1 历史数据
        self.X_history = []
        self.y_history = []
        
        # GP2 历史数据
        self.X_timeout_history = []
        self.y_timeout_history = []
        
        # ============ 5. 模型初始化 ============
        self.gp = GaussianProcessRegressor(
            kernel=self.gp_kernel,
            alpha=self.gp_alpha,
            normalize_y=True,
            n_restarts_optimizer=self.gp_n_restarts
        )
        
        self.gp_timeout = GaussianProcessRegressor(
            kernel=self.gp_timeout_kernel,
            alpha=self.gp_alpha,
            normalize_y=True,
            n_restarts_optimizer=self.gp_n_restarts
        )
        
        self.pending_experience = None
        self.pending_timeout_experience = None  # GP2 pending experience
        self.model_path = "bo_model.pkl"
        
        # ============ 6. Reward 归一化常数 ============
        self.MAX_THR_LIMIT = THROUGHPUT_SCALE
        self.MAX_LAT_LIMIT = LATENCY_SCALE * 2
        
        # ============ 7. 初始 requestTimeout ============
        self.lastD = D_values[len(D_values) // 2].item()  # 中间值 5000ms
        
        print("[BO] Dual-GP Contextual BO initialized")
        print(f"[BO]   MAX_THR_LIMIT: {self.MAX_THR_LIMIT}, MAX_LAT_LIMIT: {self.MAX_LAT_LIMIT}")
        print(f"[BO]   Action space: BatchSize [{A_values.min().item()}-{A_values.max().item()}], "
              f"BatchTimeout [{B_values.min().item()}-{B_values.max().item()}], "
              f"RequestTimeout [{D_values.min().item()}-{D_values.max().item()}]")
        
    def _compute_derived_features(self, state, batch_size, batch_timeout):
        """构建 GP1 的 Context + Action + Derived Features"""
        norm_state = Normalized(state)
        interaction = batch_size * batch_timeout 
        ratio = batch_size / (batch_timeout + 1e-6)
        
        return np.concatenate([
            [norm_state[6]], # Context: arrival_rate
            [batch_size],    # Action
            [batch_timeout], # Action
            [interaction],   # Derived
            [ratio]          # Derived
        ])

    def _compute_timeout_features(self, state, batch_timeout, request_timeout):
        """构建 GP2 的特征: (arrival_rate, batchTimeout, requestTimeout)"""
        norm_state = Normalized(state)
        return np.array([
            norm_state[6],    # arrival_rate (context)
            batch_timeout,    # current batchTimeout (context - captures coupling)
            request_timeout   # action
        ])

    def _select_action_ucb(self, state):
        """GP1: 全动作空间 UCB 搜索 (batch params)"""
        candidate_features = []
        candidate_actions = []
        
        for a_val in A_values:
            for b_val in B_values:
                features = self._compute_derived_features(state, a_val.item(), b_val.item())
                candidate_features.append(features)
                candidate_actions.append((a_val.item(), b_val.item()))
        
        X_test = np.array(candidate_features)
        mu, sigma = self.gp.predict(X_test, return_std=True)
        ucb_values = mu + self.exploration_weight * sigma
        
        best_idx = np.argmax(ucb_values)
        return candidate_actions[best_idx]

    def _select_timeout_ucb(self, state, current_batch_timeout):
        """GP2: RequestTimeout UCB 搜索，带约束"""
        candidate_features = []
        candidate_actions = []
        
        for d_val in D_values:
            d = d_val.item()
            # 约束生效：只考虑满足约束的值
            d_constrained = self._enforce_timeout_constraint(d, current_batch_timeout)
            features = self._compute_timeout_features(state, current_batch_timeout, d_constrained)
            candidate_features.append(features)
            candidate_actions.append(d_constrained)
        
        X_test = np.array(candidate_features)
        mu, sigma = self.gp_timeout.predict(X_test, return_std=True)
        ucb_values = mu + self.timeout_exploration_weight * sigma
        
        best_idx = np.argmax(ucb_values)
        return candidate_actions[best_idx]

    def modelUpdate(self, batch_state, option):
        self.iteration += 1
        
        # ============ Option 2: 处理 C 参数 ============
        if option == 2:
            if len(self.old_state) == 0:
                self.old_state = batch_state
                self.lastO = option
            return 128, 0, self.lastD
            
        # ============ Option 1: 处理 Batch + RequestTimeout 参数 ============
        
        # --- 1. 冷启动逻辑 (Time Alignment Fix) ---
        if len(self.old_state) == 0:
            self.old_state = batch_state
            self.lastO = option
            
            # 初始动作
            self.lastA = A_values[len(A_values)//2].item()
            self.lastB = B_values[len(B_values)//2].item()
            self.lastD = D_values[len(D_values)//2].item()
            
            self.pending_experience = None 
            self.pending_timeout_experience = None
            
            print(f"[BO] Cold start: BS={self.lastA}, BT={self.lastB}, RT={self.lastD}")
            return self.lastA, self.lastB, self.lastD

        # --- 2. Reward 计算 (Fixed Max Norm + Equal Weights) ---
        curr_thr = batch_state[0]
        curr_lat = batch_state[1]
        
        norm_thr = curr_thr / self.MAX_THR_LIMIT
        norm_lat = curr_lat / self.MAX_LAT_LIMIT
        
        current_score = 100.0 * (0.5 * norm_thr - 0.5 * norm_lat)
        
        self.score += current_score

        # --- 3. 累积 reward 用于 GP2 (10步平均) ---
        self.timeout_reward_accumulator += current_score
        self.timeout_reward_count += 1

        # --- 4. GP1 经验记录 (Context + Action -> Reward) ---
        if self.pending_experience is not None and self.lastO == 1:
            X = self._compute_derived_features(
                self.pending_experience['state'],
                self.pending_experience['action_bs'],
                self.pending_experience['action_bt']
            )
            
            self.X_history.append(X)
            self.y_history.append(current_score)
            
            if len(self.X_history) > self.window_size:
                self.X_history.pop(0)
                self.y_history.pop(0)
            
            if len(self.X_history) >= 20:
                try:
                    self.gp.fit(np.array(self.X_history), np.array(self.y_history))
                except Exception as e:
                    print(f"[BO] GP1 fit error: {e}")

        # --- 5. GP2 经验记录 (每 10 步) ---
        self.timeout_iteration += 1
        should_update_timeout = (self.timeout_iteration % REQUEST_TIMEOUT_UPDATE_INTERVAL == 0)
        
        if should_update_timeout and self.timeout_reward_count > 0:
            avg_timeout_reward = self.timeout_reward_accumulator / self.timeout_reward_count
            
            # 记录 GP2 经验
            if self.pending_timeout_experience is not None:
                X_t = self._compute_timeout_features(
                    self.pending_timeout_experience['state'],
                    self.pending_timeout_experience['batch_timeout'],
                    self.pending_timeout_experience['request_timeout']
                )
                self.X_timeout_history.append(X_t)
                self.y_timeout_history.append(avg_timeout_reward)
                
                if len(self.X_timeout_history) > self.timeout_window_size:
                    self.X_timeout_history.pop(0)
                    self.y_timeout_history.pop(0)
                
                if len(self.X_timeout_history) >= 5:
                    try:
                        self.gp_timeout.fit(
                            np.array(self.X_timeout_history),
                            np.array(self.y_timeout_history)
                        )
                    except Exception as e:
                        print(f"[BO] GP2 fit error: {e}")
            
            # 重置累积器
            self.timeout_reward_accumulator = 0.0
            self.timeout_reward_count = 0

        self.old_state = batch_state
        self.lastO = option

        # --- 6. GP1: 选择 batch 动作 ---
        if len(self.X_history) < 20:
            a_idx = np.random.randint(0, len(A_values))
            b_idx = np.random.randint(0, len(B_values))
            new_a, new_b = A_values[a_idx].item(), B_values[b_idx].item()
            
            if self.iteration % 5 == 0:
                print(f"[BO] GP1 Random Init: {len(self.X_history)}/20 | Score: {current_score:.4f}")
        else:
            new_a, new_b = self._select_action_ucb(batch_state)
            
            self.exploration_weight = max(
                self.min_exploration_weight,
                self.exploration_weight * self.exploration_decay
            )

        self.lastA = new_a
        self.lastB = new_b
        
        # --- 7. GP2: 选择 requestTimeout (仅每 10 步) ---
        if should_update_timeout:
            if len(self.X_timeout_history) < 5:
                d_idx = np.random.randint(0, len(D_values))
                new_d = D_values[d_idx].item()
                new_d = self._enforce_timeout_constraint(new_d, self.lastB)
                
                print(f"[BO] GP2 Random Init: {len(self.X_timeout_history)}/5 | RT={new_d}")
            else:
                new_d = self._select_timeout_ucb(batch_state, self.lastB)
                
                self.timeout_exploration_weight = max(
                    self.min_timeout_exploration_weight,
                    self.timeout_exploration_weight * self.timeout_exploration_decay
                )
                print(f"[BO] GP2 UCB -> RT={new_d}, explore={self.timeout_exploration_weight:.3f}")
            
            self.lastD = new_d
            
            # 准备 GP2 pending experience
            self.pending_timeout_experience = {
                'state': batch_state.copy(),
                'batch_timeout': self.lastB,
                'request_timeout': self.lastD
            }
        
        # --- 8. 准备 GP1 pending experience ---
        self.pending_experience = {
            'state': batch_state.copy(),
            'action_bs': self.lastA,
            'action_bt': self.lastB
        }
        
        return self.lastA, self.lastB, self.lastD

    def get_algorithm_state(self):
        """适配 DataLogger 旧格式 + GP2 信息"""
        return {
            'exploration_weight': self.exploration_weight,
            'timeout_exploration_weight': self.timeout_exploration_weight,
            'regime_id': 0, 
            'regime_0_samples': len(self.X_history),
            'regime_1_samples': len(self.X_timeout_history),
            'regime_2_samples': 0,
            'regime_3_samples': 0
        }

    def save_model(self):
        """保存模型"""
        try:
            state = {
                'X_history': self.X_history,
                'y_history': self.y_history,
                'X_timeout_history': self.X_timeout_history,
                'y_timeout_history': self.y_timeout_history,
                'exploration_weight': self.exploration_weight,
                'timeout_exploration_weight': self.timeout_exploration_weight,
                'iteration': self.iteration,
                'timeout_iteration': self.timeout_iteration,
                'lastD': self.lastD
            }
            joblib.dump(state, self.model_path)
            print(f"[BO] Model saved to {self.model_path} "
                  f"(GP1: {len(self.X_history)} samples, GP2: {len(self.X_timeout_history)} samples)")
        except Exception as e:
            print(f"[BO] Failed to save model: {e}")

    def load_model(self):
        """加载模型"""
        if os.path.exists(self.model_path):
            try:
                state = joblib.load(self.model_path)
                self.X_history = state.get('X_history', [])
                self.y_history = state.get('y_history', [])
                self.X_timeout_history = state.get('X_timeout_history', [])
                self.y_timeout_history = state.get('y_timeout_history', [])
                self.exploration_weight = state.get('exploration_weight', 2.0)
                self.timeout_exploration_weight = state.get('timeout_exploration_weight', 2.0)
                self.iteration = state.get('iteration', 0)
                self.timeout_iteration = state.get('timeout_iteration', 0)
                self.lastD = state.get('lastD', D_values[len(D_values) // 2].item())
                
                if len(self.X_history) > 0:
                    self.gp.fit(np.array(self.X_history), np.array(self.y_history))
                if len(self.X_timeout_history) > 0:
                    self.gp_timeout.fit(np.array(self.X_timeout_history), np.array(self.y_timeout_history))
                    
                print(f"[BO] Model loaded. GP1: {len(self.X_history)} samples, "
                      f"GP2: {len(self.X_timeout_history)} samples")
            except Exception as e:
                print(f"[BO] Failed to load model: {e}")

    def reset(self):
        super().reset()
        self.X_history = []
        self.y_history = []
        self.X_timeout_history = []
        self.y_timeout_history = []
        self.exploration_weight = 1.5
        self.timeout_exploration_weight = 2.0
        self.pending_experience = None
        self.pending_timeout_experience = None
        self.lastD = D_values[len(D_values) // 2].item()
        self.gp = GaussianProcessRegressor(
            kernel=self.gp_kernel,
            alpha=self.gp_alpha,
            normalize_y=True,
            n_restarts_optimizer=self.gp_n_restarts
        )
        self.gp_timeout = GaussianProcessRegressor(
            kernel=self.gp_timeout_kernel,
            alpha=self.gp_alpha,
            normalize_y=True,
            n_restarts_optimizer=self.gp_n_restarts
        )
        print("[BO] Optimizer reset (both GPs)")

class SimulatedAnnealing(OptimizerBase):
    """
    适应动态工作负载的模拟退火优化器（完整修复版）
    
    核心修复：
    1. 参数空间从全局动作空间动态获取
    2. 延迟归一化逻辑修正（降低时快速适应）
    3. previous_score 显式初始化
    4. 初始化时序优化（第一次返回初始参数）
    5. get_algorithm_state() 返回完整字段
    6. save/load_model() 保存完整状态
    7. Reheat 策略优化（遗忘历史适应新环境）
    """
    
    def __init__(self):
        super().__init__()
        
        # ============= SA 超参数 =============
        self.initial_temperature = 0.5  
        self.temperature = self.initial_temperature
        self.min_temperature = 0.005
        self.cooling_rate = 0.99
        
        # requestTimeout: SA 不主动调参，使用固定中间值
        self.lastD = D_values[len(D_values) // 2].item()
        
        # ============= 动态归一化参数 =============
        # 使用全局缩放因子作为初始参考值
        self.ref_thr = THROUGHPUT_SCALE / 10  # 初始参考吞吐量 10k
        self.ref_lat = LATENCY_SCALE / 5      # 初始参考延迟 10k 微秒
        self.decay_rate = 0.8
        
        # ============= 状态追踪 =============
        # 使用动作空间的中间值作为初始参数
        initial_batch = A_values[len(A_values) // 2].item()    # 动作空间中间值
        initial_timeout = B_values[len(B_values) // 2].item()  # 动作空间中间值
        
        self.current_params = {
            'batch': initial_batch,
            'timeout': initial_timeout
        }
        
        self.previous_score = None 
        self.current_score = -1.0
        
        self.best_score = float('-inf')
        self.best_params = {
            'batch': initial_batch,
            'timeout': initial_timeout
        }
        
        self.no_improvement_count = 0
        self.reheat_threshold = 50
        
        self.reheat_count = 0
        self.accepted_worse = 0
        
        self.model_path = "sa_checkpoint.json"
        
        print("[SA] ✅ Initialized with all fixes applied")
        # 修改1：添加 .item() 让打印格式更清晰
        print(f"[SA]    - Action space: Batch [{A_values.min().item()}-{A_values.max().item()}], "
              f"Timeout [{B_values.min().item()}-{B_values.max().item()}]")
        print(f"[SA]    - Initial params: Batch={initial_batch}, Timeout={initial_timeout}")
        print(f"[SA]    - Temperature: {self.temperature:.3f}, Cooling: {self.cooling_rate}")

    def get_exploration_range(self):
        """根据当前温度动态调整搜索步长"""
        norm_temp = (self.temperature - self.min_temperature) / \
                    (self.initial_temperature - self.min_temperature + 1e-8)
        norm_temp = np.clip(norm_temp, 0, 1)
        return 0.02 + 0.28 * norm_temp

    def generate_neighbor(self, current_a, current_b):
        """
        生成邻域解
        ✅ 修复1：从全局动作空间动态获取范围
        """
        scale = self.get_exploration_range()
        
        min_batch = A_values.min().item()
        max_batch = A_values.max().item()
        min_timeout = B_values.min().item()
        max_timeout = B_values.max().item()
        
        batch_sigma = (max_batch - min_batch) * scale
        timeout_sigma = (max_timeout - min_timeout) * scale
        
        new_batch_raw = current_a + np.random.normal(0, batch_sigma)
        new_timeout_raw = current_b + np.random.normal(0, timeout_sigma)
        
        new_batch_raw = np.clip(new_batch_raw, min_batch, max_batch)
        new_timeout_raw = np.clip(new_timeout_raw, min_timeout, max_timeout)
        
        a_idx = torch.argmin(torch.abs(A_values - new_batch_raw))
        b_idx = torch.argmin(torch.abs(B_values - new_timeout_raw))
        
        return A_values[a_idx].item(), B_values[b_idx].item()

    def normalize_reward(self, throughput, latency):
        """
        非对称动态归一化
        ✅ 修复2：延迟降低时快速适应，升高时缓慢适应
        """
        # 1. Throughput: 升高时瞬间适应（新高度）
        if throughput > self.ref_thr:
            self.ref_thr = throughput
        else:
            self.ref_thr = max(throughput, self.ref_thr * self.decay_rate)
            
        # 2. Latency: 降低时瞬间适应（新低点）
        # 修改2：添加修复标记，明确这是修复后的逻辑
        # ✅ 修复2核心：延迟降低（好事）时瞬间适应
        if latency < self.ref_lat:  # 注意：< 而不是 >
            self.ref_lat = latency
        else:
            self.ref_lat = max(latency, self.ref_lat * self.decay_rate)
            
        safe_ref_thr = max(self.ref_thr, 1.0)
        safe_ref_lat = max(self.ref_lat, 1.0)
        
        norm_thr = throughput / safe_ref_thr
        norm_lat = latency / safe_ref_lat
        
        # 加权求和: 0.5 * Thr - 0.5 * Lat
        score = 0.5 * norm_thr - 0.5 * norm_lat
        return score

    def modelUpdate(self, batch_state, option):
        """
        主更新循环
        ✅ 修复3：previous_score 显式初始化
        ✅ 修复4：初始化时序优化
        """
        # Option 2: 通信共识（不进行 SA 更新）
        if option == 2:
            if len(self.old_state) == 0:
                self.old_state = batch_state
                self.lastO = option
            return 128, 0, self.lastD

        self.iteration += 1
        
        curr_thr = batch_state[0]
        curr_lat = batch_state[1]
        
        # ✅ 修复4：初始化逻辑 - 第一次直接返回初始参数
        if len(self.old_state) == 0:
            self.old_state = batch_state
            self.lastO = option
            self.lastA = self.current_params['batch']
            self.lastB = self.current_params['timeout']
            print(f"[SA] Iter {self.iteration}: Initialization -> BS={self.lastA}, BT={self.lastB}, RT={self.lastD}")
            return self.lastA, self.lastB, self.lastD

        # 计算当前得分
        current_score = self.normalize_reward(curr_thr, curr_lat)
        
        # ✅ 修复3：使用显式初始化的 previous_score
        if self.previous_score is None:
            self.previous_score = current_score
            delta = 0
            print(f"[SA] Iter {self.iteration}: Baseline established score={current_score:.4f}")
        else:
            delta = current_score - self.previous_score
        
        # Metropolis 准则
        accept = False
        
        if delta > 0:
            accept = True
            self.no_improvement_count = 0
            if current_score > self.best_score:
                self.best_score = current_score
                self.best_params['batch'] = self.lastA
                self.best_params['timeout'] = self.lastB
                print(f"[SA] 🎯 New Best: {self.best_score:.4f} at BS={self.lastA}, BT={self.lastB}")
        else:
            if self.temperature > 0:
                probability = np.exp(delta / self.temperature)
                if np.random.random() < probability:
                    accept = True
                    self.accepted_worse += 1
            self.no_improvement_count += 1

        # 执行接受或拒绝
        if accept:
            self.previous_score = current_score
            self.current_params['batch'] = self.lastA
            self.current_params['timeout'] = self.lastB
        
        # ✅ 修复7：Reheat 逻辑（遗忘历史适应新环境）
        if self.no_improvement_count >= self.reheat_threshold:
            print(f"\n{'='*60}")
            print(f"[SA] 🔥 REHEAT #{self.reheat_count + 1} at iter {self.iteration}")
            print(f"[SA]    Environment may have changed - resetting search")
            print(f"{'='*60}\n")
            self.temperature = self.initial_temperature
            self.no_improvement_count = 0
            self.reheat_count += 1
            self.best_score = float('-inf')  # 遗忘历史
        else:
            self.temperature = max(self.min_temperature, 
                                  self.temperature * self.cooling_rate)

        # 生成下一步动作
        next_a, next_b = self.generate_neighbor(
            self.current_params['batch'], 
            self.current_params['timeout']
        )
        
        self.lastA = next_a
        self.lastB = next_b
        self.old_state = batch_state
        self.score = current_score
        
        # 修改3：添加定期监控日志
        if self.iteration % 50 == 0:
            print(f"[SA] Iter {self.iteration:4d}: T={self.temperature:.4f}, "
                  f"Score={current_score:.4f}, Best={self.best_score:.4f}, "
                  f"No-improve={self.no_improvement_count}")
        
        return next_a, next_b, self.lastD

    def get_algorithm_state(self):
        """
        返回内部状态用于日志记录
        ✅ 修复5：返回完整的8个字段
        """
        return {
            'temperature': self.temperature,
            'best_score': self.best_score,
            'current_score': self.score,
            'no_improvement_count': self.no_improvement_count,
            'ref_thr': self.ref_thr,
            'ref_lat': self.ref_lat,
            'reheat_count': self.reheat_count,
            'accepted_worse': self.accepted_worse
        }

    def save_model(self):
        """
        保存当前搜索状态
        ✅ 修复6：保存完整状态（包括 previous_score 等）
        """
        state = {
            'iteration': self.iteration,
            'current_params': {
                'batch': int(self.current_params['batch']),
                'timeout': int(self.current_params['timeout'])
            },
            'best_params': {
                'batch': int(self.best_params['batch']),
                'timeout': int(self.best_params['timeout'])
            },
            'temperature': float(self.temperature),
            'ref_thr': float(self.ref_thr),
            'ref_lat': float(self.ref_lat),
            'best_score': float(self.best_score),
            'previous_score': float(self.previous_score) if self.previous_score is not None else None,
            'current_score': float(self.score),
            'no_improvement_count': int(self.no_improvement_count),
            'reheat_count': int(self.reheat_count),
            'accepted_worse': int(self.accepted_worse)
        }
        try:
            with open(self.model_path, 'w') as f:
                json.dump(state, f, indent=2)
            print(f"[SA] ✅ State saved to {self.model_path}")
            print(f"[SA]    Iter={self.iteration}, Best={self.best_score:.4f}, T={self.temperature:.4f}")
        except Exception as e:
            print(f"[SA] ❌ Failed to save state: {e}")

    def load_model(self):
        """
        加载上次的搜索状态
        ✅ 修复6：加载完整状态
        """
        if not os.path.exists(self.model_path):
            print("[SA] No checkpoint found, starting fresh")
            return

        try:
            with open(self.model_path, 'r') as f:
                state = json.load(f)
            
            self.iteration = state.get('iteration', 0)
            self.current_params = state.get('current_params', self.current_params)
            self.best_params = state.get('best_params', self.best_params)
            self.temperature = state.get('temperature', self.initial_temperature)
            self.ref_thr = state.get('ref_thr', 1000.0)
            self.ref_lat = state.get('ref_lat', 100.0)
            self.best_score = state.get('best_score', float('-inf'))
            self.previous_score = state.get('previous_score', None)
            self.score = state.get('current_score', -1.0)
            self.no_improvement_count = state.get('no_improvement_count', 0)
            self.reheat_count = state.get('reheat_count', 0)
            self.accepted_worse = state.get('accepted_worse', 0)
            
            print(f"[SA] ✅ State loaded from {self.model_path}")
            print(f"[SA]    Resuming from iter {self.iteration}")
            print(f"[SA]    Best={self.best_score:.4f}, T={self.temperature:.4f}, Reheat={self.reheat_count}")
        except Exception as e:
            print(f"[SA] ❌ Failed to load state: {e}")
            print("[SA]    Starting with default initialization")

# ============= PPO 实现 =============
class PPO(nn.Module, OptimizerBase):
    """PPO 算法 - 支持双频率调参: batch(1s) + requestTimeout(10s)"""
    
    def __init__(self):
        super(PPO, self).__init__()
        OptimizerBase.__init__(self)  # 初始化基类
        
        self.data = []
        self.timeout_data = []  # requestTimeout 的独立经验缓冲区

        # 输入维度: [throughput, latency, size, tot_thr, tot_lat, tot_size, arrival_rate]
        input_dims = 7
        hidden_dims = 64

        self.fc1 = nn.Linear(input_dims, hidden_dims)
        self.fc_pi_a = nn.Linear(hidden_dims, len(A_values))
        self.fc_pi_b = nn.Linear(hidden_dims, len(B_values))
        self.fc_pi_c = nn.Linear(hidden_dims, len(C_values))
        self.fc_pi_d = nn.Linear(hidden_dims, len(D_values))  # requestTimeout head
        self.fc_v = nn.Linear(hidden_dims, 1)

        self.optimizer = optim.Adam(self.parameters(), lr=learning_rate)
        
        # 初始 requestTimeout
        self.lastD = D_values[len(D_values) // 2].item()

    def pi(self, x, softmax_dim=-1):
        x = F.relu(self.fc1(x))
        prob_a = F.softmax(self.fc_pi_a(x), dim=softmax_dim)
        prob_b = F.softmax(self.fc_pi_b(x), dim=softmax_dim)
        prob_c = F.softmax(self.fc_pi_c(x), dim=softmax_dim)
        return prob_a, prob_b, prob_c

    def pi_d(self, x, softmax_dim=-1):
        """RequestTimeout 策略头（独立输出）"""
        x = F.relu(self.fc1(x))
        prob_d = F.softmax(self.fc_pi_d(x), dim=softmax_dim)
        return prob_d

    def v(self, x):
        x = F.relu(self.fc1(x))
        return self.fc_v(x)

    def put_data(self, transition):
        self.data.append(transition)

    def put_timeout_data(self, transition):
        """存储 timeout 经验: (s, d, r, s_prime, prob_d)"""
        self.timeout_data.append(transition)

    def make_batch(self):
        s_lst, a_lst, b_lst, c_lst, r_lst, s_prime_lst = [], [], [], [], [], []
        prob_a_lst, prob_b_lst, prob_c_lst = [], [], []

        for transition in self.data:
            s, a, b, c, r, s_prime, p_a, p_b, p_c = transition
            s_lst.append(s)
            a_lst.append([a])
            b_lst.append([b])
            c_lst.append([c])
            r_lst.append([r])
            s_prime_lst.append(s_prime)
            prob_a_lst.append([p_a])
            prob_b_lst.append([p_b])
            prob_c_lst.append([p_c])

        s = torch.tensor(np.array(s_lst), dtype=torch.float)
        a = torch.tensor(np.array(a_lst))
        b = torch.tensor(np.array(b_lst))
        c = torch.tensor(np.array(c_lst))
        r = torch.tensor(np.array(r_lst))
        s_prime = torch.tensor(np.array(s_prime_lst), dtype=torch.float)
        prob_a = torch.tensor(np.array(prob_a_lst))
        prob_b = torch.tensor(np.array(prob_b_lst))
        prob_c = torch.tensor(np.array(prob_c_lst))
        
        self.data = []
        return s, a, b, c, r, s_prime, prob_a, prob_b, prob_c

    def make_timeout_batch(self):
        """构建 timeout 训练批次"""
        s_lst, d_lst, r_lst, s_prime_lst, prob_d_lst = [], [], [], [], []
        
        for s, d, r, s_prime, p_d in self.timeout_data:
            s_lst.append(s)
            d_lst.append([d])
            r_lst.append([r])
            s_prime_lst.append(s_prime)
            prob_d_lst.append([p_d])
        
        s = torch.tensor(np.array(s_lst), dtype=torch.float)
        d = torch.tensor(np.array(d_lst))
        r = torch.tensor(np.array(r_lst))
        s_prime = torch.tensor(np.array(s_prime_lst), dtype=torch.float)
        prob_d = torch.tensor(np.array(prob_d_lst))
        
        self.timeout_data = []
        return s, d, r, s_prime, prob_d

    def train_net(self):
        s, a, b, c, r, s_prime, prob_a, prob_b, prob_c = self.make_batch()
        
        for i in range(K_epoch):
            td_target = r + gamma * self.v(s_prime)
            delta = td_target - self.v(s)
            delta = delta.detach().numpy()

            advantage_lst = []
            advantage = 0.0
            for delta_t in delta[::-1]:
                advantage = gamma * lmbda * advantage + delta_t[0]
                advantage_lst.append([advantage])
            advantage_lst.reverse()
            advantage = torch.tensor(advantage_lst, dtype=torch.float)

            mask_a = (a != 0).float()
            mask_b = (b != 0).float()
            mask_c = (c != 0).float()

            pi_a, pi_b, pi_c = self.pi(s, softmax_dim=1)
            pi_a = pi_a.gather(1, a)
            pi_b = pi_b.gather(1, b)
            pi_c = pi_c.gather(1, c)
            
            ratio_a = torch.exp(torch.log(pi_a) - torch.log(prob_a))
            ratio_b = torch.exp(torch.log(pi_b) - torch.log(prob_b))
            ratio_c = torch.exp(torch.log(pi_c) - torch.log(prob_c))

            surr1 = (ratio_a * advantage * mask_a + 
                     ratio_b * advantage * mask_b + 
                     ratio_c * advantage * mask_c)
            
            surr2 = (torch.clamp(ratio_a, 1 - eps_clip, 1 + eps_clip) * advantage * mask_a +
                     torch.clamp(ratio_b, 1 - eps_clip, 1 + eps_clip) * advantage * mask_b +
                     torch.clamp(ratio_c, 1 - eps_clip, 1 + eps_clip) * advantage * mask_c)
            
            loss = -torch.min(surr1, surr2).mean() + F.smooth_l1_loss(self.v(s), td_target.detach())

            self.optimizer.zero_grad()
            loss.mean().backward()
            self.optimizer.step()

    def train_timeout_net(self):
        """训练 timeout 策略头（独立 PPO 更新）"""
        if len(self.timeout_data) == 0:
            return
        
        s, d, r, s_prime, prob_d = self.make_timeout_batch()
        
        for i in range(K_epoch):
            td_target = r + gamma * self.v(s_prime)
            delta = td_target - self.v(s)
            delta = delta.detach().numpy()
            
            advantage_lst = []
            advantage = 0.0
            for delta_t in delta[::-1]:
                advantage = gamma * lmbda * advantage + delta_t[0]
                advantage_lst.append([advantage])
            advantage_lst.reverse()
            advantage = torch.tensor(advantage_lst, dtype=torch.float)
            
            pi_d = self.pi_d(s, softmax_dim=1)
            pi_d = pi_d.gather(1, d)
            
            ratio_d = torch.exp(torch.log(pi_d) - torch.log(prob_d))
            
            surr1 = ratio_d * advantage
            surr2 = torch.clamp(ratio_d, 1 - eps_clip, 1 + eps_clip) * advantage
            
            loss = -torch.min(surr1, surr2).mean() + F.smooth_l1_loss(self.v(s), td_target.detach())
            
            self.optimizer.zero_grad()
            loss.mean().backward()
            self.optimizer.step()

    def select_action(self, s):
        prob_a, prob_b, prob_c = self.pi(torch.from_numpy(s).float())
        a = Categorical(prob_a).sample().item()
        b = Categorical(prob_b).sample().item()
        c = Categorical(prob_c).sample().item()
        return a, b, c

    def select_timeout_action(self, s):
        """选择 requestTimeout 动作"""
        prob_d = self.pi_d(torch.from_numpy(s).float())
        d = Categorical(prob_d).sample().item()
        return d, prob_d[d].item()

    def modelUpdate(self, batch_state, option):
        """PPO 双频率更新逻辑"""
        
        # 使用动作空间的中间值作为初始参数
        initial_batch = A_values[len(A_values) // 2].item()
        initial_timeout = B_values[len(B_values) // 2].item()
        
        # 初始化
        if len(self.old_state) == 0:
            self.old_state = batch_state
            self.lastO = option
            self.lastD = D_values[len(D_values) // 2].item()
            if option == 1:
                self.lastA, self.lastB = initial_batch, initial_timeout
                return self.lastA, self.lastB, self.lastD
            else:  # option == 2
                self.lastC = 128
                return self.lastC, 0, self.lastD

        # 计算 reward (使用归一化后的值)
        norm_thr = self.old_state[0] / THROUGHPUT_SCALE
        norm_lat = self.old_state[1] / LATENCY_SCALE
        reward = c_thr * norm_thr + c_lat * norm_lat

        norm_state = Normalized(self.old_state)
        prob_a, prob_b, prob_c = self.pi(torch.from_numpy(norm_state).float())
        
        a = (torch.abs(A_values - self.lastA)).argmin().item()
        b = (torch.abs(B_values - self.lastB)).argmin().item()
        c = (torch.abs(C_values - self.lastC)).argmin().item()

        # 存储 batch 经验
        if self.lastO == 1:
            self.put_data((norm_state, a, b, 0, reward, Normalized(batch_state),
                          prob_a[a].item(), prob_b[b].item(), 1.0))
        else:
            self.put_data((norm_state, 0, 0, c, reward, Normalized(batch_state),
                          1.0, 1.0, prob_c[c].item()))
        
        self.score += reward

        # 累积 timeout reward
        self.timeout_reward_accumulator += reward
        self.timeout_reward_count += 1

        # 训练 batch 网络
        if len(self.data) >= 1:
            self.train_net()

        # 更新状态
        self.old_state = batch_state
        self.lastO = option

        # --- Timeout 双频率逻辑 ---
        self.timeout_iteration += 1
        should_update_timeout = (self.timeout_iteration % REQUEST_TIMEOUT_UPDATE_INTERVAL == 0)
        
        if should_update_timeout and self.timeout_reward_count > 0:
            avg_reward = self.timeout_reward_accumulator / self.timeout_reward_count
            
            # 存储 timeout 经验（使用上一轮的 timeout 动作和累积 reward）
            d_idx = (torch.abs(D_values - self.lastD)).argmin().item()
            prob_d = self.pi_d(torch.from_numpy(norm_state).float())
            self.put_timeout_data((norm_state, d_idx, avg_reward, 
                                   Normalized(batch_state), prob_d[d_idx].item()))
            
            # 训练 timeout 网络
            if len(self.timeout_data) >= 1:
                self.train_timeout_net()
            
            # 选择新的 timeout
            d_new, _ = self.select_timeout_action(Normalized(batch_state))
            new_d = D_values[d_new].item()
            new_d = self._enforce_timeout_constraint(new_d, self.lastB if option == 1 else 
                                                      B_values[len(B_values) // 2].item())
            self.lastD = new_d
            
            print(f"[PPO] Timeout update: RT={self.lastD}, avg_reward={avg_reward:.4f}")
            
            # 重置累积器
            self.timeout_reward_accumulator = 0.0
            self.timeout_reward_count = 0

        # 选择下一个 batch 动作
        a, b, c = self.select_action(Normalized(self.old_state))
        
        if option == 1:
            self.lastA = A_values[a].item()
            self.lastB = B_values[b].item()
            return self.lastA, self.lastB, self.lastD
        else:  # option == 2
            self.lastC = C_values[c].item()
            return self.lastC, 0, self.lastD
    
    # ========== PPO 状态导出 ==========
    def get_algorithm_state(self):
        """导出算法状态用于记录"""
        return {
            'data_buffer_size': len(self.data),
            'timeout_buffer_size': len(self.timeout_data)
        }

    def save_model(self):
        model_path = 'ppo_model.pth'
        torch.save({
            'model_state': self.state_dict(),
            'optimizer_state': self.optimizer.state_dict(),
            'lastD': self.lastD,
            'timeout_iteration': self.timeout_iteration
        }, model_path)

    def load_model(self):
        model_path = 'ppo_model.pth'
        if os.path.exists(model_path):
            checkpoint = torch.load(model_path)
            self.load_state_dict(checkpoint['model_state'])
            self.optimizer.load_state_dict(checkpoint['optimizer_state'])
            self.lastD = checkpoint.get('lastD', D_values[len(D_values) // 2].item())
            self.timeout_iteration = checkpoint.get('timeout_iteration', 0)

# ============= Static Optimizer =============
class StaticOptimizer(OptimizerBase):
    """静态优化器 - 保持初始参数不变
    
    参数可以通过环境变量设置：
      STATIC_BATCH_SIZE    - 批量大小 (默认: 动作空间中间值)
      STATIC_BATCH_TIMEOUT - 批量超时 (默认: 动作空间中间值)
      STATIC_REQUEST_TIMEOUT - 请求超时 (默认: D_values中间值)
    """
    
    def __init__(self):
        super().__init__()
        
        # 从环境变量读取参数，如果未设置则使用动作空间的中间值
        env_batch_size = os.environ.get('STATIC_BATCH_SIZE')
        env_batch_timeout = os.environ.get('STATIC_BATCH_TIMEOUT')
        
        if env_batch_size is not None:
            self.default_batch_size = int(env_batch_size)
            print(f"[STATIC] BatchSize from environment: {self.default_batch_size}")
        else:
            self.default_batch_size = A_values[len(A_values)//2].item()
            print(f"[STATIC] BatchSize from default (middle of action space): {self.default_batch_size}")
        
        if env_batch_timeout is not None:
            self.default_batch_timeout = int(env_batch_timeout)
            print(f"[STATIC] BatchTimeout from environment: {self.default_batch_timeout}")
        else:
            self.default_batch_timeout = B_values[len(B_values)//2].item()
            print(f"[STATIC] BatchTimeout from default (middle of action space): {self.default_batch_timeout}")
        
        self.default_c_parameter = 128  # 默认的 C 参数
        
        # RequestTimeout 参数
        env_request_timeout = os.environ.get('STATIC_REQUEST_TIMEOUT')
        if env_request_timeout is not None:
            self.default_request_timeout = int(env_request_timeout)
            print(f"[STATIC] RequestTimeout from environment: {self.default_request_timeout}")
        else:
            self.default_request_timeout = D_values[len(D_values)//2].item()
            print(f"[STATIC] RequestTimeout from default (middle of action space): {self.default_request_timeout}")
        self.lastD = self.default_request_timeout
        
        # 是否已经初始化
        self.initialized = False
        
        print(f"[STATIC] Initialized with parameters:")
        print(f"  Batch Size: {self.default_batch_size}")
        print(f"  Batch Timeout: {self.default_batch_timeout}")
        print(f"  Request Timeout: {self.default_request_timeout}")
        print(f"  C Parameter: {self.default_c_parameter}")
    
    def modelUpdate(self, batch_state, option):
        """静态优化器更新 - 始终返回初始参数"""
        
        # ========== 第一次调用：初始化 ==========
        if not self.initialized:
            self.old_state = batch_state
            self.lastO = option
            self.initialized = True
            
            if option == 1:
                self.lastA = self.default_batch_size
                self.lastB = self.default_batch_timeout
                print(f"[STATIC] First call (option=1): BS={self.lastA}, BT={self.lastB}, RT={self.lastD}")
                return self.lastA, self.lastB, self.lastD
            else:  # option == 2
                self.lastC = self.default_c_parameter
                print(f"[STATIC] First call (option=2): C={self.lastC}")
                return self.lastC, 0, self.lastD
        
        # ========== 后续调用：计算 reward 但不改变参数 ==========
        # 计算当前 reward（使用归一化值）
        norm_thr = batch_state[0] / THROUGHPUT_SCALE
        norm_lat = batch_state[1] / LATENCY_SCALE
        reward = c_thr * norm_thr + c_lat * norm_lat
        self.score += reward
        
        # 更新状态
        self.old_state = batch_state
        self.lastO = option
        
        # ========== option == 1: 返回固定的 batch size 和 timeout ==========
        if option == 1:
            return self.default_batch_size, self.default_batch_timeout, self.lastD
        
        # ========== option == 2: 返回固定的 C 参数 ==========
        else:
            return self.default_c_parameter, 0, self.lastD
    
    def save_model(self):
        """保存模型参数（对于静态优化器来说是空操作）"""
        import json
        save_data = {
            'algorithm': 'STATIC',
            'default_batch_size': self.default_batch_size,
            'default_batch_timeout': self.default_batch_timeout,
            'default_c_parameter': self.default_c_parameter,
            'final_score': float(self.score)
        }
        with open('static_params.json', 'w') as f:
            json.dump(save_data, f, indent=2)
        print(f"[STATIC] Saved parameters and final score: {self.score:.4f}")
    
    def load_model(self):
        """加载模型参数（对于静态优化器来说是空操作）"""
        print("[STATIC] No model to load - using default parameters")
    
    def reset(self):
        """重置优化器状态"""
        super().reset()
        self.initialized = False

# ============= Cyclic Configuration Optimizer =============
class CyclicConfigOptimizer(OptimizerBase):
    """
    周期性配置优化器 - 以固定时间间隔循环切换预定义的配置
    
    特点：
    - 每10秒切换一次配置
    - 循环遍历预定义的配置列表
    - 仅处理 option=1 的调参（batch_size, batch_timeout）
    """
    
    def __init__(self, config_list=None, cycle_interval=10):
        """
        初始化
        
        Args:
            config_list: 配置列表，格式为 [(batch_size, batch_timeout), ...]
                        默认使用动作空间中的多个配置
            cycle_interval: 切换周期（秒），默认10秒
        """
        super().__init__()
        
        # 默认配置列表 - 使用动作空间中有意义的不同配置
        if config_list is None:
            # 从动作空间中选择代表性配置
            min_bs, max_bs = A_values.min().item(), A_values.max().item()
            min_bt, max_bt = B_values.min().item(), B_values.max().item()
            mid_bs = A_values[len(A_values) // 2].item()
            mid_bt = B_values[len(B_values) // 2].item()
            
            self.config_list = [
                (min_bs, min_bt),   # 最小 batch, 最小 timeout (低延迟)
                (max_bs, max_bt),   # 最大 batch, 最大 timeout (高吞吐)
                (mid_bs, mid_bt),   # 中间值
                (max_bs, min_bt),   # 大 batch, 小 timeout
            ]
        else:
            self.config_list = config_list
        
        # 周期参数
        self.cycle_interval = cycle_interval  # 切换周期（秒）
        self.current_config_index = 0          # 当前配置索引
        
        # 时间追踪
        self.start_time = None                 # 开始时间
        self.last_switch_time = None          # 上次切换时间
        
        # 默认的 C 参数（用于 option=2）
        self.default_c_parameter = 128
        
        # RequestTimeout: 使用固定中间值（Cyclic 不主动调参）
        self.lastD = D_values[len(D_values) // 2].item()
        
        # 统计信息
        self.switch_count = 0                  # 切换次数
        self.config_usage_count = {i: 0 for i in range(len(self.config_list))}
        
        print(f"[CYCLIC] Initialized CyclicConfigOptimizer")
        print(f"[CYCLIC] Cycle interval: {self.cycle_interval} seconds")
        print(f"[CYCLIC] Configuration list:")
        for i, (bs, bt) in enumerate(self.config_list):
            print(f"[CYCLIC]   Config {i}: batch_size={bs}, batch_timeout={bt}")
    
    def _should_switch_config(self):
        """
        判断是否应该切换配置
        
        Returns:
            bool: True 如果应该切换，False 否则
        """
        if self.last_switch_time is None:
            return False
        
        current_time = time.time()
        elapsed = current_time - self.last_switch_time
        
        return elapsed >= self.cycle_interval
    
    def _switch_to_next_config(self):
        """切换到下一个配置"""
        # 更新索引（循环）
        self.current_config_index = (self.current_config_index + 1) % len(self.config_list)
        
        # 更新切换时间
        self.last_switch_time = time.time()
        
        # 更新统计
        self.switch_count += 1
        self.config_usage_count[self.current_config_index] += 1
        
        # 获取新配置
        new_bs, new_bt = self.config_list[self.current_config_index]
        
        print(f"\n{'='*60}")
        print(f"[CYCLIC] 🔄 Configuration Switch #{self.switch_count}")
        print(f"[CYCLIC] Time: {time.time() - self.start_time:.1f}s since start")
        print(f"[CYCLIC] New Config Index: {self.current_config_index}")
        print(f"[CYCLIC] New Parameters: batch_size={new_bs}, batch_timeout={new_bt}")
        print(f"{'='*60}\n")
        
        return new_bs, new_bt
    
    def modelUpdate(self, batch_state, option):
        """
        主更新函数
        
        Args:
            batch_state: [throughput, latency, payload, tot_thr, tot_lat, tot_size]
            option: 1=调整batch参数, 2=调整C参数
        
        Returns:
            option=1: (batch_size, batch_timeout)
            option=2: (128, 0)  # 默认C参数
        """
        
        # ========== 第一次调用：初始化 ==========
        if len(self.old_state) == 0:
            self.old_state = batch_state
            self.lastO = option
            
            # 初始化时间
            self.start_time = time.time()
            self.last_switch_time = time.time()
            
            # 使用第一个配置
            self.lastA, self.lastB = self.config_list[self.current_config_index]
            self.config_usage_count[self.current_config_index] += 1
            
            if option == 1:
                print(f"[CYCLIC] First call (option=1): BS={self.lastA}, BT={self.lastB}, RT={self.lastD}")
                return self.lastA, self.lastB, self.lastD
            else:  # option == 2
                self.lastC = self.default_c_parameter
                print(f"[CYCLIC] First call (option=2): C={self.lastC}")
                return self.lastC, 0, self.lastD
        
        # ========== 计算 reward（使用归一化值）==========
        norm_thr = batch_state[0] / THROUGHPUT_SCALE
        norm_lat = batch_state[1] / LATENCY_SCALE
        reward = c_thr * norm_thr + c_lat * norm_lat
        self.score += reward
        
        # ========== 检查是否需要切换配置 ==========
        if self._should_switch_config():
            new_bs, new_bt = self._switch_to_next_config()
            self.lastA = new_bs
            self.lastB = new_bt
        
        # 更新状态
        self.old_state = batch_state
        self.lastO = option
        
        # ========== option == 1: 返回当前配置 ==========
        if option == 1:
            return self.lastA, self.lastB, self.lastD
        
        # ========== option == 2: 返回默认 C 参数 ==========
        else:
            return self.default_c_parameter, 0, self.lastD
    
    def get_algorithm_state(self):
        """
        导出算法状态用于记录
        
        Returns:
            dict: 包含当前配置索引、切换次数等信息
        """
        current_time = time.time()
        elapsed_since_start = current_time - self.start_time if self.start_time else 0
        elapsed_since_switch = current_time - self.last_switch_time if self.last_switch_time else 0
        
        return {
            'config_index': self.current_config_index,
            'switch_count': self.switch_count,
            'elapsed_since_start': elapsed_since_start,
            'elapsed_since_switch': elapsed_since_switch,
            'current_batch_size': self.lastA,
            'current_batch_timeout': self.lastB
        }
    
    def save_model(self):
        """保存优化器状态和统计信息"""
        save_data = {
            'algorithm': 'CYCLIC',
            'cycle_interval': self.cycle_interval,
            'config_list': self.config_list,
            'total_switches': self.switch_count,
            'final_score': float(self.score),
            'config_usage_count': self.config_usage_count,
            'final_config_index': self.current_config_index
        }
        
        filename = 'cyclic_optimizer_state.json'
        with open(filename, 'w') as f:
            json.dump(save_data, f, indent=2)
        
        print(f"\n[CYCLIC] ========== Final Statistics ==========")
        print(f"[CYCLIC] Total switches: {self.switch_count}")
        print(f"[CYCLIC] Final score: {self.score:.4f}")
        print(f"[CYCLIC] Configuration usage count:")
        for i, count in self.config_usage_count.items():
            bs, bt = self.config_list[i]
            print(f"[CYCLIC]   Config {i} (BS={bs}, BT={bt}): {count} times")
        print(f"[CYCLIC] State saved to {filename}")
        print(f"[CYCLIC] ============================================\n")
    
    def load_model(self):
        """加载优化器状态（可选实现）"""
        filename = 'cyclic_optimizer_state.json'
        if os.path.exists(filename):
            with open(filename, 'r') as f:
                save_data = json.load(f)
            
            # 恢复配置（如果需要）
            print(f"[CYCLIC] Loaded previous state from {filename}")
            print(f"[CYCLIC] Previous total switches: {save_data['total_switches']}")
        else:
            print("[CYCLIC] No previous state found - starting fresh")
    
    def reset(self):
        """重置优化器状态"""
        super().reset()
        self.current_config_index = 0
        self.start_time = None
        self.last_switch_time = None
        self.switch_count = 0
        self.config_usage_count = {i: 0 for i in range(len(self.config_list))}
        print("[CYCLIC] Optimizer state reset")

# ============= 模型工厂 =============
def create_model(algorithm):
    """创建优化器实例"""
    models = {
        'PPO': PPO,
        'BAYESIAN': BayesianOptimizer,
        'SA': SimulatedAnnealing,
        'STATIC': StaticOptimizer,
        'CYCLIC': CyclicConfigOptimizer,
    }
    
    if algorithm not in models:
        print(f"Unknown algorithm: {algorithm}, defaulting to BAYESIAN")
        algorithm = 'BAYESIAN'
    
    model = models[algorithm]()
    
    # 加载已保存的模型（如果存在）
    if hasattr(model, 'load_model'):
        model.load_model()
    
    return model


# ============= gRPC 服务 =============
class MetricsServiceServicer(monitor_pb2_grpc.MetricsServiceServicer):
    """gRPC 服务处理器（使用实例变量而非全局变量）"""
    
    def __init__(self, model, data_logger):
        self.model = model
        self.data_logger = data_logger
        self.notify_counter = 0
        # Use relative path for scores file
        self.scores_file = open(f"{ALGORITHM.lower()}_score.txt", 'w')
        
    def SendMetrics(self, request, context):
        """处理性能指标并返回参数调整"""
        global action_pool  # 仅用于通信协调
        
        # ========== 记录传入的指标 ==========
        throughput = request.throughput
        latency = request.latency
        payload = request.size
        arrival_rate = request.arrival_rate
        
        # 计算当前 reward (使用归一化值)
        if throughput > 0:
            norm_thr = throughput / THROUGHPUT_SCALE
            norm_lat = latency / LATENCY_SCALE
            current_reward = c_thr * norm_thr + c_lat * norm_lat
        else:
            current_reward = 0
        self.data_logger.log_metrics(throughput, latency, payload, current_reward)
        
        # ========== 构造状态 ==========
        new_state = np.array([request.throughput, request.latency, request.size,
                              request.tot_thr, request.tot_lat, request.tot_size, request.arrival_rate])
        
        action_pool.clear()
        
        # ========== 检查是否达到最大迭代次数 ==========
        self.notify_counter += 1
        print(f"[{ALGORITHM}] Iteration: {self.notify_counter}")

        if self.notify_counter % save_episode == 0:
            if hasattr(self.model, 'save_model'):
                self.model.save_model()
        
        if self.notify_counter > max_notify_count:
            print("One cycle completed. Quit running.")
            
            # 保存实验摘要
            summary = self.data_logger.get_summary()
            with open(f"{self.data_logger.exp_dir}/summary.json", 'w') as f:
                json.dump(summary, f, indent=2)
            print(f"Experiment saved to: {self.data_logger.exp_dir}")
            
            # 保存模型
            if hasattr(self.model, 'save_model'):
                self.model.save_model()
            
            self.scores_file.close()
            os._exit(0)
        
        # ========== 调用优化器更新 ==========
        start = time.perf_counter()
        
        option = request.option % 100
        batchSize, batchTimeout, requestTimeout = self.model.modelUpdate(new_state, option)
        
        end = time.perf_counter()
        print(f"Update time: {end - start:.6f} seconds")
        
        # ========== 记录参数调整 ==========
        c_param = self.model.lastC if option == 2 else 0
        self.data_logger.log_parameters(batchSize, batchTimeout, c_param, option, requestTimeout)
        
        # ========== 修改5：记录算法状态 ==========
        if hasattr(self.model, 'get_algorithm_state'):
            algorithm_state = self.model.get_algorithm_state()
            self.data_logger.log_algorithm_state(algorithm_state)
        # ==========================================
        
        # 打印监控信息
        print(f"[{ALGORITHM}] Iter {self.data_logger.iteration_count}: "
              f"Thr={throughput:.2f}, Lat={latency:.2f}, "
              f"BatchSize={batchSize}, BatchTimeout={batchTimeout}, "
              f"RequestTimeout={requestTimeout}, Score={self.model.score:.4f}")
        
        # ========== 处理 option == 1（batch size/timeout 调整）==========
        if option == 1:
            return monitor_pb2.MetricsResponse(BatchSize=batchSize, BatchTimeout=batchTimeout,
                                               RequestTimeout=int(requestTimeout))
        
        # ========== 处理 option == 2（C 参数调整，需要共识）==========
        else:
            self.scores_file.write(f'{batchSize}\n')
            self.scores_file.flush()
            time.sleep(1)
            
            # 获取 primary 和 当前节点 id
            primary = int(request.option / 100) % 100
            node_id = int(request.option / 10000)
            
            # 如果不是 primary，向 primary 发送请求
            if node_id != primary:
                with grpc.insecure_channel(addr[primary-1]) as channel:
                    stub = monitor_pb2_grpc.MetricsServiceStub(channel)
                    response = stub.Connect(monitor_pb2.Timestamp(timestamp=batchSize))
                    SeqNum = response.timestamp
            else:
                # 如果是 primary，直接调用本地 Connect
                response = self.Connect(monitor_pb2.Timestamp(timestamp=batchSize), None)
                SeqNum = response.timestamp
            
            # 更新模型的 lastC
            self.model.lastC = SeqNum
            self.scores_file.write(f'{SeqNum}\n')
            self.scores_file.flush()
            
            return monitor_pb2.MetricsResponse(BatchSize=SeqNum, BatchTimeout=0)
    
    def Connect(self, request, context):
        """
        处理 Connect 请求
        
        有两种情况：
        1. 初始握手（Java 客户端连接时）- 直接返回时间戳
        2. 共识协议（option == 2 时节点间通信）- 等待 QUORUM 个响应
        
        区分方式：如果 timestamp 是一个很大的毫秒级时间戳（> 1e12），
        说明是初始握手；如果是一个小数值（参数值），说明是共识协议。
        """
        recv_value = request.timestamp
        
        # 判断是否为初始握手：毫秒级时间戳通常 > 1e12 (约 2001 年之后的时间)
        # 而共识协议传递的值是参数值，通常 < 10000
        if recv_value > 1e12:
            # 初始握手请求 - 直接返回当前时间戳
            server_time = int(time.time() * 1000)
            print(f"[{ALGORITHM}] Initial handshake received. Client timestamp: {recv_value}")
            print(f"[{ALGORITHM}] Responding with server timestamp: {server_time}")
            return monitor_pb2.Timestamp(timestamp=server_time)
        
        # 共识协议（option == 2）
        self.scores_file.write(f'{recv_value}\n')
        self.scores_file.flush()
        self.scores_file.write(str(action_pool) + '\n')
        self.scores_file.flush()
        
        with enough_action:
            with action_lock:
                action_pool.append(recv_value)

            if len(action_pool) >= QUORUM:
                enough_action.notify_all()

            while len(action_pool) < QUORUM:
                enough_action.wait()

            result = int(np.median(action_pool))
        
        return monitor_pb2.Timestamp(timestamp=result)

# ============= 服务器启动 =============
def serve():
    """启动 gRPC 服务器"""
    
    # 初始化数据记录器
    data_logger = DataLogger(ALGORITHM)
    
    # 创建优化器模型
    model = create_model(ALGORITHM)
    
    # 创建服务器
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    servicer = MetricsServiceServicer(model, data_logger)
    monitor_pb2_grpc.add_MetricsServiceServicer_to_server(servicer, server)
    server.add_insecure_port('[::]:45678')
    server.start()
    
    # 打印启动信息
    print(f"="*60)
    print(f"Server started on port 45678")
    print(f"Algorithm: {ALGORITHM}")
    print(f"Experiment directory: {data_logger.exp_dir}")
    print(f"Metrics file: {data_logger.metrics_file}")
    print(f"Parameters file: {data_logger.params_file}")
    print(f"="*60)
    
    server.wait_for_termination()

if __name__ == '__main__':
    print("Starting server...")
    serve()
    print("Server stopped.")
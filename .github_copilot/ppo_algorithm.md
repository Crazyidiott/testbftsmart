# PPO 调参算法说明文档

> 文件对应实现：`server_agent/trainer.py`，类 `PPO`

---

## 1. 整体定位

`PPO`（Proximal Policy Optimization）是系统中三种在线调参算法之一（另外两种是 `BayesianOptimizer` 和 `SimulatedAnnealing`），通过环境变量 `OPT_ALGORITHM=PPO` 启用。

它作为 gRPC 服务端运行，每秒接收一次来自 `RLAgentConnector.java` 的性能快照，返回一组 BFT-SMaRt 参数，形成闭环控制。

```
Java (RLAgentConnector)          Python (trainer.py / PPO)
┌─────────────────────┐          ┌──────────────────────────┐
│  收集系统指标 (1s)   │ ──RPC──▶ │  modelUpdate()           │
│  应用返回的参数      │ ◀──RPC── │  返回 (BS, BT, RT)        │
└─────────────────────┘          └──────────────────────────┘
```

---

## 2. 输入：状态向量

每次 `modelUpdate` 收到一个 7 维的原始状态，经 `Normalized()` 归一化后输入网络：

| 索引 | 字段           | Java 来源                      | 物理含义                                      | 归一化上限     |
|------|----------------|-------------------------------|-----------------------------------------------|----------------|
| 0    | `throughput`   | 当前窗口 ops/s（瞬时）          | 当前秒内系统吞吐量                             | 60,000         |
| 1    | `latency`      | 当前窗口平均延迟（µs，瞬时）    | 当前秒内平均请求延迟                           | 30,000         |
| 2    | `size`         | 当前窗口平均消息大小（bytes）   | 当前秒内平均单条消息大小                       | 10,000         |
| 3    | `tot_thr`      | EMA 平滑吞吐量（α=0.2）        | ~5s 平滑后的吞吐量趋势，与 index 0 互补        | 60,000         |
| 4    | `tot_lat`      | EMA 平滑延迟（α=0.2）          | ~5s 平滑后的延迟趋势，与 index 1 互补          | 30,000         |
| 5    | `tot_size`     | 累计消息字节数（KB，累加）      | 实验以来总数据量，趋势性背景信号               | 1×10⁹          |
| 6    | `arrival_rate` | 当前窗口请求到达率（req/s）     | 客户端负载强度                                 | 60,000         |

归一化公式：`s_norm[i] = s[i] / (max_vals[i] + 1e-8)`

### EMA 设计说明

`tot_thr`（index 3）和 `tot_lat`（index 4）都使用指数移动平均（α=0.2），在 Java 侧计算：

```
smoothed(t) = 0.8 × smoothed(t-1) + 0.2 × raw(t)
```

- **有效时间窗口**：约 5s（1/0.2 = 5 个采样周期）
- **作用**：过滤瞬时噪声，向网络提供趋势信号，区别于 index 0/1 的瞬时值
- **对称性**：吞吐量和延迟使用相同的 α，两者量纲不同但归一化后范围一致

> `tot_thr` 之前使用的是累计 ops 数（单调递增，除以 1e9），这等价于只编码了实验时长，而非吞吐质量。改为 EMA 后信号有效性与 `tot_lat` 对齐。

---

## 3. 输出：动作空间

PPO 输出三个独立参数，各自对应离散动作空间中的索引：

| 参数             | 变量     | 动作空间                             | 步长  | 个数 | 更新频率         |
|------------------|----------|-------------------------------------|-------|------|------------------|
| `batchSize`      | `lastA`  | [100, 300, 500, …, 1900]            | 200   | 10   | 每 1s（每轮）    |
| `batchTimeout`   | `lastB`  | [50, 80, 110, 140, 170, 200] (ms)   | 30    | 6    | 每 1s（每轮）    |
| `requestTimeout` | `lastD`  | [1000, 2000, …, 10000] (ms)         | 1000  | 10   | 每 10s（每 10 轮）|

> **C 参数**（`lastC`，取值 `[8,16,32,64,128,256,512,1024]`）仅在 `option==2` 时生效，目前 Java 侧只发送 `option==1`，为死代码。

### `option` 字段含义

| `option` 值 | 含义                  | 返回内容                                 |
|-------------|----------------------|------------------------------------------|
| 1           | 常规 batch 调参       | `(batchSize, batchTimeout, requestTimeout)` |
| 2           | 共识参数配置（预留）   | `(C, 0, requestTimeout)`                |

---

## 4. Reward 函数

```python
norm_thr = old_state[0] / THROUGHPUT_SCALE   # ∈ [0, 1]
norm_lat = old_state[1] / LATENCY_SCALE       # ∈ [0, 1]
reward = 1.0 * norm_thr + (-1.0) * norm_lat
```

- **直觉**：吞吐越高越好（+），延迟越高惩罚越大（−）。
- 归一化后两项量级一致，权重 `±1.0` 保持对称。
- 实际范围约 `[−1, +1]`；系统运行良好时 reward 应为正值。
- **注意**：reward 使用 `old_state`（上一轮的观测），对应上一轮动作的实际效果（避免未来信息泄露）。

---

## 5. 网络架构（双子网络）

### 5.1 设计原则

`batchSize/batchTimeout` 和 `requestTimeout` 工作在**不同时间尺度**上：

- Batch 参数：每 **1s** 更新，奖励信号是**瞬时** reward。
- RequestTimeout：每 **10s** 更新，奖励信号是 **10 步累积平均** reward。

若共享同一个特征提取层，两条梯度会在不同时间尺度上交替污染共享权重，导致训练不稳定。因此将网络**完全拆分**为两个独立子网络，参数集合不相交。

### 5.2 Batch 子网络（1s 频率）

```
输入 s (7维，归一化)
    │
fc1: Linear(7 → 64) + ReLU
    ├─▶ fc_pi_a: Linear(64 → 10)  →  Softmax  →  P(batchSize)
    ├─▶ fc_pi_b: Linear(64 →  6)  →  Softmax  →  P(batchTimeout)
    ├─▶ fc_pi_c: Linear(64 →  8)  →  Softmax  →  P(C)  [当前未使用]
    └─▶ fc_v   : Linear(64 →  1)             →  V(s)   [Batch Critic]

参数量：2137   优化器：optimizer（Adam, lr=3×10⁻⁴）
```

### 5.3 Timeout 子网络（10s 频率）

```
输入 s (7维，归一化)
    │
fc1_timeout: Linear(7 → 32) + ReLU
    ├─▶ fc_pi_d     : Linear(32 → 10)  →  Softmax  →  P(requestTimeout)
    └─▶ fc_v_timeout: Linear(32 →  1)             →  V_t(s)  [Timeout Critic]

参数量：619   优化器：optimizer_timeout（Adam, lr=3×10⁻⁴）
```

**关键保证**：`optimizer` 的 `param_groups` 与 `optimizer_timeout` 的 `param_groups` 参数集合完全不相交（已通过运行时断言验证）。

---

## 6. 超参数

| 超参数                              | 值      | 含义                                            |
|-------------------------------------|---------|-------------------------------------------------|
| `learning_rate`                     | 0.0003  | Adam 优化器学习率（两个 optimizer 均适用）       |
| `gamma`                             | 0.98    | 折扣因子，控制对未来 reward 的重视程度           |
| `lmbda`                             | 0.95    | GAE λ 参数，控制 bias-variance 权衡             |
| `eps_clip`                          | 0.1     | PPO clip 范围，限制每次策略更新幅度              |
| `K_epoch`                           | 5       | 每批数据重复训练轮数                             |
| `T_horizon`                         | 20      | 水平窗口长度（已定义，但当前未强制用于触发训练）  |
| `THROUGHPUT_SCALE`                  | 60,000  | 吞吐量归一化上限（ops/s）                       |
| `LATENCY_SCALE`                     | 30,000  | 延迟归一化上限（µs = 30ms）                     |
| `REQUEST_TIMEOUT_UPDATE_INTERVAL`   | 10      | timeout 决策间隔（对应 10s）                    |

---

## 7. 完整调参流程（每轮 modelUpdate）

```
调用 modelUpdate(batch_state, option)
│
├─ [顶部] timeout_iteration += 1
│          should_update_timeout = (timeout_iteration % 10 == 0)
│
├─ [冷启动] old_state 为空
│     → 存储 batch_state，返回动作空间中间值，不训练
│
├─ 1. 计算 reward（基于 old_state，对应上一轮动作的效果）
│      reward = norm_thr(old_state) − norm_lat(old_state)
│
├─ 2. 向 batch 经验缓冲区写入 transition
│      (s_norm, a_idx, b_idx, 0/c_idx, reward, s'_norm, old_prob_a, old_prob_b, old_prob_c)
│
├─ 3. timeout_reward_accumulator += reward
│      timeout_reward_count += 1
│
├─ 4. 训练 batch 子网络（train_net）← 每轮执行
│      • make_batch() 取出缓冲区全部 transition（随即清空）
│      • K_epoch=5 次 PPO-Clip 迭代
│      • 仅更新 fc1 / fc_pi_a,b,c / fc_v（通过 optimizer）
│
├─ 5. old_state ← batch_state（滚动状态）
│
├─ 6. [每 10 轮] should_update_timeout == True
│      ├─ avg_reward = accumulator / count
│      ├─ 向 timeout 缓冲区写入 (s_norm, d_idx, avg_reward, s'_norm, old_prob_d)
│      ├─ 训练 timeout 子网络（train_timeout_net）
│      │    • K_epoch=5 次 PPO-Clip 迭代
│      │    • 仅更新 fc1_timeout / fc_pi_d / fc_v_timeout（通过 optimizer_timeout）
│      ├─ select_timeout_action → 新 requestTimeout 索引
│      ├─ 安全约束：requestTimeout ≥ max(batchTimeout × 5, 1000ms)
│      └─ 重置 timeout_reward_accumulator / count
│
└─ 7. select_action → 新 batchSize / batchTimeout
       返回 (batchSize, batchTimeout, requestTimeout)
```

---

## 8. 训练算法（PPO-Clip）

两个子网络使用相同的 PPO-Clip 方法，仅数据来源和优化器不同。

### GAE 优势估计

$$A_t = \sum_{k=0}^{\infty} (\gamma \lambda)^k \delta_{t+k}, \quad \delta_t = r_t + \gamma V(s_{t+1}) - V(s_t)$$

其中 $\gamma=0.98$，$\lambda=0.95$。

### PPO-Clip 损失

$$L = -\min\left(\rho_t A_t,\ \text{clip}(\rho_t,\ 1-\varepsilon,\ 1+\varepsilon) \cdot A_t\right) + L_{\text{value}}$$

$$\rho_t = \frac{\pi_\theta(a_t|s_t)}{\pi_{\theta_\text{old}}(a_t|s_t)}, \quad \varepsilon = 0.1$$

$$L_{\text{value}} = \text{SmoothL1}\bigl(V(s_t),\ r_t + \gamma V(s_{t+1})\bigr)$$

Batch 子网络有三个策略头（a/b/c），损失为三头之和，各乘以掩码（`mask_a/b/c`）区分 option=1 和 option=2 的样本。

---

## 9. 双频率相位同步

Java 侧（`RLAgentConnector.java`）通过 `monitorLoopCounter % 10 == 0` 决定是否将本轮的 `requestTimeout` 应用到系统。

Python 侧（PPO）通过 `timeout_iteration % 10 == 0` 决定是否更新 `requestTimeout` 策略。

两个计数器的递增时机完全对齐：

```
Java 侧 (monitorLoopCounter)     Python 侧 (timeout_iteration，顶部递增)
───────────────────────────────────────────────────────────────────
call #1  → counter = 1          timeout_iteration = 1
call #2  → counter = 2          timeout_iteration = 2
...
call #10 → counter = 10  ←──── timeout_iteration = 10  ← 双方同时触发
call #11 → counter = 11         timeout_iteration = 11
```

> **关键**：`timeout_iteration += 1` 必须放在函数**顶部**（冷启动 return 之前），否则产生 1 步相位漂移，导致 Java 和 Python 在不同轮次触发。

---

## 10. 安全约束

```python
def _enforce_timeout_constraint(self, request_timeout, batch_timeout):
    min_allowed = max(int(batch_timeout * 5), REQUEST_TIMEOUT_MIN)
    return max(request_timeout, min_allowed)
```

`requestTimeout` 至少是 `batchTimeout` 的 5 倍，且不低于 1000ms。

**原因**：若 `requestTimeout` 过小，正常的 batch 聚合等待时间就可能超过 `requestTimeout`，触发不必要的 view-change（领导者切换），造成系统抖动。

---

## 11. 经验缓冲区

| 缓冲区              | 每条 transition 字段                           | 清空时机                      |
|---------------------|------------------------------------------------|-------------------------------|
| `self.data`         | `(s, a, b, c, r, s', p_a, p_b, p_c)`          | `make_batch()` 调用后立即清空  |
| `self.timeout_data` | `(s, d, r, s', p_d)`                           | `make_timeout_batch()` 后清空 |

目前两个缓冲区都是**有 1 条就训练**（`len >= 1` 触发），每轮只有 1 条样本。更高效的做法是等缓冲区达到 `T_horizon=20` 后再训练，梯度方差更小，策略更新更稳定。

---

## 12. 模型持久化

保存到 `ppo_model.pth`：

```python
{
    'batch_net_state': {
        'fc1': ..., 'fc_pi_a': ..., 'fc_pi_b': ..., 'fc_pi_c': ..., 'fc_v': ...
    },
    'optimizer_state': ...,
    'timeout_net_state': {
        'fc1_timeout': ..., 'fc_pi_d': ..., 'fc_v_timeout': ...
    },
    'optimizer_timeout_state': ...,
    'lastD': float,            # 最近一次 requestTimeout 值
    'timeout_iteration': int,  # 相位计数器（恢复后继续同步）
}
```

加载时对缺失键（旧版模型）有兜底处理，使用默认值冷启动。

---

## 13. 已知待改进问题

| 问题 | 影响 | 优先级 |
|------|------|--------|
| 训练批大小为 1（未等到 T_horizon=20）| 梯度方差大，策略更新不稳定 | 高 |
| `mask_a = (a != 0).float()` 错误屏蔽 `A_values[0]=100` | option=2 样本误掩 batchSize 最小值（当前 option=2 为死代码，暂无影响） | 低 |
| timeout 经验同样 1 条就训练 | timeout 网络更新过于频繁，方差大 | 中 |
| reward 无 P99 延迟软约束 | 长尾延迟不受控 | 中 |

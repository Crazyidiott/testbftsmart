# PPO 调参算法说明文档（已更新）

> 文件对应实现：`server_agent/trainer.py`，类 `PPO`
> 最后更新：含 9 项 PPO 缺陷修复（#1-#8, #10）+ EMA tot_thr 修复

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
arrival         = max(old_state[6], 1.0)
completion_rate = min(old_state[0] / arrival, 1.0)
norm_lat        = old_state[1] / LATENCY_SCALE
backlog_penalty = max(0.0, (arrival - old_state[0]) / THROUGHPUT_SCALE)
reward = completion_rate - norm_lat - backlog_penalty
```

三个分量的含义：

| 分量              | 范围       | 含义                                                              |
|-------------------|------------|-------------------------------------------------------------------|
| `completion_rate` | [0, 1]     | 服务完成率（throughput / arrival_rate），感知负载强度              |
| `norm_lat`        | [0, ~1]    | 归一化延迟，越低越好                                               |
| `backlog_penalty` | [0, ~1]    | 队列积压惩罚，仅在 arrival > throughput 时非零，惩罚过载状态       |

- **旧公式 `norm_thr − norm_lat` 的缺陷**：在高负载时，吞吐因系统满载自然升高，旧公式会给出虚假高分。新公式用完成率代替绝对吞吐，reward 反映参数质量，而非负载强度。
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
| `K_epoch`                           | 5       | 每批数据重复训练轮数                                 |
| `T_horizon`                         | 20      | Batch 网络训练触发阈值（积累 20 条经验才触发训练）    |
| `entropy_coef`                      | 0.01    | 熵正则化系数，防止策略过早收敛为确定性策略           |
| `THROUGHPUT_SCALE`                  | 60,000  | 吞吐量归一化上限（ops/s）                           |
| `LATENCY_SCALE`                     | 30,000  | 延迟归一化上限（µs = 30ms）                         |
| `REQUEST_TIMEOUT_UPDATE_INTERVAL`   | 10      | timeout 决策间隔（对应 10s）                        |
| `TIMEOUT_MIN_TRAIN_SIZE`            | 5       | Timeout 网络训练所需最少经验条数                    |
| `TIMEOUT_BUFFER_MAXSIZE`            | 20      | Timeout 滚动经验缓冲区最大条数                      |

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
│      arrival         = max(old_state[6], 1.0)
│      completion_rate = min(old_state[0] / arrival, 1.0)
│      backlog_penalty = max(0, (arrival - old_state[0]) / THROUGHPUT_SCALE)
│      reward = completion_rate - norm_lat - backlog_penalty
│
├─ 2. 向 batch 经验缓冲区写入 transition（10 字段）
│      (s_norm, a_idx, b_idx, c_idx, reward, s'_norm, p_a, p_b, p_c, opt)
│      ← opt 字段：记录本轮 option 值（1 或 2），供 mask 使用
│
├─ 3. timeout_reward_accumulator += reward；count += 1
│
├─ 4. 若 len(data) >= T_horizon(=20)：触发 train_net()
│      • TD target 和 Advantage 在 K_epoch 循环外计算一次（no_grad 固定基线）
│      • Advantage 归一化：(A − mean) / (std + ε)
│      • mask_batch = (opt == 1).float()，mask_c = (opt == 2).float()
│      • K_epoch=5 次 PPO-Clip 迭代，每次含熵正则化和梯度裁剪
│      • 仅更新 fc1 / fc_pi_a,b,c / fc_v（通过 optimizer）
│      • make_batch() 训练后清空 self.data
│
├─ 5. old_state ← batch_state（滚动状态）
│
├─ 6. [每 10 轮] should_update_timeout == True
│      ├─ avg_reward = accumulator / count
│      │
│      ├─ 使用 pending_timeout_* 快照构建 timeout 经验
│      │    pending_* 在上一次 select_timeout_action 时立即保存：
│      │    行动时刻的 state、d_idx、old_prob（确保 PPO ratio 正确）
│      │
│      ├─ 追加至 timeout 滚动缓冲区（上限 20 条，不完全清空）
│      │
│      ├─ 若 len(timeout_data) >= 5：触发 train_timeout_net()
│      │    • 同 train_net 结构（固定基线、归一化、熵、梯度裁剪）
│      │    • 仅更新 fc1_timeout / fc_pi_d / fc_v_timeout（通过 optimizer_timeout）
│      │    • 训练后截断缓冲区至最新 20 条
│      │
│      ├─ select_timeout_action → 新 requestTimeout
│      ├─ 安全约束：requestTimeout ≥ max(batchTimeout × 5, 1000ms)
│      ├─ 立即更新 pending_timeout_state / d_idx / prob_d（行动时刻快照）
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

**关键**：TD target 和 $A_t$ 在 K_epoch 循环外用 `torch.no_grad()` 一次性计算固定，K_epoch 轮迭代共享同一基线（若每轮重算，clip 参考基准随策略移动，clip 机制失效）。

**归一化**：$A_t$ 参与训练前执行 $(A - \mu_A) / (\sigma_A + \varepsilon)$，稳定梯度量级。

### PPO-Clip 损失

$$L = -\min\!\left(\rho_t A_t,\ \text{clip}(\rho_t,\ 1-\varepsilon,\ 1+\varepsilon) \cdot A_t\right) + L_\text{value} - \alpha_H H(\pi)$$

$$\rho_t = \frac{\pi_\theta(a_t|s_t)}{\pi_{\theta_\text{old}}(a_t|s_t)}, \quad \varepsilon = 0.1, \quad \alpha_H = 0.01$$

$$L_\text{value} = \text{SmoothL1}\bigl(V(s_t),\ r_t + \gamma V(s_{t+1})\bigr)$$

- **Batch 网络**：三个策略头（a/b/c）的 PPO 损失按 `mask_batch` / `mask_c` 加权求和；mask 基于 transition 中存储的 `opt` 字段（`mask_batch = (opt==1).float()`），而非旧版 `a != 0`。
- **Timeout 网络**：单个策略头（d），独立熵正则化。
- **梯度裁剪**：两个网络均在 `optimizer.step()` 前执行 `clip_grad_norm_(..., max_norm=0.5)`，防止单批次大噪声破坏收敛。

---

## 9. Timeout old\_prob 正确性保证

PPO 的重要性采样比率为 $\rho_t = \pi_\theta(a_t|s_t) / \pi_{\theta_\text{old}}(a_t|s_t)$，要求 $\pi_{\theta_\text{old}}$ 必须是**行动时刻**的策略概率。

Timeout 动作每 10s 选择一次，但 Batch 子网络在此期间可能被更新若干次。若在 10s 后的"写入经验"时刻重新调用 `pi_d(s)` 计算 old_prob，则此时 $\pi_{\theta_\text{old}} \approx \pi_\theta$，ratio 恒为 1，clip 机制完全失效，退化为朴素 Policy Gradient。

**修复方案**：`select_timeout_action()` 返回完整概率向量；`modelUpdate` 在选出动作后立即将 `(state_norm, d_idx, prob_d[d_idx])` 存入 `pending_timeout_*`；10s 后用这份快照构建经验 tuple，确保 old_prob 代表真正行动时刻的策略。

```python
# 行动时刻（立即保存快照）
d_new, prob_d_vec = self.select_timeout_action(cur_norm)
self.pending_timeout_d_idx  = d_new
self.pending_timeout_prob_d = prob_d_vec[d_new].item()  # 行动时刻真实概率
self.pending_timeout_state  = cur_norm

# 10s 后写入 timeout 经验时使用该快照
self.put_timeout_data((pending_state, pending_d_idx, avg_reward, cur_norm, pending_prob_d))
```

---

## 10. 双频率相位同步

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

## 11. 安全约束

```python
def _enforce_timeout_constraint(self, request_timeout, batch_timeout):
    min_allowed = max(int(batch_timeout * 5), REQUEST_TIMEOUT_MIN)
    return max(request_timeout, min_allowed)
```

`requestTimeout` 至少是 `batchTimeout` 的 5 倍，且不低于 1000ms。

**原因**：若 `requestTimeout` 过小，正常的 batch 聚合等待时间就可能超过 `requestTimeout`，触发不必要的 view-change（领导者切换），造成系统抖动。

---

## 12. 经验缓冲区

| 缓冲区              | 每条 transition 字段                                    | 管理方式                                            |
|---------------------|--------------------------------------------------------|-----------------------------------------------------|
| `self.data`         | `(s, a, b, c, r, s', p_a, p_b, p_c, opt)`（10 字段）  | 积累 T_horizon=20 条触发训练，`make_batch()` 后清空  |
| `self.timeout_data` | `(s, d, r, s', p_d)`                                   | 滚动缓冲区：追加，训练后截断至最新 20 条，不完全清空 |

`pending_timeout_*` 辅助状态（非缓冲区）：

| 字段                      | 含义                                                    |
|---------------------------|---------------------------------------------------------|
| `pending_timeout_state`   | 行动时刻归一化状态快照（用于写 timeout 经验的 s 字段）  |
| `pending_timeout_d_idx`   | 行动时选出的 requestTimeout 索引                        |
| `pending_timeout_prob_d`  | 行动时刻的 $\pi_{\theta_\text{old}}(d|s)$（确保 ratio 正确）|

---

## 13. 模型持久化

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

## 14. 已修复问题记录

| 编号 | 问题描述 | 修复方案 |
|------|----------|----------|
| #1 | T_horizon 未生效，每步训练 1 条样本 | 改为 `len(data) >= T_horizon` 触发 |
| #2 | timeout old_prob 用了行动后（网络更新后）的策略概率 | 行动时刻立即保存 `pending_timeout_*` 快照 |
| #3 | `mask_a = (a != 0).float()` 误屏蔽 batchSize=100 | 改为基于 transition 第 10 字段 `opt` 做 mask |
| #4 | Advantage 在 K_epoch 每轮重新计算，clip 基准漂移 | 移到循环外，用 `no_grad()` 固定基线 |
| #5 | 无熵正则化，策略过早收敛为确定性策略 | 加入 `- entropy_coef * entropy`（系数 0.01）|
| #6 | 无梯度裁剪，单批噪声可破坏收敛 | 加入 `clip_grad_norm_(..., max_norm=0.5)` |
| #7 | Advantage 未归一化，梯度量级不稳定 | 加入 `(A - mean) / (std + ε)` |
| #8 | Timeout 缓冲区每次训练后清空，每轮仅单条经验 | 改为滚动缓冲区（min=5 条才训练，max=20 条保留）|
| #10 | reward 不感知 arrival_rate，高负载时给出虚假高分 | 改用完成率 + 队列积压惩罚 |

---

## 15. 已知遗留问题

| 问题 | 影响 | 优先级 |
|------|------|--------|
| batchSize 和 batchTimeout 独立学习，无法建模耦合（大 BS + 极短 BT 是无效组合） | 可能选出次优参数组合 | 低（架构改动大） |
| reward 无 P99 延迟软约束 | 长尾延迟不受控 | 中 |

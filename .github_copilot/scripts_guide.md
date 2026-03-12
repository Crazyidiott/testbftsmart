# 脚本使用说明

本项目是一个基于 BFT-SMaRt 的自适应参数调优系统，通过 RL/贝叶斯优化等算法动态调整共识协议参数（`batchSize`、`batchTimeout`、`requestTimeout`）以优化吞吐量和延迟。以下是项目中所有脚本的分类说明。

---

## 目录

- [1. 环境配置脚本](#1-环境配置脚本)
- [2. 部署脚本](#2-部署脚本)
- [3. 基准测试脚本](#3-基准测试脚本)
- [4. 模型训练脚本](#4-模型训练脚本)
- [5. 结果收集与分析脚本](#5-结果收集与分析脚本)
- [6. 工具脚本](#6-工具脚本)
- [7. 典型工作流](#7-典型工作流)

---

## 1. 环境配置脚本

### `lan_config.sh` — LAN 环境配置

定义 LAN（同区域 AWS 私有网络）环境下的节点信息和路径。被其他所有 LAN 脚本通过 `source` 引用。

**配置内容：**
- `NODES` — 5 个节点的私有 IP（前 4 个为 Replica，第 5 个为 Client）
- `KEY` — SSH 密钥路径
- `LOCAL_PROJECT_PATH` — 本地项目路径
- `REMOTE_PROJECT_PATH` — 远程节点上的项目路径
- `USER` — SSH 用户名

### `wan_config.sh` — WAN 环境配置

定义 WAN（跨区域 AWS 公网）环境下的节点信息。节点分布在不同 AWS 区域（eu-central-1、eu-west-1/2、eu-north-1、ap-northeast-1），每个区域使用独立的 SSH 密钥。

**配置内容：**
- `NODES` / `KEYS` — 各区域的公网 IP 和对应密钥
- 其余与 `lan_config.sh` 结构相同

### `setup_python_env.sh` — 远程 Python 环境初始化

在所有 4 个 Replica 节点上安装 Python 虚拟环境和依赖（gRPC、PyTorch、NumPy 等）。

```bash
./setup_python_env.sh
```

**执行步骤：**
1. 将 `server_agent/` 同步到远程节点
2. 安装 `python3-venv` 和 `python3-pip`
3. 创建 `rlenv` 虚拟环境
4. 安装 `requirements.txt` 中的依赖
5. 验证安装是否成功

### `setup_local_python_env.sh` — 本地 Python 环境初始化

与 `setup_python_env.sh` 功能相同，但在本地机器执行。用于 `local_deploy.sh` 的单机部署场景。

```bash
./setup_local_python_env.sh
```

---

## 2. 部署脚本

### `lan_deploy.sh` — LAN 部署（核心脚本）

**所有基准测试脚本的底层执行引擎。** 在 LAN 环境下完成一次完整的实验运行：编译、部署、启动集群、运行客户端、收集日志。

```bash
./lan_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [Algorithm] [WorkloadConfig]
```

**参数说明：**

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `BatchSize` | 1000 | 最大批处理大小 |
| `Timeout` | 50 | 批处理超时时间（ms） |
| `ClientRate` | -1 | 客户端发送速率（-1 表示不限速） |
| `SkipBuild` | false | 是否跳过 Gradle 编译 |
| `Algorithm` | BAYESIAN | 调参算法（见下表） |
| `WorkloadConfig` | 空 | 动态负载配置文件名（留空则使用静态客户端） |

**支持的算法：**

| 算法 | 说明 |
|------|------|
| `NONE` | 不启动 Agent，直接使用 `system.config` 中的参数 |
| `STATIC` | 使用脚本参数指定的固定配置，启动 Agent 用于采集 metrics |
| `MOCK` | 启动 `mock_agent.py` 进行通信测试 |
| `BAYESIAN` | 贝叶斯优化（使用 `trainer.py`） |
| `PPO` | 近端策略优化（使用 `trainer.py`） |
| `SA` | 模拟退火（使用 `trainer.py`） |

**执行流程（6 步）：**
1. **Step 0** — 更新 `system.config` 中的 `maxbatchsize` 和 `batchtimeout`
2. **Step 1** — 生成 `hosts.config`（节点地址和端口映射）
3. **Step 1.5** — 生成 SSL Keystore（ECDSA 密钥对）
4. **Step 2** — 同步代码到所有节点、安装 Java、编译项目
5. **Step 3** — 启动 4 个 Replica（先启动 Python Agent，再启动 Java Server）
6. **Step 4** — 启动 Client（根据是否指定 WorkloadConfig 选择 `AsyncDynamicClient` 或 `AsyncLatencyClient`）
7. **Step 5** — 等待 Client 结束后停止所有 Server 和 Agent
8. **Step 6** — 收集日志到本地 `results/` 目录

**示例：**
```bash
# 使用贝叶斯优化，动态负载
./lan_deploy.sh 500 100 -1 false BAYESIAN dynamic_workload.config

# 纯 BFT-SMaRt（无 Agent），固定参数
./lan_deploy.sh 1000 50 -1 false NONE

# 跳过编译，使用静态配置收集 metrics
./lan_deploy.sh 500 100 -1 true STATIC
```

### `wan_deploy.sh` — WAN 部署

与 `lan_deploy.sh` 逻辑相同，但使用 `wan_config.sh` 配置。适用于跨区域 WAN 实验。每个节点使用不同的 SSH 密钥。

```bash
./wan_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild]
```

> 注意：WAN 版本不支持 Algorithm 和 WorkloadConfig 参数，仅用于早期基础测试。

### `local_deploy.sh` — 本地单机部署

在本地机器上使用 `127.0.0.1` 启动 4 个 Replica + 1 个 Client，用于开发调试。无需 SSH，所有进程在本地运行。

```bash
./local_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [Algorithm] [WorkloadConfig]
```

**与 `lan_deploy.sh` 的区别：**
- 所有节点绑定 `127.0.0.1`，通过不同端口区分
- 自动检测本地 Python 虚拟环境路径（`rlenv` > `py-resdb` > 系统 Python）
- 启动前自动检测并释放 Agent 端口（45678）
- 无需 SSH、rsync

### `deploy_and_test.sh` — 早期部署测试脚本

早期版本的部署脚本，直接内联了节点配置，用于基础功能验证（CounterServer / CounterClient）。包含 view change 触发逻辑。

> **已被 `lan_deploy.sh` 替代，仅作参考。**

---

## 3. 基准测试脚本

所有基准测试脚本共享以下特性：
- **断点续跑** — 通过 `progress.txt` 记录已完成的实验，中断后可从断点继续
- **自动日志收集** — 每次实验的日志保存在 `logs/` 子目录
- **CSV 结果输出** — 结构化的实验数据，便于后续分析
- **内嵌 Python 解析器** — 从 `server_*.log` 中提取 metrics（吞吐量、延迟、内存等）

### `run_static_benchmark.sh` — 静态配置网格搜索

**目的：** 穷举 `(batchSize, batchTimeout)` 的所有组合，在每种 workload 模式下测量其性能，建立参数-性能映射的完整基线。

```bash
./run_static_benchmark.sh [SkipBuild] [ResumeDir] [ForceRerunKey]
```

**参数空间：**
- `batchSize`: 100 ~ 2000，步长 200（10 个值）
- `batchTimeout`: 50 ~ 200，步长 30（6 个值）
- Workload: 从 `dynamic_workload.config` 提取的唯一 (rate, size) 组合

**实验矩阵：** workloads × batchSizes × batchTimeouts

**每组实验运行 30 秒。** 所有实验使用 `STATIC` 模式（固定参数 + metrics 采集）。

**输出：**
- `static_benchmark_results/<experiment>/results.csv` — 每行一组配置的平均 metrics
- `static_benchmark_results/<experiment>/logs/` — 原始日志

**强制重跑某个配置：**
```bash
./run_static_benchmark.sh true experiment_20260205_150000 5000_128_100_50
```

### `run_dynamic_benchmark.sh` — 动态负载对比测试

**目的：** 在动态变化的 workload 下，比较 RL 算法（BAYESIAN、PPO）与多个代表性静态配置的表现。

```bash
./run_dynamic_benchmark.sh [SkipBuild] [ResumeDir]
```

**前置条件：** 需要预训练的模型文件：
- `server_agent/bo_model.pkl`（贝叶斯优化模型）
- `server_agent/ppo_model.pth`（PPO 模型）

**实验分为两部分：**
1. **Part 1** — 测试动态算法（BAYESIAN、PPO），参数由算法实时调整
2. **Part 2** — 测试静态配置对照组（4 种代表性配置）：
   - `2000, 200` — 大批次大超时（HIGH 阶段最优）
   - `100, 10` — 小批次小超时（LOW 阶段最优）
   - `500, 50` — 折中配置
   - `2000, 50` — 大批次短超时（伪折中对照）

**输出：**
- `results.csv` — 全局平均 metrics
- `phase_results.csv` — 按 workload 阶段分段统计（包含每个阶段的 rate、size、duration 等信息）

### `run_request_timeout_benchmark.sh` — RequestTimeout 影响测试

**目的：** 固定 `batchSize=500, batchTimeout=100`，遍历不同的 `requestTimeout` 值，验证 view change 触发时限对性能的影响。

```bash
./run_request_timeout_benchmark.sh [SkipBuild] [ResumeDir]
```

**测试的 requestTimeout 值：** 200, 500, 1000, 2000, 5000, 10000, 20000 ms

**实验矩阵：** workloads × requestTimeout 值

**每组实验运行 60 秒。**

**输出：**
- `request_timeout_benchmark_results/<experiment>/results.csv`
- `request_timeout_benchmark_results/<experiment>/summary.txt`

### `run_saturation_benchmark.sh` — 饱和吞吐量测试

**目的：** 通过逐步提高客户端发送速率，找到系统在不同 `(batchSize, batchTimeout, messageSize)` 配置下的饱和吞吐量。饱和吞吐定义为系统实际吞吐无法跟上客户端到达速率的临界点。

```bash
./run_saturation_benchmark.sh [SkipBuild] [ResumeDir]
```

**实验矩阵：**
- **Batch 配置**: (100,50)、(500,100)、(1000,100)、(2000,200)
- **消息大小**: 512, 1024 bytes
- **速率扫描**: 1000 ~ 30000 ops/s（升序）

**饱和检测：** 当 `avg_throughput / target_rate < 0.85` 时判定为饱和。连续 2 次饱和后提前终止该配置的剩余速率测试。

**每组实验运行 30 秒。**

**输出：**
- `saturation_benchmark_results/<experiment>/results.csv` — 完整速率-吞吐曲线
- `saturation_benchmark_results/<experiment>/saturation_summary.txt` — 各配置的饱和点、峰值吞吐对比表

### `run_network_timeout_benchmark.sh` — 网络延迟 × RequestTimeout 交叉测试

**目的：** 通过 `tc netem` 注入人工网络延迟，在不同延迟条件下测试 `requestTimeout` 对系统的影响。验证在 LAN 环境中 `requestTimeout` 调参无效但在高延迟场景中可能产生显著效果的假设。

```bash
./run_network_timeout_benchmark.sh [SkipBuild] [ResumeDir]
```

**前置条件：**
- 节点上已安装 `iproute2`（`tc` 命令）
- 当前用户有 `sudo` 权限

**实验矩阵（三维）：**
- **网络延迟**: 0, 10, 50, 100, 200, 500 ms
- **requestTimeout**: 200, 500, 1000, 2000, 5000, 10000 ms
- **workload**: 3 种负载模式（2000/400/50 ops/s，512 bytes）

**固定参数：** `batchSize=500, batchTimeout=100`

**每组实验运行 60 秒。** 外层循环按网络延迟分组以减少 `tc netem` 切换次数。

**输出：**
- `network_timeout_benchmark_results/<experiment>/results.csv`
- `network_timeout_benchmark_results/<experiment>/summary.txt`

> 实验结束后自动恢复网络（移除人工延迟）并恢复原始 `requestTimeout`。

---

## 4. 模型训练脚本

### `run_train_model.sh` — RL 模型训练

**目的：** 在动态 workload 下训练 BAYESIAN 和 PPO 优化器模型。训练完成后的模型用于 `run_dynamic_benchmark.sh` 的对比测试。

```bash
./run_train_model.sh [SkipBuild] [Algorithm]
```

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `SkipBuild` | false | 是否跳过编译 |
| `Algorithm` | ALL | 训练目标：`BAYESIAN`、`PPO` 或 `ALL` |

**训练配置：** 使用 `dynamic_workload_train.config`（10 循环 × 90s，约 15 分钟）

**三种 Workload 模式交替训练：**
- A: rate=500, size=1024（中等负载，中等包）
- B: rate=1000, size=4096（高负载，大包）
- C: rate=200, size=128（低负载，小包）

**输出模型（保存在远程节点上）：**
- `server_agent/bo_model.pkl`（贝叶斯优化）
- `server_agent/ppo_model.pth`（PPO）

**训练日志：** `train_results/train_<timestamp>/`

---

## 5. 结果收集与分析脚本

### `lan_collect_results.sh` — LAN 日志收集

从 LAN 节点上拉取实验日志（server、agent、gc、experiments 数据）到本地 `results/` 目录。

```bash
./lan_collect_results.sh
```

### `wan_collect_results.sh` — WAN 日志收集

从 WAN 节点上拉取日志，使用各节点对应的 SSH 密钥。

```bash
./wan_collect_results.sh
```

### `scripts/reparse_logs.sh` — 重新解析实验日志

使用最新的解析逻辑（去除尾部 0 值、跳过预热样本）重新计算 metrics 并覆盖 `results.csv`。支持 `static` 和 `dynamic` 两种实验类型。

```bash
./scripts/reparse_logs.sh <ExperimentDir> <Type>
# 示例：
./scripts/reparse_logs.sh static_benchmark_results/experiment_20260205_150000 static
./scripts/reparse_logs.sh dynamic_benchmark_results/experiment_20260205_160000 dynamic
```

> 自动备份原始 CSV 文件。

### `scripts/plot_static.py` — 静态实验热力图

读取 `results.csv`，为每种 workload 生成 `(batchSize, batchTimeout)` 参数空间的加权评分热力图。

```bash
python3 scripts/plot_static.py <ExperimentDir> [--thr-weight 0.5] [--lat-weight 0.5]
```

### `scripts/plot_dynamic.py` — 动态实验对比图

读取 `results.csv` 和 `phase_results.csv`，生成：
- 总体吞吐量/延迟对比柱状图
- 按 workload 阶段的分组柱状图
- 按阶段序列的时间序列图

```bash
python3 scripts/plot_dynamic.py <ExperimentDir>
```

---

## 6. 工具脚本

### `set_latency.sh` — 网络延迟注入

通过 `tc netem` 在所有节点上设置人工网络延迟。被 `run_network_timeout_benchmark.sh` 调用。

```bash
./set_latency.sh <delay_in_ms>
# 示例：
./set_latency.sh 50   # 添加 50ms 延迟
./set_latency.sh 0    # 移除延迟
```

> 使用 `ens5` 网络接口（AWS 当前代实例标准接口）。

### `cleanup_tmp_files.sh` — 清理临时文件

删除所有节点上的 `/tmp/bft-*` 临时文件。在每次实验结束时由 `lan_deploy.sh` 自动调用。

```bash
./cleanup_tmp_files.sh
```

### `regenerate_proto.sh` — 重新生成 gRPC 代码

当 `monitor.proto` 被修改时，重新生成 Python gRPC 桩代码（`monitor_pb2.py`、`monitor_pb2_grpc.py`）。

```bash
./regenerate_proto.sh
```

---

## 7. 典型工作流

### 首次实验（从零开始）

```bash
# 1. 配置节点信息
vim lan_config.sh           # 编辑节点 IP、密钥路径等

# 2. 安装远程 Python 环境（仅需执行一次）
./setup_python_env.sh

# 3. 训练 RL 模型（约 30 分钟）
./run_train_model.sh

# 4. 运行静态基线测试
./run_static_benchmark.sh

# 5. 运行动态对比测试
./run_dynamic_benchmark.sh

# 6. 生成分析图表
python3 scripts/plot_static.py static_benchmark_results/experiment_XXXXXXXX_XXXXXX
python3 scripts/plot_dynamic.py dynamic_benchmark_results/experiment_XXXXXXXX_XXXXXX
```

### 中断后续跑

```bash
# 从上次中断的位置继续运行
./run_static_benchmark.sh true experiment_20260205_150000
./run_dynamic_benchmark.sh true experiment_20260205_160000
```

### 本地开发调试

```bash
# 1. 安装本地 Python 环境
./setup_local_python_env.sh

# 2. 本地单机部署测试
./local_deploy.sh 500 100 -1 false BAYESIAN
```

---

## 附录：Metrics 格式

所有基准测试脚本从 `server_*.log` 中解析以下格式的 metrics 行：

```
thr=XXX, lat=XXX us | avgSize=XXX bytes, arrivalRate=XXX req/s | Memory: XXXMB/XXXMB (XX.X%)
```

解析策略：
- **跳过预热样本** — 前 5~10 个样本不计入统计
- **去除尾部零值** — 客户端停止后的拖尾零吞吐量样本被移除
- **输出格式** — CSV，字段包括：`avg_throughput, avg_latency_us, avg_msg_size_bytes, avg_arrival_rate, avg_mem_used_mb, avg_mem_max_mb, avg_mem_percent, sample_count`

---

## 附录：目录结构约定

```
results/                              # lan_deploy.sh 单次实验的日志输出
static_benchmark_results/             # run_static_benchmark.sh 结果
  experiment_XXXXXXXX_XXXXXX/
    results.csv
    progress.txt
    logs/
dynamic_benchmark_results/            # run_dynamic_benchmark.sh 结果
  experiment_XXXXXXXX_XXXXXX/
    results.csv
    phase_results.csv
    progress.txt
    logs/
request_timeout_benchmark_results/    # run_request_timeout_benchmark.sh 结果
network_timeout_benchmark_results/    # run_network_timeout_benchmark.sh 结果
saturation_benchmark_results/         # run_saturation_benchmark.sh 结果
train_results/                        # run_train_model.sh 训练日志
  train_XXXXXXXX_XXXXXX/
config/workloads/                     # Workload 配置文件
  dynamic_workload.config             # 主 workload 配置
  dynamic_workload_train.config       # 训练用 workload
  dynamic_workload_test.config        # 测试用 workload
server_agent/                         # Python Agent 代码和模型
  trainer.py                          # 主 Agent（BO/PPO/SA）
  mock_agent.py                       # 测试用 Mock Agent
  bo_model.pkl                        # 贝叶斯优化训练模型
  ppo_model.pth                       # PPO 训练模型
```

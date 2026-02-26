# BFT-SMaRt v2.0 项目总览

> 分析日期：2026-02-26

---

## 1. 项目简介

**BFT-SMaRt**（Byzantine Fault-Tolerant State Machine Replication）是一个基于 Java 的开源拜占庭容错状态机复制库，由葡萄牙里斯本大学 LASIGE 计算机科学与工程研究中心维护。

本仓库在原版 BFT-SMaRt 基础上进行了扩展，增加了**基于强化学习（RL）和贝叶斯优化（Bayesian Optimization）的动态参数调优系统**，通过实时监控共识性能指标，自动调整 BFT-SMaRt 的关键配置参数（如 `maxbatchsize` 和 `batchtimeout`），以适应动态变化的客户端负载。

### 核心能力

| 能力 | 说明 |
|------|------|
| **BFT 共识** | 容忍最多 `f` 个拜占庭故障节点，需要 `3f+1` 个副本 |
| **崩溃容错模式** | 可切换为 CFT 模式，仅需 `2f+1` 个副本 |
| **状态迁移** | 支持内存型和磁盘型两种日志/快照协议 |
| **动态重配置** | 运行时添加/移除副本节点 |
| **动态调参** | 通过 RL/贝叶斯优化实时调整共识批处理参数 |
| **基准测试框架** | 内置分布式吞吐量/延迟基准测试套件 |

---

## 2. 顶层目录结构

```
library/
├── src/                    # Java 核心源代码 + Protobuf 定义
├── server_agent/           # Python RL/优化 Agent
├── scripts/                # 结果解析与绘图脚本
├── config/                 # 系统、主机、基准测试配置文件
├── runscripts/             # 单副本/客户端启动脚本
├── lib/                    # 第三方 JAR 依赖
├── build/                  # Gradle 构建输出（自动生成）
├── py-resdb/               # Python 虚拟环境
├── docs/                   # Javadoc 文档
├── build.gradle            # Gradle 构建脚本
├── settings.gradle         # Gradle 项目设置
├── lan_config.sh           # LAN 部署节点地址配置
├── wan_config.sh           # WAN 部署节点地址配置
├── lan_deploy.sh           # LAN 自动化部署脚本
├── wan_deploy.sh           # WAN 自动化部署脚本
├── run_benchmark_suite.sh       # 静态基准测试套件
├── run_static_benchmark.sh      # 静态参数基准测试
├── run_dynamic_benchmark.sh     # 动态负载基准测试（含 RL/BO）
├── run_train_model.sh           # RL 模型训练脚本
├── lan_collect_results.sh       # LAN 结果收集
├── wan_collect_results.sh       # WAN 结果收集
├── deploy_and_test.sh           # 一键部署并测试
├── set_latency.sh               # 网络延迟模拟工具
└── cleanup_tmp_files.sh         # 临时文件清理
```

---

## 3. Java 源代码包结构（`src/main/java/bftsmart/`）

```
bftsmart/
├── communication/          # 网络通信层
├── consensus/              # BFT 核心共识协议
├── tom/                    # Total Order Multicast（核心抽象接口）
├── clientsmanagement/      # 客户端请求管理
├── statemanagement/        # 状态迁移协议
├── reconfiguration/        # 副本组动态重配置
├── benchmark/              # 分布式基准测试框架
├── demo/                   # 演示与实验应用
│   ├── counter/            # 简单计数器演示
│   ├── map/                # 键值 Map 演示
│   ├── microbenchmarks/    # 微基准（吞吐量/延迟）
│   ├── ycsb/               # YCSB 工作负载接入
│   └── rlWrapper/          # RL Agent 连接器（动态调参）
└── tests/                  # 集成测试
```

### 3.1 `communication` — 通信层

| 文件 | 职责 |
|------|------|
| `ServerCommunicationSystem.java` | 副本间通信系统入口 |
| `MessageHandler.java` | 消息收发调度 |
| `SystemMessage.java` | 系统消息基类 |
| `client/` | 客户端到副本的通信实现 |
| `server/` | 副本间的通信实现 |

底层使用 **Netty** 进行异步 NIO 通信，支持 TLS/SSL、MAC 认证和签名验证（ECDSA/RSA）。

### 3.2 `consensus` — 共识协议

| 文件/目录 | 职责 |
|-----------|------|
| `Consensus.java` | 单次共识实例管理 |
| `Decision.java` | 共识决定结果封装 |
| `Epoch.java` | 轮次（Epoch）管理 |
| `TimestampValuePair.java` | 时间戳-值对（用于 WRITE/ACCEPT 消息） |
| `messages/` | PROPOSE / WRITE / ACCEPT 消息定义 |
| `roles/` | 领导者（Proposer）与跟随者（Acceptor）角色 |

实现了基于 **PBFT 变种**的 BFT 共识，结合了领导者变更（Leader Change）与同步化（Synchronizer）机制。

### 3.3 `tom` — Total Order Multicast

这是库的核心 API 层，用户通过此层接入复制状态机。

| 文件/目录 | 职责 |
|-----------|------|
| `ServiceProxy.java` | 客户端 API：发送有序/只读请求 |
| `AsynchServiceProxy.java` | 异步版本客户端 API |
| `ServiceReplica.java` | 副本初始化与请求执行驱动 |
| `ReplicaContext.java` | 副本上下文（传递给应用层） |
| `MessageContext.java` | 单个请求的元数据上下文 |
| `core/TOMLayer.java` | 核心协调层，驱动共识与请求投递 |
| `core/ExecutionManager.java` | 共识实例生命周期管理 |
| `core/DeliveryThread.java` | 将已达成共识的请求投递给应用层 |
| `core/Synchronizer.java` | 领导者变更与同步化执行 |
| `leaderchange/` | 领导者变更协议实现 |
| `server/defaultservices/` | 默认状态服务（内存日志+快照） |
| `server/durability/` | 磁盘持久化状态服务 |
| `util/` | SequenceNumbers、StoredMessages 等工具类 |

### 3.4 `clientsmanagement` — 客户端管理

| 文件 | 职责 |
|------|------|
| `ClientsManager.java` | 维护所有活跃客户端会话 |
| `ClientData.java` | 单个客户端的连接状态与序列号追踪 |
| `RequestList.java` | 待处理请求队列 |

### 3.5 `statemanagement` — 状态迁移

| 文件/目录 | 职责 |
|-----------|------|
| `StateManager.java` | 状态迁移协议控制器 |
| `ApplicationState.java` | 应用状态的序列化接口 |
| `SMMessage.java` | 状态迁移消息类型 |
| `standard/` | 标准（内存）状态迁移实现 |
| `durability/` | 磁盘持久化状态迁移实现 |

### 3.6 `reconfiguration` — 动态重配置

支持在运行时无中断地添加或移除副本节点。

| 文件 | 职责 |
|------|------|
| `ViewManager.java` | 当前 View（副本组视图）管理 |
| `ServerViewController.java` | 服务端视图控制器 |
| `ClientViewController.java` | 客户端视图控制器 |
| `View.java` | 副本组视图（ID + 地址列表） |
| `VMServices.java` | 重配置命令工具类 |
| `Reconfiguration.java` | 重配置客户端 API |

### 3.7 `benchmark` — 基准测试框架

分布式 Controller-Worker 架构的基准测试框架：

| 文件 | 职责 |
|------|------|
| `BenchmarkSetup.java` | 基准测试实验参数封装 |
| `Measurement.java` | 吞吐量/延迟测量记录 |
| `ThroughputLatencyClient.java` | 基准测试客户端 Worker |
| `ThroughputLatencyServer.java` | 基准测试服务端（含指标上报） |
| `ThroughputLatencyBenchmarkStrategy.java` | 实验策略（客户端数量递进等） |
| `ThroughputEventProcessor.java` | 事件处理与指标聚合 |

### 3.8 `demo/rlWrapper` — RL Agent 连接器（扩展核心）

`RLAgentConnector.java` 是本项目最重要的扩展组件。

**功能流程：**
1. 启动后等待 Warmup（默认 10 秒）
2. 每隔 1 秒通过 gRPC 向 Python Agent 上报当前性能指标（吞吐量、延迟）
3. 接收 Agent 返回的新参数（`maxBatchSize`、`batchTimeout`）
4. 调用 `serviceReplica.setDynamicConsensusConfig()` 热更新副本配置
5. 每 10 个周期更新一次 `requestTimeout`（避免频繁振荡）

---

## 4. Python Server Agent（`server_agent/`）

Python 端实现了三种参数优化算法，通过 gRPC 服务与 Java 副本通信。

### 4.1 文件概览

| 文件 | 职责 |
|------|------|
| `trainer.py` | 主 Agent 服务，实现 PPO / Bayesian Optimization / Simulated Annealing |
| `mock_agent.py` | 模拟 Agent，用于调试（支持 random / fixed / incremental 三种模式） |
| `monitor_pb2.py` | Protobuf 生成的消息类 |
| `monitor_pb2_grpc.py` | Protobuf 生成的 gRPC 存根 |
| `requirements.txt` | Python 依赖列表 |

### 4.2 优化算法对比

| 算法 | 类 | 特点 |
|------|-----|------|
| **PPO**（近端策略优化） | `PPOAgent` | Actor-Critic 神经网络，连续动作空间调参 |
| **Bayesian Optimization** | `BayesianOptimizationAgent` | 基于高斯过程（Matern 核），样本效率高 |
| **Simulated Annealing** | `SimulatedAnnealingAgent` | 基于模拟退火，无需训练数据 |

### 4.3 gRPC 接口（`monitor.proto`）

服务名：`MetricsService`，端口默认 `45678`

| RPC 方法 | 请求 | 响应 | 说明 |
|----------|------|------|------|
| `Connect` | `Timestamp` | `Timestamp` | 握手/心跳 |
| `SendMetrics` | `MetricsData` | `ConfigParams` | 上报指标，获取新参数 |

`MetricsData` 包含：吞吐量、平均延迟、P99 延迟等  
`ConfigParams` 包含：`maxBatchSize`、`batchTimeout`

---

## 5. 配置文件（`config/`）

| 文件 | 说明 |
|------|------|
| `system.config` | BFT-SMaRt 核心参数（副本数、批处理大小、超时、签名算法等） |
| `hosts.config` | 副本 IP 地址和端口映射表 |
| `benchmark.config` | 基准测试 Controller/Worker 参数 |
| `logback.xml` | 日志框架配置 |
| `java.security` | Java 安全策略覆盖 |
| `keysECDSA/` | ECDSA 公私钥对（0-3 为副本，1001+ 为客户端） |
| `keysRSA/` | RSA 公私钥对（备用） |
| `keysSSL_TLS/` | SSL/TLS 证书（用于加密传输） |
| `system_config_parameter_analysis.md` | 系统参数动态调参可行性分析文档 |

### 关键动态调参参数

| 参数 | 当前默认值 | 说明 |
|------|-----------|------|
| `system.totalordermulticast.maxbatchsize` | 1024 | 每轮共识最大请求批量 |
| `system.totalordermulticast.batchtimeout` | -1（立即触发） | 批量等待超时（ms） |
| `system.totalordermulticast.timeout` | 2000 | 客户端请求超时（ms） |
| `system.servers.num` | 4 | 副本总数 |
| `system.servers.f` | 1 | 最大容忍拜占庭故障数 |

---

## 6. 部署架构

### LAN 部署（AWS 私有网络）

`lan_config.sh` 中定义了 5 个节点（前 4 个为副本，第 5 个为客户端）：

```
Node 0 (Replica) : 172.31.15.219
Node 1 (Replica) : 172.31.4.11
Node 2 (Replica) : 172.31.10.49
Node 3 (Replica) : 172.31.10.254
Node 4 (Client)  : 172.31.13.125
```

### 部署流程

```
./gradlew installDist          # 1. 编译打包
./lan_deploy.sh                # 2. 通过 SCP 分发到各节点
# 在各副本节点上启动 Java 进程
# 在客户端节点上启动基准测试客户端
# 在其中一个节点上启动 Python Agent（trainer.py）
./lan_collect_results.sh       # 3. 收集日志和测量结果
```

### 基准测试流程

| 脚本 | 用途 |
|------|------|
| `run_static_benchmark.sh` | 静态参数组合遍历测试 |
| `run_dynamic_benchmark.sh` | 动态负载下对比 BAYESIAN / PPO / 多组静态配置 |
| `run_benchmark_suite.sh` | （已废弃）早期批量测试脚本 |
| `run_train_model.sh` | 训练 PPO 或 BO 模型并保存 `.pth` / `.pkl` 文件 |

---

## 7. 构建系统

- **构建工具**: Gradle 7.x
- **Java 版本**: Java 8 (source & target compatibility)
- **主要依赖**:

| 库 | 版本 | 用途 |
|----|------|------|
| Bouncy Castle (`bcpkix`, `bcprov`) | 1.69 | 加密/签名（ECDSA） |
| Netty | 4.1.67 | 异步网络通信 |
| gRPC Netty | 1.42.1 | 副本↔Agent 通信 |
| Protobuf Java | 3.19.1 | 消息序列化 |
| Logback | 1.2.5 | 日志框架 |
| Commons Codec | 1.15 | 编解码工具 |

- **Gradle 任务**:

| 任务 | 说明 |
|------|------|
| `installDist` | 编译并打包为可分发目录 |
| `localDeploy` | 本地多进程部署（4 副本 + 1 客户端） |
| `remoteDeploy` | 通过 SSH 部署到远程 Master 节点 |
| `runIntegrationTest` | 运行集成测试 |
| `generateProto` | 从 `.proto` 文件生成 Java gRPC 代码 |

---

## 8. 数据流与系统架构图

```
┌─────────────────────────────────────────────────────────────┐
│                        客户端 (Client)                        │
│  ServiceProxy.java  ──────  发送有序/只读请求 ──────▶         │
└──────────────────────────────────────────────────────────────┘
                              │  TCP/Netty
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                  副本 0/1/2/3 (Replica)                       │
│                                                              │
│  ServerCommunicationSystem                                   │
│       ↓                                                      │
│  TOMLayer  ←→  ExecutionManager  ←→  Consensus (PBFT)        │
│       ↓                                                      │
│  DeliveryThread → ServiceReplica → 应用层 (User App)         │
│                                                              │
│  ThroughputLatencyServer  ──指标──▶  RLAgentConnector        │
│                                            │  gRPC           │
└────────────────────────────────────────────│────────────────┘
                                             ▼
                              ┌──────────────────────────┐
                              │  Python Agent (trainer.py) │
                              │  PPO / Bayesian / SA       │
                              │  端口: 45678               │
                              └──────────────────────────┘
                                             │  新配置参数
                                             ▼
                  ┌──────────────────────────────────────────────┐
                  │           参数分类处理（RLAgentConnector）        │
                  │                                              │
                  │  batchSize / batchTimeout                    │
                  │  → 本地 volatile 写入，直接生效（无需共识）       │
                  │                                              │
                  │  requestTimeout（每 10s，仅当前 PBFT leader 提交）│
                  │  → configProxy.invokeOrdered(ConfigChange)  │
                  │    ↓ 与普通请求交织，走同一 PBFT 共识流水线      │
                  │    ↓ 所有副本在同一 appExecuteBatch 交付点应用  │
                  │    → replica.applyConsensusRequestTimeout()  │
                  └──────────────────────────────────────────────┘
```

### 参数共识流程详解

**本地参数（batchSize / batchTimeout）**：
- 每个副本独立接受 Python Agent 的建议并直接写入（`volatile`）
- 不一致不会破坏协议正确性

**共识参数（requestTimeout）**：
- `requestTimeout` 决定每个副本何时认为 leader 超时并触发 leader change；若各副本值不同，会导致部分副本提前触发视图变更，破坏协议活性
- 由**当前 PBFT consensus leader** 每 10s 通过 `configProxy.invokeOrdered()` 提交一次（每个副本检查 `serviceReplica.getCurrentLeader()` == 自身 ID，仅 leader 提交）
- `configProxy` 在首次成为 leader 时懒初始化（clientId=4999，所有副本均可），避免资源浪费
- 该请求以 8 字节魔数`0xBF434647`开头，在 `appExecuteBatch` 中被识别为参数共识请求
- **不会暂停普通共识**：config-change 与普通业务请求共享同一 PBFT 排序流水线，可在同一批次中混合处理
- 所有副本在**同一共识交付点**原子应用新值，保证全局一致

**Config Proposer 角色跟随 PBFT Leader**：

| 角色 | 绑定 | Leader Change 影响 |
|------|------|-----------------|
| PBFT Leader（Proposer）| 当前 regency 的 leader，随 leader change 变化 | 变化 |
| Config Proposer | **动态绑定到当前 PBFT leader**（`serviceReplica.getCurrentLeader()`） | **同步变化** |

Leader change 后，新 leader 的 `RLAgentConnector` 在下一个 10s 滴答时检测到 `replicaId == getCurrentLeader()` 为真，自动承担 Config Proposer 职责；旧 leader 检测到自己不再是 leader，跳过提交。`configProxy` 采用懒初始化，首次成为 leader 时才创建 ServiceProxy，避免全部副本同时持有连接。

**唯一暂停窗口**：leader change 协议执行期间（旧 leader 挂起、新 leader 尚未当选），config 提交暂停；选主完成后在下一个滴答自动恢复，最大延迟等于一次 `REQUEST_TIMEOUT_UPDATE_INTERVAL`（10s）+ 选主时延。

---

## 9. Python 脚本工具（`scripts/`）

| 文件 | 用途 |
|------|------|
| `plot_static.py` | 绘制静态基准测试结果图（吞吐量/延迟热图） |
| `plot_dynamic.py` | 绘制动态负载实验结果对比图 |
| `reparse_logs.sh` | 重新解析日志文件，提取性能指标 |

---

## 10. 测试

- **集成测试**: `src/test/java/bftsmart/tests/IntegrationTestsExecutor.java`  
  使用 `runIntegrationTest` Gradle 任务，在本地自动启动多个 JVM 进程模拟副本，验证端到端正确性。
- **单元测试**: 位于 `src/test/java/`，通过 `./gradlew test` 运行。

---

## 11. 关键设计要点与注意事项

1. **动态调参安全性**  
   只有 `maxbatchsize` 和 `batchtimeout` 被标记为安全的动态参数（通过 `volatile` 热更新），其他通信/签名参数均为静态配置。

2. **确定性要求**  
   应用层必须避免 `HashMap`/`HashSet`（非确定性序列化），应使用 `TreeMap`/`TreeSet`，以确保状态迁移后各副本状态一致。

3. **生产环境安全**  
   生产环境需将 `system.communication.defaultkeys` 设为 `false`，确保各副本使用独立私钥。

4. **只读优化**  
   只读请求优化（跳过共识）默认关闭（内存消耗较高），可通过 `system.optimizations.readonly_requests = true` 开启。

5. **客户端 ID 唯一性**  
   每个客户端必须使用唯一的整数 ID，否则会导致请求无法完成。

---

> 本文件由 GitHub Copilot 自动分析生成于 2026-02-26。

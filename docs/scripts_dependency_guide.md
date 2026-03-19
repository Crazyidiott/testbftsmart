# testbftsmart 脚本依赖与使用说明

本文档覆盖仓库中 Git 跟踪的全部脚本文件（`.sh/.py/.bat/.cmd`），并补全了缺失或不完整的使用方式。

## 1. 总体依赖关系

## 1.1 核心基础层

- `lan_config.sh` / `lan_config_local.sh`
  - 提供 LAN 节点、认证方式、路径等配置。
- `lan_connection.sh`
  - 基于上述配置提供 `remote_ssh` / `remote_scp_from` / `remote_rsync_to` / `remote_file_exists` 等统一远程操作函数。
  - 被绝大多数 LAN 相关脚本依赖。
- `wan_config.sh`
  - 提供 WAN 节点与多密钥配置；被 WAN 脚本依赖。

## 1.2 执行层（部署/运行）

- `lan_deploy.sh`、`local_deploy.sh`、`wan_deploy.sh`
  - 部署、启动副本与客户端、等待运行结束、回收日志。
- `runscripts/smartrun.sh`（Linux）/`runscripts/smartrun.cmd`（Windows）
  - Java 进程统一启动入口，被部署脚本调用。

## 1.3 实验编排层（Benchmark）

- `run_static_benchmark.sh`
- `run_dynamic_benchmark.sh`
- `run_saturation_benchmark.sh`
- `run_request_timeout_benchmark.sh`
- `run_network_timeout_benchmark.sh`
- `run_asymmetric_timeout_benchmark.sh`
- `run_request_timeout_closed_loop.sh`
- `run_batch_steady_asymmetric_timeout_benchmark.sh`
- `run_train_model.sh`

这些脚本主要通过调用 `lan_deploy.sh` 反复执行实验。

## 1.4 数据处理与工具层

- `scripts/reparse_logs.sh`：重新解析日志并重建结果 CSV。
- `scripts/aggregate_steady_grid.py`：聚合多轮 steady grid 结果。
- `scripts/plot_static.py` / `scripts/plot_dynamic.py`：可视化。
- `set_latency.sh` / `set_asymmetric_latency.sh`：注入网络延迟。
- `setup_python_env.sh` / `setup_local_python_env.sh`：准备 Python agent 环境。
- `regenerate_proto.sh`：更新 gRPC Python 代码。

## 1.5 典型调用链

- 静态网格实验：
  - `run_static_benchmark.sh` -> `lan_deploy.sh` -> `runscripts/smartrun.sh`
- 动态算法对比：
  - `run_dynamic_benchmark.sh` -> `lan_deploy.sh` -> `server_agent/trainer.py`
- 非对称超时实验：
  - `run_asymmetric_timeout_benchmark.sh` -> `set_asymmetric_latency.sh` + `lan_deploy.sh`
- 三次稳态聚合：
  - `run_batch_steady_asymmetric_timeout_benchmark.sh` -> `run_asymmetric_timeout_benchmark.sh` -> `scripts/aggregate_steady_grid.py`

---

## 2. 脚本逐个说明

下面按目录分组说明：用途、依赖、用法、补充说明。

## 2.1 仓库根目录脚本

### `cleanup_tmp_files.sh`
- 用途：清理各 replica 与 client 机器上的 `/tmp/bft-*` 临时文件。
- 依赖：`lan_connection.sh`。
- 用法：
  - `./cleanup_tmp_files.sh`
- 补充：支持本地 client 与远端 client 两种模式（取决于 `LAN_CONFIG_FILE` 配置）。

### `deploy_and_test.sh`
- 用途：面向固定 AWS 节点的一体化部署/启动/取日志脚本（较早期流程，可弃用）。
- 依赖：系统 `ssh/scp/rsync/keytool/java/gradle`；`runscripts/smartrun.sh`。
- 用法：
  - `./deploy_and_test.sh`
- 补充：节点 IP、密钥、用户均写死在脚本内，建议仅用于快速临时验证。

### `gradlew.bat`
- 用途：Windows 下 Gradle Wrapper 启动脚本（标准生成文件）。
- 依赖：Windows + `JAVA_HOME` 或 `java` 可执行。
- 用法：
  - `gradlew.bat installDist`

### `lan_collect_results.sh`
- 用途：从 LAN 节点与 client 收集日志到本地 `results/`。
- 依赖：`lan_connection.sh`。
- 用法：
  - `./lan_collect_results.sh`
- 补充：会尝试拉取 `server_agent/experiments/` 目录。

### `lan_config.sh`
- 用途：LAN 远程部署配置（节点、密钥、远程目录、用户等）。
- 依赖：被 `lan_connection.sh` source。
- 用法：
  - 编辑配置后供其他脚本自动读取。
  - 临时指定：`LAN_CONFIG_FILE=./lan_config.sh <script>`

### `lan_config_local.sh`
- 用途：LAN 配置的本地 client 变体（replica 远端，client 本机）。
- 依赖：被 `lan_connection.sh` source。
- 用法：
  - `LAN_CONFIG_FILE=./lan_config_local.sh ./lan_deploy.sh 500 100 -1 false STATIC`

### `lan_connection.sh`
- 用途：LAN 统一连接层，封装 key/password 两种 SSH 认证及 rsync/scp 操作。
- 依赖：`lan_config_local.sh` 或 `lan_config.sh`。
- 用法：
  - 一般作为库脚本：`source ./lan_connection.sh`
  - 也可通过环境变量切换配置：`LAN_CONFIG_FILE=./lan_config_local.sh ...`
- 补充：提供 `SUDO_CMD`，用于远程执行需要 sudo 的命令。

### `lan_deploy.sh`
- 用途：LAN 全流程部署与单轮实验执行主入口。
- 依赖：`lan_connection.sh`、`runscripts/smartrun.sh`、`cleanup_tmp_files.sh`、Java/Gradle/keytool。
- 用法：
  - `./lan_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [ALGORITHM] [WorkloadConfig]`
  - 示例：
    - `./lan_deploy.sh 500 100 -1 false BAYESIAN`
    - `LAN_CONFIG_FILE=./lan_config_local.sh ./lan_deploy.sh 500 100 -1 false STATIC`
- 参数说明：
  - `ALGORITHM` 支持 `NONE/STATIC/MOCK/BAYESIAN/PPO/SA`（其中 `trainer.py` 实际实现为主）。
  - `WorkloadConfig` 为空时使用 `AsyncLatencyClient`，不为空时使用 `AsyncDynamicClient`。

### `local_deploy.sh`
- 用途：单机部署版（4 replicas + 1 client 同机）用于本地快速调试。
- 依赖：`runscripts/smartrun.sh`、本机 Java/Gradle；可选 `server_agent/rlenv`。
- 用法：
  - `./local_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild] [ALGORITHM] [WorkloadConfig]`
  - 示例：
    - `./local_deploy.sh 500 100 -1 false NONE`
    - `./local_deploy.sh 500 100 -1 false STATIC`
    - `./local_deploy.sh 500 100 5000 false NONE workload_burst.yaml`

### `regenerate_proto.sh`
- 用途：根据 `src/main/proto/monitor.proto` 重新生成 Python gRPC stub。
- 依赖：`python3` + `grpcio-tools`。
- 用法：
  - `./regenerate_proto.sh`
- 补充：会覆盖 `server_agent/monitor_pb2.py` 与 `server_agent/monitor_pb2_grpc.py`。

### `run_asymmetric_timeout_benchmark.sh`
- 用途：非对称延迟（leader 高延迟）下扫描 `requestTimeout`。
- 依赖：`set_asymmetric_latency.sh`、`lan_deploy.sh`、`python3`。
- 用法：
  - `./run_asymmetric_timeout_benchmark.sh [SkipBuild] [ResumeDir]`
  - 示例：
    - `./run_asymmetric_timeout_benchmark.sh`
    - `./run_asymmetric_timeout_benchmark.sh true`
- 常用环境变量：
  - `LEADER_DELAYS_OVERRIDE`、`REQUEST_TIMEOUTS_OVERRIDE`、`RUN_DURATION_OVERRIDE`
  - `ENABLE_BURST_MODE=true/false`
  - `AUTO_CONFIRM=true`（免交互确认）

### `run_batch_steady_asymmetric_timeout_benchmark.sh`
- 用途：批量执行 3 轮稳态非对称超时实验并聚合结果。
- 依赖：`run_asymmetric_timeout_benchmark.sh`、`scripts/aggregate_steady_grid.py`。
- 用法：
  - `bash run_batch_steady_asymmetric_timeout_benchmark.sh`
- 补充：脚本无 shebang，建议显式使用 `bash` 执行。

### `run_dynamic_benchmark.sh`
- 用途：动态负载下对比 BAYESIAN/PPO 与若干 STATIC 参数。
- 依赖：`lan_deploy.sh`、`python3`。
- 用法：
  - `./run_dynamic_benchmark.sh [SkipBuild] [ResumeDir]`
  - 示例：
    - `./run_dynamic_benchmark.sh`
    - `./run_dynamic_benchmark.sh true`
    - `./run_dynamic_benchmark.sh true experiment_20260205_150000`

### `run_network_timeout_benchmark.sh`
- 用途：网络对称延迟 × requestTimeout 交叉实验。
- 依赖：`set_latency.sh`、`lan_deploy.sh`、`python3`。
- 用法：
  - `./run_network_timeout_benchmark.sh [SkipBuild] [ResumeDir]`
  - 示例：
    - `./run_network_timeout_benchmark.sh`
    - `./run_network_timeout_benchmark.sh true`

### `run_request_timeout_benchmark.sh`
- 用途：固定 batch 参数下扫描 requestTimeout。
- 依赖：`lan_deploy.sh`、`python3`。
- 用法：
  - `./run_request_timeout_benchmark.sh [SkipBuild] [ResumeDir]`

### `run_request_timeout_closed_loop.sh`
- 用途：闭环验证“timeout 过小/过大都可能不好”。
- 依赖：`run_asymmetric_timeout_benchmark.sh`、`python3`。
- 用法：
  - `./run_request_timeout_closed_loop.sh [SkipBuild]`
- 常用环境变量：
  - `WORKLOAD_RATE_OVERRIDE`
  - `RUN_DURATION_OVERRIDE`
  - `REQUEST_TIMEOUTS_OVERRIDE`

### `run_saturation_benchmark.sh`
- 用途：在不同参数下逐步升压，估计饱和吞吐点。
- 依赖：`lan_connection.sh`、`lan_deploy.sh`、`python3`。
- 用法：
  - `./run_saturation_benchmark.sh [SkipBuild] [ResumeDir]`

### `run_static_benchmark.sh`
- 用途：静态网格搜索 `(batch_size, batch_timeout)`。
- 依赖：`lan_deploy.sh`、`python3`。
- 用法：
  - `./run_static_benchmark.sh [SkipBuild] [ResumeDir] [ForceRerunKey]`
  - 示例：
    - `./run_static_benchmark.sh true experiment_20260205_150000 5000_128_100_50`

### `run_train_model.sh`
- 用途：训练 BAYESIAN/PPO 模型文件。
- 依赖：`lan_connection.sh`、`lan_deploy.sh`。
- 用法：
  - `./run_train_model.sh [SkipBuild] [Algorithm]`
  - 示例：
    - `./run_train_model.sh`
    - `./run_train_model.sh true ALL`
    - `./run_train_model.sh true BAYESIAN`
    - `./run_train_model.sh true PPO`
- 补充：脚本会有交互确认（`Press Enter to start`）。

### `set_asymmetric_latency.sh`
- 用途：按 replica 节点分别注入不同延迟。
- 依赖：`lan_connection.sh`、远端 `tc` 命令。
- 用法：
  - `./set_asymmetric_latency.sh <delay_node0> <delay_node1> <delay_node2> <delay_node3>`
  - 示例：
    - `./set_asymmetric_latency.sh 200 0 0 0`
    - `./set_asymmetric_latency.sh 0 0 0 0`

### `set_latency.sh`
- 用途：对所有节点（及可选 client）注入相同延迟。
- 依赖：`lan_connection.sh`、远端 `tc` 命令。
- 用法：
  - `./set_latency.sh <delay_in_ms>`
  - 示例：
    - `./set_latency.sh 50`
    - `./set_latency.sh 0`
  - 指定网卡：`LATENCY_INTERFACE=eth0 ./set_latency.sh 50`

### `setup_local_python_env.sh`
- 用途：本机创建并验证 `server_agent/rlenv`。
- 依赖：`python3-venv`、`python3-pip`、`server_agent/requirements.txt`。
- 用法：
  - `./setup_local_python_env.sh`

### `setup_python_env.sh`
- 用途：在各 replica 远程准备 Python agent 运行环境。
- 依赖：`lan_connection.sh`、远端 apt、`server_agent/requirements.txt`。
- 用法：
  - `./setup_python_env.sh`

### `wan_collect_results.sh`
- 用途：WAN 实验日志收集。
- 依赖：`wan_config.sh`、`scp`。
- 用法：
  - `./wan_collect_results.sh`

### `wan_config.sh`
- 用途：WAN 节点、公钥、远端目录配置。
- 依赖：被 `wan_deploy.sh` / `wan_collect_results.sh` source。
- 用法：
  - 编辑配置后由调用方脚本加载。

### `wan_deploy.sh`
- 用途：WAN 部署实验流程（与 LAN 流程类似，但缺失lan大量逻辑，需要重写）。
- 依赖：`wan_config.sh`、`runscripts/smartrun.sh`、系统 `ssh/scp/rsync`。
- 用法：
  - `./wan_deploy.sh [BatchSize] [Timeout] [ClientRate] [SkipBuild]`
  - 示例：
    - `./wan_deploy.sh`
    - `./wan_deploy.sh 500 100 -1 false`
- 补充：脚本内包含大量说明性注释；当前流程仍偏手工化，建议先在测试环境验证。

## 2.2 runscripts 目录

### `runscripts/generate-javadoc.sh`
- 用途：生成 Javadoc（旧脚本）。
- 依赖：`javadoc`。
- 用法：
  - `bash runscripts/generate-javadoc.sh`
- 补充：脚本使用 `doc/` 目录，而仓库当前有 `docs/`，执行前请确认路径。

### `runscripts/smartrun.cmd`
- 用途：Windows 下启动任意 Java 主类。
- 依赖：`java`、`lib/*`。
- 用法：
  - `runscripts\smartrun.cmd <MainClass> [args...]`

### `runscripts/smartrun.sh`
- 用途：Linux 下启动任意 Java 主类（支持 GC 日志与 agent 端口）。
- 依赖：`java`、`lib/*`、`config/java.security`、`config/logback.xml`。
- 用法：
  - `./runscripts/smartrun.sh <MainClass> [args...]`
  - 示例：
    - `./runscripts/smartrun.sh bftsmart.demo.microbenchmarks.ThroughputLatencyServer 0 1000 1024 1024 false nosig 0`
    - `AGENT_PORT=45679 ./runscripts/smartrun.sh <MainClass> ...`
    - `ENABLE_GC_LOG=true ./runscripts/smartrun.sh <MainClass> ...`

### `runscripts/startReplicaYCSB.sh`
- 用途：启动 YCSB server 副本。
- 依赖：`java`。
- 用法：
  - `bash runscripts/startReplicaYCSB.sh <ReplicaIndex>`
  - 示例：`bash runscripts/startReplicaYCSB.sh 0`

### `runscripts/ycsb.sh`
- 用途：YCSB 启动包装脚本。
- 依赖：`JAVA_HOME`。
- 用法：
  - `bash runscripts/ycsb.sh <CLASSNAME> [args...]`
- 补充：若未设置 `JAVA_HOME` 会直接退出。

### `runscripts/ycsbClient.sh`
- 用途：以固定参数启动 YCSB 客户端。
- 依赖：`java`、`com.yahoo.ycsb.Client`。
- 用法：
  - `bash runscripts/ycsbClient.sh`
- 补充：线程数、workload 文件在脚本内写死。

## 2.3 scripts 目录（数据处理）

### `scripts/aggregate_steady_grid.py`
- 用途：汇总多个 steady grid 实验目录，输出统计 CSV/MD。
- 依赖：Python 标准库（无重包依赖）。
- 用法：
  - `python3 scripts/aggregate_steady_grid.py <exp_dir1> <exp_dir2> ...`
  - 示例：
    - `python3 scripts/aggregate_steady_grid.py asymmetric_timeout_benchmark_results/experiment_20260319_101010 asymmetric_timeout_benchmark_results/experiment_20260319_121212`

### `scripts/plot_dynamic.py`
- 用途：为 dynamic benchmark 生成对比图。
- 依赖：`pandas`、`numpy`、`matplotlib`、`seaborn`。
- 用法：
  - `python3 scripts/plot_dynamic.py <results_csv> <phase_results_csv> [--out-dir <dir>]`

### `scripts/plot_static.py`
- 用途：为 static benchmark 生成热力图。
- 依赖：`pandas`、`numpy`、`matplotlib`、`seaborn`。
- 用法（补全）：
  - `python3 scripts/plot_static.py <results_csv> [--workload-id <id>] [--weights <throughput,latency>] [--out-dir <dir>] [--cmap <name>]`
  - 示例：`python3 scripts/plot_static.py static_benchmark_results/experiment_xxx/results.csv --weights 0.7,0.3 --cmap magma`

### `scripts/reparse_logs.sh`
- 用途：按最新逻辑重算日志并覆盖旧 `results.csv`。
- 依赖：`python3`。
- 用法：
  - `./scripts/reparse_logs.sh <ExperimentDir> <Type>`
  - 示例：
    - `./scripts/reparse_logs.sh static_benchmark_results/experiment_20260205_150000 static`
    - `./scripts/reparse_logs.sh dynamic_benchmark_results/experiment_20260205_160000 dynamic`

## 2.4 server_agent 目录脚本

### `server_agent/mock_agent.py`
- 用途：模拟 RL Agent gRPC 服务，返回随机/固定/增量参数。
- 依赖：`grpcio`、`monitor_pb2.py`、`monitor_pb2_grpc.py`。
- 用法：
  - `python3 server_agent/mock_agent.py [--port 45678] [--mode random|fixed|incremental]`

### `server_agent/monitor_pb2.py`
- 用途：由 protobuf 生成的消息定义代码。
- 依赖：`protobuf`。
- 用法：
  - 不直接运行；由 `mock_agent.py` / `trainer.py` import。
  - 重新生成：`./regenerate_proto.sh`

### `server_agent/monitor_pb2_grpc.py`
- 用途：由 gRPC 插件生成的服务桩代码。
- 依赖：`grpcio`。
- 用法：
  - 不直接运行；由 `mock_agent.py` / `trainer.py` import。
  - 重新生成：`./regenerate_proto.sh`

### `server_agent/trainer.py`
- 用途：核心在线优化 agent（BAYESIAN/PPO/SA/STATIC）。
- 依赖：`grpcio`、`numpy`、`torch`、`sklearn`、`joblib`、生成的 pb2 文件。
- 用法：
  - 直接运行：`python3 server_agent/trainer.py`
  - 常用环境变量：
    - `OPT_ALGORITHM=BAYESIAN|PPO|SA|STATIC`
    - `STATIC_BATCH_SIZE=<int>`（STATIC 模式）
    - `STATIC_BATCH_TIMEOUT=<int>`（STATIC 模式）
    - `AGENT_PORT=<port>`（默认 `45678`）
- 补充：生产上通常由 `lan_deploy.sh` 远程拉起，而非手工直接执行。

---

## 3. 快速上手建议（推荐顺序）

1. 配置连接：
   - LAN：编辑 `lan_config.sh` 或 `lan_config_local.sh`
   - WAN：编辑 `wan_config.sh`
2. 准备 Python 环境（若使用 agent）：
   - 远端：`./setup_python_env.sh`
   - 本地：`./setup_local_python_env.sh`
3. 先跑一次基础部署：
   - `./lan_deploy.sh 500 100 -1 false STATIC`
4. 再运行实验脚本：
   - 例如 `./run_static_benchmark.sh true`

## 4. 常见问题与注意事项

- 大多数实验脚本默认依赖 `lan_deploy.sh`，因此先确保 LAN 配置可连通。
- 网络延迟脚本依赖远端 `tc`，并需要 sudo 权限。
- `run_batch_steady_asymmetric_timeout_benchmark.sh` 没有 shebang，建议 `bash` 执行。
- `monitor_pb2.py` 与 `monitor_pb2_grpc.py` 是生成文件，修改应通过 `regenerate_proto.sh`。
- 部分旧脚本（如 `deploy_and_test.sh`、YCSB 相关）参数写死较多，优先用于特定场景而非通用流程。

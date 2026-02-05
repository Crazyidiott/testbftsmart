#!/bin/bash
# ==============================================================================
# run_train_model.sh - 模型训练脚本
# ==============================================================================
# 
# 功能：
#   在动态变化的 workload 下训练 BAYESIAN 和 PPO 优化器模型。
#   训练完成后，模型将保存在 server_agent/ 目录下，供后续测试使用。
#
# 训练配置：
#   - 使用 dynamic_workload_train.config (10 循环 × 90s = 15 分钟)
#   - 三种 Workload 模式交替：
#       A: rate=500,  size=1024  (中等负载，中等包)
#       B: rate=1000, size=4096  (高负载，大包)
#       C: rate=200,  size=128   (低负载，小包)
#
# 输出模型：
#   - server_agent/bo_model.pkl   (Bayesian Optimization)
#   - server_agent/ppo_model.pth  (PPO)
#
# 使用方式：
#   ./run_train_model.sh [SkipBuild] [Algorithm]
#   例如：
#     ./run_train_model.sh              # 训练所有算法（需要编译）
#     ./run_train_model.sh true         # 跳过编译，训练所有算法
#     ./run_train_model.sh true BAYESIAN  # 只训练 Bayesian
#     ./run_train_model.sh true PPO       # 只训练 PPO
#
# 预计时间：
#   - 单个算法：~15 分钟
#   - 全部算法：~30 分钟
#
# ==============================================================================

set -e  # 出错时退出

# 加载 LAN 配置（获取节点地址等变量）
source ./lan_config.sh

# ============= 配置参数 =============

# 是否跳过编译
SKIP_BUILD="${1:-false}"

# 指定训练的算法（可选：BAYESIAN, PPO, ALL）
TRAIN_ALGORITHM="${2:-ALL}"

# 训练用 workload 配置
TRAIN_WORKLOAD_CONFIG="dynamic_workload_train.config"

# 结果目录
RESULTS_DIR="train_results"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
EXPERIMENT_DIR="${RESULTS_DIR}/train_${TIMESTAMP}"

# ============= 主逻辑 =============

echo "============================================================"
echo "          Model Training Script"
echo "============================================================"
echo "Timestamp: ${TIMESTAMP}"
echo "Skip Build: ${SKIP_BUILD}"
echo "Algorithm: ${TRAIN_ALGORITHM}"
echo "Workload Config: ${TRAIN_WORKLOAD_CONFIG}"
echo "Results will be saved to: ${EXPERIMENT_DIR}"
echo ""

# 创建结果目录
mkdir -p "${EXPERIMENT_DIR}"

# 显示训练计划
echo ">>> Training Plan:"
if [[ "$TRAIN_ALGORITHM" == "ALL" ]]; then
    echo "    1. BAYESIAN (~15 minutes)"
    echo "    2. PPO (~15 minutes)"
    echo "    Total estimated time: ~30 minutes"
elif [[ "$TRAIN_ALGORITHM" == "BAYESIAN" ]]; then
    echo "    1. BAYESIAN (~15 minutes)"
elif [[ "$TRAIN_ALGORITHM" == "PPO" ]]; then
    echo "    1. PPO (~15 minutes)"
else
    echo "ERROR: Unknown algorithm '${TRAIN_ALGORITHM}'"
    echo "Supported algorithms: BAYESIAN, PPO, ALL"
    exit 1
fi
echo ""

read -p "Press Enter to start training, or Ctrl+C to abort..."

# ============= 训练 Bayesian =============
if [[ "$TRAIN_ALGORITHM" == "ALL" ]] || [[ "$TRAIN_ALGORITHM" == "BAYESIAN" ]]; then
    echo ""
    echo "============================================================"
    echo ">>> Training BAYESIAN Optimizer"
    echo "============================================================"
    echo "    Workload: ${TRAIN_WORKLOAD_CONFIG}"
    echo "    Expected duration: ~15 minutes"
    echo "    Model output: server_agent/bo_model.pkl"
    echo ""
    
    START_TIME=$(date +%s)
    
    ./lan_deploy.sh 500 100 -1 "$SKIP_BUILD" BAYESIAN "$TRAIN_WORKLOAD_CONFIG" > "${EXPERIMENT_DIR}/train_bayesian.log" 2>&1 || {
        echo "WARNING: BAYESIAN training may have encountered issues. Check ${EXPERIMENT_DIR}/train_bayesian.log"
    }
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo "    BAYESIAN training completed in ${DURATION} seconds"
    
    # 保存训练日志副本
    cp results/server_0.log "${EXPERIMENT_DIR}/server_bayesian.log" 2>/dev/null || true
    cp results/agent_0.log "${EXPERIMENT_DIR}/agent_bayesian.log" 2>/dev/null || true
    
    # 检查模型是否生成
    if ssh -i "$KEY" "$USER@${NODES[0]}" "test -f ${REMOTE_PROJECT_PATH}/server_agent/bo_model.pkl" 2>/dev/null; then
        echo "    ✅ Model saved: bo_model.pkl"
    else
        echo "    ⚠️  Model file not found (may save on next run)"
    fi
    
    # 后续跳过编译
    SKIP_BUILD="true"
fi

# ============= 训练 PPO =============
if [[ "$TRAIN_ALGORITHM" == "ALL" ]] || [[ "$TRAIN_ALGORITHM" == "PPO" ]]; then
    echo ""
    echo "============================================================"
    echo ">>> Training PPO Optimizer"
    echo "============================================================"
    echo "    Workload: ${TRAIN_WORKLOAD_CONFIG}"
    echo "    Expected duration: ~15 minutes"
    echo "    Model output: server_agent/ppo_model.pth"
    echo ""
    
    START_TIME=$(date +%s)
    
    ./lan_deploy.sh 500 100 -1 "$SKIP_BUILD" PPO "$TRAIN_WORKLOAD_CONFIG" > "${EXPERIMENT_DIR}/train_ppo.log" 2>&1 || {
        echo "WARNING: PPO training may have encountered issues. Check ${EXPERIMENT_DIR}/train_ppo.log"
    }
    
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    echo "    PPO training completed in ${DURATION} seconds"
    
    # 保存训练日志副本
    cp results/server_0.log "${EXPERIMENT_DIR}/server_ppo.log" 2>/dev/null || true
    cp results/agent_0.log "${EXPERIMENT_DIR}/agent_ppo.log" 2>/dev/null || true
    
    # 检查模型是否生成
    if ssh -i "$KEY" "$USER@${NODES[0]}" "test -f ${REMOTE_PROJECT_PATH}/server_agent/ppo_model.pth" 2>/dev/null; then
        echo "    ✅ Model saved: ppo_model.pth"
    else
        echo "    ⚠️  Model file not found (may save on next run)"
    fi
fi

# ============= 训练完成 =============
echo ""
echo "============================================================"
echo "          Training Complete!"
echo "============================================================"
echo "Training logs saved to: ${EXPERIMENT_DIR}"
echo ""
echo "Model files (on remote nodes):"
echo "  - server_agent/bo_model.pkl  (Bayesian)"
echo "  - server_agent/ppo_model.pth (PPO)"
echo ""
echo "Next steps:"
echo "  1. Run benchmark tests:"
echo "     ./run_dynamic_benchmark.sh"
echo ""
echo "Done!"
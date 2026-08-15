#!/bin/bash
#HPC --partition=lab4
#HPC --cpu=60
#HPC --mem=100Gi
#HPC --time=30m

set -euo pipefail

echo "==================================================="
echo "🚀 开始 AMSS-NCKU O8 混合并行敏捷测试 (30x2 + owner-local 16线程)"
echo "==================================================="

RUN_ID=$(date +%Y%m%d_%H%M%S)
SAVE_DIR="test_archives/hybrid_${RUN_ID}"
mkdir -p "$SAVE_DIR"

echo "[1/6] 环境初始化与 O8 配置 (归档至: $SAVE_DIR)"

cp AMSS_NCKU_Input.py AMSS_NCKU_Input.py.bak
sed -i -E 's/^(GPU_Calculation[[:space:]]*=[[:space:]]*).*/\1"no"/' AMSS_NCKU_Input.py
sed -i -E 's/^(Final_Evolution_Time[[:space:]]*=[[:space:]]*).*/\12.0/' AMSS_NCKU_Input.py

# ==============================================================
# ⚠️ 全新混合并行配置区
# ==============================================================
export AMSS_ENABLE_OPENMP=ON
export AMSS_ENABLE_GPU=OFF
export AMSS_GPU_CALCULATION=no
export AMSS_BUILD_DIR="$PWD/build"
export AMSS_OUTPUT_ROOT="$PWD"
export AMSS_CACHE_DIR="$PWD/twopuncture_cache"
unset CUDACXX AMSS_CUDA_ARCHITECTURES

# O8 最佳配置：owner-local 表面积分 + 非对称 OpenMP
export AMSS_ABE_MPI_PROCESSES=30
export AMSS_ABE_OMP_THREADS=2
export AMSS_SURFACE_COLLECTIVE=owner_local
export AMSS_SURFACE_OMP_THREADS=16

# unbound 调度：线程可迁移，等待的 rank 让出 CPU
# HISTORY.md O8 实测 owner-local + 16 线程演化时间最快
export AMSS_MPIEXEC="mpiexec --allow-run-as-root --use-hwthread-cpus --map-by slot --bind-to none --mca mpi_yield_when_idle 1"
export OMP_PROC_BIND=false
unset OMP_PLACES
# ==============================================================

echo "[2/6] 正在编译混合并行版本代码..."
./compile.sh > "${SAVE_DIR}/compile.log" 2>&1 || { echo "❌ 编译失败"; mv AMSS_NCKU_Input.py.bak AMSS_NCKU_Input.py; exit 1; }

echo "[3/6] 正在运行演化程序 (t=2.0, 30 MPI x 2 OMP, owner-local 16线程)..."
LOG_FILE="${SAVE_DIR}/running.log"
./run.sh --twop-cache 2>&1 | tee "$LOG_FILE"

echo "[4/6] 适配 2.0 秒的黄金参考数据..."
FINAL_TIME=$(python3 -c 'import AMSS_NCKU_Input as cfg; print(cfg.Final_Evolution_Time)')
mkdir -p golden_cpu
awk -v cutoff="$FINAL_TIME" '
  /^[[:space:]]*#/ || NF == 0 { print; next }
  ($1 + 0) < cutoff { print }
' golden/bssn_BH.dat > golden_cpu/bssn_BH.dat

echo "[5/6] 执行物理精度校验..."
CHECK_LOG="${SAVE_DIR}/check.log"
./check.sh GW250118/AMSS_NCKU_output golden_cpu > "$CHECK_LOG" 2>&1

echo "[6/6] 整理数据并恢复环境..."
cp GW250118/AMSS_NCKU_output/binary_output/*.dat "$SAVE_DIR/" 2>/dev/null || true
mv AMSS_NCKU_Input.py.bak AMSS_NCKU_Input.py

echo ""
echo "==================================================="
echo "🎯 测试完成! O8 混合并行 (30x2 + owner-local 16线程) 核心简报:"
echo "==================================================="
echo "📁 详细归档至: $SAVE_DIR"
echo "---------------------------------------------------"

# 改变抓取策略：舍弃伪时间的单步耗时，抓取真实的墙钟总耗时
EVOLVE_TIME=$(grep -i "Total Evolve" "$LOG_FILE" || echo "未找到 Evolve 耗时，请查阅完整日志")
TOTAL_TIME=$(grep "This Program Cost" "$LOG_FILE" || echo "未找到端到端总耗时记录")

echo "⏱️  $EVOLVE_TIME"
echo "⏱️  $TOTAL_TIME"
echo "---------------------------------------------------"

TRAJ_RES=$(grep "Trajectory:" "$CHECK_LOG" || echo "未找到轨迹比对")
CONS_RES=$(grep "Constraints: PASS" "$CHECK_LOG" || echo "未找到约束比对")
FINAL_RES=$(grep "FINAL:" "$CHECK_LOG" || echo "FINAL: 状态未知")
echo "🧪 精度检查结果:"
echo "   - $TRAJ_RES"
echo "   - $CONS_RES"
echo "   - $FINAL_RES"
echo "==================================================="
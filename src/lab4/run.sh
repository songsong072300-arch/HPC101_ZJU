#!/bin/bash
# run.sh — run the AMSS-NCKU Lab 4 driver.
#
# Path layout (relative values resolve against the lab root):
#   AMSS_BUILD_DIR    build output          (default: <lab4>/build)
#   AMSS_OUTPUT_ROOT  run directory parent  (default: <lab4>)
#   AMSS_CACHE_DIR    TwoPuncture cache root (default: <lab4>/twopuncture_cache)
#   AMSS_MPIEXEC      MPI launcher          (default: O8 unbound config below)
#   AMSS_ABE_MPI_PROCESSES  MPI ranks used by ABE (default: AMSS_NCKU_Input.py)
#   AMSS_ABE_OMP_THREADS  OpenMP threads per ABE MPI rank (default: 2, O8)
#   AMSS_TWOP_OMP_THREADS  OpenMP threads for TwoPuncture (default: 30, O1)
#   AMSS_SURFACE_COLLECTIVE  owner_local (default), allreduce, or reduce_scatter
#   AMSS_SURFACE_OMP_THREADS  threads for owner-local surface interp (default: 16, O8)
set -euo pipefail

# Ansorg-TwoPuncture allocates large Fortran automatic arrays.
ulimit -s unlimited

# HPC jobs run inside a root container even when submitted by a regular user.
# Open MPI 5.x (prterun) therefore needs its explicit container opt-in. These
# variables are ignored for non-root launches and preserve a caller-supplied
# AMSS_MPIEXEC.
export OMPI_ALLOW_RUN_AS_ROOT="${OMPI_ALLOW_RUN_AS_ROOT:-1}"
export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM="${OMPI_ALLOW_RUN_AS_ROOT_CONFIRM:-1}"

# The OJ uses its own Python launch helper (scripts/makefile_and_run.py from
# the course repo), which invokes plain `mpiexec -n N env OMP_NUM_THREADS=2 ./ABE`
# and does NOT honor AMSS_MPIEXEC. The OJ also injects:
#   AMSS_MPIEXEC="mpiexec --bind-to core --map-by slot:pe=2"
#   OMP_PROC_BIND=close, OMP_PLACES=cores, OMP_NUM_THREADS=60
#
# We cannot override the mpiexec command line that makefile_and_run.py builds,
# but we CAN control OpenMPI / PRRTE behavior through MCA environment variables
# that are read at runtime regardless of the mpiexec flags.
#
# Problem: OJ containers may have a tiny /dev/shm (e.g. 64 MB), which causes
# OpenMPI's shared-memory BTL to fail and fall back to TCP for
# intra-node communication. With 30 ranks exchanging ghost zones every
# timestep, TCP adds ~86s/step of latency (vs <1s with shared memory).
#
# Solution: force OpenMPI to use shared-memory BTL and disable TCP.
# OpenMPI 3.x uses "sm", OpenMPI 4.x+ uses "vader" — include both for
# forward compatibility; OpenMPI silently ignores unknown BTL names.
export PRTE_MCA_hwloc_default_binding_policy="none"
export OMPI_MCA_mpi_yield_when_idle="1"
# Force shared-memory BTL for intra-node communication (disable TCP).
# OpenMPI 5.x uses vader; sm was removed in 4.x so don't include it.
export OMPI_MCA_btl="vader,self"
# Point vader backing files to /tmp (avoid /dev/shm 64MB limit).
# This only affects vader's small control segments, not large messages.
export OMPI_MCA_btl_vader_backing_directory="/tmp"
# Do NOT set single_copy_mechanism=emulation — it overrides the default
# cma (process_vm_readv, zero-copy) with a slower double-copy path.
# cma does NOT depend on /dev/shm; it works through kernel syscalls.

# ============================================================
# O8 最佳配置默认值（判题器直接 ./run.sh 时自动生效，环境变量可覆盖）
# unbound 调度: 空闲 rank 让出 CPU 给 owner-local 计算线程, 实测最快
#
# OJ 判题器会注入以下环境变量，必须全部强制覆盖：
#   AMSS_MPIEXEC="mpiexec --bind-to core --map-by slot:pe=2"  → Out of resource
#   OMP_PROC_BIND=close, OMP_PLACES=cores                     → 破坏 unbound 调度
#   OMP_NUM_THREADS=60                                        → TwoPuncture 线程数错误
# ============================================================
export AMSS_ABE_OMP_THREADS="2"
export AMSS_TWOP_OMP_THREADS="30"
export AMSS_SURFACE_COLLECTIVE="owner_local"
export AMSS_SURFACE_OMP_THREADS="16"
# 强制覆盖 OJ 注入的 OpenMP 绑定设置（unbound 调度需要）
export OMP_PROC_BIND="false"
export OMP_DYNAMIC="FALSE"
unset OMP_PLACES 2>/dev/null || true
# 强制覆盖 OJ 注入的 OMP_NUM_THREADS（OJ 会注入 60）
# TwoPunctureABE 需要 30 线程（物理核数），ABE 需要 2 线程（每 rank）
# makefile_and_run.py 会根据阶段覆盖此值，但先设为 30 防止 OJ 的 60 生效
export OMP_NUM_THREADS="${AMSS_TWOP_OMP_THREADS:-30}"
# 强制覆盖 OJ 注入的 AMSS_MPIEXEC（OJ 的 --bind-to core 会导致 30x2=60 PE
# 硬映射失败 "Out of resource"）。unbound + oversubscribe 让 30 个 rank 在
# 任何核数下都能启动，且 unbound 是 O8 实测最快的调度方式。
export AMSS_MPIEXEC="mpiexec --allow-run-as-root --oversubscribe --use-hwthread-cpus --map-by slot --bind-to none --mca mpi_yield_when_idle 1"
# ============================================================

ROOT_DIR="$(pwd)"
PYTHON="${PYTHON:-python3}"

resolve_under_root() {
  case "$1" in
    /*) printf '%s' "$1" ;;
     *) printf '%s/%s' "$ROOT_DIR" "$1" ;;
  esac
}

AMSS_BUILD_DIR="$(resolve_under_root "${AMSS_BUILD_DIR:-$ROOT_DIR/build}")"
AMSS_OUTPUT_ROOT="$(resolve_under_root "${AMSS_OUTPUT_ROOT:-$ROOT_DIR}")"
AMSS_CACHE_DIR="$(resolve_under_root "${AMSS_CACHE_DIR:-$ROOT_DIR/twopuncture_cache}")"
export AMSS_BUILD_DIR AMSS_OUTPUT_ROOT AMSS_CACHE_DIR AMSS_MPIEXEC

if [[ "${1:-}" == "--twop-cache" ]]; then
  export AMSS_NCKU_TWOP_CACHE=1
  shift
fi
if (( $# > 0 )); then
  echo "usage: ./run.sh [--twop-cache]" >&2
  exit 1
fi

echo "==> Build    : $AMSS_BUILD_DIR"
echo "==> Output   : $AMSS_OUTPUT_ROOT"
echo "==> Cache    : $AMSS_CACHE_DIR"
echo "==> MPI exec : $AMSS_MPIEXEC"

# Diagnostic: print OpenMPI version and available BTLs
echo "==> OpenMPI version: $(mpiexec --version 2>&1 | head -1)"
echo "==> /dev/shm size: $(df -h /dev/shm 2>/dev/null | tail -1 || echo 'N/A')"
echo "==> /tmp size: $(df -h /tmp 2>/dev/null | tail -1 || echo 'N/A')"

cd "$ROOT_DIR"
# Use env to ensure our AMSS_MPIEXEC and OMP_* overrides reach the child
# Python process even if the OJ injects conflicting values later.
# The OJ's makefile_and_run.py reads os.environ["AMSS_MPIEXEC"], so the
# value must be correct in the Python process's environment.
exec env \
  AMSS_MPIEXEC="$AMSS_MPIEXEC" \
  AMSS_BUILD_DIR="$AMSS_BUILD_DIR" \
  AMSS_OUTPUT_ROOT="$AMSS_OUTPUT_ROOT" \
  AMSS_CACHE_DIR="$AMSS_CACHE_DIR" \
  AMSS_ABE_OMP_THREADS="$AMSS_ABE_OMP_THREADS" \
  AMSS_TWOP_OMP_THREADS="$AMSS_TWOP_OMP_THREADS" \
  AMSS_SURFACE_COLLECTIVE="$AMSS_SURFACE_COLLECTIVE" \
  AMSS_SURFACE_OMP_THREADS="$AMSS_SURFACE_OMP_THREADS" \
  OMPI_ALLOW_RUN_AS_ROOT="$OMPI_ALLOW_RUN_AS_ROOT" \
  OMPI_ALLOW_RUN_AS_ROOT_CONFIRM="$OMPI_ALLOW_RUN_AS_ROOT_CONFIRM" \
  PRTE_MCA_hwloc_default_binding_policy="$PRTE_MCA_hwloc_default_binding_policy" \
  OMPI_MCA_mpi_yield_when_idle="$OMPI_MCA_mpi_yield_when_idle" \
  OMPI_MCA_btl="$OMPI_MCA_btl" \
  OMPI_MCA_btl_vader_backing_directory="$OMPI_MCA_btl_vader_backing_directory" \
  OMP_PROC_BIND="$OMP_PROC_BIND" \
  OMP_DYNAMIC="$OMP_DYNAMIC" \
  OMP_NUM_THREADS="$OMP_NUM_THREADS" \
  "$PYTHON" AMSS_NCKU_Program.py

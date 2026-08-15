#!/bin/bash
#HPC --partition=lab4
#HPC --cpu=60
#HPC --mem=100Gi
#HPC --time=30m

set -euo pipefail

# Submit this file from the lab4 project root:
#   hpc submit ./perf_analysis.sh
# AMSS_NCKU_Input.py should use the short CPU configuration:
# GPU_Calculation="no" and Final_Evolution_Time=2.0.
PROJECT_DIR="${PWD}"
cd "${PROJECT_DIR}"

if [[ ! -x ./compile.sh || ! -x ./run.sh ]]; then
  echo "ERROR: perf_analysis.sh must be located in the lab4 project root." >&2
  exit 2
fi

RUN_ID="$(date +%Y%m%d_%H%M%S)"
OUT_DIR="${PROJECT_DIR}/test_archives/perf_${RUN_ID}"
BUILD_DIR="${OUT_DIR}/build"
mkdir -p "${OUT_DIR}"

export AMSS_ENABLE_OPENMP=ON
export AMSS_ENABLE_GPU=OFF
export AMSS_GPU_CALCULATION=no
export AMSS_BUILD_DIR="${BUILD_DIR}"
export AMSS_CACHE_DIR="${PROJECT_DIR}/twopuncture_cache"
unset CUDACXX AMSS_CUDA_ARCHITECTURES

# ==============================================================
# O8 最佳配置：owner-local 表面积分 + 非对称 OpenMP
# ==============================================================
export AMSS_ABE_MPI_PROCESSES=30
export AMSS_ABE_OMP_THREADS=2
export AMSS_SURFACE_COLLECTIVE=owner_local
export AMSS_SURFACE_OMP_THREADS=16

# unbound 调度与 O8 对齐；注意 perf 采样会扰动 unbound 调度，
# 因此 perf 的墙钟时间不能与 quick_test.sh 直接比较，以热点占比为准。
export AMSS_MPIEXEC="mpiexec --allow-run-as-root --use-hwthread-cpus --map-by slot --bind-to none --mca mpi_yield_when_idle 1"
export OMP_PROC_BIND=false
unset OMP_PLACES
# ==============================================================

echo "Output directory: ${OUT_DIR}"
echo "Building..."
./compile.sh > "${OUT_DIR}/compile.log" 2>&1

echo "Running perf stat..."
export AMSS_OUTPUT_ROOT="${OUT_DIR}/stat_run"
mkdir -p "${AMSS_OUTPUT_ROOT}"
STAT_START="$(date +%s)"
set +e
perf stat -o "${OUT_DIR}/perf.stat" \
  -e cycles,instructions,branches,branch-misses,cache-references,cache-misses \
  ./run.sh --twop-cache > "${OUT_DIR}/application.log" 2>&1
STAT_RC=$?
set -e
STAT_END="$(date +%s)"
echo "$((STAT_END - STAT_START))" > "${OUT_DIR}/perf_stat_wall_seconds.txt"
echo "perf stat exit code: ${STAT_RC}"

echo "Running perf record..."
# Sample the complete driver process tree. perf inherits into mpiexec and its
# ABE ranks, while --twop-cache avoids profiling TwoPuncture initialization.
export AMSS_OUTPUT_ROOT="${OUT_DIR}/record_run"
mkdir -p "${AMSS_OUTPUT_ROOT}"
RECORD_START="$(date +%s)"
set +e
perf record -m 4 -F 99 -g -o "${OUT_DIR}/perf.data" \
  -- ./run.sh --twop-cache > "${OUT_DIR}/perf_record.log" 2>&1
RECORD_RC=$?
set -e
RECORD_END="$(date +%s)"
echo "$((RECORD_END - RECORD_START))" > "${OUT_DIR}/perf_record_wall_seconds.txt"
echo "perf record exit code: ${RECORD_RC}"

{
  echo "===== Timing ====="
  grep -E "Before Evolve|Timestep #|This Program Cost" \
    "${OUT_DIR}/application.log" || true
  echo "perf stat wall seconds: $(cat "${OUT_DIR}/perf_stat_wall_seconds.txt")"
  echo "perf record wall seconds: $(cat "${OUT_DIR}/perf_record_wall_seconds.txt")"
  echo "perf stat exit code: ${STAT_RC}"
  echo "perf record exit code: ${RECORD_RC}"
  echo "===== perf stat ====="
  cat "${OUT_DIR}/perf.stat" || true
  echo "===== Top symbols ====="
  if [[ -s "${OUT_DIR}/perf.data" ]]; then
    perf report --stdio -i "${OUT_DIR}/perf.data" --sort comm,dso,symbol \
      2>/dev/null | sed -n '1,100p' || true
  else
    echo "No perf.data was produced; inspect perf_record.log."
  fi
} | tee "${OUT_DIR}/summary.txt"

echo "Performance results saved in: ${OUT_DIR}"

if (( STAT_RC != 0 || RECORD_RC != 0 )); then
  echo "WARNING: one or more perf commands failed; see summary.txt and logs." >&2
  exit 1
fi

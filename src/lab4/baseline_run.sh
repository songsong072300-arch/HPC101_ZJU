#!/bin/bash
# baseline_run.sh — build with -O3 -g then run formal baseline on compute node.
set -euo pipefail

echo "=== PWD: $(pwd) ==="
echo "=== Compiler / MPI versions ==="
mpicxx --version | head -1
gfortran --version | head -1
mpiexec --version | head -2
echo "=== nproc / topology ==="
nproc
lscpu | grep -iE "model name|architecture|numa|cpu\(s\)|thread|core|socket" || true
numactl --hardware 2>/dev/null || true

echo "=== Build (-O3 -g) ==="
./compile.sh -DAMSS_OPT='-O3 -g'

echo "=== Run (formal: MPI=30, OMP=1, GPU=no, t=40.0, no cache) ==="
./run.sh

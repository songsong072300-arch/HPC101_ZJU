#!/bin/bash
# test_optimized.sh — quick correctness check with t=2.0 and --twop-cache
set -euo pipefail

echo "=== PWD: $(pwd) ==="
echo "=== Compiler / MPI versions ==="
mpicxx --version | head -1
gfortran --version | head -1
mpiexec --version | head -2

echo "=== Build (-O3 -g, with workspace optimization) ==="
./compile.sh -DAMSS_OPT='-O3 -g'

echo "=== Temporarily set Final_Evolution_Time = 2.0 for quick test ==="
cp AMSS_NCKU_Input.py AMSS_NCKU_Input.py.formal_backup
sed -i 's/Final_Evolution_Time.*/Final_Evolution_Time = 2.0  ## DEBUG/' AMSS_NCKU_Input.py

echo "=== Run with --twop-cache (t=2.0, 2 steps) ==="
./run.sh --twop-cache

echo "=== Restore formal input ==="
mv AMSS_NCKU_Input.py.formal_backup AMSS_NCKU_Input.py

echo "=== Correctness check ==="
./check.sh

echo "=== DONE ==="

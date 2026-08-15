#!/bin/bash
# test_e2e.sh — end-to-end test with all optimizations (t=2.0 for quick check)
set -euo pipefail

echo "=== PWD: $(pwd) ==="
echo "=== Build with OpenMP ==="
./compile.sh -DAMSS_ENABLE_OPENMP=ON -DAMSS_OPT='-O3 -g'

echo "=== Set t=2.0, OMP_threads=30 for TwoPuncture ==="
cp AMSS_NCKU_Input.py AMSS_NCKU_Input.py.formal_backup
sed -i 's/OMP_threads      = 1/OMP_threads      = 30/' AMSS_NCKU_Input.py
sed -i 's/Final_Evolution_Time.*/Final_Evolution_Time = 2.0  ## DEBUG/' AMSS_NCKU_Input.py

echo "=== Run with --twop-cache ==="
./run.sh --twop-cache

echo "=== Correctness check ==="
./check.sh || true

echo ""
echo "=== Restore formal input ==="
mv AMSS_NCKU_Input.py.formal_backup AMSS_NCKU_Input.py

echo "=== DONE ==="

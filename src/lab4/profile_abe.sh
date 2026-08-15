#!/bin/bash
# profile_abe.sh — profile ABE on compute node with perf
set -euo pipefail

echo "=== PWD: $(pwd) ==="

echo "=== Build (-O3 -g -fopenmp) ==="
./compile.sh -DAMSS_ENABLE_OPENMP=ON -DAMSS_OPT='-O3 -g'

echo "=== Set t=2.0 for quick profiling ==="
cp AMSS_NCKU_Input.py AMSS_NCKU_Input.py.formal_backup
sed -i 's/Final_Evolution_Time.*/Final_Evolution_Time = 2.0  ## DEBUG/' AMSS_NCKU_Input.py

echo "=== Create TwoPuncture cache (first run) ==="
./run.sh --twop-cache || true

echo ""
echo "=== Profile ABE with perf (second run, cache hit) ==="
cd GW250118/AMSS_NCKU_output

# perf stat on the ABE command
echo "--- perf stat ---"
perf stat -d -- \
  mpiexec --allow-run-as-root -n 30 env OMP_NUM_THREADS=1 /workspace/lab4/build/ABE < /dev/null \
  2>&1 | tail -30

# perf record (sample hotspots)
echo ""
echo "--- perf record ---"
timeout 200 perf record -F 99 -o /tmp/perf.abe.data -- \
  mpiexec --allow-run-as-root -n 30 env OMP_NUM_THREADS=1 /workspace/lab4/build/ABE < /dev/null \
  2>&1 || true

# Report hotspots
echo ""
echo "--- perf report (top functions) ---"
perf report -i /tmp/perf.abe.data --stdio --no-children -g none --percent-limit 1 2>&1 | head -50

cd ../..
echo "=== Restore formal input ==="
mv AMSS_NCKU_Input.py.formal_backup AMSS_NCKU_Input.py

echo "=== DONE ==="

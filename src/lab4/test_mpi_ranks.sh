#!/bin/bash
# test_mpi_ranks.sh — test different MPI rank counts for ABE
# TwoPunctureABE doesn't use MPI, so MPI_processes only affects ABE.
# OMP_threads=30 benefits TwoPunctureABE; ABE has no OpenMP regions yet.
set -euo pipefail

echo "=== PWD: $(pwd) ==="
echo "=== Build with OpenMP ==="
./compile.sh -DAMSS_ENABLE_OPENMP=ON -DAMSS_OPT='-O3 -g'

echo "=== Set OMP_threads=30 for TwoPunctureABE, t=2.0 for quick test ==="
cp AMSS_NCKU_Input.py AMSS_NCKU_Input.py.formal_backup
sed -i 's/OMP_threads      = 1/OMP_threads      = 30/' AMSS_NCKU_Input.py
sed -i 's/Final_Evolution_Time.*/Final_Evolution_Time = 2.0  ## DEBUG/' AMSS_NCKU_Input.py

echo "=== Create TwoPuncture cache (first run, OMP=30) ==="
./run.sh --twop-cache || true

echo ""
echo "=== Test different MPI rank counts ==="
for nrank in 30 20 15 10 9 6; do
    echo ""
    echo "===== MPI_processes=$nrank ====="
    sed -i "s/MPI_processes    = .*/MPI_processes    = $nrank/" AMSS_NCKU_Input.py
    
    cd GW250118/AMSS_NCKU_output
    start=$(date +%s)
    mpiexec --allow-run-as-root -n $nrank env OMP_NUM_THREADS=1 /workspace/lab4/build/ABE < /dev/null > /tmp/abe_mpi_${nrank}.log 2>&1
    end=$(date +%s)
    elapsed=$((end - start))
    
    # Extract ABE timing
    before=$(grep "Before Evolve" /tmp/abe_mpi_${nrank}.log | awk '{print $5}')
    total=$(grep "Total Evolve Time" /tmp/abe_mpi_${nrank}.log | awk '{print $5}')
    steps=$(grep "Timestep #" /tmp/abe_mpi_${nrank}.log | tail -1 | awk '{print $3}')
    
    echo "MPI=$nrank: ABE took ${elapsed}s (Before Evolve: ${before}s, Total Evolve: ${total}s, steps: $steps)"
    cd ../..
done

echo ""
echo "=== Restore formal input ==="
mv AMSS_NCKU_Input.py.formal_backup AMSS_NCKU_Input.py

echo "=== DONE ==="

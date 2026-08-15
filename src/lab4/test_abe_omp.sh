#!/bin/bash
# test_abe_omp.sh — test ABE with OpenMP in fderivs/fdderivs
set -euo pipefail

echo "=== PWD: $(pwd) ==="
echo "=== Build with OpenMP ==="
./compile.sh -DAMSS_ENABLE_OPENMP=ON -DAMSS_OPT='-O3 -g'

echo "=== Set t=2.0, OMP_threads=30 for TwoPuncture cache ==="
cp AMSS_NCKU_Input.py AMSS_NCKU_Input.py.formal_backup
sed -i 's/OMP_threads      = 1/OMP_threads      = 30/' AMSS_NCKU_Input.py
sed -i 's/Final_Evolution_Time.*/Final_Evolution_Time = 2.0  ## DEBUG/' AMSS_NCKU_Input.py

echo "=== Create TwoPuncture cache ==="
./run.sh --twop-cache || true

echo ""
echo "=== Test ABE with different MPI×OMP configurations ==="
for config in "30 1" "30 2" "15 2" "15 4" "10 3" "10 6"; do
    nrank=$(echo $config | awk '{print $1}')
    nthreads=$(echo $config | awk '{print $2}')
    echo ""
    echo "===== MPI=$nrank OMP=$nthreads ====="
    sed -i "s/MPI_processes    = .*/MPI_processes    = $nrank/" AMSS_NCKU_Input.py
    
    cd GW250118/AMSS_NCKU_output
    start=$(date +%s)
    mpiexec --allow-run-as-root -n $nrank env OMP_NUM_THREADS=$nthreads OMP_PROC_BIND=close OMP_PLACES=cores /workspace/lab4/build/ABE < /dev/null > /tmp/abe_${nrank}_${nthreads}.log 2>&1
    end=$(date +%s)
    elapsed=$((end - start))
    
    total=$(grep "Total Evolve Time" /tmp/abe_${nrank}_${nthreads}.log | awk '{print $5}')
    before=$(grep "Before Evolve" /tmp/abe_${nrank}_${nthreads}.log | awk '{print $5}')
    echo "MPI=$nrank OMP=$nthreads: ABE took ${elapsed}s (Before: ${before}s, Evolve: ${total}s)"
    cd ../..
done

echo ""
echo "=== Restore formal input ==="
mv AMSS_NCKU_Input.py.formal_backup AMSS_NCKU_Input.py

echo "=== DONE ==="

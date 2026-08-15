#!/bin/bash
# test_omp.sh — test TwoPunctureABE with OpenMP + trig precomputation, different thread counts
set -euo pipefail

echo "=== PWD: $(pwd) ==="
echo "=== Build with OpenMP ==="
./compile.sh -DAMSS_ENABLE_OPENMP=ON -DAMSS_OPT='-O3 -g'

echo "=== Testing different OMP thread counts ==="
for nthreads in 1 2 4 8 16 30; do
    echo ""
    echo "===== OMP_NUM_THREADS=$nthreads ====="
    export OMP_NUM_THREADS=$nthreads
    cd GW250118/AMSS_NCKU_output
    start=$(date +%s)
    /workspace/lab4/build/TwoPunctureABE < /dev/null > /tmp/twop_omp_${nthreads}.log 2>&1
    end=$(date +%s)
    elapsed=$((end - start))
    echo "OMP=$nthreads: TwoPunctureABE took ${elapsed}s"
    # Check results match
    mp=$(grep "bare mass: mp=" /tmp/twop_omp_${nthreads}.log | tail -1 | awk '{print $4}')
    mm=$(grep "bare mass: mp=" /tmp/twop_omp_${nthreads}.log | tail -1 | awk '{print $5}')
    adm=$(grep "total ADM mass" /tmp/twop_omp_${nthreads}.log | awk '{print $6}')
    newton_it=$(grep "Newton: it=" /tmp/twop_omp_${nthreads}.log | tail -1 | awk '{print $2}')
    echo "  mp=$mp mm=$mm ADM=$adm Newton_last=$newton_it"
    cd ../..
done

echo ""
echo "=== Summary ==="
echo "Baseline (no opt, OMP=1) was ~260s on compute node"

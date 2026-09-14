#!/usr/bin/env bash
# Batch 1: placement penalty with model pages 100% on node1 (as deployed).
# CPU restriction via the unit's cpuset (AllowedCPUs), not llama's -C mask:
# -C/--cpu-strict pinned the OpenMP pool's idle threads onto one core.
cd "$(dirname "$0")"
run(){ ./bench.sh "$@" || true; }
UNITPROPS="-p AllowedCPUs=14-25"       run b1-n1phys-t12  -p 1024 -n 32 -t 12 -fa 1
UNITPROPS="-p AllowedCPUs=3-13"        run b1-n0phys-t11  -p 1024 -n 32 -t 11 -fa 1
UNITPROPS="-p AllowedCPUs=3-25"        run b1-allphys-t23 -p 1024 -n 32 -t 23 -fa 1
UNITPROPS="-p AllowedCPUs=14-25,42-53" run b1-n1all-t24   -p 1024 -n 32 -t 24 -fa 1
run b1-fence-t46 -p 1024 -n 32 -t 46 -fa 1
run b1-dist-t23  -p 1024 -n 32 -t 23 --numa distribute -fa 1
run b1-dist-t46  -p 1024 -n 32 -t 46 --numa distribute -fa 1
echo BATCH1 DONE

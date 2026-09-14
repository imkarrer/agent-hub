#!/usr/bin/env bash
# Batch 4: combine the batch-3 winners and check them at realistic prompt sizes.
set -u
cd "$(dirname "$0")"
run(){ ./bench.sh "$@" || true; }
P="-p AllowedCPUs=3-25 -p NUMAPolicy=interleave -p NUMAMask=0-1"
IK=1 UNITPROPS="$P" run b4-rtr-fa0        -p 1024 -n 32 -t 23 -fa 0 -rtr 1
IK=1 UNITPROPS="$P" run b4-rtr-fa0-t22    -p 1024 -n 32 -t 22 -fa 0 -rtr 1
IK=1 UNITPROPS="$P" run b4-fa0-t22        -p 1024 -n 32 -t 22 -fa 0
IK=1 UNITPROPS="$P" run b4-fa0-pp4096     -p 4096 -n 0  -t 23 -fa 0
IK=1 UNITPROPS="$P" run b4-fa0-pg4096     -p 0 -n 0 -pg 4096,64 -t 23 -fa 0
IK=1 UNITPROPS="$P" run b4-rtr-fa0-pp4096 -p 4096 -n 0  -t 23 -fa 0 -rtr 1
IK=1 UNITPROPS="$P" run b4-fa1-pp8192     -p 8192 -n 0  -t 23 -fa 1
IK=1 UNITPROPS="$P" run b4-fa0-pp8192     -p 8192 -n 0  -t 23 -fa 0
echo BATCH4 DONE

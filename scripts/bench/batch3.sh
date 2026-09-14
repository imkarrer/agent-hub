#!/usr/bin/env bash
# Batch 3: deployment-candidate shape with ik_llama.cpp -- physical-core cpuset
# (3-25), unit-level interleave policy -- and the remaining A/Bs on top of it.
# Live server stays up (its pages are now interleaved too).
set -u
cd "$(dirname "$0")"
run(){ ./bench.sh "$@" || true; }
P="-p AllowedCPUs=3-25 -p NUMAPolicy=interleave -p NUMAMask=0-1"
IK=1 UNITPROPS="$P" run b3-fa1        -p 1024 -n 32 -t 23 -fa 1
IK=1 UNITPROPS="$P" run b3-fa0        -p 1024 -n 32 -t 23 -fa 0
IK=1 UNITPROPS="$P" run b3-rtr        -p 1024 -n 32 -t 23 -fa 1 -rtr 1
IK=1 UNITPROPS="$P" run b3-rtr-muge   -p 1024 -n 32 -t 23 -fa 1 -rtr 1 -muge 1
IK=1 UNITPROPS="$P" run b3-rtr-thp    -p 1024 -n 32 -t 23 -fa 1 -rtr 1 -thp 1
IK=1 UNITPROPS="$P" run b3-fa1-t22    -p 1024 -n 32 -t 22 -fa 1
IK=1 UNITPROPS="$P" run b3-fa1-pp4096 -p 4096 -n 0  -t 23 -fa 1
IK=1 UNITPROPS="$P" run b3-fa1-pg4096 -p 0 -n 0 -pg 4096,64 -t 23 -fa 1
echo BATCH3 DONE

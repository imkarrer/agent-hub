#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # the sweep below the guard is the record, unreachable on purpose
# Batch 4: combine the batch-3 winners and check them at realistic prompt sizes.
#
# A DATED RECORD, and it refuses to run as-is. The 14 Sep 2026 follow-up to
# batch3.sh behind the 4k and 8k numbers in docs/prefill-tuning.md's
# "remaining flags" table, exactly as run, against the bench.sh of 763d76a
# (`git show 763d76a:scripts/bench/bench.sh`: IK=1 was its ik 3bb386e), on
# the same shape -- AllowedCPUs=3-25, 23 threads, interleave, inside
# background.slice. Not translated to the live layout (system.slice, cpus
# 0-27, 28 threads): its -t 22 lines only mean "one core short of the
# fence's 23", and the document cites this file as those numbers' exact
# source. The prompt-size question on the live layout is bench.sh with no
# UNITPROPS and no -t, -p 4096 or -p 8192, under a new name prefix.
echo "batch4.sh: refusing: a dated record of the 14 Sep 2026 fenced layout (background.slice, cores 3-25), not the live one; see its header" >&2
exit 1
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

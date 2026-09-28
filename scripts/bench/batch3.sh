#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # the sweep below the guard is the record, unreachable on purpose
# Batch 3: deployment-candidate shape with ik_llama.cpp -- physical-core cpuset
# (3-25), unit-level interleave policy -- and the remaining A/Bs on top of it.
# Live server stays up (its pages are now interleaved too).
#
# A DATED RECORD, and it refuses to run as-is. The 14 Sep 2026 A/Bs behind
# docs/prefill-tuning.md's "remaining flags" table, exactly as run, against
# the bench.sh of 763d76a (`git show 763d76a:scripts/bench/bench.sh`: IK=1
# was its ik 3bb386e), on the candidate shape of the day -- AllowedCPUs=3-25,
# 23 threads, interleave, inside background.slice. Not translated to the
# live layout (system.slice, cpus 0-27, 28 threads): its verdicts shipped
# (-rtr in, flash-attn on, 23 threads over 22), and the document cites this
# file as their exact source. Re-asking one on the live layout is bench.sh
# with no UNITPROPS and no -t, under a new name prefix, so live lines never
# sit beside these b3- ones in results/all.jsonl as if comparable.
echo "batch3.sh: refusing: a dated record of the 14 Sep 2026 fenced layout (background.slice, cores 3-25), not the live one; see its header" >&2
exit 1
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

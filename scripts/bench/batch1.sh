#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # the sweep below the guard is the record, unreachable on purpose
# Batch 1: placement penalty with model pages 100% on node1 (as deployed).
# CPU restriction via the unit's cpuset (AllowedCPUs), not llama's -C mask:
# -C/--cpu-strict pinned the OpenMP pool's idle threads onto one core.
#
# A DATED RECORD, and it refuses to run as-is. The 14 Sep 2026 sweep behind
# docs/prefill-tuning.md's Finding 1 table, exactly as run, against the
# bench.sh of 763d76a (`git show 763d76a:scripts/bench/bench.sh`): inside
# background.slice's fence (3-25,31-53), every line nixpkgs' llama-cpp b9190
# (no IK=1 -- that bench.sh's MAIN_BIN, the scalar build of the document's
# addendum), the model's pages 100 % on node 1 where the unit of the day had
# mlocked them. Every cpuset and -t below is that fence's. Not translated to
# the live layout (system.slice, cpus 0-27, 28 threads; bench.sh's default):
# the condition it measured is gone -- the unit's -rtr puts coder's weights
# in anonymous memory under NUMAPolicy=interleave -- and so is its binary,
# so new numbers under this name would answer another question, and the
# document cites this file as its table's exact source.
echo "batch1.sh: refusing: a dated record of the 14 Sep 2026 fenced layout (background.slice, cores 3-25), not the live one; see its header" >&2
exit 1
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

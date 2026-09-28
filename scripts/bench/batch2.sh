#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2329 # the sweep below the guard is the record, unreachable on purpose
# IT STOPS agent-hub-llm, DROPS THE BOX'S PAGE CACHE, turns
# kernel.numa_balancing off and back on, and starts the unit again at the
# end: the model server is down for the whole sweep, and every model loads
# cold after it. Whether to do that is an operator's decision, each run --
# never this script's default.
#
# Batch 2: NUMA placement + ik_llama.cpp. Stop the server, drop the (node1-only)
# page cache, re-populate it MPOL_INTERLEAVE across both nodes via `cat` under
# a systemd NUMAPolicy, verify placement, then bench mainline and ik on it.
# Ends by restarting agent-hub-llm (it will mlock the interleaved pages).
#
# A DATED RECORD, and it refuses to run as-is. The 14 Sep 2026 sweep behind
# docs/prefill-tuning.md's Finding 3 table, exactly as run, against the
# bench.sh of 763d76a (`git show 763d76a:scripts/bench/bench.sh`: IK=1 was
# its ik 3bb386e, no IK nixpkgs' llama-cpp b9190), inside background.slice's
# fence (3-25,31-53); every cpuset and -t below is that fence's. Not
# translated to the live layout (system.slice, cpus 0-27, 28 threads;
# bench.sh's default): its page-in runs in background.slice, which has no
# unit file now (systemd would synthesise one, unfenced); its question --
# where the mmap'd pages land -- was settled by -rtr, which puts coder's
# weights in anonymous memory under the unit's own NUMAPolicy; and its
# mainline half is a build deployed nowhere. The document cites this file
# as its table's exact source.
echo "batch2.sh: refusing: a dated record of the 14 Sep 2026 fenced layout (background.slice, cores 3-25), not the live one; see its header" >&2
exit 1
set -u
cd "$(dirname "$0")"
run(){ ./bench.sh "$@" || true; }
M=/srv/agent-hub/models
IL="-p NUMAPolicy=interleave -p NUMAMask=0-1"   # systemd-run also accepts 'NUMAMask=0 1'
SW=/run/current-system/sw/bin   # systemd-run units get a minimal PATH: no cat
if [ "${SKIP_PAGEIN:-0}" != 1 ]; then
echo "== $(date -Is) stopping server, dropping caches"
ssh ac-box "systemctl stop agent-hub-llm; sync; echo 3 > /proc/sys/vm/drop_caches; grep -E 'FilePages' /sys/devices/system/node/node*/meminfo"
echo "== $(date -Is) interleaved page-in"
ssh ac-box "systemd-run --quiet --wait --pipe --collect --slice=background.slice $IL \
  $SW/bash -c 'for f in $M/Qwen3-Coder-Next-Q8_0-0000?-of-00004.gguf; do $SW/cat \$f > /dev/null; done'; grep -E 'FilePages' /sys/devices/system/node/node*/meminfo"
fi
echo "== $(date -Is) mainline on interleaved pages"
UNITPROPS="-p AllowedCPUs=3-25"        run b2il-allphys-t23 -p 1024 -n 32 -t 23 -fa 1
run b2il-fence-t46 -p 1024 -n 32 -t 46 -fa 1
UNITPROPS="-p AllowedCPUs=14-25,42-53" run b2il-n1all-t24   -p 1024 -n 32 -t 24 -fa 1
echo "== $(date -Is) ik on interleaved pages"
IK=1 run b2ik-il-t23        -p 1024 -n 32 -t 23 -fa 1
IK=1 UNITPROPS="-p AllowedCPUs=3-25" run b2ik-il-allphys-t23 -p 1024 -n 32 -t 23 -fa 1
IK=1 UNITPROPS="-p AllowedCPUs=14-25" run b2ik-il-n1phys-t12 -p 1024 -n 32 -t 12 -fa 1
IK=1 run b2ik-il-t23-fa0    -p 1024 -n 32 -t 23 -fa 0
IK=1 run b2ik-il-t23-ub1024 -p 1024 -n 0  -t 23 -fa 1 -ub 1024 -b 2048
IK=1 PRE="sysctl -w kernel.numa_balancing=0" run b2ik-il-t23-nobal -p 1024 -n 32 -t 23 -fa 1
ssh ac-box "sysctl -w kernel.numa_balancing=1"
echo "== $(date -Is) ik run-time repack (no mmap, anon memory interleaved)"
IK=1 UNITPROPS="$IL" run b2ik-il-t23-rtr      -p 1024 -n 32 -t 23 -fa 1 -rtr 1
IK=1 UNITPROPS="$IL" run b2ik-il-t23-rtr-muge -p 1024 -n 32 -t 23 -fa 1 -rtr 1 -muge
echo "== $(date -Is) restarting server"
ssh ac-box "systemctl start agent-hub-llm"
echo BATCH2 DONE

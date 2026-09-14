#!/usr/bin/env bash
# bench.sh <name> [llama-bench args...]
#
# One llama-bench run on ac-box, as a transient systemd unit inside
# background.slice -- the same cgroup fence agent-hub-llm lives in, so the
# race servers on cores 0-2 never see it -- with one summary line per test
# appended to results/all.jsonl. This is the harness behind
# docs/prefill-tuning.md; batch*.sh next to it are the exact sweeps that
# produced that document's tables.
#
# The live server can stay up: both processes mmap the same GGUF, so the
# page cache is shared and a run costs no reload. That also means a run
# inherits whatever NUMA placement the pages already have -- see batch2.sh
# for how to re-place them.
#
# Env:
#   IK=1        bench the ik_llama.cpp build (IK_BIN) instead of nixpkgs'
#               llama-cpp (MAIN_BIN); the two have different output flags
#   REPS        repetitions per test (default 2; use 3+ for a decision)
#   PRE         shell snippet run on the box first (e.g. a sysctl); its
#               output goes to stderr so it cannot pollute the JSON
#   UNITPROPS   extra `systemd-run -p` args: the cpuset and NUMA policy
#               (e.g. "-p AllowedCPUs=3-25 -p NUMAPolicy=interleave
#               -p NUMAMask=0-1") -- prefer these over llama-bench's own
#               -C/--cpu-strict, which pinned the idle OpenMP pool onto a
#               single core and skewed everything
# Requires: ssh ac-box (root), jq (nix develop provides it).
set -euo pipefail
name=$1; shift
MODEL=${MODEL:-/srv/agent-hub/models/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf}
MAIN_BIN=${MAIN_BIN:-/nix/store/mp11q8akazws98r70cv5yb1cshz9i0ac-llama-cpp-9190/bin/llama-bench}
IK_BIN=${IK_BIN:-/nix/store/qn6qpywlzv0mi1d80kgk4s3cm8acnr76-llama-cpp-3bb386e/bin/llama-bench}
REPS=${REPS:-2}
PRE=${PRE:-true}
UNITPROPS=${UNITPROPS:-}
if [ "${IK:-0}" = 1 ]; then
  BIN=$IK_BIN; OUT="-o json -w 0"; build=ik-3bb386e
else
  BIN=$MAIN_BIN; OUT="-o jsonl --no-warmup --progress"; build=main-b9190
fi
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/results"
args=$(printf '%q ' "$@")
start=$(date -Is)
ssh ac-box "{ $PRE; } >&2; systemd-run --quiet --wait --pipe --collect --slice=background.slice --unit=prefill-bench-$name-\$RANDOM $UNITPROPS \
  $BIN -m $MODEL $OUT -r $REPS $args" \
  > "$here/results/$name.out" 2> "$here/results/$name.err" || { echo "FAILED $name (see results/$name.err)"; tail -5 "$here/results/$name.err"; exit 1; }
jq -c --arg name "$name" --arg start "$start" --arg args "$*" --arg build "$build" \
  'if type=="array" then .[] else . end | {name:$name, build:$build, start:$start, args:$args, test:(if .n_prompt>0 then "pp\(.n_prompt)" else "tg\(.n_gen)" end), t:.n_threads, b:.n_batch, ub:.n_ubatch, fa:.flash_attn, mmap:.use_mmap, avg_ts:(.avg_ts*100|round/100), std:(.stddev_ts*100|round/100)}' \
  "$here/results/$name.out" | tee -a "$here/results/all.jsonl"

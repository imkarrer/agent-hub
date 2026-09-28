#!/usr/bin/env bash
# bench.sh <name> [llama-bench args...]
#
# One llama-bench run on llm-box, as a transient systemd unit placed where
# agent-hub-llm runs, with one summary line per test appended to
# results/all.jsonl. The placement is read off the unit on every run, never
# written here: Slice, AllowedCPUs, NUMAPolicy and NUMAMask from `systemctl
# show` -- the loaded unit, which is the running placement unless a switch
# changed it since the unit last started; the llama-bench and the thread
# count from its main process's environment -- FLOX_ENV, the flox
# environment llama-swap.yaml takes llama-server from, and
# AGENT_HUB_THREADS -- because the unit has restartIfChanged = false, so
# its file can be ahead of what is serving.
# The version before this one wrote background.slice and cores 3-25 in, and
# once homelab-ygc.13 removed that slice a run would have landed in one
# systemd synthesises on the spot, no cpuset and default weight, measuring
# something that was not the server without a word.
#
# Live on 28 Sep 2026 (the fence came down 26 Sep; agent-hub is the box's
# only tenant): system.slice, AllowedCPUs=0-27 (every physical core, none of
# the SMT siblings), NUMAPolicy=interleave over nodes 0-1, 28 threads, ik
# 3bb386e. docs/prefill-tuning.md's tables came from this script as of
# 763d76a -- 23 threads on cores 3-25 inside the fence, 14 Sep 2026 -- so
# numbers from here are not comparable with them; batch*.sh are that
# document's exact sweeps, kept as its dated record, and refuse to run.
#
# Refuses, rather than measure something else, when the placement cannot be
# read: ssh or the unit unreadable, no deployed llama-bench (the unit not
# running, or its FLOX_ENV without one) and neither IK_BIN nor MAIN_BIN set,
# or no -t in the args and no AGENT_HUB_THREADS to default it from.
#
# The live server can stay up, but a run of coder's GGUF (the default) shares
# no pages with it: -rtr (llama-swap.yaml's llama_extra) makes the server's
# copy anonymous memory. Without -rtr a run maps the GGUF into page cache
# (pages already cached keep the NUMA placement they have); with it, the run
# allocates its own copy, ~85 GB for coder -- `free -g` on the box first when
# both 80Bs are resident.
#
# Env:
#   MODEL       the GGUF (default: coder's); a model the table gives its own
#               --threads (utility: 8) needs that -t passed
#   REPS        repetitions per test (default 2; use 3+ for a decision)
#   PRE         shell snippet run on the box first (e.g. a sysctl); its
#               output goes to stderr so it cannot pollute the JSON
#   UNITPROPS   extra `systemd-run -p` args for a deliberate experiment;
#               naming AllowedCPUs=, NUMAPolicy= or NUMAMask= replaces the
#               unit's value (e.g. "-p AllowedCPUs=0-55", the SMT siblings
#               too), and the result line records the placement either way.
#               Prefer these over llama-bench's own -C/--cpu-strict, which
#               pinned the idle OpenMP pool onto a single core and skewed
#               everything
#   IK_BIN      an ik_llama.cpp llama-bench other than the deployed one
#   MAIN_BIN    a mainline llama.cpp llama-bench instead (its output flags
#               differ); nothing deployed is mainline
# Requires: ssh llm-box (root), jq (nix develop provides it).
set -euo pipefail
refuse() { echo "bench.sh: refusing: $*" >&2; exit 1; }
name=${1:?usage: bench.sh <name> [llama-bench args...]}; shift
MODEL=${MODEL:-/srv/agent-hub/models/Qwen3-Coder-Next-Q8_0-00001-of-00004.gguf}
REPS=${REPS:-2}
PRE=${PRE:-true}
UNITPROPS=${UNITPROPS:-}

# KEY=value lines about the unit, from the box; quoted, so nothing expands here.
facts=$(ssh llm-box bash -s <<'EOF'
u=agent-hub-llm.service
systemctl show "$u" -p LoadState -p ActiveState -p MainPID -p Slice -p AllowedCPUs -p NUMAPolicy -p NUMAMask
pid=$(systemctl show "$u" -p MainPID --value)
if [ "${pid:-0}" != 0 ]; then
  tr '\0' '\n' <"/proc/$pid/environ" | grep -E '^(FLOX_ENV|AGENT_HUB_THREADS)='
  env=$(tr '\0' '\n' <"/proc/$pid/environ" | sed -n 's/^FLOX_ENV=//p')
  [ -z "$env" ] || [ ! -x "$env/bin/llama-bench" ] || echo "DeployedBin=$(readlink -f "$env/bin/llama-bench")"
fi
EOF
) || refuse "could not read agent-hub-llm on llm-box over ssh"
fact() { sed -n "s/^$1=//p" <<<"$facts"; }
[ "$(fact LoadState)" = loaded ] || refuse "agent-hub-llm is not a unit on llm-box (LoadState=$(fact LoadState))"
slice=$(fact Slice)
[ -n "$slice" ] || refuse "agent-hub-llm names no slice"

if [ -n "${MAIN_BIN:-}" ]; then
  BIN=$MAIN_BIN; flavor=main; OUT="-o jsonl --no-warmup --progress"
else
  BIN=${IK_BIN:-$(fact DeployedBin)}; flavor=ik; OUT="-o json -w 0"
  [ -n "$BIN" ] || refuse "no deployed llama-bench: agent-hub-llm is $(fact ActiveState) and its FLOX_ENV ('$(fact FLOX_ENV)') has no bin/llama-bench. Starting the model server is the operator's call; or set IK_BIN or MAIN_BIN"
fi
pkg=${BIN#/nix/store/}; pkg=${pkg%%/*}; ver=${pkg##*-}   # <hash>-llama-cpp-3bb386e -> 3bb386e
build=$flavor-${ver:-local}

# The server's thread count, unless the args ask for another.
case " $* " in
  *" -t "* | *" --threads "*) ;;
  *)
    t=$(fact AGENT_HUB_THREADS)
    [ -n "$t" ] || refuse "no -t in the args and no AGENT_HUB_THREADS on a running agent-hub-llm to default it from"
    set -- "$@" -t "$t"
    ;;
esac

# The unit's placement, property by property; a property UNITPROPS names is the caller's.
placement="--slice=$slice"
for kv in "AllowedCPUs=$(fact AllowedCPUs)" "NUMAPolicy=$(fact NUMAPolicy)" "NUMAMask=$(fact NUMAMask)"; do
  case $UNITPROPS in *"${kv%%=*}="*) continue ;; esac
  case ${kv#*=} in '' | n/a | default) ;; *) placement+=" -p $kv" ;; esac
done
placement+=${UNITPROPS:+ $UNITPROPS}

here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$here/results"
args=$(printf '%q ' "$@")
echo "bench.sh: $name: $placement $BIN $*" >&2
start=$(date -Is)
ssh llm-box "{ $PRE; } >&2; systemd-run --quiet --wait --pipe --collect --unit=prefill-bench-$name-\$RANDOM $placement \
  $BIN -m $MODEL $OUT -r $REPS $args" \
  > "$here/results/$name.out" 2> "$here/results/$name.err" || { echo "FAILED $name (see results/$name.err)"; tail -5 "$here/results/$name.err"; exit 1; }
jq -c --arg name "$name" --arg start "$start" --arg args "$*" --arg build "$build" --arg placement "$placement" --arg bin "$BIN" \
  'if type=="array" then .[] else . end | {name:$name, build:$build, start:$start, args:$args, test:(if .n_prompt>0 then "pp\(.n_prompt)" else "tg\(.n_gen)" end), t:.n_threads, b:.n_batch, ub:.n_ubatch, fa:.flash_attn, mmap:.use_mmap, avg_ts:(.avg_ts*100|round/100), std:(.stddev_ts*100|round/100), placement:$placement, bin:$bin}' \
  "$here/results/$name.out" | tee -a "$here/results/all.jsonl"

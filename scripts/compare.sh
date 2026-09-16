#!/usr/bin/env bash
# compare.sh [prompt-file] -- the same chat request to each model server,
# one line per target: prompt tokens, prefill tok/s, generation tok/s, wall
# time. Reads the `timings` object llama-server puts in a non-streaming
# response (llama-swap passes it through untouched), so it costs each box
# exactly one request and needs nothing installed on it -- unlike
# bench/bench.sh, which runs llama-bench on ac-box inside its cgroup fence.
#
# Targets are "<base-url> <model>" pairs, one per line, in TARGETS (default:
# this box and ac-box, both `coder`, the two ends of the README's split).
# The prompt defaults to ~1.5k tokens of this repo's module, which is a
# realistic size for one agent turn's fresh context; pass a file for another.
# A server's prompt cache makes a repeated identical prompt look free
# (prompt_n drops to 1), so the prompt carries a nonce and is never cached.
#
# A loaded model is swapped in on first use (20-60 s on ac-box, similar
# here) and that time lands in "wall", not in the tok/s columns.
# Requires: curl, jq (nix develop provides them).
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
prompt_file=${1:-}
TARGETS=${TARGETS:-$'http://127.0.0.1:8100 coder\nhttp://192.168.1.50:8100 coder'}
MAX_TOKENS=${MAX_TOKENS:-128}

if [ -n "$prompt_file" ]; then
  body=$(cat "$prompt_file")
else
  body=$(head -c 6000 "$here/../modules/agent-hub.nix")
fi
nonce=$(date +%s%N)

printf '%-28s %-12s %8s %10s %10s %8s\n' target model prompt_n prefill_ts gen_ts wall_s
while IFS=' ' read -r base model; do
  [ -z "$base" ] && continue
  req=$(jq -n --arg m "$model" --arg n "$nonce" --arg b "$body" --argjson max "$MAX_TOKENS" \
    '{model:$m, max_tokens:$max, temperature:0,
      messages:[{role:"user", content:("Request \($n). Summarize this file in two sentences:\n\n" + $b)}]}')
  t0=$(date +%s.%N)
  if ! resp=$(curl -sS --fail-with-body -m 1800 "$base/v1/chat/completions" \
        -H 'content-type: application/json' -d "$req" 2>&1); then
    printf '%-28s %-12s %s\n' "$base" "$model" "FAILED: ${resp:0:80}"
    continue
  fi
  t1=$(date +%s.%N)
  jq -r --arg base "$base" --arg model "$model" --arg wall "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print b - a }')" \
    '"\($base) \($model) \(.timings.prompt_n) \(.timings.prompt_per_second) \(.timings.predicted_per_second) \($wall)"' <<<"$resp" \
  | awk '{printf "%-28s %-12s %8d %10.1f %10.2f %8.1f\n", $1, $2, $3, $4, $5, $6}'
done <<<"$TARGETS"

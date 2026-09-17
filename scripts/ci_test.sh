#!/usr/bin/env bash
# The tenant's own gate: the environment's binaries resolve, and llama-swap
# loads llama-swap.yaml -- every ${env.*} macro set by the manifest's hook,
# every model entry parsed -- and lists the six models the box serves. It
# starts no backend (that needs the GGUFs, ~210 GB), so this proves the
# table and the wiring, not inference; scripts/smoke-test.sh is inference.
#
# Runs inside `flox activate` (CI's flox plugin, or hub-gates.sh locally),
# which is what sets FLOX_ENV and the AGENT_HUB_* defaults. Ports are
# private to this run so it can sit beside a live unit on a dev box.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${FLOX_ENV:?run me under flox activate}"
export AGENT_HUB_LISTEN="127.0.0.1:${CI_SWAP_PORT:-18999}"
export AGENT_HUB_BACKEND_PORT="${CI_BACKEND_PORT:-18990}"

echo "== binaries =="
for b in llama-server sd-server llama-swap; do
  p=$(command -v "$b") || { echo "MISSING: $b"; exit 1; }
  case "$p" in "$FLOX_ENV"/*) echo "  $b -> $(readlink -f "$p")" ;;
    *) echo "  $b resolves outside the environment: $p"; exit 1 ;; esac
done
llama-server --version 2>&1 | tail -1 | sed 's/^/  llama-server: /'

echo "== llama-swap loads $AGENT_HUB_SWAP_CONFIG =="
log=$(mktemp -t ci-swap.XXXXXX)
llama-swap -config "$AGENT_HUB_SWAP_CONFIG" -listen "$AGENT_HUB_LISTEN" >"$log" 2>&1 &
swap=$!
trap 'kill "$swap" 2>/dev/null; wait "$swap" 2>/dev/null; rm -f "$log"' EXIT

for _ in $(seq 1 20); do
  curl -fsS "http://$AGENT_HUB_LISTEN/v1/models" -o "$log.models" 2>/dev/null && break
  kill -0 "$swap" 2>/dev/null || { echo "llama-swap exited:"; cat "$log"; exit 1; }
  sleep 0.5
done
[ -s "$log.models" ] || { echo "no answer from llama-swap:"; cat "$log"; exit 1; }

want="coder embed flux2-klein-4b flux2-klein-9b instruct z-image-turbo"
got=$(jq -r '.data[].id' "$log.models" | sort | tr '\n' ' ' | sed 's/ $//')
rm -f "$log.models"
if [ "$got" = "$want" ]; then
  echo "  models: $got"
  echo "OK llama-swap serves the table"
else
  echo "  want: $want"; echo "  got:  $got"; exit 1
fi

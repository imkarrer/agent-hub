#!/usr/bin/env bash
# One-shot chat-completion smoke test against a running scripts/serve.sh
# instance. Run from inside `nix develop` so jq is on PATH.
set -euo pipefail

PORT="${1:-8091}"

REQ='{"model":"local","messages":[{"role":"user","content":"Write a Python function fizzbuzz(n) that returns the FizzBuzz sequence from 1 to n as a list of strings. Just the function, no explanation."}],"max_tokens":300,"temperature":0.2}'

RESP=$(curl -s "http://127.0.0.1:${PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "$REQ")

echo "$RESP" | jq -r '.choices[0].message.content'
echo "---"
echo "$RESP" | jq '.timings | {prompt_per_second, predicted_per_second}'

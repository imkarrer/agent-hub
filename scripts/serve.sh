#!/usr/bin/env bash
# Manual dev-shell smoke test for the model server, ahead of wiring it into
# the systemd module. Run from inside `nix develop`.
set -euo pipefail

MODEL_PATH="${1:?usage: serve.sh <path-to-gguf> [port] [ctx-size]}"
PORT="${2:-8091}"
CTX="${3:-8192}"

exec llama-server \
  --model "$MODEL_PATH" \
  --host 127.0.0.1 \
  --port "$PORT" \
  --ctx-size "$CTX" \
  --threads 0

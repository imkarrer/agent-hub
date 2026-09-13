#!/usr/bin/env bash
# Fetch the model ac-box actually serves, into the directory homelab's
# configuration.nix points llama-server at.
#
# This used to fetch the Phase 1 smoke-test model (Qwen2.5-Coder-14B Q4_K_M)
# into a relative models/ directory, and it stayed that way after the real
# model was chosen and downloaded -- by a different script, written by hand
# in /root on the box on 7 Sep 2026 and never committed. Found 13 Sep during
# the gitops reconciliation: the procedure that produced 85 GB of deployed
# data lived nowhere git could see, and this file described a model that was
# never deployed. Now it is the box's script, with the model named once.
#
# The choice of THIS model over the larger Qwen3-Coder-480B is argued in
# homelab hosts/ac-box/configuration.nix at services.agent-hub.llm.modelPath,
# which must name shard 1 of what this fetches. If you change REPO/QUANT here,
# change modelPath there in the same commit -- they are one fact in two repos.
#
# Idempotent and resumable: curl -C - continues a partial shard, and a
# complete shard is a no-op. Four shards, ~85 GB total; from Hugging Face on a
# 1 Gbit link this is about an hour.
set -euo pipefail

REPO="${REPO:-Qwen/Qwen3-Coder-Next-GGUF}"
QUANT="${QUANT:-Qwen3-Coder-Next-Q8_0}"
SHARDS="${SHARDS:-4}"
DEST="${DEST:-/srv/agent-hub/models}"

mkdir -p "$DEST"
cd "$DEST"
for i in $(seq 1 "$SHARDS"); do
  f=$(printf "%s-%05d-of-%05d.gguf" "$QUANT" "$i" "$SHARDS")
  url="https://huggingface.co/${REPO}/resolve/main/${QUANT}/${f}?download=true"
  echo "=== $(date -Is) fetching $f"
  curl -L --fail --retry 10 --retry-delay 5 --retry-all-errors -C - -o "$f" "$url"
done
echo "=== $(date -Is) done"
ls -la "$DEST"

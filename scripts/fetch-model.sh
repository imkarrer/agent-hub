#!/usr/bin/env bash
# Fetch every model ac-box serves, into the directory homelab's
# configuration.nix points the model server at. One entry per served model,
# named once here and referenced from homelab's `services.agent-hub.llm.models`
# by the same file names -- if a name changes in one place it changes in the
# other, in the same commit.
#
# History: this used to fetch the Phase 1 smoke-test model into a relative
# models/ directory and stayed that way after the real model was chosen and
# downloaded by an uncommitted script in /root (found 13 Sep 2026 during the
# gitops reconciliation). Since then it is the box's script. 14 Sep 2026 it
# grew the second Qwen model and the image model when the server became
# llama-swap in front of several backends; 20 Sep 2026 the image models
# left again (homelab-b9u: generating evicted both 80Bs, and the RAM is
# wanted for a second reviewer and a utility model).
#
# Idempotent and resumable: curl -C - continues a partial file, and a complete
# file is a no-op. ~170 GB in total; from Hugging Face on a 1 Gbit link that
# is about two hours the first time. Pass model names to fetch a subset:
#   fetch-model.sh coder instruct embed
set -euo pipefail

DEST="${DEST:-/srv/agent-hub/models}"
mkdir -p "$DEST"
cd "$DEST"

get() { # get <repo> <path-in-repo> [local-name]
  local repo=$1 path=$2 f=${3:-$(basename "$2")}
  local url="https://huggingface.co/${repo}/resolve/main/${path}?download=true"
  echo "=== $(date -Is) fetching $f"
  curl -L --fail --retry 10 --retry-delay 5 --retry-all-errors -C - -o "$f" "$url"
}

# The coding agent. The choice of this over the larger Qwen3-Coder-480B is
# argued in homelab hosts/ac-box/configuration.nix. Four shards, ~85 GB.
coder() {
  local q=Qwen3-Coder-Next-Q8_0
  for i in 1 2 3 4; do
    get Qwen/Qwen3-Coder-Next-GGUF "$q/$(printf '%s-%05d-of-%05d.gguf' "$q" "$i" 4)"
  done
}

# The general-purpose sibling: same architecture, size and speed, tuned for
# instructions and prose rather than code. Serves inquire-platform's rubric
# scoring. One file, ~85 GB.
instruct() {
  get Qwen/Qwen3-Next-80B-A3B-Instruct-GGUF Qwen3-Next-80B-A3B-Instruct-Q8_0.gguf
}

# Embeddings: Qwen3-Embedding-0.6B, the small end of the same family the
# chat models come from, 1024-dim vectors, 32k context, pooling stored in
# the GGUF (last token). Served by llama-server in embedding mode and
# written into Qdrant (services.agent-hub.vectors). ~0.6 GB.
embed() {
  get Qwen/Qwen3-Embedding-0.6B-GGUF Qwen3-Embedding-0.6B-Q8_0.gguf
}

for m in "${@:-coder instruct embed}"; do "$m"; done
echo "=== $(date -Is) done"
ls -la "$DEST"

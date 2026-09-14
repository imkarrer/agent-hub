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
# llama-swap in front of several backends.
#
# Idempotent and resumable: curl -C - continues a partial file, and a complete
# file is a no-op. ~210 GB in total; from Hugging Face on a 1 Gbit link that
# is about two hours the first time. Pass model names to fetch a subset:
#   fetch-model.sh coder instruct z-image flux2-klein
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

# Image generation: Z-Image-Turbo (6B DiT, 8 steps, no CFG) for
# stable-diffusion.cpp, which needs the diffusion model, its Qwen3-4B text
# encoder, and the FLUX autoencoder. black-forest-labs' own copy of the VAE
# is gated; Comfy-Org's repackage of the same file is not. ~11 GB.
z-image() {
  get leejet/Z-Image-Turbo-GGUF z_image_turbo-Q8_0.gguf
  get unsloth/Qwen3-4B-Instruct-2507-GGUF Qwen3-4B-Instruct-2507-Q8_0.gguf
  get Comfy-Org/z_image_turbo split_files/vae/ae.safetensors z_image-vae-ae.safetensors
}

# FLUX.2 klein, 4B (Apache 2.0) and 9B (non-commercial licence), 4-step
# distilled: the 4B is ~3x faster than Z-Image-Turbo at similar quality and
# can edit images; the 9B is a quality step up at Z-Image speed. Each needs
# its own Qwen3 text encoder (the ORIGINAL Qwen3-4B/8B, not the 2507
# Instruct that Z-Image uses -- klein was trained against these) and the
# FLUX.2 VAE, which is gated on BFL's repo and not on Comfy-Org's. ~28 GB.
flux2-klein() {
  get Comfy-Org/flux2-klein-4B split_files/vae/flux2-vae.safetensors flux2-vae.safetensors
  get leejet/FLUX.2-klein-4B-GGUF flux-2-klein-4b-Q8_0.gguf
  get unsloth/Qwen3-4B-GGUF Qwen3-4B-Q8_0.gguf
  get leejet/FLUX.2-klein-9B-GGUF flux-2-klein-9b-Q8_0.gguf
  get unsloth/Qwen3-8B-GGUF Qwen3-8B-Q8_0.gguf
}

for m in "${@:-coder instruct z-image flux2-klein}"; do "$m"; done
echo "=== $(date -Is) done"
ls -la "$DEST"

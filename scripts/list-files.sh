#!/usr/bin/env bash
# Lists GGUF quantizations available in a Hugging Face model repo, e.g.:
#   scripts/list-files.sh bartowski/Qwen2.5-Coder-14B-Instruct-GGUF
set -euo pipefail

REPO="${1:?usage: list-files.sh <huggingface-repo>}"
curl -sL "https://huggingface.co/api/models/${REPO}" |
  grep -o '"rfilename":"[^"]*\.gguf"'

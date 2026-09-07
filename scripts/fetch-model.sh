#!/usr/bin/env bash
# Fetches the Phase 1 smoke-test model into models/ (gitignored).
set -euo pipefail

REPO="bartowski/Qwen2.5-Coder-14B-Instruct-GGUF"
FILE="Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf"
DEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/models"

mkdir -p "$DEST_DIR"
curl -L -C - --progress-bar \
  "https://huggingface.co/${REPO}/resolve/main/${FILE}" \
  -o "${DEST_DIR}/${FILE}"

echo "Saved to ${DEST_DIR}/${FILE}"
sha256sum "${DEST_DIR}/${FILE}"

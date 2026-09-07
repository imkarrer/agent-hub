#!/usr/bin/env bash
# Phase 2a proof-out: repo + task -> sandboxed aider run -> draft PR.
# Everything that touches the repo or GitHub happens inside the
# container; the host only launches it, applies resource/security
# limits, and enforces the timeout.
set -euo pipefail

REPO_URL="${1:?usage: run-task.sh <repo-url> <task> [base-branch] [test-cmd]}"
TASK="${2:?usage: run-task.sh <repo-url> <task> [base-branch] [test-cmd]}"
BASE_BRANCH="${3:-main}"
TEST_CMD="${4:-}"

: "${GITHUB_TOKEN:?set GITHUB_TOKEN to a PAT scoped to this one repo}"
# NixOS's virtualisation.docker.rootless doesn't actually put dockerd in
# its own network namespace (rootlesskit here shares the host's netns --
# confirmed via /proc/*/ns/net), so host.docker.internal / bridge routing
# to the host never resolves the way it does on Docker Desktop. --network
# host (below) is what actually reaches llama-server; point this at
# whatever real host IP/port it's bound to.
: "${LLAMA_BASE_URL:=http://172.18.37.247:8091/v1}"
: "${LLAMA_MODEL:=openai/local}"
# llama-server doesn't require auth, but litellm (which aider uses under
# the hood) refuses to call an "openai/" model with no key set at all --
# any non-empty placeholder satisfies it.
: "${OPENAI_API_KEY:=sk-local-placeholder}"
: "${RUNNER_IMAGE:=agent-hub-runner:latest}"
: "${RUNNER_TIMEOUT:=1800}"

WORKDIR="$(mktemp -d)"
CONTAINER_NAME="agent-hub-runner-$$"
BRANCH="agent-hub/$(date +%s)"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# shellcheck disable=SC2016
INNER_SCRIPT='
set -euo pipefail
gh auth setup-git
git clone --depth 1 --branch "$BASE_BRANCH" "$REPO_URL" repo
cd repo
git checkout -b "$BRANCH"
git config user.email "agent-hub@localhost"
git config user.name "agent-hub runner"

AIDER_ARGS=(--yes --message "$TASK" --openai-api-base "$LLAMA_BASE_URL" --model "$LLAMA_MODEL")
if [ -n "${TEST_CMD:-}" ]; then
  AIDER_ARGS+=(--test-cmd "$TEST_CMD" --auto-test)
fi

# Test files go in as read-only context, never editable -- otherwise the
# model can "pass" a task by weakening the test instead of fixing the
# code. Found this the hard way: a proof-out run rewrote a test
# assertion to match its (still-correct, but not guaranteed) implementation
# rather than the reverse.
while IFS= read -r -d "" test_file; do
  AIDER_ARGS+=(--read "$test_file")
done < <(find . -type f \( -name "test_*.py" -o -name "*_test.py" \) -print0)

aider "${AIDER_ARGS[@]}" 2>&1 | tee /workspace/aider.log

if [ -z "$(git log "origin/$BASE_BRANCH..HEAD" --oneline)" ]; then
  echo "no commits produced -- not opening a PR" | tee /workspace/status
  exit 1
fi

git push origin "$BRANCH"
gh pr create --draft --base "$BASE_BRANCH" --head "$BRANCH" \
  --title "agent-hub: $TASK" \
  --body "Opened automatically by agent-hub'"'"'s sandboxed runner. Review before merging." \
  | tee /workspace/status
'

set +e
timeout "$RUNNER_TIMEOUT" docker run --rm \
  --name "$CONTAINER_NAME" \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --memory 4g \
  --network host \
  -v "$WORKDIR:/workspace" \
  -w /workspace \
  -e REPO_URL="$REPO_URL" \
  -e TASK="$TASK" \
  -e BASE_BRANCH="$BASE_BRANCH" \
  -e TEST_CMD="$TEST_CMD" \
  -e BRANCH="$BRANCH" \
  -e GITHUB_TOKEN="$GITHUB_TOKEN" \
  -e GH_TOKEN="$GITHUB_TOKEN" \
  -e LLAMA_BASE_URL="$LLAMA_BASE_URL" \
  -e LLAMA_MODEL="$LLAMA_MODEL" \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  "$RUNNER_IMAGE" -lc "$INNER_SCRIPT"
STATUS=$?
set -e

echo "--- workdir: $WORKDIR ---"
if [ $STATUS -ne 0 ]; then
  echo "run-task failed (exit $STATUS). aider.log and status left in $WORKDIR for inspection." >&2
  exit "$STATUS"
fi

cat "$WORKDIR/status" 2>/dev/null || true
rm -rf "$WORKDIR"

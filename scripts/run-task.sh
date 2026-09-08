#!/usr/bin/env bash
# Phase 2a proof-out: repo + task -> sandboxed aider run -> draft PR.
# Everything that touches the repo or GitHub happens inside the
# container; the host only launches it, applies resource/security
# limits, and enforces the timeout.
#
# Networking (see docs/network-isolation.md for the full analysis):
# RUNNER_NETWORK_MODE=bridge (the safe default, set by the module) puts the
# container on a dedicated Docker network instead of the host's network
# namespace, with a host-side DOCKER-USER iptables allowlist (provisioned by
# modules/agent-hub.nix, not by this script) restricting that network's
# egress to LLAMA_BASE_URL's host:port and github.com's published ranges on
# 443. RUNNER_NETWORK_MODE=host reproduces the old --network host behaviour
# and is only reachable when services.agent-hub.runner.network.singleTenantHost
# is set true -- the module's own assertion refuses it otherwise. When
# invoking this script directly (bypassing the module, per the README), an
# unset RUNNER_NETWORK_MODE defaults to "bridge" here too, and there will be
# no allowlist unless something else provisioned DOCKER-USER -- the preflight
# canary below is what catches that rather than silently falling back to an
# unfiltered network.
set -euo pipefail

REPO_URL="${1:?usage: run-task.sh <repo-url> <task> [base-branch] [test-cmd]}"
TASK="${2:?usage: run-task.sh <repo-url> <task> [base-branch] [test-cmd]}"
BASE_BRANCH="${3:-main}"
TEST_CMD="${4:-}"

: "${GITHUB_TOKEN:?set GITHUB_TOKEN to a PAT scoped to this one repo}"
: "${LLAMA_BASE_URL:=http://172.18.37.247:8091/v1}"
: "${LLAMA_MODEL:=openai/local}"
# llama-server doesn't require auth, but litellm (which aider uses under
# the hood) refuses to call an "openai/" model with no key set at all --
# any non-empty placeholder satisfies it.
: "${OPENAI_API_KEY:=sk-local-placeholder}"
: "${RUNNER_IMAGE:=agent-hub-runner:latest}"
: "${RUNNER_TIMEOUT:=1800}"
: "${RUNNER_NETWORK_MODE:=bridge}"
: "${RUNNER_NETWORK_NAME:=agent-hub-runner}"
: "${RUNNER_NETWORK_SUBNET:=172.30.99.0/24}"

# Non-root sandbox process -- with one detected, documented exception.
# Rootless Docker (this dev box) remaps any non-zero container UID into a
# subordinate range (/etc/subuid), so it never matches the real host user
# that owns the bind-mounted workdir -- only container UID 0 does, via
# rootlesskit's own base mapping. That makes "non-root" and "can write the
# workspace" mutually exclusive there specifically: verified empirically
# (touch/git both fail under --user with a world-writable workdir; --userns
# =host --user 0:0 succeeds, i.e. only root-in-container lines up with the
# real host uid). ac-box runs plain rootful Docker, where no such remap
# exists and --user genuinely drops privileges -- detect which one this
# host is rather than assume.
if docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
  # The image's own default (User=1000:1000, nix/runner-image.nix) hits the
  # exact same remap problem -- omitting --user here would inherit that
  # default, not fall back to root. Root-in-container is the one UID that
  # lines up with the real host user under rootless Docker's own
  # convention, so it has to be requested explicitly.
  DOCKER_USER_ARGS=(--user 0:0)
else
  DOCKER_USER_ARGS=(--user "$(id -u):$(id -g)")
fi

WORKDIR="$(mktemp -d)"
CONTAINER_NAME="agent-hub-runner-$$"
BRANCH="agent-hub/$(date +%s)"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

case "$RUNNER_NETWORK_MODE" in
  bridge)
    docker network inspect "$RUNNER_NETWORK_NAME" >/dev/null 2>&1 || \
      docker network create --subnet "$RUNNER_NETWORK_SUBNET" "$RUNNER_NETWORK_NAME" >/dev/null
    DOCKER_NET_ARGS=(--network "$RUNNER_NETWORK_NAME")
    ;;
  host)
    DOCKER_NET_ARGS=(--network host)
    ;;
  *)
    echo "unknown RUNNER_NETWORK_MODE '$RUNNER_NETWORK_MODE' (expected bridge or host)" >&2
    exit 1
    ;;
esac

# Preflight canary: verify the isolation actually holds for THIS invocation
# rather than trust the module's iptables rules are provisioned and correct.
# Two checks, both must pass before any model-generated code runs:
#   1. LLAMA_BASE_URL is reachable from the sandbox network -- catches the
#      allowlist being too strict, or simply not provisioned at all under
#      bridge mode (a `nixos-rebuild switch` that hasn't happened yet is a
#      silent, confusing aider failure otherwise).
#   2. A real external host outside every allowed range (1.1.1.1) is NOT
#      reachable -- catches the allowlist being too loose, missing
#      entirely, or this being run on a host where DOCKER-USER isn't wired
#      the way modules/agent-hub.nix assumes. Skipped in host mode: with
#      the whole host namespace shared, this would correctly fail every
#      time and proves nothing.
if [ "$RUNNER_NETWORK_MODE" = "bridge" ]; then
  echo "preflight: checking llama-server reachability on '$RUNNER_NETWORK_NAME'..." >&2
  if ! timeout 10 docker run --rm "${DOCKER_USER_ARGS[@]}" "${DOCKER_NET_ARGS[@]}" "$RUNNER_IMAGE" \
      python3 -c "import urllib.request,sys; urllib.request.urlopen(sys.argv[1], timeout=5)" \
      "$LLAMA_BASE_URL/models" >/dev/null 2>&1; then
    echo "preflight FAILED: cannot reach $LLAMA_BASE_URL from '$RUNNER_NETWORK_NAME'." >&2
    echo "Either the DOCKER-USER egress allowlist isn't provisioned yet (nixos-rebuild" >&2
    echo "switch not applied) or it is wrongly blocking the one endpoint it should allow." >&2
    echo "Refusing to run the task rather than let aider fail confusingly mid-run." >&2
    echo "See docs/network-isolation.md." >&2
    exit 1
  fi

  echo "preflight: checking default-deny egress actually blocks an unlisted host..." >&2
  if timeout 10 docker run --rm "${DOCKER_USER_ARGS[@]}" "${DOCKER_NET_ARGS[@]}" "$RUNNER_IMAGE" \
      python3 -c "import urllib.request; urllib.request.urlopen('http://1.1.1.1', timeout=5)" >/dev/null 2>&1; then
    echo "preflight FAILED: '$RUNNER_NETWORK_NAME' can reach 1.1.1.1, which is outside" >&2
    echo "every allowed destination. The egress allowlist is missing, misconfigured, or" >&2
    echo "not being enforced on this host -- refusing to run an untrusted task on a" >&2
    echo "network that isn't actually isolated. See docs/network-isolation.md." >&2
    exit 1
  fi
fi

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
  "${DOCKER_USER_ARGS[@]}" \
  --cap-drop=ALL \
  --security-opt no-new-privileges \
  --pids-limit 256 \
  --memory 4g \
  "${DOCKER_NET_ARGS[@]}" \
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

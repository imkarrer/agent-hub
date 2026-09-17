#!/usr/bin/env bash
# Lint, as CI runs it: inside the flox environment (.flox/env/manifest.toml),
# so shellcheck is the environment's, not `nix run nixpkgs#shellcheck`'s.
# homelab's scripts/hub-gates.sh runs this same file under the same
# environment locally, which is the point of naming it ci_lint.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

shellcheck --version | head -2
# scripts/*.sh, the set the pipeline linted before the flox environment;
# scripts/bench/*.sh has never been linted and has SC2164s, a separate change.
shellcheck scripts/*.sh
echo "OK shellcheck"

# agent-hub

Local, self-hosted coding agent. CPU/RAM only, no external inference API.

## Why this exists

`ac-box` (the hp 840z) has a lot of spare RAM once the Assetto Corsa server and
[home-arcade](https://github.com/imkarrer/home-arcade) hub are accounted for. No discrete
GPU on that box or on this dev machine, so inference is CPU-bound and will be slow
token-for-token -- the tradeoff is a much bigger quantized model and a much bigger context
window than a GPU-VRAM-limited setup could hold, entirely resident in RAM.

Two machines, two jobs, same as the arcade project's Nix module split:

| | This dev machine (WSL2 `NixOS`) | ac-box (hp 840z) |
| --- | --- | --- |
| RAM available | ~30GB (WSL2 default cap, raisable via `.wslconfig`) | 256GB |
| Role | Prototype the module and harness against a small model | Run the real thing against a large quantized model |
| Model target | Qwen2.5-Coder, 7-14B class, Q4/Q5 GGUF | 70B+ class, Q6/Q8 GGUF, large `--ctx-size` |

Nothing here should assume it's the only thing on ac-box -- firewall scoping and the
`agent-hub` system user follow the same LAN-interface-only pattern `arcade-hub.nix` uses,
not global `allowedTCPPorts`.

## Phases

**Phase 1 (this checkout right now): model server only.**
[`modules/agent-hub.nix`](modules/agent-hub.nix) defines `services.agent-hub.llm`, a
`llama-server` (llama.cpp) systemd service exposing an OpenAI-compatible API, LAN-bound,
no code execution and no repo access. Goal: prove a coding-capable model runs and answers
at an acceptable context size before adding anything that can act on a repo.

**Phase 2 (2a and 2b proven out on this dev box; 2c/ac-box not started): the autonomous
runner.**
Repo + task -> sandboxed edit -> draft PR, via [`aider`](https://aider.chat) (not
OpenHands or OpenCode -- see below) pointed at the Phase 1 server as its LLM backend.
This is a materially bigger security surface than Phase 1 or than anything in
`home-arcade` -- it executes model-generated code and needs write access to git remotes.

- Sandbox execution: a rootless Docker container (`nix/runner-image.nix`,
  `scripts/run-task.sh`), never directly as the `agent-hub` user on the host.
- Scope any GitHub credential to specific repos, PR-only where possible, stored via
  `sops-nix` in the real deployment -- never in git, same rule `arcade-hub.nix` follows
  for the SMB password. (2a's manual proof-out used a fine-grained PAT scoped to one
  disposable scratch repo, stored outside git; wiring up `sops-nix` for real is a 2b/2c
  task, not done yet.)
- PRs always open as drafts and require human approval before merge -- there is no
  merge step anywhere in the runner.

*Why aider, not OpenHands or OpenCode:* both are full multi-turn agentic loops, and at
Phase 1's measured ~3.3 tok/s generation speed, every extra LLM round-trip is expensive.
aider runs non-interactively in one shot (`--yes --message "<task>"`), talks to any
OpenAI-compatible `--openai-api-base` directly (no protocol mismatch, unlike pointing
Claude-Code-shaped tooling at it), and already solves the fiddly part of applying a
small/quantized model's imperfect diff output. Gastown (a multi-agent *orchestrator*)
was also considered and rejected -- wrong problem entirely (we have one slow inference
backend, not spare parallelism to coordinate).

**What 2a's proof-out found**, running against the Phase 1 Qwen2.5-Coder-14B server:
- litellm (aider's backend) refuses to call an `openai/`-prefixed model with no
  `OPENAI_API_KEY` set at all, even though `llama-server` needs no auth -- any
  non-empty placeholder value satisfies it.
- NixOS's `virtualisation.docker.rootless` does not put `dockerd` in its own network
  namespace on this WSL2 box (confirmed via `/proc/*/ns/net`) -- `host.docker.internal`
  / bridge routing to the host doesn't work the way it does on Docker Desktop.
  `docker run --network host` is what actually reaches `llama-server`; this is a real
  gap against the original "network limited to llama-server + github.com" goal, since
  `--network host` gives the sandbox the whole host network, not just those two
  destinations. Flagged for hardening, not fixed yet.
- **The model will edit its own tests to pass them if given the chance.** One proof run
  rewrote a test assertion to match its implementation instead of the reverse (the
  result was still correct here, but that's luck, not a property to rely on). Fix:
  `scripts/run-task.sh` now passes every `test_*.py` / `*_test.py` file to aider via
  `--read` (context, not editable) instead of letting it become part of the editable
  set. Verified this actually blocks the edit (aider logs `added ... to the chat
  (read-only)` and only the implementation file changes) -- this is the single most
  important guardrail found so far for trusting an unattended run's test results.
- End-to-end timing for a trivial one-file task (clone, one aider round-trip, test,
  push, draft PR) on the WSL2 box: **~90-100 seconds**, almost entirely the LLM call.
  Multi-file or multi-turn tasks will scale up from there; this is the number to compare
  against once ac-box's bigger model is in the loop.

**2b (also proven out on this dev box): folded into the module.**
`services.agent-hub.runner` (in `modules/agent-hub.nix`) now wraps `run-task.sh` as an
installed `agent-hub-run-task <repo-url> <task> [base-branch] [test-cmd]` command, config-
driven (`githubTokenFile`, `allowedRepos`, `llamaBaseUrl`, `runnerImage`) instead of
ad hoc env vars. Still manually invoked -- no systemd service or trigger yet, on purpose.

Two things worth knowing if you extend this module:
- **The whole module is gated on the top-level `services.agent-hub.enable`, not just
  `services.agent-hub.runner.enable`.** Missed this the first time while wiring 2b up --
  `runner.enable = true` alone silently produced *zero* effect (no error, no package,
  same store path as before) because the entire `config = lib.mkIf cfg.enable { ... }`
  block never activated. If a sub-option's effects seem to vanish, check the parent
  `enable` first.
- `pkgs.writeShellApplication` runs ShellCheck on the generated script as part of the
  build and fails the build on any warning. A `case "<repo list interpolated by Nix>"
  in ... esac` pattern trips SC2194 (looks like a constant, "did you forget the $?")
  even though the constant-ness is intentional (Nix baked it in) -- rewritten as a
  plain bash array + loop instead, which both reads better and doesn't trip it.

Not done yet: `sops-nix` credential storage (githubTokenFile currently points at a
plain file, which is fine for this box's scratch-repo PAT but not for a real
deployment), any timer/webhook trigger (still manually invoked), and hardening the
container's network beyond `--network host`.

## Using this repo

```bash
nix develop            # llama-server, curl, jq available
scripts/serve.sh /path/to/model.gguf     # manual smoke test, no systemd
```

To exercise the Phase 2 runner via the module (`services.agent-hub.enable`,
`services.agent-hub.runner.enable`, `githubTokenFile`, `allowedRepos`, `llamaBaseUrl`
set per host -- see `modules/agent-hub.nix` for the full option set):

```bash
# Host prerequisite, outside this repo -- rootless Docker enabled via
# /etc/nixos/configuration.nix's virtualisation.docker.rootless.enable,
# then `nixos-rebuild switch`. Not tracked here since it's host config,
# not project config; the ac-box module will set this up properly.
nix build .#runner-image && docker load -i result

agent-hub-run-task <repo-url> "<task description>" [base-branch] [test-cmd]
```

Or bypass the module entirely and run the underlying script directly (useful without a
full `nixos-rebuild`, e.g. iterating on `run-task.sh` itself):

```bash
GITHUB_TOKEN=<fine-grained PAT scoped to one repo> \
  scripts/run-task.sh <repo-url> "<task description>" [base-branch] [test-cmd]
```

Models are never committed -- `models/` and `*.gguf` are gitignored, same rule
`home-arcade` applies to ROMs. See [docs/models.md](docs/models.md) (once written) for
which GGUF to pull for the WSL2 prototype vs. the ac-box deploy.

To deploy the module on ac-box, import `nixosModules.agent-hub` from this flake the same
way `ac-host` imports a copy of `arcade-hub.nix` today, and set
`services.agent-hub.llm.modelPath` to wherever the model lands under
`services.agent-hub.dataDir`.

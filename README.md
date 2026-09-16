# agent-hub

Local, self-hosted coding agent. CPU/RAM only, no external inference API.

## Why this exists

`ac-box` (the hp 840z) has a lot of spare RAM once the Assetto Corsa server and
[home-arcade](https://github.com/imkarrer/home-arcade) hub are accounted for. No discrete
GPU on that box, so inference there is CPU-bound and slow token-for-token -- the tradeoff
is a much bigger quantized model and a much bigger context window than a GPU-VRAM-limited
setup could hold, entirely resident in RAM. (Earlier drafts said the dev machine had no GPU
either; it has an RTX 4080 that WSL2 exposes, found 16 Sep 2026 -- see the table.)

Two machines, two jobs, same as the arcade project's Nix module split:

| | This dev machine (WSL2 `NixOS`) | ac-box (hp 840z) |
| --- | --- | --- |
| RAM available | ~30GB (WSL2 default cap, raisable via `.wslconfig`) | 256GB |
| GPU | RTX 4080, 16 GB, via `/dev/dxg` (CUDA build of llama.cpp b11007) | none |
| Role | Prototype the module and harness against a small model | Run the real thing against a large quantized model |
| Model target | Qwen3-Coder-30B-A3B Q4 (tool calling) beside the Phase 1 Qwen2.5-Coder-14B Q4, behind llama-swap | 70B+ class, Q6/Q8 GGUF, large `--ctx-size` |

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

**The code is ahead of where earlier drafts of this README said it was.** `modules/agent-hub.nix`
already contains a real `services.agent-hub.runner` (rootless-Docker aider setup,
`githubTokenFile`, `allowedRepos`), backed by `nix/runner-image.nix` and
`scripts/run-task.sh`. What follows is what that code actually does today, checked
precondition by precondition against what Phase 2 originally required before a
repo-acting runner could be considered safe to wire in -- honestly, including the parts
that don't hold up yet:

| Precondition | Status | Reality |
| --- | --- | --- |
| Sandboxed execution -- container or VM, never as the `agent-hub` user on the host | **Met** | `scripts/run-task.sh` runs aider inside a Docker container (`nix/runner-image.nix`) built from a deliberately narrow image (no compilers, no package managers), with `--cap-drop=ALL`, `--security-opt no-new-privileges`, `--pids-limit 256`, `--memory 4g`, and a non-root `--user` (see below for the rootless-Docker exception). The host process (`agent-hub-run-task`) only launches and reaps the container; the model never runs code as the `agent-hub` host user. `services.agent-hub.runner.network.mode` now defaults to `"bridge"`: a dedicated Docker network plus a `DOCKER-USER` iptables allowlist scoped to `llama-server` + `github.com`, replacing the old unconditional `--network host` (see [`docs/network-isolation.md`](docs/network-isolation.md) for the full analysis, including why that fix holds on ac-box's actual rootful Docker but not on this dev box's rootless one -- the dev box still uses `network.mode = "host"` deliberately, gated behind an explicit `singleTenantHost` acknowledgement precisely because it is not a shared host). |
| GitHub credentials scoped to specific repos, stored via `sops-nix` | **Half met** | Repo scoping exists and is enforced twice: the PAT itself should be a fine-grained token scoped to one repo (a human/operator responsibility, not something Nix can verify), and `services.agent-hub.runner.allowedRepos` is a second, defense-in-depth allowlist the generated `agent-hub-run-task` script checks before it will touch a repo (module assertion also requires `allowedRepos != []`). **But**: `sops-nix` storage is not done. `githubTokenFile` is a plain option of type `nullOr path` -- at invocation time it just needs to point at a readable file; nothing decrypts it via `sops-nix`. 2a's proof-out used a fine-grained PAT for one disposable scratch repo, stored outside git but still a plain file. Wiring real `sops-nix` secret storage is explicitly still open work. |
| Human approval before PR merge | **Met** | `scripts/run-task.sh` always runs `gh pr create --draft`; there is no `gh pr merge`, no auto-merge flag, and no code path in this repo that can merge a PR. Merging is a human action outside this tool, same as `nixos-rebuild switch` is a human action on ac-box. |

None of this has been deployed anywhere -- there is no host importing
`nixosModules.agent-hub` with `runner.enable = true` yet, ac-box included. "Proven out on
this dev box" means: manually invoked on the WSL2 prototype, against a small model,
by a human watching it run. It has not run unattended, has not run on ac-box, and has
no systemd service or timer triggering it -- `services.agent-hub.runner` only installs
an `agent-hub-run-task` command for someone to run by hand.

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
  `docker run --network host` is what actually reaches `llama-server`; this was a real
  gap against the original "network limited to llama-server + github.com" goal, since
  `--network host` gives the sandbox the whole host network, not just those two
  destinations. **Since addressed** (beads homelab-bqo.20, see
  [`docs/network-isolation.md`](docs/network-isolation.md)): the module now defaults
  `services.agent-hub.runner.network.mode` to a scoped Docker bridge + egress allowlist,
  which works cleanly on ac-box's actual (rootful) Docker but, as this same investigation
  found, does *not* work under this dev box's rootless Docker without weakening a
  security default that's blocking it on purpose -- so this WSL2 box specifically still
  runs `network.mode = "host"`, opted into explicitly rather than left as an unexamined
  default.
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

**Non-root sandbox process, with one detected, documented exception.**
`nix/runner-image.nix` now sets `User = "1000:1000"`, and `run-task.sh` passes
`--user "$(id -u):$(id -g)"` matching whoever invokes it -- except when Docker itself is
rootless (`docker info`'s `SecurityOptions` reports it, checked at runtime), where it
explicitly forces `--user 0:0` instead. Root-in-container sounds like the wrong answer,
but it's the *correct* one there: rootless Docker's own convention maps container UID 0
to the real host user, while any non-zero container UID gets shoved into a subordinate
range (`/etc/subuid`) that never matches the bind-mounted workdir's owner. Verified
empirically on this dev box -- `--user 1000:1000` against a world-writable workdir still
gets `Permission denied`, `--userns=host --user 0:0` succeeds. ac-box runs plain rootful
Docker, where no such remap exists and a genuinely unprivileged UID just works. Detected
per-host rather than assumed, same pattern as the network isolation work.

Not done yet: `sops-nix` credential storage (`githubTokenFile` currently points at a
plain file, which is fine for this box's scratch-repo PAT but not for a real
deployment) and any timer/webhook trigger (still manually invoked).

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

**Throughput on ac-box is a measured thing, not a guess:** [docs/prefill-tuning.md](docs/prefill-tuning.md)
is the 14 Sep 2026 sweep that took the deployed server from 17 to 140 tok/s prefill (4.5 to
13.3 generation) with no model change -- NUMA placement, the cgroup cpuset, and ik_llama.cpp
(`services.agent-hub.llm.engine = "ik-llama-cpp"`). `scripts/bench/` is the harness; re-run it
before trusting any number in this README or in homelab's routing skill against a new build.

**Several models, one port.** `services.agent-hub.llm.models` puts llama-swap on the port with
one backend per entry -- ac-box serves `coder` (Qwen3-Coder-Next), `instruct` (Qwen3-Next
Instruct, with `claude-*` aliases so inquire-platform's Anthropic SDK lands on it unchanged),
three image models (stable-diffusion.cpp: `z-image-turbo`, `flux2-klein-4b`, `flux2-klein-9b`)
and `embed` (Qwen3-Embedding-0.6B, `kind = "embedding"`, `/v1/embeddings` only). A model runs
alone unless `concurrent` lists it in a set that may stay resident together; a swap is 20-60 s.
`/` on that port is the front page (`landingPage`), `/upstream/<name>/` each backend's own UI.
`scripts/fetch-model.sh` on the box fetches every file those entries name. The single-model
unit (`modelPath`) is unchanged; the WSL2 box has since moved to `models` too, two entries,
nothing `concurrent` (30 GB holds one of them at a time).

**Consuming it from a coding agent (opencode).** The port is a plain OpenAI-compatible
`/v1`; the `model` in a request is an entry name from `models` (`coder`, `instruct`), which
`GET /v1/models` lists -- not the GGUF's name. Three things a client cannot fix on its side,
all found 16 Sep 2026 pointing opencode at both boxes:

- The backend must run with `--jinja` (in `llm.extraArgs`), or every request carrying a
  `tools` array is answered `500 "tools param requires --jinja flag"`.
- The model has to emit the template's tool-call format. Qwen2.5-Coder-14B-Instruct answers
  a tools request with a ```` ```json ```` fence instead of `<tool_call>` (deterministic at
  temperature 0, both engines, with and without flash-attn), so it drives aider but not
  opencode.
- The server's parser has to accept what the model emits. Qwen3-Coder-30B-A3B omits the
  opening `<tool_call>` token and goes straight to `<function=...>` (7 of 7 samples; the
  token is absent from the generated ids). The ik build pinned in `nix/ik-llama-cpp.nix` and
  nixpkgs' llama-cpp b9190 both have only the generic template-derived parser, which needs
  that literal, so every call came back as plain content. Mainline llama.cpp newer than b9190
  has a dedicated Qwen3-Coder parser (grammar armed on `<function=<name>>`, `<tool_call>`
  optional); the WSL2 box serves `coder` with b11007 for that reason, built with this CPU's
  ISA named explicitly (nixpkgs strips `-march=native`) and with CUDA. On ac-box the
  question does not arise: Qwen3-Coder-Next opens every call with `<tool_call>` (raw
  `/completion` on the box, 4 of 4 samples), and after `--jinja` landed (homelab 7e095ae)
  opencode ran a tool call through it end to end.

An `opencode.json` provider entry per box:

```json
"acbox": {
  "npm": "@ai-sdk/openai-compatible",
  "options": { "baseURL": "http://192.168.1.50:8100/v1", "apiKey": "not-needed" },
  "models": { "coder": { "tool_call": true, "limit": { "context": 32768, "output": 8192 } } }
}
```

`scripts/compare.sh` sends one identical request to each server and prints prefill and
generation tok/s from the `timings` llama-server returns -- one request per box, nothing
run on it -- for the box-to-box comparison the table at the top of this README promises.
16 Sep 2026, a 1.6k-token prompt: ac-box `coder` 135 tok/s prefill / 13 gen; WSL2 `coder`
(30B-A3B, 24 layers' experts on the CPU, the rest and the KV cache on the GPU) 477 / 44;
WSL2 `coder-14b` fully on the GPU 3859 / 60. An opencode turn that needs one tool call
takes ~18 s locally and ~2 min against ac-box, almost all of it the first prefill.

**A vector store beside it.** `services.agent-hub.vectors` runs nixpkgs' Qdrant on the LAN
address (`:6333`, HTTP only) as the store the embedding model writes into; nothing indexes
into it yet. `scripts/vectors-smoke.sh` embeds three sentences, upserts them, searches with a
fourth and checks the nearest hit, then drops the collection -- the proof the pair works.


To deploy the module on ac-box, import `nixosModules.agent-hub` from this flake the same
way `ac-host` imports a copy of `arcade-hub.nix` today, and set
`services.agent-hub.llm.modelPath` to wherever the model lands under
`services.agent-hub.dataDir`.

**nixpkgs: the platform layer owns it, this flake must follow.** ac-box runs
`nixos-26.05`, and `homelab` (the platform repo that owns the host, tenants included) is
where `nixpkgs` gets pinned for the whole closure -- tenant flakes are not supposed to
drag in their own copy. This flake's own `inputs.nixpkgs.url` points at
`github:NixOS/nixpkgs/nixos-26.05` so standalone use of this repo (`nix build`,
`nix flake check`, `nix develop`, all run in WSL2 outside `homelab`) matches the deploy
target, but that pin is *not* what actually gets used once this is deployed. Whatever
imports `nixosModules.agent-hub` as a tenant input (`homelab`, on ac-box) must set:

```nix
inputs.agent-hub.inputs.nixpkgs.follows = "nixpkgs";
```

so the host's single `nixpkgs` evaluation is authoritative and this repo's own pin never
reaches the built closure. Every `llama-server` flag this module passes or documents in
`extraArgs` (`--flash-attn on`, plus `--threads`, `--ctx-size`, `--host`, `--port`) has
been checked against `nixos-26.05`'s `llama-cpp` package (version `9190`, matching the
`homelab` README's own note) via `llama-server --help` on that exact build -- all five
exist and behave as documented there. If the pinned `nixos-26.05` revision (or whatever
it's superseded by) ever moves, re-run that check before trusting this module's flags
against the new build; it does not re-verify itself.

**Port note:** `services.agent-hub.llm.port` defaults to `8100`. That default is a
shared-host allocation, not a free choice -- ac-box's Assetto Corsa tenant reserves the
contiguous HTTP block `8081`-`8096` (8081 + 16 lobby slots), and `8100` sits outside
every range reserved on that box today. It is not derived from any port registry here;
if `homelab`'s tenant port registry ever claims `8100` for something else, this default
has to move again, not be assumed still safe.

**CPU note:** `services.agent-hub.llm.threads` defaults to `4`, not `0`. `0` (like
llama-server's own default of `-1`) means "auto-detect and use every core llama.cpp can
see" -- on ac-box that's all 56 threads, which would starve the live race servers
sharing the box. `4` is a safe, non-grabby placeholder for dev use, not a capacity plan:
on ac-box, `homelab`'s tier system is what actually owns CPU allocation (shares of
`homelab.host.capacity.cpuThreads`, applied as `CPUWeight`/`AllowedCPUs` on this
tenant's slice, per that repo's "tiers are shares, not absolute indices" rule). Whoever
deploys this module must set `threads` to match the CPU allowance that slice actually
grants agent-hub, not the host's total core count and not this default without
checking.

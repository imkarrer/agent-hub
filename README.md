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

## What this repo is: the environment is the tenant, the module is the skeleton

Since homelab ADR 0009 step 1 (18 Sep 2026) the model server on ac-box runs from this
repo's **flox environment**, not from Nix:

| | The environment (`.flox/env/manifest.toml`, `llama-swap.yaml`) | The module (`modules/agent-hub.nix`) |
| --- | --- | --- |
| What it is | The tenant: the packages (ik_llama.cpp, stable-diffusion.cpp, llama-swap 224), the six-model table, the command. A tenant author writes no Nix. | The unit's skeleton in the closure: the `agent-hub` user, `/srv/agent-hub` and `/var/lib/agent-hub`, the firewall rule, `agent-hub-llm.service`'s name / user / restart policy / ordering, nginx (the landing page) and qdrant. It generates nothing that runs a model. |
| Who runs it | A developer: `flox activate`. The box: `agent-hub-llm.service`'s `ExecStart=flox activate -d /var/lib/agent-hub/env -- llama-swap -config <env>/llama-swap.yaml -listen 127.0.0.1:8100`, set by homelab's unit stub (`homelab.tenants.agent-hub.environment` in `hosts/ac-box/configuration.nix`). | homelab imports it as a flake input, as before, until `homelab-158.11` makes the stub the whole unit. Without the stub the unit exists and fails on start with a message naming the stub -- never a unit that quietly serves the old way. |
| How a change reaches the box | Push to `main`; CI (`.buildkite/pipeline.yml`) proves the table loads and stages the sha; the box's `agent-hub-environment-pull` checks it out, warms it once online, restarts the unit. No closure switch. | A `flake.lock` bump in homelab (`bump-lock`), a closure switch at 03:30 -- only when a host-side thing changes: a directory, the landing page, qdrant. |
| Host facts | Seven `AGENT_HUB_*` variables the unit's `Environment=` sets: models dir, threads, ctx, listen address, backend port, the table's path, the assets dir. The manifest's hook sets **none** of them under a unit; a missing one is llama-swap's refusal at load, `environment variable 'X' is not set`. | Declared as options (`llm.threads`, `llm.contextSize`, `llm.port`, `llm.landingPage`, `lanAddress`, `dataDir`, `llm.backendPort`) that homelab's stub reads from, so a value has one spelling. Table fields ac-box still sets (`engine`, `extraArgs`, `concurrent`, a model's `modelPath`...) are declared but read by nothing; `llama-swap.yaml` is the table. |

### What a developer runs

```bash
flox activate                       # llama-server (ik fork), sd-server, llama-swap, curl, jq, shellcheck on PATH
DEST=$PWD/models scripts/fetch-model.sh embed   # models/ is gitignored
flox activate -- llama-swap -config llama-swap.yaml -listen 127.0.0.1:18900
curl -s http://127.0.0.1:18900/v1/models | jq -r '.data[].id'
```

Outside a systemd unit the manifest's hook fills in **laptop** values -- 4 threads,
8192 ctx, `$PWD/models`, `127.0.0.1:18900`, backends from 18910, the table and
`nix/sd-ui.html` from the checkout -- chosen so a small model runs beside a NixOS unit
on the same machine, and so that none of them is the box's (23 threads on a laptop was
the earlier mistake; the box's values live in `hosts/ac-box/configuration.nix` and
arrive by the stub, never by default). Export any `AGENT_HUB_*` to override.
`flox activate --start-services` runs the same command under process-compose for an
interactive session; it is the developer's shape, not the unit's (the manifest says
why). `scripts/ci_test.sh` is the gate CI runs: the binaries resolve inside the
environment and llama-swap lists the six models; `bash
/path/to/homelab/scripts/hub-gates.sh agent-hub` runs it locally with flox pinned to
the box's version.

### What the box runs

The same environment at a sha, checked out to `/var/lib/agent-hub/env` by the pull
unit, activated by the stub with the box's seven values, in `background.slice` with the
cpuset and NUMA policy the host sets on the unit. `nix/index.html` (the landing page
nginx serves at `http://192.168.1.50:8100/`) and qdrant on `:6333` still come from the
module. `hub-status` in homelab prints `agent-hub env: staged <sha> / applied <sha>
(run <hash>)` beside the closure's rev pair.

## Phases

**Phase 1: model server.** Served as above -- LAN-bound, no code execution and no repo
access. The goal was to prove a coding-capable model runs and answers at an acceptable
context size before adding anything that can act on a repo; it does (the numbers are
below).

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

Where the runner sits in ADR 0009's terms: it is a **Docker image** (`nix/runner-image.nix`,
`dockerTools.buildImage`) plus a host-side wrapper and iptables rules from the module, with
no systemd unit -- so it is not a second stub on the model server's environment. Its kind
is the ADR's step 4, `flox containerize` (as ac-host's bot and sidecars, `homelab-ybm`):
the image from a manifest of its own (aider, git, gh, python3 are all catalog packages),
the wrapper and the `DOCKER-USER` allowlist staying host-side. Not started.

## Using this repo

The environment is the way in ("What a developer runs", above). `nix develop` still
exists for the flake's own outputs -- nixpkgs' `llama-server`, curl, jq -- and
`scripts/serve.sh /path/to/model.gguf` runs one bare llama-server without llama-swap or
systemd; neither is what the box runs.

The environment was proven on this WSL box 17 Sep 2026 with `AGENT_HUB_MODELS` pointed at
a directory holding the production `embed` GGUF (fetched with `DEST=$PWD/models
scripts/fetch-model.sh embed`) and the local Qwen3-Coder-30B-A3B substituted for `coder`'s
file: /v1/embeddings answered 1024 dims, /v1/chat/completions answered, and a request with
`tools` came back as a parsed `tool_calls` -- the ik build with `--jinja`. ik_llama.cpp and
stable-diffusion.cpp are installed from this repo's own flake outputs (the catalog has
neither at these options), so a change to `nix/ik-llama-cpp.nix` or
`nix/stable-diffusion-cpp.nix` reaches the environment only after it is on GitHub *and*
`flox upgrade` has re-locked -- two commits, in that order.

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

**Several models, one port.** `llama-swap.yaml` puts llama-swap on the port with one backend
per entry -- ac-box serves `coder` (Qwen3-Coder-Next), `instruct` (Qwen3-Next Instruct, with
`claude-*` aliases so inquire-platform's Anthropic SDK lands on it unchanged), three image
models (stable-diffusion.cpp: `z-image-turbo`, `flux2-klein-4b`, `flux2-klein-9b`) and `embed`
(Qwen3-Embedding-0.6B, `/v1/embeddings` only). A model runs alone unless the table's `matrix`
lists it in a set that may stay resident together; a swap is 20-60 s. `/` on that port is the
front page (the module's `landingPage`, nginx, listing the models from
`services.agent-hub.llm.models`' `kind` and `description` -- the names there must match the
table's), `/upstream/<name>/` each backend's own UI. `scripts/fetch-model.sh` on the box
fetches every file the table names.

The WSL2 dev box is the one host that still imports this module **by path** from
`~/src/agent-hub` (its `/etc/nixos/configuration.nix`) and served three models -- mainline
b11007 with CUDA, not the fork -- from the module's generated table. That table is gone,
and that box has no homelab stub, so its next `nixos-rebuild switch` gives it the placeholder
ExecStart: it needs its own stub (a unit whose `ExecStart=flox activate -d ~/src/agent-hub --
llama-swap ...` with its own `AGENT_HUB_*`; its GPU table is not `llama-swap.yaml`) or an
import pinned before this change. Deliberately not decided here.

**Consuming it from a coding agent (opencode).** The port is a plain OpenAI-compatible
`/v1`; the `model` in a request is an entry name from `models` (`coder`, `instruct`), which
`GET /v1/models` lists -- not the GGUF's name. Three things a client cannot fix on its side,
all found 16 Sep 2026 pointing opencode at both boxes:

- The backend must run with `--jinja` (in `llama-swap.yaml`'s `llama_extra` macro), or every
  request carrying a `tools` array is answered `500 "tools param requires --jinja flag"`.
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


**Two pins, two owners.** The *module* is composed into ac-box's closure by `homelab`,
which owns `nixpkgs` for the whole closure and sets
`inputs.agent-hub.inputs.nixpkgs.follows = "nixpkgs"`; this flake's own
`inputs.nixpkgs.url` (`nixos-26.05`) governs only standalone use (`nix build`, `nix flake
check`, `nix develop`) and never reaches the built closure. The *environment* is pinned by
`.flox/env/manifest.lock`: the fork and stable-diffusion.cpp at this repo's own rev (so
their nixpkgs is this flake's, not the host's -- the point of ADR 0009), llama-swap 224
from the catalog. The flag audit that used to live here ("every flag this module passes
exists in b9190") is now `scripts/ci_test.sh`'s: llama-swap loads the table with the
environment's binaries on every push, and a flag the fork does not know fails there.

**Port note:** `services.agent-hub.llm.port` defaults to `8100`, and homelab's stub builds
`AGENT_HUB_LISTEN` from it. That default is a shared-host allocation, not a free choice --
ac-box's Assetto Corsa tenant reserves the contiguous HTTP block `8081`-`8096` (8081 + 16
lobby slots), and `8100` sits outside every range reserved on that box today. It is not
derived from any port registry here; if `homelab`'s tenant port registry ever claims `8100`
for something else, this default has to move again, not be assumed still safe. The
backends' loopback ports (`llm.backendPort`, 18100 up) are not a LAN allocation and not
in the registry.

**CPU note:** `services.agent-hub.llm.threads` defaults to `4`, not `0`, and homelab's stub
passes it as `AGENT_HUB_THREADS`. `0` (like llama-server's own default of `-1`) means
"auto-detect and use every core llama.cpp can see" -- on ac-box that's all 56 threads, which
would starve the live race servers sharing the box. `4` is a safe, non-grabby placeholder
(the manifest's hook uses the same number for a developer's shell), not a capacity plan: on
ac-box, `homelab`'s tier system is what actually owns CPU allocation (shares of
`homelab.host.capacity.cpuThreads`, applied as `CPUWeight`/`AllowedCPUs` on this tenant's
slice, per that repo's "tiers are shares, not absolute indices" rule), and
`hosts/ac-box/configuration.nix` sets `threads = 23` to match the fence.

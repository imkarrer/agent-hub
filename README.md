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

**Phase 2 (not started): the autonomous runner.**
An OpenHands-style harness that takes a repo + task and opens a PR, pointed at the Phase 1
server as its LLM backend. This is a materially bigger security surface than Phase 1 or
than anything in `home-arcade` -- it executes model-generated code and needs write access
to git remotes. Before wiring it in:

- Sandbox execution (container or VM), never directly as the `agent-hub` user on the host.
- Scope any GitHub credential to specific repos, PR-only where possible, stored via
  `sops-nix` -- never in git, same rule `arcade-hub.nix` follows for the SMB password.
- Decide whether PRs need human approval before merge (yes, by default).

Phase 2 needs its own design pass; don't extend the module for it until Phase 1 is
validated end to end.

## Using this repo

```bash
nix develop            # llama-server, curl, jq available
scripts/serve.sh /path/to/model.gguf     # manual smoke test, no systemd
```

Models are never committed -- `models/` and `*.gguf` are gitignored, same rule
`home-arcade` applies to ROMs. See [docs/models.md](docs/models.md) (once written) for
which GGUF to pull for the WSL2 prototype vs. the ac-box deploy.

To deploy the module on ac-box, import `nixosModules.agent-hub` from this flake the same
way `ac-host` imports a copy of `arcade-hub.nix` today, and set
`services.agent-hub.llm.modelPath` to wherever the model lands under
`services.agent-hub.dataDir`.

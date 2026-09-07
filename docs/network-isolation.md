# Network isolation for the Phase 2 runner

beads homelab-bqo.20. Everything below was checked live, not assumed:
`ac-box` over read-only SSH (no `nixos-rebuild`, no `systemctl`, no docker
command that changes state — `docker ps`/`inspect`/`network inspect`/`ss`
only), and the WSL2 dev box (where mutation is fine — it's not ac-box) by
actually running containers and inspecting namespaces.

## 1. What was verified

### The premise in `run-task.sh`'s own comments does not hold on ac-box

The existing comment above `--network host` says rootless Docker "doesn't
actually put dockerd in its own network namespace... confirmed via
`/proc/*/ns/net`." That's true, and reproduced independently here — but only
on the **WSL2 dev box**, which has `virtualisation.docker.rootless.enable =
true` set deliberately in `/etc/nixos/configuration.nix` for prototyping.

`ac-box` runs a **rootful** Docker daemon:

```
$ ssh ac-box docker info | grep -i rootless
$ ssh ac-box ps aux | grep dockerd
root  1749  ...  dockerd --config-file=...      # single process, owned by root
$ ssh ac-box ls -la /var/run/docker.sock
srw-rw---- 1 root docker 0 ... /var/run/docker.sock
```

No `Security Options: rootless` in `docker info`, single root-owned `dockerd`
process, socket owned `root:docker`. `homelab/modules/platform/docker.nix`
confirms this is deliberate: it only ever sets
`virtualisation.docker.enable`, never `virtualisation.docker.rootless` — the
whole `homelab` repo has zero references to rootless Docker. **The
network-namespace argument that justified `--network host` was correct for
the dev box it was written on and does not transfer to the actual deploy
target.** This matters a lot for section 2: rootful Docker's bridge
networking is the mature, standard, kernel-level (veth + bridge + iptables)
mechanism, not the userspace slirp4netns path rootless Docker uses — the two
have materially different reachability properties, tested below.

### What `--network host` actually exposes on ac-box today

Live `ss -tlnp` on ac-box, cross-referenced against
`homelab/hosts/ac-box/tenants.nix`:

| Bind | Service | Reachable under `--network host`? |
| --- | --- | --- |
| `127.0.0.1:9090` | Prometheus | Yes — same netns, same loopback |
| `127.0.0.1:9093` | Alertmanager | Yes |
| `127.0.0.1:9000`, `:9001` | MinIO (via `docker-proxy`, ci tenant) | Yes |
| `127.0.0.1:9102` | cAdvisor | Yes |
| `127.0.0.1:9130`/`9131`/`9132` | unpoller / udr-fw / docker-name exporters | Yes |
| `127.0.0.1:9100` | node_exporter | Yes |
| `0.0.0.0:8181`/`8182`/`8183`/`8189` | AC "details" sidecars (python) | Yes |
| `*:8081`–`8083`, `*:8089`, `*:9600`–`9602`/`9608` | acServer (game/http ports) | Yes |
| `192.168.1.50:3000` | Grafana | Yes |
| `192.168.1.50:445`/`139`/`873` | Samba/rsync (arcade tenant) | Yes |
| `0.0.0.0:22` | sshd | Yes (can't authenticate without a key, but can probe/fingerprint) |

Two more loopback services were found live (`127.0.0.1:18080`, `:18081`,
both `python`) that don't correspond to anything in `tenants.nix` — not
investigated further here since they're outside this task's scope, but
worth a follow-up: the tenant port registry doesn't yet account for
everything actually listening on the box.

This is the concrete shape of "the largest lateral-movement surface in the
tenancy": under `--network host`, model-generated code running as `aider`
can reach every one of these, not just the LLM endpoint it needs.

### Rootless Docker's bridge networking cannot reach a LAN-bound host service (dev box, empirically)

Tested directly on the WSL2 box (rootless Docker, `rootlesskit --net=slirp4netns
--disable-host-loopback ... --port-driver=builtin`):

```
$ docker run --rm alpine wget -qO- http://1.1.1.1          # external egress
<!DOCTYPE html>...                                          # works
$ docker run --rm alpine wget -qO- http://172.17.0.1:PORT   # docker bridge gateway -> host loopback
Connection refused                                          # blocked
```

`rootlesskit`'s `--disable-host-loopback` flag (present in the dev box's
actual invocation, confirmed via `ps aux`) is what does this — and it's a
deliberate rootless-Docker security default, not a bug. The practical
consequence: a bridge-networked container under rootless Docker can reach
the open internet, but **cannot** reach anything bound to the host itself,
loopback or LAN address alike, without explicitly weakening that flag —
which would be removing a hardening default the sandbox threat model wants
kept, not a fix.

NixOS's `virtualisation.docker.rootless` module
(`nixos/modules/virtualisation/docker-rootless.nix`, fetched and read
directly) exposes exactly four knobs: `enable`, `setSocketVariable`,
`daemon.settings`, `extraPackages`. There is no option to select `pasta` in
place of `slirp4netns`; `dockerd-rootless` hardcodes the rootlesskit
invocation. Reaching pasta would mean overriding
`systemd.user.services.docker.serviceConfig.Environment` by hand (setting
`DOCKERD_ROOTLESS_ROOTLESSKIT_NET=pasta`), unsupported by the module and
untested here — noted in the options table below as unverified, not
recommended.

**This is moot for ac-box specifically**, since ac-box runs rootful Docker
and none of rootless Docker's slirp4netns constraints apply there. It matters
for reasoning about the dev box's own default and for being honest that
"scoped bridge network" is not a universally portable answer across both
targets this module ships to.

### Rootful Docker's bridge networking on ac-box

Not directly tested by running a new container on ac-box (that would be a
state-changing `docker` command against production infrastructure, out of
bounds for this task). Verified instead via `docker network inspect` (read
only) and standard, well-documented Docker/Linux networking behavior:

- ac-box already runs three custom bridge networks
  (`ac-host_default` 172.18.0.0/16, `ac-host-ci_default` 172.19.0.0/16, plus
  the default `bridge` 172.17.0.0/16) serving the assetto and ci tenants
  today. Rootful bridge networking is not new machinery on this box — it's
  the thing already running.
- Rootful Docker containers reaching a **loopback-only** host service
  (Prometheus, Alertmanager, MinIO, cAdvisor, the exporters) is structurally
  impossible regardless of iptables: a container's `127.0.0.1` is its own
  network namespace's loopback, never the host's. This is a property of
  Linux network namespaces, not a rule that can be misconfigured away. Just
  moving off `--network host` closes this whole category — the single
  biggest item in this task's threat description — for free.
- Rootful Docker containers reaching a **wildcard (`0.0.0.0`)-bound** host
  service (the AC details sidecars, acServer, sshd) is *not* automatically
  blocked — `0.0.0.0` listens on the docker bridge's host-side interface
  too, so a bridge-networked container can typically still reach it via the
  bridge gateway address unless something explicitly denies that path. This
  is exactly what section 3's egress allowlist is for.
- Reaching an **explicit LAN address** the host owns (`services.agent-hub.llm`
  binds `192.168.1.50:8100`, never `0.0.0.0`) from a bridge-networked
  container is standard, reliable kernel-level routing on rootful Docker
  (hairpin NAT to a locally-owned address) — unlike the rootless/slirp4netns
  case above, there's no userspace proxy in the way. This is well-trodden
  Docker behavior, not something exotic to this deployment, but it has not
  been empirically re-proven on ac-box itself (would require running a
  container there) — see the verification steps in section 4 for how a
  human should confirm it during the actual cutover.

## 2. Options considered

| Option | Works under rootless Docker (dev box)? | Works under rootful Docker (ac-box)? | Real mitigation or theater? | How to verify |
| --- | --- | --- | --- | --- |
| **Scoped bridge network + egress allowlist (llama-server + github.com only)** | Reaches github.com fine (normal egress); **cannot** reach the LAN-bound llama-server by default (`--disable-host-loopback`, verified above) without deliberately weakening rootless Docker's own hardening — not a clean win here | Yes. Loopback-bound services become unreachable structurally (namespace property); wildcard-bound services and general egress need the allowlist, which rootful Docker's standard `DOCKER-USER` iptables hook supports cleanly | Real. Namespace isolation for the loopback-bound stack is a kernel guarantee, not a convention; the allowlist for the rest is standard, auditable iptables, not obscurity | `docker network inspect`, `iptables -L DOCKER-USER -n -v` / `-L AGENT-HUB-RUNNER-EGRESS -n -v` with hit counters, and a throwaway container probing an allowed vs. a disallowed destination |
| **slirp4netns (current default) or pasta for a userspace stack under rootless Docker** | slirp4netns: yes, this is what's already running, and it happens to already block host reachability by default (see above) — but that blocks the *legitimate* llama-server target too, so it "solves" isolation by breaking function, not by being scoped. pasta: NixOS's rootless module doesn't expose it; would need a systemd unit override outside the module's supported surface, untested here | N/A — ac-box doesn't run rootless Docker at all, so neither driver is in play | slirp4netns as configured: real isolation, but not *scoped* isolation (it's all-or-nothing against the host, including the one endpoint that should be reachable). pasta: unverified, can't call it either way honestly | Same canary as above (llama reachable, unlisted host not) would immediately show slirp4netns's default failing the "llama reachable" half |
| **Keep `--network host`, constrain reachability another way** (e.g. run the container as a dedicated UID and add `iptables -m owner --uid-owner` OUTPUT rules) | Would work the same as rootful, in principle — owner-match rules don't care about rootless vs. rootful | Technically implementable: cap-drop=ALL + no-new-privileges already stop the containerized process from re-executing as a different UID or regaining capabilities, so an owner-match rule *would* hold against "aider does something unwanted" | **Partly theater.** It's real defense-in-depth against the sandboxed process misbehaving on its own, but it does **not** provide network-namespace isolation: a container escape or kernel bug lands the attacker directly in the host's network namespace with all those services one hop away, no second barrier. It also requires a change not yet made — the runner image has no `USER` set, so the container currently runs as root in the container's UID space, which makes owner-match filtering meaningless as shipped today. Presented for completeness; not recommended, not implemented | Same canary, but a canary passing here means less: it only tells you the *aider process* is fenced, not that the *namespace* is |
| **Don't run the runner on ac-box at all** | N/A | N/8/A | The only option that removes the surface entirely rather than reducing it | N/A — see section 5 |

Given this, the module implements the first option, defaulting to it, and
gates `--network host` behind an explicit acknowledgement rather than
offering it as a plain toggle (task instruction: refuse rather than invent a
fix that doesn't hold, where a fix doesn't hold).

## 3. What was implemented

`modules/agent-hub.nix` gained `services.agent-hub.runner.network.*`:

- `mode` (`"bridge"` default | `"host"`). Bridge puts the sandbox on a
  dedicated Docker network (`dockerNetworkName`, default
  `agent-hub-runner`, fixed `subnet`, default `172.30.99.0/24` — chosen
  clear of every subnet actually seen on ac-box: `172.17/18/19.0.0/16`).
  `host` reproduces the previous, unrestricted behavior.
- `singleTenantHost` (default `false`). `mode = "host"` is rejected by a
  module assertion unless this is explicitly `true`. This is the "refuse
  rather than assume" mechanism the task asked for, applied to the one
  option that is genuine risk on a shared host rather than a working fix.
- `githubCidrs` (default: the four IPv4 ranges `api.github.com/meta`
  publishes under `web`/`api`/`git` as of 2026-09-07:
  `192.30.252.0/22`, `185.199.108.0/22`, `140.82.112.0/20`,
  `143.55.64.0/20`. GitHub documents these as subject to change — re-fetch
  before trusting this long-term. IPv6 is out of scope on purpose: the
  runner's Docker network never enables IPv6, so there's no v6 egress path
  to allow or restrict in the first place. Port 22 (git-over-SSH) is
  deliberately not allowed — `run-task.sh` only ever clones
  `https://github.com/...` URLs.)

When `runner.enable && network.mode == "bridge"`, the module also declares
`networking.firewall.extraCommands`/`extraStopCommands` that:

1. Create (or flush and rebuild) a chain that belongs entirely to
   agent-hub, `AGENT-HUB-RUNNER-EGRESS`: allow established/related traffic,
   allow TCP to `lanAddress:llm.port` (the actual llama-server target),
   allow DNS (53/udp+tcp, unrestricted destination — see the residual-gap
   note below), allow TCP/443 to each `githubCidrs` entry, then `DROP`
   everything else.
2. Add exactly one idempotent jump rule into Docker's own `DOCKER-USER`
   chain, matched by source subnet only: `-s <subnet> -j
   AGENT-HUB-RUNNER-EGRESS`.

`DOCKER-USER` is Docker's own documented hook for operator-added rules
(dockerd creates it once with a trailing `RETURN` and never flushes it on
daemon restart) — but it's a **global** chain shared by every Docker
consumer on the host. The implementation never flushes `DOCKER-USER` itself
or touches any rule it didn't add — only ever adds/removes its one
subnet-scoped jump — specifically so ac-host's and ac-host-ci's own
container networking can't be collaterally broken by this module's
activation or deactivation.

`scripts/run-task.sh`:

- Creates the dedicated network idempotently and uses it via
  `--network agent-hub-runner` instead of `--network host` (still supports
  `--network host` when `RUNNER_NETWORK_MODE=host`, for the gated dev-box
  case).
- Runs a **preflight canary before any model-generated code executes**:
  (1) confirm the sandbox can actually reach `LLAMA_BASE_URL` — catches a
  too-strict or unprovisioned allowlist (e.g. the Nix change landed but
  `nixos-rebuild switch` hasn't run yet) with a clear error instead of a
  confusing aider failure deep into the run; (2) confirm the sandbox
  **cannot** reach an arbitrary external host (`1.1.1.1`) outside every
  allowed range — catches a missing, too-loose, or bypassed allowlist. Both
  checks must pass or the script refuses to run the task at all. This is
  the "verify, don't assume" mechanism operating on every single invocation,
  not just at design time.

**Default enablement is unchanged**: `services.agent-hub.runner.enable`
still defaults to `false`, no host imports this module with the runner
turned on, and nothing here flips that. The new `network.mode` default only
takes effect on a host that has already turned the runner on by hand.

## 4. How to verify isolation holds (beyond the automated preflight)

The preflight canary above runs on every task and is the sanity check meant
to catch drift or misconfiguration automatically. For a human doing the
actual ac-box cutover, do this too, once, in the maintenance window (all
read/inspect, or scoped to a throwaway container — the last three lines are
the only state-changing docker commands in this whole procedure, and they're
against a disposable container, not the host):

```bash
# 1. Confirm the dedicated network exists with the expected subnet.
docker network inspect agent-hub-runner

# 2. Confirm the firewall rules actually landed.
iptables -L DOCKER-USER -n -v | grep 172.30.99.0/24
iptables -L AGENT-HUB-RUNNER-EGRESS -n -v

# 3. Run a real task, then re-check hit counters increased on the ACCEPT
#    rule for llama-server and (if it ever needed to) the github CIDRs, and
#    that the trailing DROP counter is what's absorbing everything else.
iptables -L AGENT-HUB-RUNNER-EGRESS -n -v

# 4. Prove the negative directly: from a throwaway container on the same
#    network, confirm loopback-bound services are unreachable (structural,
#    should fail regardless of iptables), confirm a wildcard-bound service
#    the allowlist doesn't cover is blocked (iptables-enforced), and confirm
#    llama-server IS reachable.
docker run --rm --network agent-hub-runner curlimages/curl -m3 http://127.0.0.1:9090/           # expect: fails (own loopback)
docker run --rm --network agent-hub-runner curlimages/curl -m3 http://172.30.99.1:8181/          # expect: blocked by DROP
docker run --rm --network agent-hub-runner curlimages/curl -m3 http://192.168.1.50:8100/v1/models # expect: succeeds
```

Re-run step 4 after any change to `githubCidrs`, `subnet`, or the llama
address/port — the allowlist is data the module generates from config, and
config drift is exactly what a canary like this exists to catch instead of
assuming the rule that looked right at write-time is still right.

## 5. What could not be made to work, and what's still open

- **A scoped bridge network does not work under the dev box's rootless
  Docker as configured** — reaching the llama-server target is blocked by
  the same `--disable-host-loopback` hardening that (correctly) blocks
  reaching everything else. The dev box is single-tenant, so it uses
  `network.mode = "host"` with `singleTenantHost = true` explicitly set,
  which is an honest, bounded use of the escape hatch rather than a fix for
  the general case.
- **The wildcard-bound AC sidecars and acServer ports are reachable from a
  bridge-networked container unless the egress allowlist explicitly blocks
  that path** — implemented here as a default-deny policy (so it's covered
  automatically, not left as a gap), but this was not empirically re-proven
  by running a container against a live ac-box, per the no-write-to-ac-box
  constraint. Section 4's step 4 is exactly the check a human should run
  once, live, before trusting it.
- **DNS egress is not destination-restricted** — allowed to any resolver on
  53/udp+tcp, because Docker's embedded DNS proxy may issue the actual
  upstream query from outside the filtered subnet depending on version, and
  getting this precisely right without breaking name resolution needs
  testing against ac-box's actual Docker version, which this task's
  constraints don't allow. This is a real, acknowledged residual gap — it
  permits hostname lookups (metadata leakage), not arbitrary payload
  delivery to a chosen host, so it does not undermine the allowlist's
  core property.
- **Two unregistered loopback services** (`127.0.0.1:18080`, `:18081`) were
  found live on ac-box during this investigation, unrelated to agent-hub and
  outside this task's scope, but not accounted for in
  `homelab/hosts/ac-box/tenants.nix`. Worth a separate follow-up.
- **pasta as a rootless-Docker alternative to slirp4netns** was not
  evaluated beyond confirming NixOS's module doesn't expose it as an option
  — a manual systemd override might make it work better for the dev-box
  case, but that's unverified and out of scope here.
- **The runner container has no `USER` set** (`nix/runner-image.nix`), so it
  runs as root-in-container today. Irrelevant to the network-namespace
  isolation implemented here, but it's what makes the "constrain
  `--network host` via UID-matched iptables" option in section 2 currently
  non-viable as shipped — noted for whoever picks that thread up later, not
  fixed in this change.

## 6. Should the runner run on ac-box at all?

Not this document's call — the task that opened this beads issue was
explicit that this is the user's decision, not something to resolve here.
What's on the table, from everything above:

- **In favor of running it there**: ac-box has the RAM for a large model
  (the entire reason Phase 1 targets it); rootful Docker's bridge networking
  is the mature, well-understood mechanism, not something exotic, and the
  isolation implemented here rests on real kernel guarantees (namespaces)
  plus standard, auditable iptables (`DOCKER-USER`) rather than obscurity.
- **Against**: ac-box is a **verified, live, multi-tenant host** serving a
  real community's race servers — even with network isolation, this is the
  least-trusted, most novel piece of software on the box (a model executing
  generated code, per the README's own account, has already rewritten a
  test to pass rather than fixing the implementation once). Sections 1 and
  5 show the isolation is real but not exhaustively re-proven live (the
  no-write constraint means the strongest verification here is design-time
  plus a dev-box empirical test, not an ac-box empirical test) — a human
  running section 4's checks once, live, is a real remaining step before
  "should work" becomes "verified working." The two unaccounted-for
  loopback services found in section 5 are a small but concrete sign the
  box's actual surface isn't fully mapped yet, independent of this task.
- **A middle option not evaluated in depth here**: running the runner on a
  separate, genuinely single-tenant host (the WSL2 dev box already
  demonstrates the pattern, just not sized for a large model) and having it
  reach ac-box's llama-server as its only cross-host dependency, trading
  ac-box's RAM advantage for removing the shared-host risk entirely. Whether
  that tradeoff is worth it is exactly the kind of call this document was
  told not to make.

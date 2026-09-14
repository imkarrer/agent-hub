# Local coding-agent host module. CPU-only LLM serving via llama.cpp, plus
# (as of 2b) a sandboxed repo+task->draft-PR runner: services.agent-hub.llm
# and services.agent-hub.runner both live here now -- this comment used to
# say the runner "lands... once the serving layer is validated," which is
# stale now that it's in this same file. See README.md for the honest,
# precondition-by-precondition account of what's actually wired up (2a/2b,
# proven out on the WSL2 dev box) versus what a real ac-box deployment (2c)
# still needs. Never bind services.agent-hub.llm past the LAN interface:
# the runner can execute model-generated code and push commits, which makes
# the whole stack a bigger target than arcade-hub.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agent-hub;

  # Which llama-server serves a model. See `llm.engine`.
  packageFor =
    engine: if engine == "ik-llama-cpp" then import ../nix/ik-llama-cpp.nix { inherit pkgs; } else pkgs.llama-cpp;

  multi = cfg.llm.models != { };

  # nixpkgs' sd.cpp has no SIMD under Nix; ../nix/stable-diffusion-cpp.nix says why.
  sdPackage = import ../nix/stable-diffusion-cpp.nix { inherit pkgs; };

  # llama-swap's config, as JSON: YAML is a superset, and this keeps the
  # generated file a pure function of the options with no templating.
  # `${PORT}` is llama-swap's own macro for the loopback port it assigns
  # each backend, substituted before the command is split into argv, so it
  # must reach the file unescaped.
  swapModel =
    name: m:
    let
      llamaCmd = lib.escapeShellArgs (
        [
          "${packageFor m.engine}/bin/llama-server"
          "--model"
          (toString m.modelPath)
          "--host"
          "127.0.0.1"
          "--ctx-size"
          (toString m.contextSize)
          "--threads"
          (toString m.threads)
        ]
        ++ cfg.llm.extraArgs
        ++ m.extraArgs
      ) + " --port \${PORT}";
      imageCmd = lib.escapeShellArgs (
        [
          "${sdPackage}/bin/sd-server"
          "--diffusion-model"
          (toString m.modelPath)
          "--listen-ip"
          "127.0.0.1"
          "-t"
          (toString m.threads)
        ]
        ++ lib.optionals (m.vae != null) [ "--vae" (toString m.vae) ]
        ++ lib.optionals (m.textEncoder != null) [ "--llm" (toString m.textEncoder) ]
        ++ m.extraArgs
      ) + " --listen-port \${PORT}";
    in
    {
      cmd = if m.kind == "image" then imageCmd else llamaCmd;
      proxy = "http://127.0.0.1:\${PORT}";
      # llama-server answers /health; sd-server has no /health but does
      # answer /v1/models once the pipeline is loaded.
      checkEndpoint = if m.kind == "image" then "/v1/models" else "/health";
      inherit (m) aliases ttl;
    };

  swapConfig = pkgs.writeText "agent-hub-llama-swap.json" (
    builtins.toJSON {
      # Loopback ports for the backends. Not a LAN allocation, so not in
      # the port registry; chosen away from anything else on 127.0.0.1.
      startPort = 18100;
      # How long a backend may take to answer its checkEndpoint after
      # start. llama-swap's default is 120 s; a cold 85 GB model read off
      # NVMe plus ik's run-time repack is under a minute on ac-box, but a
      # box under memory pressure can take longer and a timeout here is
      # a spurious "model failed to load".
      healthCheckTimeout = 600;
      models = lib.mapAttrs swapModel cfg.llm.models;
    }
  );
in
{
  options.services.agent-hub = {
    enable = lib.mkEnableOption ''
      Local coding-agent host: llama.cpp model server, LAN-only. Prototype
      target is WSL2 NixOS with a small model; deploy target is ac-box with
      256GB RAM and a much larger quantized model.
    '';

    lanAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.50";
      description = "LAN address the model server binds to. Not 0.0.0.0.";
    };

    gameInterface = lib.mkOption {
      type = lib.types.str;
      default = "enp8s0";
      description = "LAN NIC. agent-hub ports open on this interface only, matching arcade-hub.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/agent-hub";
      description = "Model weights and caches. Large GGUF files live here, never in git.";
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/agent-hub";
      description = "Runtime state: logs, future runner workspaces/secrets.";
    };

    llm = {
      enable = lib.mkEnableOption "llama.cpp OpenAI-compatible server (llama-server)";

      engine = lib.mkOption {
        type = lib.types.enum [ "llama-cpp" "ik-llama-cpp" ];
        default = "llama-cpp";
        description = ''
          Which llama-server binary runs the model. "llama-cpp" is nixpkgs'
          package (b9190 on nixos-26.05); "ik-llama-cpp" is ikawrakow's fork
          built from ../nix/ik-llama-cpp.nix. On a CPU-only host the fork's
          matrix kernels are the difference between a tool you wait on and
          one you use: on ac-box, same model, same cores, same memory
          placement, prefill 121 vs 30 tok/s and generation 12.5 vs 5.8
          (14 Sep 2026, docs/prefill-tuning.md). Every flag this module emits
          (--model, --host, --port, --ctx-size, --threads) and every flag
          ac-box passes in extraArgs exists in both binaries with the same
          meaning; fork-only flags (-rtr, -thp, -fmoe) belong in extraArgs
          and must only be set together with this engine.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = packageFor cfg.llm.engine;
        defaultText = lib.literalExpression ''pkgs.llama-cpp, or the ik_llama.cpp build when engine = "ik-llama-cpp"'';
        description = "The llama.cpp package providing bin/llama-server. Normally chosen by `engine`; override only to test a different build.";
      };


      modelPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Single-model mode: absolute path to a GGUF model file under
          dataDir, served directly by llama-server. Must be set per host
          unless `models` is non-empty, in which case this must stay null
          and every model lives in `models`.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        # This is a shared-host allocation, not a free choice: on ac-box the
        # assetto tenant reserves the contiguous HTTP block 8081-8096 (8081 +
        # 16 lobby slots). 8091 sat inside that block. 8100 is outside every
        # reserved range on that box as of the ac-box port survey -- if the
        # platform's port registry (homelab/modules/tenant/) ever claims 8100
        # for something else, this needs to move again, not just be trusted.
        default = 8100;
      };


      models = lib.mkOption {
        default = { };
        description = ''
          More than one model behind the one port, swapped on demand. When
          this is non-empty the unit runs llama-swap on `port` instead of a
          bare llama-server, and each entry here becomes a backend llama-swap
          starts on a loopback port the first time a request names it
          (`"model": "<name>"`, or any of its `aliases`) and stops when a
          different one is asked for. Every request path the tools use goes
          through unchanged -- /v1/chat/completions, /v1/messages,
          /completion, /v1/images/generations -- and llama-swap's own UI at
          /ui lists the models with a picker; /upstream/<name>/ reaches a
          backend's native UI directly.

          One model at a time is the point: on a box where one model fills
          a third of RAM and all of the fenced cores, two running at once
          would thrash. Load time between swaps is the cost, and on ac-box
          it is 20-60 s. Leave this empty for the single-model unit
          (`modelPath`), which the WSL2 prototype still uses.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                kind = lib.mkOption {
                  type = lib.types.enum [ "llama" "image" ];
                  default = "llama";
                  description = ''
                    "llama": a GGUF served by llama-server (`engine` picks
                    which build). "image": a diffusion model served by
                    stable-diffusion.cpp's sd-server, which speaks the same
                    OpenAI images API llama-swap routes.
                  '';
                };

                modelPath = lib.mkOption {
                  type = lib.types.path;
                  description = ''
                    The GGUF. For a sharded GGUF, shard 1. For kind = "image",
                    the diffusion model (sd-server's --diffusion-model);
                    `vae` and `textEncoder` carry the rest of the pipeline.
                  '';
                };

                vae = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "kind = \"image\" only: the autoencoder (sd-server --vae).";
                };

                textEncoder = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "kind = \"image\" only: the text encoder / LLM (sd-server --llm).";
                };

                engine = lib.mkOption {
                  type = lib.types.enum [ "llama-cpp" "ik-llama-cpp" ];
                  default = cfg.llm.engine;
                  defaultText = lib.literalExpression "config.services.agent-hub.llm.engine";
                  description = "kind = \"llama\" only: which llama-server build serves this model. Defaults to the unit-wide `engine`.";
                };

                contextSize = lib.mkOption {
                  type = lib.types.int;
                  default = cfg.llm.contextSize;
                  defaultText = lib.literalExpression "config.services.agent-hub.llm.contextSize";
                  description = "kind = \"llama\" only: --ctx-size for this model.";
                };

                threads = lib.mkOption {
                  type = lib.types.int;
                  default = cfg.llm.threads;
                  defaultText = lib.literalExpression "config.services.agent-hub.llm.threads";
                  description = "--threads (llama-server) or -t (sd-server). Same contract as the unit-wide `threads`: match the tier's allowance, never auto-detect.";
                };

                extraArgs = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Extra CLI args for this backend, after the ones the module emits. Same rules as the unit-wide `extraArgs`; for kind = \"image\" they are sd-server's.";
                };

                aliases = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  example = [ "claude-sonnet-4-6" ];
                  description = ''
                    Other names a request may use for this model. Useful for
                    code that hard-codes a hosted model's name: point the
                    Anthropic SDK at this port and "claude-sonnet-4-6" lands
                    here instead of 404ing. A name may alias only one model.
                  '';
                };

                ttl = lib.mkOption {
                  type = lib.types.int;
                  default = 0;
                  description = "Seconds of idleness after which llama-swap unloads this model; 0 keeps it loaded until another is requested.";
                };
              };
            }
          )
        );
      };

      imagePackage = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = sdPackage;
        defaultText = lib.literalExpression "import ../nix/stable-diffusion-cpp.nix { inherit pkgs; }";
        description = "Read-only: the stable-diffusion.cpp build image models run on (nixpkgs' package with AVX2/FMA/F16C turned on; see nix/stable-diffusion-cpp.nix).";
      };

      swapConfigFile = lib.mkOption {
        type = lib.types.package;
        readOnly = true;
        default = swapConfig;
        defaultText = lib.literalMD "the generated llama-swap config";
        description = "Read-only: the llama-swap config generated from `models`, so it can be inspected with `nix build .#nixosConfigurations.<host>.config.services.agent-hub.llm.swapConfigFile`.";
      };

      contextSize = lib.mkOption {
        type = lib.types.int;
        default = 8192;
        description = "KV cache context length. RAM-bound hosts (ac-box) can push this much higher than the WSL2 prototype.";
      };

      threads = lib.mkOption {
        type = lib.types.int;
        # 0 (like llama-server's own default of -1) means "auto-detect and
        # use every core llama.cpp can see" -- on ac-box that's all 56
        # threads, which would starve the live Assetto Corsa race servers
        # sharing the box. This default is a conservative, non-grabby
        # placeholder for standalone/dev use (WSL2 prototype box), not a
        # real capacity plan.
        #
        # On ac-box, the platform layer (homelab/modules/tenant/) is what
        # actually owns CPU allocation: it assigns this tenant a share of
        # homelab.host.capacity.cpuThreads via its tier (CPUWeight/
        # AllowedCPUs on the tenant's slice), per the "tiers are shares, not
        # absolute indices" rule. Whoever deploys this module must set this
        # option to match the CPU count that slice actually grants agent-hub
        # -- never to the host's total thread count, and never left at a
        # value picked without checking the tier assignment.
        default = 4;
        description = ''
          CPU threads for inference. Must be set to match the CPU allowance
          the platform's tenant tier actually grants this service on the
          deploy host, not left at a default guess and never llama.cpp's own
          auto-detect-all-cores behavior (0 or negative).
        '';
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Extra llama-server CLI args, e.g. [ "--flash-attn" "on" ].
          Verified against nixpkgs nixos-26.05's llama-cpp package (version
          9190, the deploy host's pin) via `llama-server --help`:
          `-fa, --flash-attn [on|off|auto]` exists and takes an "on" value.
          `--threads`, `--ctx-size`, `--host` and `--port` (used elsewhere in
          this module) all exist in that build too. Re-check this comment
          against `llama-server --help` if the pinned nixpkgs revision ever
          moves.

          With engine = "ik-llama-cpp" the same flags exist with the same
          meaning (checked against that build's `llama-server --help`, 14 Sep
          2026); `-rtr`, `-thp`, `-fmoe` and friends are ik-only and belong
          here too, but only alongside that engine.
        '';
      };
    };

    runner = {
      enable = lib.mkEnableOption ''
        Sandboxed repo+task->PR runner: aider, in a Docker container,
        pointed at services.agent-hub.llm. Phase 2a -- manually invoked
        only, no systemd service/timer yet.

        On Docker flavour, because it decides whether isolation is even
        achievable: ac-box runs ROOTFUL Docker (verified 7 Sep 2026 --
        dockerd as root, /run/docker.sock root:docker, no rootless entry
        under `docker info` security options), so a scoped bridge network
        genuinely works there. The WSL2 dev box is the rootless one, and
        its rootlesskit --disable-host-loopback hardening is what stops a
        bridged container reaching llama-server -- which is why that box,
        and only that box, opts into network.mode = "host" via
        network.singleTenantHost.
      '';

      githubTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to a file containing a GitHub PAT scoped to allowedRepos
          only, nothing broader. Decrypted via sops-nix in a real
          deployment -- this option just needs a plain readable file
          path at invocation time. No default: must be set per host.
        '';
      };

      allowedRepos = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          "owner/repo" strings this runner is allowed to touch. Defense
          in depth on top of githubTokenFile's own PAT scoping -- empty
          means nothing is allowed, not everything.
        '';
      };

      llamaBaseUrl = lib.mkOption {
        type = lib.types.str;
        default = "http://${cfg.lanAddress}:${toString cfg.llm.port}/v1";
        description = "OpenAI-compatible endpoint the runner's aider instance calls.";
      };

      runnerImage = lib.mkOption {
        type = lib.types.str;
        default = "agent-hub-runner:latest";
        description = ''
          Docker image tag for the sandbox (built via
          `nix build .#runner-image && docker load -i result`, per the
          README -- not built automatically by this module).
        '';
      };

      network = {
        mode = lib.mkOption {
          type = lib.types.enum [ "bridge" "host" ];
          default = "bridge";
          description = ''
            How the sandbox container reaches the network. See
            docs/network-isolation.md for the full analysis; the short
            version:

            "bridge" (the safe default): the container runs on a dedicated
            Docker network (network.dockerNetworkName /
            network.subnet), never the host's network namespace. A
            DOCKER-USER iptables allowlist (provisioned by this module,
            below) restricts that subnet to services.agent-hub.llm's
            address:port plus network.githubCidrs on 443, default-deny
            otherwise. Verified against ac-box's actual Docker daemon
            (rootful, not rootless -- confirmed live 7 Sep 2026 via
            `docker info` and process ownership) where standard
            veth+bridge networking is mature and reliable, including
            reaching a host-bound LAN address from a container.

            "host" gives the container the whole host network namespace,
            identical to the behaviour this option replaces. It is real
            risk on a shared host, not neutral -- see
            docs/network-isolation.md's option table -- so it is gated by
            network.singleTenantHost below rather than offered as a plain
            toggle.
          '';
        };

        singleTenantHost = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Explicit acknowledgement that this host runs no tenant other
            than agent-hub, so network.mode = "host" is not handing the
            model's sandbox reachability to services it has no business
            touching. Must be set true (by whoever writes the host config,
            never by this module's own default) before network.mode =
            "host" is accepted -- see the assertion below. Defaults false
            so an ac-box-style shared host fails closed if someone copies
            a dev-box config that used "host" without re-reading this.
          '';
        };

        dockerNetworkName = lib.mkOption {
          type = lib.types.str;
          default = "agent-hub-runner";
          description = ''
            Name of the dedicated Docker bridge network the runner uses
            when network.mode = "bridge". Never shared with another
            tenant's compose project network (e.g. ac-host_default) --
            the DOCKER-USER egress rule below is scoped to
            network.subnet specifically so it cannot accidentally apply
            to, or be evaded via, a different network on the same bridge
            driver.
          '';
        };

        subnet = lib.mkOption {
          type = lib.types.str;
          default = "172.30.99.0/24";
          description = ''
            IPv4 subnet (CIDR) for network.dockerNetworkName, and the
            source-match for the DOCKER-USER egress allowlist. Default is
            clear of every Docker subnet observed live on ac-box on 7 Sep
            2026 (`docker network inspect`): 172.17.0.0/16 (default
            bridge), 172.18.0.0/16 (ac-host_default), 172.19.0.0/16
            (ac-host-ci_default). That survey is host-specific and not
            re-verified by this module -- confirm no collision with
            `docker network inspect` before deploying to a different or
            changed host, the same way llm.port's default documents that
            it is a point-in-time allocation, not a derived value.
          '';
        };

        githubCidrs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [
            "192.30.252.0/22"
            "185.199.108.0/22"
            "140.82.112.0/20"
            "143.55.64.0/20"
          ];
          description = ''
            IPv4 CIDRs allowed outbound on tcp/443 from
            network.dockerNetworkName, sourced from
            https://api.github.com/meta's "web"/"api"/"git" keys (fetched
            7 Sep 2026 -- GitHub documents these ranges as subject to
            change, so re-fetch and update before trusting this list
            long-term). IPv6 is deliberately out of scope: the runner's
            Docker network is IPv4-only (Docker user-defined bridges
            don't get IPv6 unless explicitly enabled, and this module
            never does), so there is no v6 egress path to allow or block.
            tcp/22 (git-over-SSH) is not included -- run-task.sh only
            ever clones "https://github.com/..." URLs, so allowing SSH
            egress here would be a permission this runner has no use for.
          '';
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.agent-hub = { };
    users.users.agent-hub = {
      isSystemUser = true;
      group = "agent-hub";
      home = cfg.stateDir;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 agent-hub agent-hub -"
      "d ${cfg.dataDir}/models 0750 agent-hub agent-hub -"
      "d ${cfg.stateDir} 0750 agent-hub agent-hub -"
    ];

    # Interface-scoped only, same reasoning as arcade-hub: never global
    # allowedTCPPorts, and never forward these past the LAN.
    networking.firewall.interfaces.${cfg.gameInterface} = {
      allowedTCPPorts = lib.optional cfg.llm.enable cfg.llm.port;
    };

    systemd.services.agent-hub-llm = lib.mkIf cfg.llm.enable {
      description =
        if multi then
          "agent-hub model server: llama-swap over ${toString (builtins.length (builtins.attrNames cfg.llm.models))} models (LAN only)"
        else
          "agent-hub llama.cpp model server (LAN only)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "agent-hub";
        Group = "agent-hub";
        # Multi-model: llama-swap owns the port and starts the backends as
        # its own children, so everything a host sets on this unit -- the
        # slice, the cpuset, the NUMA policy -- is inherited by whichever
        # model is loaded. Single-model: llama-server on the port directly.
        ExecStart =
          if multi then
            lib.escapeShellArgs [
              "${pkgs.llama-swap}/bin/llama-swap"
              "-config"
              "${swapConfig}"
              "-listen"
              "${cfg.lanAddress}:${toString cfg.llm.port}"
            ]
          else
            lib.escapeShellArgs (
              [
                "${cfg.llm.package}/bin/llama-server"
                "--model"
                (toString cfg.llm.modelPath)
                "--host"
                cfg.lanAddress
                "--port"
                (toString cfg.llm.port)
                "--ctx-size"
                (toString cfg.llm.contextSize)
                "--threads"
                (toString cfg.llm.threads)
              ]
              ++ cfg.llm.extraArgs
            );
        # llama-swap stops its backends itself on SIGTERM; give a model
        # mid-load time to die cleanly before systemd escalates.
        TimeoutStopSec = lib.mkIf multi 90;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };


    environment.systemPackages = lib.optional cfg.runner.enable (
      pkgs.writeShellApplication {
        name = "agent-hub-run-task";
        runtimeInputs = [ pkgs.docker pkgs.gnused ];
        text = ''
          repo_url="''${1:?usage: agent-hub-run-task <repo-url> <task> [base-branch] [test-cmd]}"

          owner_repo=$(echo "$repo_url" | sed -E 's#^https://github.com/##; s#\.git$##')
          allowed_repos=(${lib.concatStringsSep " " (map lib.escapeShellArg cfg.runner.allowedRepos)})
          allowed=0
          for r in "''${allowed_repos[@]}"; do
            [ "$owner_repo" = "$r" ] && allowed=1
          done
          if [ "$allowed" != 1 ]; then
            echo "refusing: '$owner_repo' is not in services.agent-hub.runner.allowedRepos" >&2
            exit 1
          fi

          export GITHUB_TOKEN
          GITHUB_TOKEN="$(cat ${lib.escapeShellArg (toString cfg.runner.githubTokenFile)})"
          export GH_TOKEN="$GITHUB_TOKEN"
          export LLAMA_BASE_URL=${lib.escapeShellArg cfg.runner.llamaBaseUrl}
          export RUNNER_IMAGE=${lib.escapeShellArg cfg.runner.runnerImage}
          export RUNNER_NETWORK_MODE=${lib.escapeShellArg cfg.runner.network.mode}
          export RUNNER_NETWORK_NAME=${lib.escapeShellArg cfg.runner.network.dockerNetworkName}
          export RUNNER_NETWORK_SUBNET=${lib.escapeShellArg cfg.runner.network.subnet}
          exec ${../scripts/run-task.sh} "$@"
        '';
      }
    );

    # Egress allowlist for services.agent-hub.runner.network.mode = "bridge",
    # the safe default. See docs/network-isolation.md for why this shape
    # (DOCKER-USER + a dedicated jump chain, not --network host) and how to
    # verify it actually holds rather than trust it by reading this file.
    #
    # DOCKER-USER is dockerd's own documented hook for operator-added rules:
    # dockerd creates it once (with a trailing `-j RETURN` so unmatched
    # traffic falls through to Docker's normal processing) and never flushes
    # it on daemon restart, but it is a GLOBAL chain shared by every Docker
    # consumer on the box (ac-host_default, ac-host-ci_default, ...) -- so
    # this must never flush DOCKER-USER itself, only ever add one idempotent
    # jump rule scoped by source subnet into a chain that belongs entirely to
    # agent-hub. Flushing DOCKER-USER outright would also delete dockerd's own
    # trailing RETURN and could break every other tenant's container
    # networking on the same host.
    networking.firewall.extraCommands = lib.mkIf (cfg.runner.enable && cfg.runner.network.mode == "bridge") ''
      iptables -N AGENT-HUB-RUNNER-EGRESS 2>/dev/null || true
      iptables -F AGENT-HUB-RUNNER-EGRESS

      # Return traffic for connections this chain already allowed out.
      iptables -A AGENT-HUB-RUNNER-EGRESS -m state --state ESTABLISHED,RELATED -j ACCEPT

      # The one thing this sandbox actually needs to talk to.
      iptables -A AGENT-HUB-RUNNER-EGRESS -p tcp -d ${lib.escapeShellArg cfg.lanAddress} --dport ${toString cfg.llm.port} -j ACCEPT

      # DNS, unrestricted by destination: needed to resolve github.com, and
      # not filtered further because Docker's embedded resolver may issue
      # the upstream query from outside this subnet depending on version.
      # Residual gap, not a hole: this permits hostname lookups, not
      # arbitrary TCP/UDP payload delivery to a chosen host.
      iptables -A AGENT-HUB-RUNNER-EGRESS -p udp --dport 53 -j ACCEPT
      iptables -A AGENT-HUB-RUNNER-EGRESS -p tcp --dport 53 -j ACCEPT

      # GitHub only, HTTPS only (run-task.sh never clones over SSH).
      ${lib.concatMapStringsSep "\n" (cidr: ''
        iptables -A AGENT-HUB-RUNNER-EGRESS -p tcp -d ${lib.escapeShellArg cidr} --dport 443 -j ACCEPT
      '') cfg.runner.network.githubCidrs}

      # Default deny: this is what makes it an allowlist. Also the property
      # the run-task.sh preflight canary checks on every invocation.
      iptables -A AGENT-HUB-RUNNER-EGRESS -j DROP

      iptables -C DOCKER-USER -s ${lib.escapeShellArg cfg.runner.network.subnet} -j AGENT-HUB-RUNNER-EGRESS 2>/dev/null || \
        iptables -I DOCKER-USER 1 -s ${lib.escapeShellArg cfg.runner.network.subnet} -j AGENT-HUB-RUNNER-EGRESS
    '';

    networking.firewall.extraStopCommands = lib.mkIf (cfg.runner.enable && cfg.runner.network.mode == "bridge") ''
      iptables -D DOCKER-USER -s ${lib.escapeShellArg cfg.runner.network.subnet} -j AGENT-HUB-RUNNER-EGRESS 2>/dev/null || true
      iptables -F AGENT-HUB-RUNNER-EGRESS 2>/dev/null || true
      iptables -X AGENT-HUB-RUNNER-EGRESS 2>/dev/null || true
    '';

    assertions = lib.optionals cfg.llm.enable [
      {
        assertion = multi -> cfg.llm.modelPath == null;
        message = "services.agent-hub.llm: set either modelPath (single model) or models (llama-swap), not both.";
      }
      {
        assertion = multi || cfg.llm.modelPath != null;
        message = "services.agent-hub.llm: modelPath must be set when models is empty.";
      }
      {
        assertion = lib.all (m: m.kind == "llama" || m.vae != null) (lib.attrValues cfg.llm.models);
        message = "services.agent-hub.llm.models: an image model needs a vae.";
      }
      {
        assertion =
          let
            names = lib.concatMap (m: m.aliases) (lib.attrValues cfg.llm.models) ++ lib.attrNames cfg.llm.models;
          in
          lib.length names == lib.length (lib.unique names);
        message = "services.agent-hub.llm.models: model names and aliases must be unique across all models.";
      }

    ] ++ [
      {
        assertion = cfg.lanAddress != "0.0.0.0";
        message = "services.agent-hub.lanAddress must be the LAN IP, not 0.0.0.0.";
      }
      {
        assertion = !cfg.runner.enable || cfg.runner.githubTokenFile != null;
        message = "services.agent-hub.runner.githubTokenFile must be set when the runner is enabled.";
      }
      {
        assertion = !cfg.runner.enable || cfg.runner.allowedRepos != [ ];
        message = "services.agent-hub.runner.allowedRepos must be non-empty when the runner is enabled -- it defaults closed, not open.";
      }
      {
        assertion = !cfg.runner.enable || cfg.runner.network.mode != "host" || cfg.runner.network.singleTenantHost;
        message = ''
          services.agent-hub.runner.network.mode = "host" gives the sandbox
          the entire host network namespace -- every other tenant's
          loopback- and wildcard-bound service included. Refusing to enable
          it unless services.agent-hub.runner.network.singleTenantHost is
          also set true, an explicit acknowledgement that no other tenant
          shares this host. See docs/network-isolation.md.
        '';
      }
    ];
  };
}

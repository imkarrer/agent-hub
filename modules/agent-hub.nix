# Local coding-agent host module -- the SKELETON of the tenant, not the
# tenant. Since homelab ADR 0009 step 1 (18 Sep 2026) what runs behind
# agent-hub-llm.service on ac-box is this repo's flox environment
# (.flox/env/manifest.toml, llama-swap.yaml): the unit's ExecStart is
# `flox activate -d /var/lib/agent-hub/env -- llama-swap ...`, set by
# homelab's unit stub (homelab.tenants.agent-hub.environment.units
# ."agent-hub-llm.service" in hosts/ac-box/configuration.nix, rendered by
# homelab/modules/tenant/environment.nix), which mkForces ExecStart and
# passes the seven AGENT_HUB_* variables the manifest's hook reads.
#
# What this module still owns, and the stub relies on: the agent-hub user
# and group, the data and state directories, the firewall rule on the LAN
# interface, the unit's existence -- name, description, After=/Wants=,
# User=/Group=, Restart=/RestartSec=, TimeoutStopSec= -- so the contract
# (homelab tenants.nix) has a unit to slice and the stub has a unit to
# redirect; the nginx landing page and qdrant, which the environment does
# not provide (homelab-158.11 decides their shape); and the runner
# (services.agent-hub.runner, off everywhere; a Docker image, see its
# options). What it no longer does: generate the llama-swap table or an
# ExecStart that runs a model. The table is llama-swap.yaml; the ExecStart
# here is a placeholder that exits 1 naming the stub, never a unit that
# quietly serves the old way.
#
# The llm.* options below split accordingly. HOST FACTS the stub reads
# (threads, contextSize, port, landingPage, lanAddress, dataDir,
# backendPort) keep their declarations and defaults because
# hosts/ac-box/configuration.nix reads them from this option set to fill
# the stub's environment -- one spelling per value, which is what keeps
# the module and the stub from drifting while both are live. TABLE FIELDS
# (engine, extraArgs, concurrent, and a model's modelPath, vae,
# textEncoder, aliases, extraArgs, contextSize) are read by nothing; they
# stay declared only because ac-box's configuration still sets them, and
# they leave with that block (homelab-158.11). A model's kind and
# description are live: the landing page's models.json is built from them.
#
# Never bind services.agent-hub.llm past the LAN interface: the runner can
# execute model-generated code and push commits, which makes the whole
# stack a bigger target than arcade-hub.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.agent-hub;

  multi = cfg.llm.models != { };

  # What the landing page says beside a model. The UI lists every model on
  # every playground tab and cannot know a model's kind; the description is
  # where a person learns which tab. The same text llama-swap.yaml carries
  # per model, so the page and /v1/models agree.
  modelDescription =
    name: m:
    if m.description != "" then m.description
    else if m.kind == "image" then "image generation -- use the Images tab (or /upstream/${name}/); it has no chat endpoint"
    else if m.kind == "embedding" then "embeddings -- POST /v1/embeddings; it has no chat endpoint and no UI"
    else "text -- use the Chat tab";

  landingDir = pkgs.runCommand "agent-hub-landing" { } ''
    mkdir -p $out
    cp ${../nix/index.html} $out/index.html
    cp ${pkgs.writeText "models.json" (
      builtins.toJSON (
        lib.mapAttrs (name: m: {
          inherit (m) kind;
          description = modelDescription name m;
        }) cfg.llm.models
      )
    )} $out/models.json
  '';

  # The unit's ExecStart when no stub has replaced it. Exits 1 and says why
  # on every start (Restart=on-failure makes that a loud 5 s loop in the
  # journal), never a `true` that leaves a unit "active" with nothing on
  # the port. With the stub on, this value is mkForce'd away and the script
  # is not in the closure.
  unstubbed = pkgs.writeShellScript "agent-hub-llm-unstubbed" ''
    echo "agent-hub-llm.service: modules/agent-hub.nix no longer runs the model server (homelab ADR 0009)." >&2
    echo "ExecStart is set by homelab's unit stub -- homelab.tenants.agent-hub.environment.units.\"agent-hub-llm.service\" in hosts/ac-box/configuration.nix -- which activates this tenant's flox environment. That stub is not enabled on this host." >&2
    exit 1
  '';
in
{
  options.services.agent-hub = {
    enable = lib.mkEnableOption ''
      Local coding-agent host, LAN-only: the agent-hub user, its
      directories, the firewall rule, the model server's unit skeleton (the
      process itself comes from the flox environment via homelab's stub),
      the landing page and the vector store.
    '';

    lanAddress = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.50";
      description = ''
        LAN address the tenant's ports bind to. Not 0.0.0.0. Host fact:
        homelab's stub builds AGENT_HUB_LISTEN from it (with `llm.port`,
        unless `llm.landingPage` puts nginx on it and llama-swap on
        loopback); nginx and qdrant bind it directly.
      '';
    };

    gameInterface = lib.mkOption {
      type = lib.types.str;
      default = "enp8s0";
      description = "LAN NIC. agent-hub ports open on this interface only, matching arcade-hub.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/srv/agent-hub";
      description = ''
        Model weights and caches. Large GGUF files live here, never in git.
        Host fact: homelab's stub sets AGENT_HUB_MODELS = <dataDir>/models,
        the directory llama-swap.yaml's `''${models}` macro names; this module
        creates it.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/agent-hub";
      description = ''
        Runtime state. On ac-box <stateDir>/env is the tenant's checked-out
        flox environment (homelab derives the stub's `dir` from the tenant's
        first state dir), so this is also where AGENT_HUB_SWAP_CONFIG
        (<env>/llama-swap.yaml) and AGENT_HUB_ASSETS (<env>/nix) point.
      '';
    };

    llm = {
      enable = lib.mkEnableOption ''
        the model server's unit, agent-hub-llm.service: the skeleton
        (name, user, restart policy, ordering) that homelab's stub redirects
        into the flox environment. Without the stub the unit exists and
        fails on start, naming the stub -- this module runs no model
      '';

      # -- Table fields: read by nothing. --------------------------------
      # The llama-swap table is llama-swap.yaml in this repo; the flags,
      # engine, aliases and concurrency set these options used to become
      # are spelled there. hosts/ac-box/configuration.nix still sets them
      # (with the reasoning for each value in its comments), which is the
      # only reason they are declared: an option set but undeclared is an
      # evaluation error. They go when that block goes (homelab-158.11).

      engine = lib.mkOption {
        type = lib.types.enum [ "llama-cpp" "ik-llama-cpp" ];
        default = "llama-cpp";
        description = ''
          Table field, read by nothing: which llama-server the manifest
          installs is `ik-llama-cpp.flake` in .flox/env/manifest.toml
          (ikawrakow's fork, this repo's nix/ik-llama-cpp.nix; the 4-5x on
          a CPU host is in docs/prefill-tuning.md).
        '';
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Table field, read by nothing: the flags every llama backend gets
          are llama-swap.yaml's `llama_extra` macro.
        '';
      };

      concurrent = lib.mkOption {
        type = lib.types.listOf (lib.types.listOf lib.types.str);
        default = [ ];
        example = [ [ "coder" "instruct" ] ];
        description = ''
          Table field, read by nothing: which models may stay resident
          together is llama-swap.yaml's `matrix` block.
        '';
      };

      modelPath = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Single-model mode's GGUF, read by nothing: the environment always
          runs llama-swap over llama-swap.yaml. Kept because the unit's shape
          (its description, TimeoutStopSec) still follows whether `models` is
          empty, and the assertion pair on the two keeps that meaningful.
          Null on ac-box.
        '';
      };

      # -- Host facts: homelab's stub reads these. -----------------------

      port = lib.mkOption {
        type = lib.types.port;
        # This is a shared-host allocation, not a free choice: on ac-box the
        # assetto tenant reserves the contiguous HTTP block 8081-8096 (8081 +
        # 16 lobby slots). 8091 sat inside that block. 8100 is outside every
        # reserved range on that box as of the ac-box port survey -- if the
        # platform's port registry (homelab/modules/tenant/) ever claims 8100
        # for something else, this needs to move again, not just be trusted.
        default = 8100;
        description = ''
          The LAN port. Host fact: homelab's stub builds AGENT_HUB_LISTEN from
          it (see `lanAddress`); this module opens it on `gameInterface` and,
          with `landingPage`, binds nginx to it.
        '';
      };

      backendPort = lib.mkOption {
        type = lib.types.port;
        default = 18100;
        description = ''
          Where llama-swap's loopback backends start (llama-swap.yaml's
          `startPort`, one port per model upward). Not a LAN allocation, so
          not in homelab's port registry; chosen away from anything else on
          127.0.0.1. Host fact: the value homelab's stub passes as
          AGENT_HUB_BACKEND_PORT (today a literal there equal to this default;
          this option is where it should be read from).
        '';
      };

      contextSize = lib.mkOption {
        type = lib.types.int;
        default = 8192;
        description = ''
          KV cache context length for the chat models. Host fact: homelab's
          stub passes it as AGENT_HUB_CTX (llama-swap.yaml's `ctx` macro; the
          embedding model has its own 8192 there). RAM-bound hosts (ac-box)
          can push this much higher than the WSL2 prototype.
        '';
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
          CPU threads for inference. Host fact: homelab's stub passes it as
          AGENT_HUB_THREADS (llama-swap.yaml's `threads` macro, every
          backend). Must be set to match the CPU allowance the platform's
          tenant tier actually grants this service on the deploy host, not
          left at a default guess and never llama.cpp's own
          auto-detect-all-cores behavior (0 or negative).
        '';
      };

      landingPage = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Multi-model mode only. Put nginx on `lanAddress`:`port` serving
          nix/index.html at / -- chat models and image models listed apart,
          each linking to its backend's own UI -- and proxying everything
          else to llama-swap, which then listens on 127.0.0.1:`port` instead.
          Host fact: homelab's stub reads it to decide AGENT_HUB_LISTEN
          (loopback with nginx in front, the LAN address without).
          llama-swap's own /ui stays reachable; it just is not the front
          door, because it lists every model on every playground tab. Adds
          nginx.service to the host; a tenant contract that slices units by
          name must be told.
        '';
      };

      models = lib.mkOption {
        default = { };
        description = ''
          The models behind the one port, by name. Two things are live: the
          set being non-empty (the unit's description says how many, and
          TimeoutStopSec gives llama-swap time to stop a backend), and each
          model's `kind` and `description`, from which the landing page's
          models.json is built so nix/index.html can list chat models and
          image models apart. Everything else a model carries -- the GGUF,
          the pipeline files, flags, aliases -- is the table's, and the table
          is llama-swap.yaml. Names here must match the names there for the
          landing page to link to the right backend; nothing checks that.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                kind = lib.mkOption {
                  type = lib.types.enum [ "llama" "image" "embedding" ];
                  default = "llama";
                  description = ''
                    "llama": a chat model (llama-server). "image": a
                    diffusion model (stable-diffusion.cpp's sd-server, the
                    same OpenAI images API llama-swap routes). "embedding":
                    /v1/embeddings and nothing else. Read by the landing
                    page, which puts each kind on its own tab.
                  '';
                };

                description = lib.mkOption {
                  type = lib.types.str;
                  default = "";
                  description = "Shown beside the model on the landing page. Empty means a per-kind default that says which playground tab the model belongs on. llama-swap.yaml carries the same text for /v1/models.";
                };

                # Table fields, read by nothing (see the note on `engine`).
                modelPath = lib.mkOption {
                  type = lib.types.path;
                  description = "Table field, read by nothing: the GGUF is llama-swap.yaml's `--model` / `--diffusion-model` under `\${models}`.";
                };

                vae = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "Table field, read by nothing: llama-swap.yaml's `--vae`.";
                };

                textEncoder = lib.mkOption {
                  type = lib.types.nullOr lib.types.path;
                  default = null;
                  description = "Table field, read by nothing: llama-swap.yaml's `--llm`.";
                };

                contextSize = lib.mkOption {
                  type = lib.types.int;
                  default = cfg.llm.contextSize;
                  defaultText = lib.literalExpression "config.services.agent-hub.llm.contextSize";
                  description = "Table field, read by nothing: a per-model `--ctx-size` is written literally in llama-swap.yaml (the embedding model's 8192).";
                };

                extraArgs = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  description = "Table field, read by nothing: a backend's own flags are in its `cmd` in llama-swap.yaml.";
                };

                aliases = lib.mkOption {
                  type = lib.types.listOf lib.types.str;
                  default = [ ];
                  example = [ "claude-sonnet-4-6" ];
                  description = "Table field, read by nothing: llama-swap.yaml's `aliases` per model.";
                };
              };
            }
          )
        );
      };
    };

    vectors = {
      enable = lib.mkEnableOption ''
        Qdrant beside the model server: the vector store an embedding model
        (llm.models.<name>.kind = "embedding") writes into and agents search.
        nixpkgs' services.qdrant, bound to lanAddress on `port` like the
        model server and nothing wider; gRPC stays off, so one port. Adds
        qdrant.service to the host, with its state in /var/lib/qdrant (the
        module's StateDirectory; a tenant contract that lists units and
        state paths by name must be told both). Memory is where it spends:
        the HNSW index lives in RAM, the vectors and payloads on disk.
      '';

      port = lib.mkOption {
        type = lib.types.port;
        default = 6333;
        description = "Qdrant's HTTP port on lanAddress. Its upstream default; a shared host's port registry must claim it.";
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
      allowedTCPPorts =
        lib.optional cfg.llm.enable cfg.llm.port
        ++ lib.optional cfg.vectors.enable cfg.vectors.port;
    };

    # The unit skeleton. Every key here except ExecStart is what the box
    # runs today and what homelab's stub leaves alone (its module writes
    # only ExecStart and the environment); the host adds its own
    # AllowedCPUs/NUMAPolicy and the contract adds Slice=/Nice=. Change a
    # key here and the live unit changes -- the ADR's "fifteen lines where
    # a module was" are these, until homelab-158.11 moves them into the stub.
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
        # llama-swap owns the port and starts the backends as its own
        # children, so everything a host sets on this unit -- the slice, the
        # cpuset, the NUMA policy -- is inherited by whichever model is
        # loaded. The stub's `flox activate -d <env> -- llama-swap ...`
        # exec's into llama-swap, so that holds from the environment too.
        # Without the stub: the placeholder above, which refuses and says so.
        ExecStart = "${unstubbed}";
        # llama-swap stops its backends itself on SIGTERM; give a model
        # mid-load time to die cleanly before systemd escalates.
        TimeoutStopSec = lib.mkIf multi 90;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };


    services.nginx = lib.mkIf (cfg.llm.enable && cfg.llm.landingPage) {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts."agent-hub" = {
        listen = [ { addr = cfg.lanAddress; port = cfg.llm.port; } ];
        # The page plus a models.json saying which model is which kind,
        # from the same options the llama-swap config comes from.
        locations."= /" = {
          root = landingDir;
          tryFiles = "/index.html =404";
        };
        locations."= /models.json" = {
          root = landingDir;
          extraConfig = "default_type application/json;";
        };
        locations."/" = {
          proxyPass = "http://127.0.0.1:${toString cfg.llm.port}";
          proxyWebsockets = true;
          # Answers stream (chat tokens, llama-swap's SSE at /api/events)
          # and take minutes (an image is minutes of CPU; a 32k prompt is
          # minutes of prefill): no buffering, and timeouts that outlast
          # any single request. Image edits upload an image.
          extraConfig = ''
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_read_timeout 3600s;
            proxy_send_timeout 3600s;
            client_max_body_size 64m;
          '';
        };
      };
    };

    services.qdrant = lib.mkIf cfg.vectors.enable {
      enable = true;
      settings.service = {
        host = cfg.lanAddress;
        http_port = cfg.vectors.port;
        # null is how qdrant's own config.yaml spells "no gRPC listener";
        # the NixOS module defaults it to 6334, which would be a second
        # LAN port nothing here speaks.
        grpc_port = null;
      };
      # The module's other defaults stand: state under /var/lib/qdrant,
      # HNSW in RAM, payloads on disk, telemetry off, and qdrant-web-ui at
      # /dashboard on the same port for looking at collections by hand.
    };

    # Binding lanAddress means waiting for it: nixpkgs' unit orders after
    # network.target only, and at boot on 16 Sep 2026 qdrant hit its start
    # limit in 200 ms with "Cannot assign requested address" before
    # NetworkManager had the address up. Every earlier switch had found the
    # address already there. Same two lines the model server carries above.
    systemd.services.qdrant = lib.mkIf cfg.vectors.enable {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
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
        assertion = cfg.llm.landingPage -> multi;
        message = "services.agent-hub.llm.landingPage needs models (multi-model mode); the single-model unit serves llama-server's own UI.";
      }
      # The table's own consistency (an image model needs a vae, aliases are
      # unique, concurrent names models) is llama-swap's to check at load --
      # it refuses a bad llama-swap.yaml -- and scripts/ci_test.sh's to prove.
    ] ++ [
      {
        assertion = cfg.lanAddress != "0.0.0.0";
        message = "services.agent-hub.lanAddress must be the LAN IP, not 0.0.0.0.";
      }
      {
        assertion = cfg.vectors.enable -> cfg.llm.enable;
        message = "services.agent-hub.vectors is the store for llm's embedding model; it makes no sense without llm.enable.";
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

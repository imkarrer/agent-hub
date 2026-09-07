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

      modelPath = lib.mkOption {
        type = lib.types.path;
        description = "Absolute path to a GGUF model file under dataDir. No default -- must be set per host.";
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
        '';
      };
    };

    runner = {
      enable = lib.mkEnableOption ''
        Sandboxed repo+task->PR runner: aider, in a rootless Docker
        container, pointed at services.agent-hub.llm. Phase 2a --
        manually invoked only, no systemd service/timer yet.
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
      description = "agent-hub llama.cpp model server (LAN only)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        User = "agent-hub";
        Group = "agent-hub";
        ExecStart = lib.escapeShellArgs (
          [
            "${pkgs.llama-cpp}/bin/llama-server"
            "--model"
            cfg.llm.modelPath
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
          exec ${../scripts/run-task.sh} "$@"
        '';
      }
    );

    assertions = [
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
    ];
  };
}

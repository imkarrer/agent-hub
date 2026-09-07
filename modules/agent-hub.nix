# Local coding-agent host module. CPU-only LLM serving via llama.cpp.
# Phase 1 (this module): the model server only. No agent harness, no
# repo/GitHub access yet -- that lands as services.agent-hub.runner once
# the serving layer is validated. Never bind this past the LAN interface:
# the runner phase will be able to execute code and push commits, which
# makes the whole stack a bigger target than arcade-hub.
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
        default = 8091;
      };

      contextSize = lib.mkOption {
        type = lib.types.int;
        default = 8192;
        description = "KV cache context length. RAM-bound hosts (ac-box) can push this much higher than the WSL2 prototype.";
      };

      threads = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = "CPU threads for inference. 0 lets llama.cpp auto-detect.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Extra llama-server CLI args, e.g. [ \"--flash-attn\" \"on\" ].";
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

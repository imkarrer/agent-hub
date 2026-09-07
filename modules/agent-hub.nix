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

    assertions = [
      {
        assertion = cfg.lanAddress != "0.0.0.0";
        message = "services.agent-hub.lanAddress must be the LAN IP, not 0.0.0.0.";
      }
    ];
  };
}

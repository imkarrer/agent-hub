{
  description = "Local coding-agent host: CPU/RAM-bound LLM serving + agent harness. Prototype on WSL2 NixOS, deploy to ac-box.";

  inputs = {
    # Pinned to match the deploy host (ac-box, nixos-26.05), not unstable --
    # the module is written and verified against that channel's llama-cpp
    # (version 9190). This pin only governs standalone use of this repo
    # (`nix build`, `nix flake check`, `nix develop` here). The platform
    # layer (homelab) owns nixpkgs for the actual deployment: when this flake
    # is consumed as a tenant input there, it sets
    # `inputs.agent-hub.inputs.nixpkgs.follows = "nixpkgs"` so agent-hub
    # never drags its own nixpkgs into the host closure. Do not bump this
    # independently of that host's channel.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      # No nixosModules since 18 Sep 2026 (homelab-158.11): the box runs this
      # tenant from .flox/ (ADR 0009), and the unit skeleton lives in homelab
      # (hosts/ac-box/tenants/agent-hub.nix). This flake exists for the
      # package the manifest installs by `.flake` reference (ik_llama.cpp;
      # stable-diffusion.cpp left with the image models, homelab-b9u), and for
      # `nix flake check` in CI.
      packages.${system} = {
        runner-image = import ./nix/runner-image.nix { inherit pkgs; };
        ik-llama-cpp = import ./nix/ik-llama-cpp.nix { inherit pkgs; };
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          llama-cpp
          curl
          jq
          git
        ];
        shellHook = ''
          echo "agent-hub dev shell: llama-server available. See scripts/ for model fetch + serve helpers."
        '';
      };
    };
}

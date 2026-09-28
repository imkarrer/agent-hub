{
  description = "Local coding-agent host: CPU/RAM-bound LLM serving + agent harness. Prototype on WSL2 NixOS, deploy to llm-box.";

  inputs = {
    # Pinned to match the deploy host (llm-box, nixos-26.05), not unstable.
    # Since homelab-158.11 (18 Sep 2026) this flake is no input of homelab
    # and reaches no closure. The pin is the nixpkgs of this repo's own
    # outputs: `nix build`, `nix flake check`, `nix develop` here, and the
    # ik-llama-cpp the flox environment installs by `.flake` reference --
    # built by this lock, not the host's (ADR 0009). A bump therefore
    # changes that derivation once `flox upgrade ik-llama-cpp` re-locks it,
    # and llm-box's environment pull realises the lock's outputs
    # substitute-only (homelab modules/tenant/environment-pull.nix), so a
    # binary no cache it trusts holds is refused there, not built. Do not
    # bump this independently of that host's channel.
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
      # (hosts/llm-box/tenants/agent-hub.nix). This flake exists for the
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

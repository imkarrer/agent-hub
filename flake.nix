{
  description = "Local coding-agent host: CPU/RAM-bound LLM serving + agent harness. Prototype on WSL2 NixOS, deploy to ac-box.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in
    {
      nixosModules.agent-hub = import ./modules/agent-hub.nix;
      nixosModules.default = self.nixosModules.agent-hub;

      packages.${system}.runner-image = import ./nix/runner-image.nix { inherit pkgs; };

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

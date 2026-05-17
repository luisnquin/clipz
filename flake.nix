{
  description = "Wayland clipboard history manager with TTL and ephemeral mode";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    systems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
    forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (pkgs: rec {
      cliphizt = pkgs.callPackage ./nix/package.nix {};
      default = cliphizt;
    });

    homeManagerModules = {
      cliphizt = import ./nix/hm-module.nix self;
      default = self.homeManagerModules.cliphizt;
    };

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        nativeBuildInputs = [
          pkgs.zig_0_16
        ];
      };
    });
  };
}

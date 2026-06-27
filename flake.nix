{
  description = "clipz — Wayland clipboard stack: cliphizt storage and cliplenz native viewer";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    lib = nixpkgs.lib;
    allSystems = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
    forAllSystems = f: lib.genAttrs allSystems (system: f nixpkgs.legacyPackages.${system});
  in {
    packages = forAllSystems (pkgs: let
      cliphizt = pkgs.callPackage ./cliphizt/package.nix {};
    in
      {
        inherit cliphizt;
        default = cliphizt;
      }
      # cliplenz is a Wayland layer-shell GUI: Linux only.
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        cliplenz = pkgs.callPackage ./cliplenz/package.nix {};
      });

    homeManagerModules = {
      cliphizt = import ./nix/hm-module.nix self;
      default = self.homeManagerModules.cliphizt;
    };

    devShells = forAllSystems (pkgs:
      {
        cliphizt = pkgs.mkShell {
          nativeBuildInputs = [pkgs.zig_0_16];
        };
        default = self.devShells.${pkgs.stdenv.hostPlatform.system}.cliphizt;
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        cliplenz = pkgs.mkShell {
          inputsFrom = [self.packages.${pkgs.stdenv.hostPlatform.system}.cliplenz];
          packages = with pkgs; [rustfmt clippy rust-analyzer];
          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
        };
      });
  };
}

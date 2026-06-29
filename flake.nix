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
    forAllSystems = f: lib.genAttrs allSystems (system: f (nixpkgs.legacyPackages.${system}.extend self.overlays.default));
  in {
    overlays.default = final: prev:
      {
        cliphizt = final.callPackage ./cliphizt/package.nix {};
      }
      # cliplenz is a Wayland layer-shell GUI: Linux only.
      // lib.optionalAttrs prev.stdenv.hostPlatform.isLinux {
        cliplenz = final.callPackage ./cliplenz/package.nix {};
      };

    packages = forAllSystems (pkgs:
      {
        inherit (pkgs) cliphizt;
        default = pkgs.cliphizt;
      }
      // lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        inherit (pkgs) cliplenz;
      });

    homeManagerModules = {
      cliphizt = import ./nix/hm-module.nix self;
      cliplenz = import ./nix/cliplenz-hm-module.nix self;
      default = {
        imports = [
          self.homeManagerModules.cliphizt
          self.homeManagerModules.cliplenz
        ];
      };
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
          inputsFrom = [pkgs.cliplenz];
          packages = with pkgs; [rustfmt clippy rust-analyzer];
          RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
        };
      });
  };
}

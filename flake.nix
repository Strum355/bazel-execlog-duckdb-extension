{
  description = "DuckDB extension template for Zig";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";
  };

  outputs = { self, nixpkgs, ... }: let
    forAllSystems = function:
      nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ] (system: function nixpkgs.legacyPackages.${system});
    in {
      packages =  nixpkgs.lib.recursiveUpdate (forAllSystems (pkgs: {
        default = pkgs.callPackage ./extension.nix {
          libduckdb = self.packages.${pkgs.system}.libduckdb;
        };

        libduckdb = pkgs.callPackage ./libduckdb.nix { };
      })) {
        x86_64-linux.default-gcc4 = (self.packages.x86_64-linux.default.overrideAttrs (oldAttrs: {
          zigBuildFlags = oldAttrs.zigBuildFlags ++ [ "-Dgcc-suffix=true" ];
        })).override { stdenv = nixpkgs.legacyPackages.x86_64-linux.gcc49Stdenv; };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell.override { stdenv = if pkgs.hostPlatform.isLinux then pkgs.gcc49Stdenv else pkgs.stdenv; } {
          LIBDUCKDB_PATH = "${self.packages.${pkgs.system}.libduckdb}";

          nativeBuildInputs = with pkgs; [
            pkg-config
            gnumake
            zig_0_13
	          zls
            duckdb
            #gdb
          ];
        };
      });
    };
}

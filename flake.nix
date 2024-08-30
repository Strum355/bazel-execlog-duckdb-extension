{
  description = "DuckDB extension template for Zig";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { flake-utils, nixpkgs, ... }: 
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        duckdb-custom = pkgs.duckdb.overrideAttrs (oldAttrs: {
          postInstall = (oldAttrs.postInstall or "") + ''
            mkdir -p $out/third_party
            cp -r $src/third_party/* $out/third_party
          '';
        });
      in {
        packages.default = pkgs.stdenv.mkDerivation rec {
          pname = "bazel-execlog-duckdb-extension";
          version = "1.0.0";

          src = ./.;

          dontConfigure = true;

          deps = pkgs.callPackage ./build.zig.zon.nix { };

          nativeBuildInputs = with pkgs; [
            pkg-config
            gnumake
            zig_0_13.hook
          ];
          
          buildInputs = with pkgs; [
            duckdb-custom
            re2.dev
          ] ++ pkgs.lib.optionals (pkgs.stdenv.isLinux) [ pkgs.libcxx ];

          zigBuildFlags = [
            "--system"
            "${deps}"
          ];

          installPhase = ''
            mkdir -p $out
            ls -la
            cp zig-out/lib/compact_execlog.duckdb_extension $out/compact_execlog.duckdb_extension
          '';

          DUCKDB_THIRD_PARTY_PATH = "${duckdb-custom}/third_party";
          DUCKDB_DEV_PATH = "${duckdb-custom.dev}/";
        };
        
        devShells.default = pkgs.mkShell.override { stdenv = pkgs.libcxxStdenv; } {
          DUCKDB_THIRD_PARTY_PATH = "${duckdb-custom}/third_party";
          DUCKDB_DEV_PATH = "${duckdb-custom.dev}/";

          nativeBuildInputs = with pkgs; [
            pkg-config
            gnumake
            zig_0_13
	          zls
            duckdb-custom
            re2.dev
          ] ++ pkgs.lib.optionals (pkgs.stdenv.isLinux) [ pkgs.libcxx gdb ];
        };
      });
}

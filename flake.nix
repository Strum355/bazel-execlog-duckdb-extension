{
  description = "DuckDB extension template for Zig";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { flake-utils, nixpkgs, zig, ... }: let
      systems = builtins.attrNames zig.packages;
    in flake-utils.lib.eachSystem systems (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        duckdb-custom = pkgs.duckdb.overrideAttrs (oldAttrs: {
          postInstall = (oldAttrs.postInstall or "") + ''
            mkdir -p $out/third_party
            cp -r $src/third_party/* $out/third_party
          '';
        });
      in  {
        devShells.default = pkgs.mkShell.override { stdenv = pkgs.libcxxStdenv; } {
          name = "nixpkgs duckdb dev shell";

          DUCKDB_THIRD_PARTY_PATH = "${duckdb-custom}/third_party";
          DUCKDB_DEV_PATH = "${duckdb-custom.dev}/";

          nativeBuildInputs = with pkgs; [
            pkg-config
            gnumake
            zig.packages.${system}."0.13.0"
	          zls
            duckdb-custom
            re2.dev
          ] ++ pkgs.lib.optionals (pkgs.stdenv.isLinux) [ pkgs.libcxx ];
        };
      });
}

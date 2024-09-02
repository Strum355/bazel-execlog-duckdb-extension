{ stdenv, callPackage, libduckdb, pkg-config, zig_0_13 }:
stdenv.mkDerivation rec {
  pname = "bazel-execlog-duckdb-extension";
  version = "1.0.0";

  src = ./.;

  dontConfigure = true;

  deps = callPackage ./build.zig.zon.nix { };

  nativeBuildInputs = [
    pkg-config
    zig_0_13.hook
  ];
  
  buildInputs = [
    libduckdb
  ];

  zigBuildFlags = [
    "--system"
    "${deps}"
  ];

  LIBDUCKDB_PATH = "${libduckdb}";
}
{ stdenv, fetchFromGitHub, cmake, ninja }:
stdenv.mkDerivation {
  pname = "libduckdb-static";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "duckdb";
    repo = "duckdb";
    rev = "1f98600c2cf8722a6d2f2d805bb4af5e701319fc";
    hash = "sha256-bzFxWv8+Ac8vZLd2OWJyu4T0/0dc7wykdOORMpx92Ic=";
  };

  nativeBuildInputs = [
    cmake
    ninja
  ];

  enableParallelBuilding = true;

  buildFlags = [
    "bundle-library"
  ];

  makeFlags = [
    "GEN=ninja"
    "SKIP_EXTENSIONS=1"
    "DISABLE_PARQUET=1"
    # "EXTRA_CMAKE_VARIABLES=\"-DBUILD_SHELL=0 -DBUILD_UNITTESTS=0 -DEXTENSION_STATIC_BUILD=1\""
    "OVERRIDE_GIT_DESCRIBE=v1.0.0-0-g1f98600c2c"
  ];

  installPhase = ''
    mkdir -p $out/{lib,include}
    install build/release/libduckdb_bundle.a $out/lib/libduckdb.a
    install src/include/duckdb.h $out/include/duckdb.h
  '';

  dontUseCmakeConfigure = true;
  dontUseNinjaBuild = true;
  dontUseNinjaInstall = true;
  dontUseNinjaCheck = true;
}
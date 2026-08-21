{
  description = "farbenbuilds/uWebZockets - A Zig implementation inspired by uWebSockets, designed for zero-allocation and better IO.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zon2nix.url = "github:jcollie/zon2nix";
  };

  outputs = inputs @ {flake-parts, ...}:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem = {
        pkgs,
        system,
        ...
      }: let
        isLinux = pkgs.stdenv.hostPlatform.isLinux;
        pkgsMusl =
          if isLinux
          then pkgs.pkgsMusl
          else null;

        zig = inputs.zig-overlay.packages.${system}."0.16.0" or pkgs.zig;
        zon2nix = inputs.zon2nix.packages.${system}.zon2nix;

        mkDevShell = p:
          p.mkShell {
            packages = [
              zig
              p.zls
              zon2nix
              p.cmake
              p.ninja
              p.pkg-config
              p.go
            ];
          };

        mkBuildDeps = p: [
          zig
          zon2nix
          p.cmake
          p.ninja
          p.pkg-config
          p.go
        ];

      in {
        formatter = pkgs.alejandra;

        checks =
          {
            test-default = pkgs.stdenv.mkDerivation {
              name = "uWebZockets-test-default";
              src = ./.;
              nativeBuildInputs = mkBuildDeps pkgs;
              dontConfigure = true;
              buildPhase = ''
                export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
                zig build test --summary all
              '';
              installPhase = "touch $out";
            };
          }
          // pkgs.lib.optionalAttrs isLinux {
            test-musl = pkgsMusl.stdenv.mkDerivation {
              name = "uWebZockets-test-musl";
              src = ./.;
              nativeBuildInputs = mkBuildDeps pkgsMusl;
              dontConfigure = true;
              buildPhase = ''
                export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
                zig build test --summary all
              '';
              installPhase = "touch $out";
            };
          };

        devShells =
          {
            default = mkDevShell pkgs;
          }
          // pkgs.lib.optionalAttrs isLinux {
            musl = mkDevShell pkgsMusl;
          };

      };
    };
}

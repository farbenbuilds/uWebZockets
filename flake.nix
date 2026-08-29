{
  description = "farbenbuilds/uWebZockets - A pure Zig WebSocket server (uWebSockets port)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
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
              p.deno
              p.gnutar
              p.bzip2
              p.gzip
              p.xz
              p.zip
              p.zlib
            ];
          };

        mkBuildDeps = p: [
          zig
          zon2nix
          p.cmake
          p.ninja
          p.pkg-config
          p.go
          p.deno
          p.gnutar
          p.bzip2
          p.gzip
          p.xz
          p.zip
          p.zlib
        ];

      in {
        formatter = pkgs.alejandra;

        packages =
          {
            default = pkgs.stdenv.mkDerivation {
              name = "uWebZockets-binaries-default";
              src = ./.;
              nativeBuildInputs = mkBuildDeps pkgs;
              dontConfigure = true;
              buildPhase = ''
                export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
                # Build everything (library and examples) in ReleaseFast mode.
                # Output binaries will automatically go to $out/bin due to --prefix.
                zig build -Doptimize=ReleaseFast --prefix $out
              '';
              installPhase = "true"; # zig build --prefix handles installation
            };
          }
          // pkgs.lib.optionalAttrs isLinux {
            musl = pkgsMusl.stdenv.mkDerivation {
              name = "uWebZockets-binaries-musl";
              src = ./.;
              nativeBuildInputs = mkBuildDeps pkgsMusl;
              dontConfigure = true;
              buildPhase = ''
                export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
                zig build -Doptimize=ReleaseFast --prefix $out
              '';
              installPhase = "true";
            };
          };

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

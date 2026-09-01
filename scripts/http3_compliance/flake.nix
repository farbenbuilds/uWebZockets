{
  description = "Pinned HTTP/3 cross-implementation compliance clients";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/d57af924f160a5084293c71c2043f058bd1cdb60";

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};
    python = pkgs.python3.withPackages (python_packages: [
      python_packages.aioquic
    ]);
  in {
    devShells.${system}.default = pkgs.mkShellNoCC {
      packages = [
        pkgs.coreutils
        pkgs.curl
        pkgs.gnugrep
        pkgs.jq
        pkgs.openssl
        pkgs.procps
        python
      ];
    };
  };
}

{
  description = "CLI tool to migrate conversation sessions between AI coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          name = "ctxmv";

          src = ./.;

          buildInputs = [ pkgs.swift pkgs.swiftpm ];

          # Swift Package Manager fetches dependencies at build time;
          # disable the network sandbox only for the fetch phase.
          buildPhase = ''
            swift build -c release --disable-sandbox
          '';

          installPhase = ''
            install -Dm755 .build/release/ctxmv $out/bin/ctxmv
          '';
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/ctxmv";
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.swift pkgs.swiftpm ];
        };
      }
    );
}

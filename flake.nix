{
  description = "bimg  CLI ASCII image viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, zig-overlay }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      zig = zig-overlay.packages.${system}."0.13.0";
    in {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "bimg";
        version = "0.1.0";
        src = ./.;

        nativeBuildInputs = [ zig ];
        buildInputs = [ pkgs.imagemagick ];

        dontInstall = true;

        buildPhase = ''
          export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
          zig build -Doptimize=ReleaseFast --prefix $out
        '';
      };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/bimg";
      };

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = [ zig pkgs.imagemagick ];
      };
    };
}

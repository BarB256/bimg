{
  description = "bimg - CLI ASCII image viewer";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.${system}.default = pkgs.stdenv.mkDerivation {
        pname = "bimg";
        version = "0.1.0";
        src = ./.;

        nativeBuildInputs = [ pkgs.zig ];
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
    };
}

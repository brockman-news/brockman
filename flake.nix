{
  description = "Brockman package, module and test VM.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }: let
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in {
    overlays.default = final: prev: {
      brockman = prev.haskellPackages.callPackage ./default.nix {};
    };

    packages = forAllSystems (system: {
      default = (import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      }).brockman;
      # vm = nixos-generators.nixosGenerate {
      #   pkgs = nixpkgs.legacyPackages.${system};
      #   modules = [
      #     { nixpkgs.overlays = [ self.overlays.default ]; }
      #     self.nixosModules.default
      #     (import nix/vm.nix)
      #   ];
      #   format = "vm-nogui";
      # };
    });

    apps = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      generate = {
        type = "app";
        program = toString (pkgs.writeScript "generate" "${pkgs.cabal2nix}/bin/cabal2nix . > default.nix");
      };
      format = {
        type = "app";
        program = toString (pkgs.writeScript "fix-formatting" ''${pkgs.findutils}/bin/find src/ -type f -exec ${pkgs.ormolu}/bin/ormolu --mode inplace '{}' \;'');
      };
    });

    checks = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      formatting = pkgs.runCommand "formatting" {} ''
        ${pkgs.findutils}/bin/find ${./src} -type f -exec ${pkgs.ormolu}/bin/ormolu --mode check '{}' \; > $out
      '';
      configs = pkgs.runCommand "configs" {} ''
        set -e
        for config in ${./config}/*.json; do
          echo === checking "$config"
          ${self.packages.${system}.default}/bin/brockman --check "$config"
        done > $out
      '';
    });

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      package = pkgs.haskellPackages.callPackage ./default.nix {};
    in {
      default = package.env.overrideAttrs (old: old // {
        buildInputs = [ pkgs.cabal-install ];
      });
    });

    nixosModules.default = { ... }: {
      imports = [nix/module.nix];
      nixpkgs.overlays = [ self.overlays.default ];
    };
  };
}

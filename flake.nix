{
  description = "Brockman package, module and test VM.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators }: let
    supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    pkgsForSystem = system: import nixpkgs {
      inherit system;
      overlays = [ self.overlays.default ];
    };
  in {
    overlays.default = final: prev: {
      brockman = prev.haskellPackages.callPackage ./default.nix {};
      brockman-linkrot = prev.callPackage ./brockman-linkrot.nix {};
    };

    packages = forAllSystems (system: let
      pkgs = (import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
      });
    in {
      default = pkgs.brockman;
      brockman-linkrot = pkgs.brockman-linkrot;
      vm = nixos-generators.nixosGenerate {
        format = "vm-nogui";
        pkgs = pkgsForSystem system;
        modules = [
          self.nixosModules.default
          nix/vm.nix
        ];
      };
    });

    apps = forAllSystems (system: let
      pkgs = pkgsForSystem system;
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
      pkgs = pkgsForSystem system;
    in {
      formatting = pkgs.runCommand "formatting" {} ''
        ${pkgs.findutils}/bin/find ${./src} -type f -exec ${pkgs.ormolu}/bin/ormolu --mode check '{}' \; > $out
      '';
      configs = pkgs.runCommand "configs" {} ''
        set -e
        for config in ${./config}/*.json; do
          echo === checking "$config"
          ${pkgs.brockman}/bin/brockman --check "$config"
        done > $out
      '';
    });

    devShells = forAllSystems (system: let
      pkgs = pkgsForSystem system;
    in {
      default = pkgs.brockman.env.overrideAttrs (old: old // {
        buildInputs = [ pkgs.cabal-install ];
      });
    });

    nixosModules.default = { ... }: {
      imports = [nix/module.nix];
      nixpkgs.overlays = [ self.overlays.default ];
    };
  };
}

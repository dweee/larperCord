{
  description = "larperCord: a native Discord client in Zig (Nix packaging fork)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/2786a2a72088ecf32aea5b3ec52099e6a7cff78f";
    # Only used by the module checks; consumers do not need it.
    home-manager = {
      url = "github:nix-community/home-manager/6a13737c0ed27c7c285f59e3be423ed972aa605f";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Only used by the nix-darwin module check.
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/663d8b962a11cda261b6e9f14e03911fac94baf0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nix-darwin,
    }:
    let
      inherit (nixpkgs) lib;
      # Release inventory: system -> packages built and cached for it. The
      # release workflow builds exactly this set.
      inventory = lib.importJSON ./nix/platforms.json;
      packageSystems = builtins.attrNames inventory;
      # Nixpkgs 26.11 dropped x86_64-darwin.
      allSystems = lib.unique (packageSystems ++ [ "aarch64-darwin" ]);
      forSystems = systems: f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      recipes = {
        larpercord = ./nix/package.nix;
        # Cross-compiled by Zig like upstream's release build.
        larpercord-windows = ./nix/windows.nix;
      };
    in
    {
      overlays.default = final: _prev: {
        larpercord = final.callPackage ./nix/package.nix { };
      };

      packages = forSystems packageSystems (
        pkgs:
        let
          built = lib.genAttrs inventory.${pkgs.stdenv.hostPlatform.system} (
            name: pkgs.callPackage recipes.${name} { }
          );
        in
        built // lib.optionalAttrs (built ? larpercord) { default = built.larpercord; }
      );

      nixosModules.default = import ./nix/nixos-module.nix self;
      nixosModules.larpercord = self.nixosModules.default;
      homeModules.default = import ./nix/hm-module.nix self;
      homeModules.larpercord = self.homeModules.default;
      homeManagerModules = self.homeModules;
      darwinModules.default = import ./nix/darwin-module.nix self;
      darwinModules.larpercord = self.darwinModules.default;

      checks = forSystems packageSystems (
        pkgs:
        import ./nix/checks.nix {
          inherit
            self
            pkgs
            home-manager
            nix-darwin
            ;
        }
      );

      # Need KVM; run by .github/workflows/runtime.yml.
      tests = forSystems [ "x86_64-linux" ] (pkgs: import ./nix/tests.nix { inherit self pkgs; });

      devShells = forSystems allSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ (pkgs.callPackage ./nix/package.nix { }) ];
          packages = [
            pkgs.zig_0_17
            pkgs.pkg-config
          ];
        };
      });

      formatter = forSystems allSystems (pkgs: pkgs.nixfmt);
    };
}

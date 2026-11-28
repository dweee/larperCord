{
  description = "larperCord: a native Discord client in Zig (Nix packaging fork)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/78cc855faf4382e44b781c23bf9f456b924ef0e2";
    # Only used by the module checks; consumers do not need it.
    home-manager = {
      url = "github:nix-community/home-manager/5f5abf5eb8de62d954232f3797b5bf4505656b91";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Only used by the nix-darwin module check.
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/594c680c429be020d7130cc2b17d43c4760d17c7";
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

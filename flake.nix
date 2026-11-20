{
  description = "larperCord: a native Discord client in Zig (Nix packaging fork)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/0bb8272318b4ca41bf0edc6224df3e3e3046b70d";
    # Only used by the module checks; consumers do not need it.
    home-manager = {
      url = "github:nix-community/home-manager/2b13c9cb3aa20653e6f8ee0b7f8331a53ea9b0a9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
    }:
    let
      inherit (nixpkgs) lib;
      # Release inventory: system -> packages built and cached for it. The
      # release workflow builds exactly this set.
      inventory = lib.importJSON ./nix/platforms.json;
      packageSystems = builtins.attrNames inventory;
      linuxSystems = builtins.filter (lib.hasSuffix "-linux") packageSystems;
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

      checks = forSystems linuxSystems (
        pkgs: import ./nix/checks.nix { inherit self pkgs home-manager; }
      );

      # Need KVM; run by .github/workflows/vm-and-windows.yml.
      tests = forSystems [ "x86_64-linux" ] (pkgs: import ./nix/tests.nix { inherit self pkgs; });

      devShells = forSystems allSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = lib.optional pkgs.stdenv.hostPlatform.isLinux (pkgs.callPackage ./nix/package.nix { });
          packages = [
            pkgs.zig_0_17
            pkgs.pkg-config
          ];
        };
      });

      formatter = forSystems allSystems (pkgs: pkgs.nixfmt);
    };
}

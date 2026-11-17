{
  self,
  pkgs,
  home-manager,
}:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  pkg = self.packages.${system}.larpercord;

  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };

  nixosSystem = import "${pkgs.path}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [
      self.nixosModules.default
      {
        programs.larpercord.enable = true;
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
        system.stateVersion = "25.11";
      }
    ];
  };

  nixTestTheme = pkgs.runCommand "nix-test.kdl" { } ''
    sed 's/^theme "terminal"/theme "nix-test"/' ${../themes/terminal.kdl} > $out
    grep -q '^theme "nix-test"' $out
  '';

  # Same demo session start for every frame, so only the theme differs.
  frameEnv = {
    FONTCONFIG_FILE = fontsConf;
    SDL_VIDEO_DRIVER = "offscreen";
    LARPER_RENDERER = "software";
    LARPER_DEMO_EPOCH_MS = "1790000000000";
    TZ = "UTC";
  };

  hmConfig = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeModules.default
      {
        home = {
          username = "larper";
          homeDirectory = "/home/larper";
          stateVersion = "25.11";
        };
        programs.larpercord = {
          enable = true;
          # A real theme: the built-in terminal theme under another name, plus
          # an inline one to cover the `lines` form.
          themes.nix-test = nixTestTheme;
          themes.inline = builtins.readFile nixTestTheme;
          plugins.hello = ./checks/hello.lua;
          tokenFile = "/run/agenix/larpercord-token";
          autostart = true;
        };
      }
    ];
  };
in
{
  package = pkg;

  # Draws one frame of the built-in demo offscreen and checks the PNG. Proves
  # the binary links, finds fonts through fontconfig and renders without a GPU.
  screenshot =
    pkgs.runCommand "larpercord-screenshot"
      {
        nativeBuildInputs = [ pkgs.file ];
        FONTCONFIG_FILE = fontsConf;
        SDL_VIDEO_DRIVER = "offscreen";
        LARPER_RENDERER = "software";
      }
      ''
        export HOME=$TMPDIR/home XDG_CONFIG_HOME=$TMPDIR/config XDG_CACHE_HOME=$TMPDIR/cache
        mkdir -p $HOME $out
        timeout 120 ${lib.getExe pkg} --theme classico --shot $out/classico.png
        file $out/classico.png | grep -q 'PNG image data, 1280 x 800'
        test "$(stat -c %s $out/classico.png)" -gt 20000
      '';

  home-manager-module =
    let
      files = hmConfig.config.home-files;
      bin = "${hmConfig.config.programs.larpercord.finalPackage}/bin/larpercord";
    in
    pkgs.runCommand "larpercord-hm-module" frameEnv ''
      cmp ${nixTestTheme} ${files}/.config/larpercord/themes/nix-test.kdl
      cmp ${nixTestTheme} ${files}/.config/larpercord/themes/inline.kdl
      cmp ${./checks/hello.lua} ${files}/.config/larpercord/plugins/hello.lua

      # The app loads the module's theme from the read-only config tree: its
      # frame differs from the fallback an unknown theme name gets.
      export HOME=$TMPDIR/home XDG_CONFIG_HOME=${files}/.config XDG_CACHE_HOME=$TMPDIR/cache
      mkdir -p $HOME
      timeout 120 ${lib.getExe pkg} --theme nix-test --shot $TMPDIR/nix-test.png
      timeout 120 ${lib.getExe pkg} --theme no-such-theme --shot $TMPDIR/fallback.png
      test -s $TMPDIR/nix-test.png
      if cmp -s $TMPDIR/nix-test.png $TMPDIR/fallback.png; then
        echo "the Home Manager theme was not applied" >&2
        exit 1
      fi
      test -e ${files}/.config/autostart/dev.larpercord.desktop
      grep -q LARPER_TOKEN ${bin}
      grep -q /run/agenix/larpercord-token ${bin}
      touch $out
    '';

  # The NixOS module evaluated in a full system, without booting it (release
  # gates build checks without KVM; the VM test is under `tests`).
  nixos-module =
    let
      cfg = nixosSystem.config;
      names = map lib.getName cfg.environment.systemPackages;
      fonts = map lib.getName cfg.fonts.packages;
    in
    assert lib.elem "larpercord" names;
    assert lib.elem "noto-fonts-color-emoji" fonts;
    assert cfg.services.gnome.gnome-keyring.enable;
    pkgs.writeText "larpercord-nixos-module" (builtins.toJSON { inherit names fonts; });
}
// lib.optionalAttrs (system == "x86_64-linux") {
  windows = self.packages.${system}.larpercord-windows;
}

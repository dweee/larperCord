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
        programs.larpercord = {
          enable = true;
          keyring.enable = true;
        };
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

  nixosDefault = import "${pkgs.path}/nixos/lib/eval-config.nix" {
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
          # An absolute path given as a string is linked, not written as text.
          themes.by-string = "${nixTestTheme}";
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

  # The license and every vendored library's notice ship with the package.
  notices = pkgs.runCommand "larpercord-notices" { } ''
    d=${pkg}/share/licenses/larpercord
    for f in LICENSE third_party/rnnoise/COPYING third_party/imgui/LICENSE.txt \
      third_party/lua/LICENSE third_party/fribidi/COPYING third_party/libdave/LICENSE \
      third_party/mlspp/LICENSE third_party/nlohmann/NOTICE third_party/stb/LICENSE \
      third_party/nlohmann/LICENSE.MIT third_party/mlspp-variant/LICENSE.md; do
      test -s $d/$f
    done
    # Full permission texts, not only names or SPDX identifiers.
    grep -q 'Permission is hereby granted' $d/third_party/nlohmann/LICENSE.MIT
    grep -q 'Boost Software License' $d/third_party/mlspp-variant/LICENSE.md
    grep -q 'Permission is hereby granted' $d/third_party/mlspp-variant/LICENSE.md
    grep -q 'THE SOFTWARE IS PROVIDED' $d/third_party/imgui/LICENSE.txt
    grep -q 'Redistribution and use in source and binary forms' $d/third_party/rnnoise/COPYING
    touch $out
  '';

  # The libcurl the binary loads speaks WebSocket (the gateway and voice need
  # wss). Upstream's --tls-check prints the protocol list result before it
  # tries the network, which the sandbox does not have.
  websocket = pkgs.runCommand "larpercord-websocket" { } ''
    export HOME=$TMPDIR
    ${lib.getExe pkg} --tls-check https://discord.invalid > log 2>&1 || true
    cat log
    grep -q 'WebSocket: true' log
    touch $out
  '';

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
      cmp ${nixTestTheme} ${files}/.config/larpercord/themes/by-string.kdl
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
    # Off by default: another Secret Service provider may already run.
    assert !nixosDefault.config.services.gnome.gnome-keyring.enable;
    pkgs.writeText "larpercord-nixos-module" (builtins.toJSON { inherit names fonts; });
}
// lib.optionalAttrs (system == "x86_64-linux") {
  # The portable zip carries the license and the notices of everything linked
  # into the .exe or shipped beside it.
  windows =
    let
      win = self.packages.${system}.larpercord-windows;
    in
    pkgs.runCommand "larpercord-windows-zip" { nativeBuildInputs = [ pkgs.unzip ]; } ''
      unzip -Z1 ${win}/larpercord-windows-x86_64.zip > files
      for f in larpercord.exe SDL3.dll libcurl-x64.dll libcrypto-3-x64.dll licenses/LICENSE \
        licenses/third_party/rnnoise/COPYING licenses/windows/SDL3/LICENSE.txt \
        licenses/windows/curl/COPYING.txt licenses/windows/openssl/LICENSE \
        licenses/windows/freetype/FTL.TXT; do
        grep -qx "$f" files
      done
      touch $out
    '';
}

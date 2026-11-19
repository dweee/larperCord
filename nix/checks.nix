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

  # A minimal NixOS system around the module, plus `extra`.
  mkSystem =
    extra:
    import "${pkgs.path}/nixos/lib/eval-config.nix" {
      inherit system;
      modules = [
        self.nixosModules.default
        {
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "25.11";
        }
        extra
      ];
    };

  nixosSystem = mkSystem {
    programs.larpercord = {
      enable = true;
      keyring.enable = true;
    };
  };
  nixosDefault = mkSystem { programs.larpercord.enable = true; };
  # GNOME Keyring and KWallet would both claim org.freedesktop.secrets.
  nixosPlasmaKeyring = mkSystem {
    services.desktopManager.plasma6.enable = true;
    programs.larpercord = {
      enable = true;
      keyring.enable = true;
    };
  };
  nixosPlasma = mkSystem {
    services.desktopManager.plasma6.enable = true;
    programs.larpercord.enable = true;
  };
  secretServiceWarning = w: lib.hasInfix "org.freedesktop.secrets" w && lib.hasInfix "KWallet" w;
  hasSecretServiceWarning = sys: lib.any secretServiceWarning sys.config.warnings;

  # The built-in terminal theme renamed, with its dark background turned pure
  # magenta so a frame drawn with it is recognisable by its pixels. Plain Nix
  # string work: evaluating the checks must not need a build (IFD).
  nixTestThemeText =
    let
      text =
        lib.replaceStrings [ "theme \"terminal\"" "\"#0b0906\"" ] [ "theme \"nix-test\"" "\"#ff00ff\"" ]
          (builtins.readFile ../themes/terminal.kdl);
    in
    assert lib.hasInfix "theme \"nix-test\"" text;
    assert lib.hasInfix "\"#ff00ff\"" text;
    text;
  nixTestTheme = pkgs.writeText "nix-test.kdl" nixTestThemeText;

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
          themes.inline = nixTestThemeText;
          # An absolute path given as a string is linked, not written as text.
          themes.by-string = "${nixTestTheme}";
          plugins.hello = ./checks/hello.lua;
          tokenFile = "/run/agenix/larpercord-token";
          autostart = true;
        };
      }
    ];
  };

  # A stand-in for the nixGL package set: it only has to be a program that
  # runs its arguments, which is all the wrapper chain needs.
  nixGLStub = pkgs.writeShellScriptBin "nixGLIntel" ''exec "$@"'';
  hmNixGL = home-manager.lib.homeManagerConfiguration {
    inherit pkgs;
    modules = [
      self.homeModules.default
      {
        home = {
          username = "larper";
          homeDirectory = "/home/larper";
          stateVersion = "25.11";
        };
        targets.genericLinux = {
          enable = true;
          gpu.enable = false;
          nixGL.packages = {
            nixGLIntel = nixGLStub;
          };
        };
        programs.larpercord = {
          enable = true;
          useNixGL = true;
          tokenFile = "/run/agenix/larpercord-token";
        };
      }
    ];
  };
  # useNixGL without a nixGL package set wraps nothing, so it must say so.
  hmNixGLUnset = home-manager.lib.homeManagerConfiguration {
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
          useNixGL = true;
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
    pkgs.runCommand "larpercord-hm-module" (frameEnv // { nativeBuildInputs = [ pkgs.imagemagick ]; })
      ''
        cmp ${nixTestTheme} ${files}/.config/larpercord/themes/nix-test.kdl
        cmp ${nixTestTheme} ${files}/.config/larpercord/themes/inline.kdl
        cmp ${nixTestTheme} ${files}/.config/larpercord/themes/by-string.kdl
        cmp ${./checks/hello.lua} ${files}/.config/larpercord/plugins/hello.lua

        # The app loads the module's theme from the read-only config tree: its
        # frame is mostly the theme's magenta background, and the fallback an
        # unknown theme name gets has none of it (negative control).
        export HOME=$TMPDIR/home XDG_CONFIG_HOME=${files}/.config XDG_CACHE_HOME=$TMPDIR/cache
        mkdir -p $HOME
        timeout 120 ${lib.getExe pkg} --theme nix-test --shot $TMPDIR/nix-test.png
        timeout 120 ${lib.getExe pkg} --theme no-such-theme --shot $TMPDIR/fallback.png
        magenta() {
          magick "$1" -alpha off -format %c histogram:info:- \
            | awk 'toupper($0) ~ /#FF00FF/ { sub(":", "", $1); n += $1 } END { print n + 0 }'
        }
        themed=$(magenta $TMPDIR/nix-test.png)
        fallback=$(magenta $TMPDIR/fallback.png)
        echo "magenta pixels: nix-test=$themed fallback=$fallback"
        if [ "$themed" -lt 100000 ] || [ "$fallback" -ne 0 ]; then
          echo "the Home Manager theme was not applied" >&2
          exit 1
        fi
        test -e ${files}/.config/autostart/dev.larpercord.desktop
        grep -q LARPER_TOKEN ${bin}
        grep -q /run/agenix/larpercord-token ${bin}
        touch $out
      '';

  # Home Manager on a non-NixOS distribution: with `useNixGL` the installed
  # program starts through the nixGL wrapper (a stub here), which then runs the
  # token wrapper and the real binary. Without it, nothing is wrapped.
  home-manager-nixgl =
    let
      bin = "${hmNixGL.config.programs.larpercord.finalPackage}/bin/larpercord";
      plain = hmConfig.config.programs.larpercord.finalPackage;
      unsetWarned = lib.any (lib.hasInfix "useNixGL") hmNixGLUnset.config.warnings;
      setWarned = lib.any (lib.hasInfix "useNixGL") hmNixGL.config.warnings;
    in
    assert unsetWarned && !setWarned;
    pkgs.runCommand "larpercord-hm-nixgl" { } ''
      combined=$(grep -o '/nix/store/[a-z0-9]*-nixGLCombinedWrapper-Intel/bin/nixGLCombinedWrapper-Intel' ${bin} | head -1)
      test -x "$combined"
      grep -q ${nixGLStub}/bin/nixGLIntel "$combined"
      # The chain still reaches the real binary and the desktop entry survives.
      ${bin} --version | grep -q larperCord
      test -e ${hmNixGL.config.programs.larpercord.finalPackage}/share/applications/dev.larpercord.desktop
      # Off by default: the plain package has no nixGL in its launcher.
      ! grep -q nixGLCombinedWrapper ${plain}/bin/larpercord
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
    # Plasma plus the GNOME Keyring option warns about the two Secret Service
    # providers; either alone, or Plasma without the option, does not. Eval
    # only: nothing here builds a derivation.
    assert hasSecretServiceWarning nixosPlasmaKeyring;
    assert !hasSecretServiceWarning nixosSystem;
    assert !hasSecretServiceWarning nixosDefault;
    assert !hasSecretServiceWarning nixosPlasma;
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

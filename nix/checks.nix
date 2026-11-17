{
  self,
  pkgs,
  home-manager,
  nix-darwin,
}:
let
  inherit (pkgs) lib;
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
  system = pkgs.stdenv.hostPlatform.system;
  pkg = self.packages.${system}.larpercord;

  fontsConf = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };

  # Where the client reads its configuration, relative to $HOME. The macOS
  # build ignores the XDG variables (sys.configHome), so checks there move
  # HOME instead.
  configDir = if isDarwin then "Library/Application Support/larpercord" else ".config/larpercord";
  homeDirectory = if isDarwin then "/Users/larper" else "/home/larper";
  # macOS has no /run; the macOS runtime CI job writes a dummy token here.
  tokenFile = if isDarwin then "/tmp/larpercord-check-token" else "/run/agenix/larpercord-token";
  # Stands in for a real signer such as flakey's `monke-tcc-sign sign`: same
  # `<command> IDENTIFIER PATH` call, and it records each call. The macOS
  # runtime CI job signs the installed bundle with a real Keychain identity.
  fakeSigner = pkgs.writeShellScript "fake-signer" ''
    [ "$1" = dev.larpercord ] && [ -x "$2/Contents/MacOS/larpercord" ] || exit 1
    echo "$1" >> "$HOME/.larpercord-signed"
  '';

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

  darwinSystem = nix-darwin.lib.darwinSystem {
    modules = [
      self.darwinModules.default
      (
        { config, ... }:
        {
          nixpkgs.hostPlatform = system;
          programs.larpercord.enable = true;
          system.stateVersion = config.system.maxStateVersion;
        }
      )
    ];
  };

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
          inherit homeDirectory;
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
          inherit tokenFile;
          autostart = true;
          macos.codeSign.command = "${fakeSigner}";
        };
      }
    ];
  };

  common = {
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
    # the binary links, finds fonts through fontconfig and renders without a GPU
    # (on macOS without a WindowServer session too).
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
        final = hmConfig.config.programs.larpercord.finalPackage;
        bin = "${final}/bin/larpercord";
        agent = "${hmConfig.config.home.activationPackage}/LaunchAgents/dev.larpercord.plist";
        installer = hmConfig.config.programs.larpercord.macos.appInstaller;
      in
      pkgs.runCommand "larpercord-hm-module"
        (
          frameEnv
          // {
            nativeBuildInputs = [ pkgs.imagemagick ];
            # For the macOS runtime CI job: the app installer and the launchd agent.
            passthru = {
              inherit final installer;
              activation = hmConfig.config.home.activationPackage;
            };
          }
        )
        (
          ''
            cfg="${files}/${configDir}"
            cmp ${nixTestTheme} "$cfg/themes/nix-test.kdl"
            cmp ${nixTestTheme} "$cfg/themes/inline.kdl"
            cmp ${nixTestTheme} "$cfg/themes/by-string.kdl"
            cmp ${./checks/hello.lua} "$cfg/plugins/hello.lua"

            # The app loads the module's theme from the read-only config tree: its
            # frame is mostly the theme's magenta background, and the fallback an
            # unknown theme name gets has none of it (negative control).
            export HOME=$TMPDIR/home XDG_CONFIG_HOME=${files}/.config XDG_CACHE_HOME=$TMPDIR/cache
            mkdir -p $HOME
          ''
          + lib.optionalString isDarwin ''
            mkdir -p "$HOME/$(dirname "${configDir}")"
            ln -s "$cfg" "$HOME/${configDir}"
          ''
          + ''
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
            grep -q LARPER_TOKEN ${bin}
            grep -q ${tokenFile} ${bin}
          ''
          + lib.optionalString isLinux ''
            test -e ${files}/.config/autostart/dev.larpercord.desktop
          ''
          # Activation installs a signed copy of the bundle in ~/Applications
          # whose Info.plist passes the token path; autostart opens that copy.
          + lib.optionalString isDarwin ''
            # Home Manager runs it as `/bin/sh -c '/bin/wait4path /nix/store && exec …'`.
            grep -qF 'exec /usr/bin/open -a ${homeDirectory}/Applications/larperCord.app</string>' ${agent}
            grep -q '<string>dev.larpercord</string>' ${agent}
            grep -q larpercord-install-app ${hmConfig.config.home.activationPackage}/activate
            grep -q LARPER_TOKEN_FILE ${bin}

            # The installer, as activation runs it, in a scratch home.
            export HOME=$TMPDIR/apphome
            mkdir -p $HOME
            ${installer}
            app=$HOME/Applications/larperCord.app
            test -x $app/Contents/MacOS/larpercord
            test ! -L $app/Contents/MacOS/larpercord
            grep -q '<string>dev.larpercord</string>' $app/Contents/Info.plist
            grep -q '<key>LARPER_TOKEN_FILE</key>' $app/Contents/Info.plist
            grep -q '<string>${tokenFile}</string>' $app/Contents/Info.plist
            grep -q '<key>FONTCONFIG_FILE</key>' $app/Contents/Info.plist
            test -e $app/Contents/Resources/larperCord.icns
            # FFmpeg copied into the bundle, not linked out of it.
            ls $app/Contents/Frameworks/libavformat.*.dylib >/dev/null
            if find $app -type l | grep -q .; then
              echo "the installed bundle still links outside itself" >&2
              exit 1
            fi
            test "$(cat $HOME/.larpercord-signed)" = dev.larpercord
            # Unchanged inputs: no second copy or signature.
            ${installer}
            test "$(wc -l < $HOME/.larpercord-signed)" -eq 1
            # The command runs the installed copy.
            ${bin} --version | grep -qx 'larperCord ${pkg.version}'
            timeout 120 ${bin} --theme nix-test --shot $TMPDIR/installed.png
            test -s $TMPDIR/installed.png
          ''
          + ''
            touch $out
          ''
        );
  };

  linuxOnly = {
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
  };

  darwinOnly = {
    # The nix-darwin module in a full system closure (built, not activated):
    # the app lands in Applications (linked to /Applications/Nix Apps on
    # activation), the command in sw/bin and the fonts in Library/Fonts/Nix Fonts.
    darwin-module =
      let
        top = darwinSystem.config.system.build.toplevel;
      in
      pkgs.runCommand "larpercord-darwin-module" { } ''
        test -x ${top}/sw/bin/larpercord
        ${top}/sw/bin/larpercord --version | grep -qx 'larperCord ${pkg.version}'
        grep -q '<string>dev.larpercord</string>' ${top}/Applications/larperCord.app/Contents/Info.plist
        test -x ${top}/Applications/larperCord.app/Contents/MacOS/larpercord
        find "${top}/Library/Fonts/Nix Fonts/" -name 'NotoColorEmoji*' | grep -q .
        find "${top}/Library/Fonts/Nix Fonts/" -name 'NotoSansCJK*' | grep -q .
        touch $out
      '';
  };
in
common
// lib.optionalAttrs isLinux linuxOnly
// lib.optionalAttrs isDarwin darwinOnly
// lib.optionalAttrs (self.packages.${system} ? larpercord-windows) {
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

self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.larpercord;
  inherit (pkgs.stdenv.hostPlatform) isDarwin isLinux;
  inherit (lib)
    mkEnableOption
    mkIf
    mkOption
    types
    ;

  # A file to link: a path, a derivation, or a single-line absolute path
  # string ("/run/…", "${pkg}/x.kdl"). Anything else is the file's text. A
  # multi-line value is always text, even when it starts with a `//` comment.
  isFileSource =
    value:
    builtins.isPath value
    || lib.isDerivation value
    || (types.path.check value && !(lib.hasInfix "\n" value));

  # Where the client reads its configuration: $XDG_CONFIG_HOME/larpercord on
  # Linux, ~/Library/Application Support/larpercord on macOS (which ignores
  # the XDG variables, see sys.configHome).
  configDir = if isDarwin then "Library/Application Support/larpercord" else "larpercord";

  # Written under <configDir>/<dir>/<name><ext>.
  fileEntries =
    dir: ext: attrs:
    lib.mapAttrs' (
      name: value:
      lib.nameValuePair "${configDir}/${dir}/${name}${ext}" (
        if isFileSource value then { source = value; } else { text = value; }
      )
    ) attrs;

  fileType = types.either types.path types.lines;

  # Reads the token at launch so it is never in the Nix store or the
  # environment of the session. Upstream never saves LARPER_TOKEN.
  tokenWrapper = pkgs.writeShellScriptBin "larpercord" ''
    if [ -r ${lib.escapeShellArg cfg.tokenFile} ]; then
      LARPER_TOKEN="$(< ${lib.escapeShellArg cfg.tokenFile})"
      export LARPER_TOKEN
    fi
    exec ${lib.getExe cfg.package} "$@"
  '';

  # macOS: Home Manager installs its own copy of the bundle in
  # ~/Applications/larperCord.app. A real directory (not a store link) so it can
  # be signed with a stable identity, and with its own Info.plist so Finder,
  # Spotlight, the Dock and login launches get LARPER_TOKEN_FILE through
  # LSEnvironment: the path travels, never the token.
  bundle = "Applications/larperCord.app";
  appPath = "${config.home.homeDirectory}/${bundle}";
  basePlist = cfg.package.passthru.darwinInfoPlist or null;
  infoPlist =
    if basePlist == null then
      "${cfg.package}/${bundle}/Contents/Info.plist"
    else
      pkgs.writeText "larperCord-Info.plist" (
        lib.generators.toPlist { escape = true; } (
          basePlist
          // {
            LSEnvironment =
              (basePlist.LSEnvironment or { })
              // lib.optionalAttrs (cfg.tokenFile != null) { LARPER_TOKEN_FILE = cfg.tokenFile; };
          }
        )
      );
  signCommand = cfg.macos.codeSign.command;
  installApp = pkgs.writeShellScript "larpercord-install-app" ''
    set -euo pipefail
    src=${lib.escapeShellArg "${cfg.package}/${bundle}"}
    plist=${lib.escapeShellArg "${infoPlist}"}
    sign=${lib.escapeShellArg (if signCommand == null then "" else signCommand)}
    dest="$HOME/${bundle}"
    state="$HOME/.local/state/larpercord"
    want="$src"$'\n'"$plist"$'\n'"$sign"
    if [[ "$(cat "$state/app.stamp" 2>/dev/null || true)" == "$want" && -x "$dest/Contents/MacOS/larpercord" ]]; then
      exit 0
    fi
    mkdir -p "$HOME/Applications" "$state"
    tmp="$HOME/Applications/.larperCord.app.new"
    rm -rf "$tmp"
    # -L: the bundle's Frameworks links (FFmpeg) become files, since a signed
    # bundle may not link outside itself.
    /bin/cp -RL "$src" "$tmp"
    /bin/chmod -R u+w "$tmp"
    /bin/cp "$plist" "$tmp/Contents/Info.plist"
    /bin/chmod 644 "$tmp/Contents/Info.plist"
    if [[ -n "$sign" ]]; then
      # `<command> IDENTIFIER PATH`; the command may carry its own quoting.
      /bin/sh -c "$sign \"\$1\" \"\$2\"" sign dev.larpercord "$tmp"
    fi
    /bin/rm -rf "$dest"
    /bin/mv "$tmp" "$dest"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" || true
    printf '%s' "$want" > "$state/app.stamp"
    echo "larpercord: installed $dest''${sign:+ (signed)}" >&2
  '';

  # The command line on macOS: the installed bundle (same identity as a Finder
  # launch), falling back to the store copy before the first activation.
  darwinBin = pkgs.writeShellScriptBin "larpercord" ''
    ${lib.optionalString (
      cfg.tokenFile != null
    ) "export LARPER_TOKEN_FILE=${lib.escapeShellArg cfg.tokenFile}"}
    : "''${FONTCONFIG_FILE:=${cfg.package.passthru.fontsConf or ""}}"
    export FONTCONFIG_FILE
    app="$HOME/${bundle}/Contents/MacOS/larpercord"
    [ -x "$app" ] || app=${lib.escapeShellArg "${cfg.package}/${bundle}/Contents/MacOS/larpercord"}
    exec "$app" "$@"
  '';

  withToken =
    if cfg.tokenFile == null then
      cfg.package
    else
      pkgs.symlinkJoin {
        name = "larpercord-with-token-${cfg.package.version or "unknown"}";
        # The first path wins where they overlap.
        paths = [
          tokenWrapper
          cfg.package
        ];
        meta = (cfg.package.meta or { }) // {
          mainProgram = "larpercord";
        };
      };

  # Home Manager's own nixGL wrapper (targets.genericLinux.nixGL). It is the
  # identity function until `targets.genericLinux.nixGL.packages` is set, and
  # `or` keeps older Home Manager releases without it evaluating.
  nixGLWrap = config.lib.nixGL.wrap or lib.id;

  finalPackage =
    if isDarwin then
      darwinBin
    else if cfg.useNixGL then
      nixGLWrap withToken
    else
      withToken;
in
{
  options.programs.larpercord = {
    enable = mkEnableOption "larperCord, a native Discord client";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.larpercord;
      defaultText = lib.literalExpression "larpercord.packages.\${pkgs.stdenv.hostPlatform.system}.larpercord";
      description = "The larperCord package to install.";
    };

    finalPackage = mkOption {
      type = types.package;
      readOnly = true;
      default = finalPackage;
      description = ''
        What goes into `home.packages`: on Linux the package, with the token
        wrapper when `tokenFile` is set and the nixGL wrapper when `useNixGL`
        is; on macOS only a `larpercord` command that runs the installed
        `~/Applications/larperCord.app`.
      '';
    };

    useNixGL = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Run larperCord through Home Manager's nixGL wrapper
        (`config.lib.nixGL.wrap`), for a Home Manager install on a distribution
        other than NixOS. A Nix-built larperCord cannot load the host's GPU
        driver by itself: on a Wayland session it fails to start with no
        renderer (SDL3's Wayland backend has no GPU-less path). Needs
        `targets.genericLinux.nixGL.packages` to be set; the wrapper does nothing
        without it, so that case warns. As an alternative that needs no wrapper,
        enable `targets.genericLinux.gpu` and run its setup script once.
        Leave it off on NixOS. Linux only.
      '';
    };

    macos.appInstaller = mkOption {
      type = types.package;
      readOnly = true;
      internal = true;
      default = installApp;
      description = "The script activation runs to install (and sign) ~/Applications/larperCord.app.";
    };

    macos.codeSign.command = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = lib.literalExpression ''
        "''${lib.getExe osConfig.monke.codeSigning.package} sign"
        # or: "/usr/bin/codesign --force --sign 'My Code Signing' --timestamp=none --identifier"
      '';
      description = ''
        macOS: signs `~/Applications/larperCord.app` after each install, run as
        `<command> dev.larpercord <app path>` as the user. With a stable
        Keychain identity, privacy grants (the microphone for voice calls)
        follow the certificate and bundle identifier instead of the ad-hoc
        signature, which changes with every build. Null leaves the linker's
        ad-hoc signatures.
      '';
    };

    themes = mkOption {
      type = types.attrsOf fileType;
      default = { };
      example = lib.literalExpression ''
        {
          mine = ./mine.kdl;
          tiny = '''
            theme "tiny" { extends "terminal" }
          ''';
        }
      '';
      description = ''
        KDL themes placed in `$XDG_CONFIG_HOME/larpercord/themes/<name>.kdl`
        (on macOS, `~/Library/Application Support/larpercord/themes/<name>.kdl`).
        Each value is a path (a Nix path, a derivation, or a single-line
        absolute path string) to link, or the theme's text. The files are
        read-only links: edit the source and switch, and the app reloads the
        changed file.
      '';
    };

    plugins = mkOption {
      type = types.attrsOf fileType;
      default = { };
      example = lib.literalExpression "{ hello = ./hello.lua; }";
      description = ''
        Lua plugins placed in `$XDG_CONFIG_HOME/larpercord/plugins/<name>.lua`
        (on macOS, under `~/Library/Application Support/larpercord/plugins`),
        given as a path or as text like `themes`. Plugins still have to be
        turned on in Settings → Plugins.
      '';
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/larpercord-token";
      description = ''
        A file read at launch into `LARPER_TOKEN` (on macOS passed to the app
        as `LARPER_TOKEN_FILE`, which it reads itself, so Finder and login
        launches get it too), for example an agenix or sops-nix secret. A string, not a path, so the token never enters the
        Nix store. The app never writes this token anywhere. Leave null to sign in
        through the app and its keyring.
      '';
    };

    autostart = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Start larperCord with the graphical session: an XDG autostart entry on
        Linux, a launchd user agent that opens the app at login on macOS.
      '';
    };
  };

  config = mkIf cfg.enable (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = cfg.tokenFile == null || !(lib.hasPrefix builtins.storeDir cfg.tokenFile);
            message = "programs.larpercord.tokenFile must not point into the Nix store.";
          }
        ];

        warnings =
          lib.optional (cfg.useNixGL && (config.targets.genericLinux.nixGL.packages or null) == null)
            ''
              programs.larpercord.useNixGL is set, but targets.genericLinux.nixGL.packages is
              null, so larperCord is not wrapped. Set it to the nixGL package set, or turn on
              targets.genericLinux.gpu instead.
            '';

        home.packages = [ cfg.finalPackage ];

      }
      (mkIf isLinux {
        xdg.configFile = fileEntries "themes" ".kdl" cfg.themes // fileEntries "plugins" ".lua" cfg.plugins;
      })
      (mkIf isDarwin {
        home.file = fileEntries "themes" ".kdl" cfg.themes // fileEntries "plugins" ".lua" cfg.plugins;
        home.activation.larpercordApp = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run ${installApp}
        '';
      })
      (mkIf (cfg.autostart && isLinux) {
        xdg.autostart = {
          enable = true;
          entries = [ "${cfg.finalPackage}/share/applications/dev.larpercord.desktop" ];
        };
      })
      # Through LaunchServices (`open`), like a login item: the app gets its
      # Dock icon and focus, and an already running copy is just brought up.
      (mkIf (cfg.autostart && isDarwin) {
        launchd.agents.larpercord = {
          enable = true;
          config = {
            Label = "dev.larpercord";
            ProgramArguments = [
              "/usr/bin/open"
              "-a"
              appPath
            ];
            RunAtLoad = true;
            LimitLoadToSessionType = "Aqua";
            ProcessType = "Interactive";
          };
        };
      })
    ]
  );
}

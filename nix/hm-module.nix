self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.larpercord;
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

  # Written under ~/.config/larpercord/<dir>/<name><ext>.
  fileEntries =
    dir: ext: attrs:
    lib.mapAttrs' (
      name: value:
      lib.nameValuePair "larpercord/${dir}/${name}${ext}" (
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

  withToken =
    if cfg.tokenFile == null then
      cfg.package
    else
      pkgs.symlinkJoin {
        name = "larpercord-with-token-${cfg.package.version or "unknown"}";
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

  finalPackage = if cfg.useNixGL then nixGLWrap withToken else withToken;
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
      description = "The installed package, including the token wrapper when `tokenFile` is set and the nixGL wrapper when `useNixGL` is.";
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
        Leave it off on NixOS.
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
        KDL themes placed in `$XDG_CONFIG_HOME/larpercord/themes/<name>.kdl`.
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
        Lua plugins placed in `$XDG_CONFIG_HOME/larpercord/plugins/<name>.lua`,
        given as a path or as text like `themes`. Plugins still have to be
        turned on in Settings → Plugins.
      '';
    };

    tokenFile = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/run/agenix/larpercord-token";
      description = ''
        A file read at launch into `LARPER_TOKEN`, for example an agenix or
        sops-nix secret. A string, not a path, so the token never enters the
        Nix store. The app never writes this token anywhere. Leave null to sign in
        through the app and its keyring.
      '';
    };

    autostart = mkOption {
      type = types.bool;
      default = false;
      description = "Start larperCord with the graphical session (XDG autostart).";
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

        xdg.configFile = fileEntries "themes" ".kdl" cfg.themes // fileEntries "plugins" ".lua" cfg.plugins;
      }
      (mkIf (cfg.autostart && pkgs.stdenv.hostPlatform.isLinux) {
        xdg.autostart = {
          enable = true;
          entries = [ "${cfg.finalPackage}/share/applications/dev.larpercord.desktop" ];
        };
      })
    ]
  );
}

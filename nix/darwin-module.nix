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
in
{
  options.programs.larpercord = {
    enable = mkEnableOption "larperCord, a native Discord client";

    package = mkOption {
      type = types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.larpercord;
      defaultText = lib.literalExpression "larpercord.packages.\${pkgs.stdenv.hostPlatform.system}.larpercord";
      description = ''
        The larperCord package to install. Its `larperCord.app` is linked
        into `/Applications/Nix Apps`, and `larpercord` is put on `PATH`.
      '';
    };

    fonts.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install Noto Color Emoji and Noto Sans CJK into `/Library/Fonts/Nix Fonts`,
        the same fonts the NixOS module installs. The package's fontconfig
        reads that folder next to the macOS system fonts.
      '';
    };
  };

  # Tokens go to the login Keychain through /usr/bin/security and
  # notifications through osascript, both part of macOS: nothing to set up.
  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    fonts.packages = mkIf cfg.fonts.enable [
      pkgs.noto-fonts-color-emoji
      pkgs.noto-fonts-cjk-sans
    ];
  };
}

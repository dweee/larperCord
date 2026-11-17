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
      description = "The larperCord package to install.";
    };

    keyring.enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Enable GNOME Keyring as the Secret Service provider, so "Remember"
        stores tokens in the keyring through `secret-tool`. Leave it off when
        the desktop already provides one (GNOME, KDE Plasma's KWallet,
        KeePassXC, pass-secret-service). Without any provider the app keeps
        tokens in `~/.config/larpercord/tokens/<ID>` with mode 600.
      '';
    };

    fonts.enable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install color emoji and CJK fonts. larperCord finds fonts through
        fontconfig and falls back to boxes without them.
      '';
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    services.gnome.gnome-keyring.enable = mkIf cfg.keyring.enable true;

    fonts.packages = mkIf cfg.fonts.enable [
      pkgs.noto-fonts-color-emoji
      pkgs.noto-fonts-cjk-sans
    ];
  };
}

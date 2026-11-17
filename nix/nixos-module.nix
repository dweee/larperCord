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
    mkDefault
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
      default = true;
      description = ''
        Run a Secret Service provider (GNOME Keyring) so that "Remember"
        stores tokens in the keyring instead of a `chmod 600` file under
        `~/.config/larpercord/tokens`. Has no effect when another provider,
        such as KWallet, is already configured.
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

    services.gnome.gnome-keyring.enable = mkIf (
      cfg.keyring.enable && !(config.services.desktopManager.plasma6.enable or false)
    ) (mkDefault true);

    fonts.packages = mkIf cfg.fonts.enable [
      pkgs.noto-fonts-color-emoji
      pkgs.noto-fonts-cjk-sans
    ];
  };
}

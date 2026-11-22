self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.larpercord;
  # `or false` so evaluation never fails where the option does not exist.
  plasma6 = config.services.desktopManager.plasma6.enable or false;
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
        the desktop already provides one: GNOME, KDE Plasma (KWallet answers
        `org.freedesktop.secrets` itself; GNOME Keyring would compete with it
        for that name), KeePassXC, pass-secret-service. Without any provider
        the app keeps tokens in `~/.config/larpercord/tokens/<ID>` with mode
        600.
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
    warnings = lib.optional (cfg.keyring.enable && plasma6) ''
      programs.larpercord.keyring.enable turns on GNOME Keyring, but
      services.desktopManager.plasma6 is enabled too. GNOME Keyring and
      KWallet would both claim org.freedesktop.secrets, and a D-Bus name
      has one owner, so they fight over it. On Plasma leave
      programs.larpercord.keyring.enable off: KWallet already provides the
      Secret Service that larperCord uses through secret-tool.
    '';

    environment.systemPackages = [ cfg.package ];

    services.gnome.gnome-keyring.enable = mkIf cfg.keyring.enable true;

    fonts.packages = mkIf cfg.fonts.enable [
      pkgs.noto-fonts-color-emoji
      pkgs.noto-fonts-cjk-sans
    ];
  };
}

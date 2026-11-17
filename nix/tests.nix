# Tests that need hardware virtualisation. Kept out of `checks` because the
# release gate builds checks on runners without KVM.
{ self, pkgs }:
{
  # The NixOS module on a real VM: the package, keyring, fonts and a headless
  # frame drawn as a normal user.
  nixos-vm = pkgs.testers.runNixOSTest {
    name = "larpercord-nixos-vm";
    nodes.machine = {
      imports = [ self.nixosModules.default ];
      programs.larpercord = {
        enable = true;
        keyring.enable = true;
      };
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
      };
    };
    testScript = ''
      machine.wait_for_unit("multi-user.target")
      machine.succeed("command -v larpercord")
      machine.succeed("test -x /run/current-system/sw/bin/gnome-keyring-daemon")
      machine.succeed("fc-list | grep -qi 'Noto Color Emoji'")
      machine.succeed("su - alice -c 'SDL_VIDEO_DRIVER=offscreen LARPER_RENDERER=software timeout 120 larpercord --theme terminal --shot /tmp/shot.png'")
      machine.succeed("test -s /tmp/shot.png")
      machine.copy_from_machine("/tmp/shot.png", "")
    '';
  };
}

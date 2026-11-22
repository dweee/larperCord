# larperCord fork

Upstream: https://github.com/RshaCuDeVidro/larperCord (GPL-3.0-only)

Base: upstream release `v0.6.7` (`7f2814a982fa4ab8f1e8e85ea157d266d58161c3`).
Upstream history and authorship are kept. The fork adds Nix packaging,
modules and CI, plus the small, upstreamable source fixes listed under
[Source patches](#source-patches).

When this fork was created (2026-11-17) nobody had published a Nix package or
flake for larperCord. We checked GitHub code search, all 20 public forks, NUR
and nixpkgs. `shortpie3/maclarperCord` has an unmerged macOS port (two commits on
an old base) that is useful reference for Darwin work.

## Outputs

| Output | What it is |
|---|---|
| `packages.{x86_64,aarch64}-linux.larpercord` | Native Linux client, built from source with nixpkgs Zig 0.17, SDL3, curl (with WebSocket), OpenSSL |
| `packages.x86_64-linux.larpercord-windows` | Windows x86_64 build cross-compiled by Zig (`bin/larpercord.exe`, its three DLLs, and a portable zip) |
| `overlays.default` | Adds `pkgs.larpercord` |
| `nixosModules.default` | `programs.larpercord`: the package, emoji/CJK fonts, and an opt-in GNOME Keyring (`keyring.enable`) for desktops without a Secret Service provider. It warns when combined with Plasma 6: KWallet is already the Secret Service there |
| `homeModules.default` | `programs.larpercord`: package, declarative themes and Lua plugins, `tokenFile`, autostart, `useNixGL` (non-NixOS GPU, see [below](#gpu-on-a-non-nixos-distribution)) |
| `checks.<linux>.*` | Package build (runs `zig build test`), an offscreen frame of the demo, both module evaluations |
| `tests.x86_64-linux.nixos-vm` | NixOS VM test: the module on a booted system, a frame drawn as a normal user (needs KVM) |

`nix/platforms.json` is the release inventory: every package listed there is
built, checked and cached by the release workflow, and nothing else is.

```sh
nix run github:dweee/larperCord/flakey
nix build github:dweee/larperCord/flakey#larpercord-windows
```

NixOS:

```nix
{
  inputs.larpercord.url = "github:dweee/larperCord/flakey";
  # in a module:
  imports = [ inputs.larpercord.nixosModules.default ];
  programs.larpercord.enable = true;
}
```

Home Manager:

```nix
{
  imports = [ inputs.larpercord.homeModules.default ];
  programs.larpercord = {
    enable = true;
    themes.mine = ./mine.kdl;          # ~/.config/larpercord/themes/mine.kdl
    plugins.shrug = ./shrug.lua;       # ~/.config/larpercord/plugins/shrug.lua
    tokenFile = "/run/agenix/larpercord-token"; # optional; read at launch into LARPER_TOKEN
    autostart = true;
  };
}
```

## Source patches

| Files | Why |
|---|---|
| `src/platform/sys.zig`, `src/qa_lsp_server.zig` | Ignore SIGPIPE/SIGTERM via `std.posix.sigaction` instead of `c.signal(..., c.SIG_IGN)`: translate-c rejects the `SIG_IGN` cast on aarch64, so upstream did not build for aarch64-linux. |
| `src/net/discord.zig`, `src/main.zig` | Read `LARPER_TOKEN` once at startup and remove it from the libc and SDL environments, so helpers the app spawns (`notify-send`, `secret-tool`, `xdg-open`) do not inherit the token. The Home Manager `tokenFile` wrapper passes the token this way. |
| `src/platform/ptt_portal.zig`, `src/net/voz_audio.zig` | Use the Wayland GlobalShortcuts portal for push-to-talk while another window has focus. |
| `src/platform/accent_portal.zig`, `src/app.zig` | Offer the desktop accent on Linux and follow changes through the Settings portal. |

## Packaging notes

- The upstream build parses its own `-Doptimize=debug|safe|fast|small` and
  does not use `standardOptimizeOption`, so the Zig hook's default flags are
  off and the package passes `-Dcpu=baseline -Doptimize=fast`. RNNoise still
  picks AVX/AVX2 at run time, as in the upstream release.
- libcurl is built with `websocketSupport`: the gateway and voice use
  `curl_ws_*`, and nixpkgs leaves WebSocket off. The `websocket` check runs
  upstream's `--tls-check` and requires `WebSocket: true`.
- Runtime helpers that upstream calls by name are on the wrapper's `PATH`:
  `secret-tool` (keyring), `notify-send`, `xdg-open`. Libraries it opens with
  `SDL_LoadObject` (`libdbus-1`, `libwayland-client`, FFmpeg for inline video)
  are on `LD_LIBRARY_PATH`. `withFfmpeg = false` drops FFmpeg; videos then open
  in the browser.
- The GlobalShortcuts portal resolves the registered app ID through
  `dev.larpercord.desktop`. Install the package where the desktop can see this
  launcher to use global push-to-talk. A bare `nix run` can use a launcher
  already installed in the desktop session.
- The in-app updater needs no patch. Upstream already detects a read-only
  install directory and shows "Installed by a package manager: update through
  it" instead of installing.
- The Windows build uses exactly the pinned MSYS2 packages, SDL3 and curl
  release builds, and FreeType source from `tools/windows_deps.sh`, as
  fixed-output fetches. Those DLLs and static libraries are upstream
  prebuilt binaries; `meta.sourceProvenance` says so.
- Both packages install the GPL license and the notices of every vendored
  library under `share/licenses/larpercord`; the Windows zip carries them in
  `licenses/`, with the notices of the DLLs and static libraries it ships.
- The source passed to Zig excludes `nix/`, `ci/`, `.github/`, `site/` and the
  flake files, so packaging edits do not rebuild the client.

## GPU on a non-NixOS distribution

A Nix-built larperCord does not use the host's graphics driver by itself, and
on a Wayland session it does not fall back to a software renderer either: it
fails to start. What we read and measured:

- nixpkgs `libglvnd` (`pkgs/by-name/li/libglvnd/package.nix`) looks for EGL
  vendor files in `/run/opengl-driver/share/glvnd/egl_vendor.d`, then
  `/etc/glvnd/egl_vendor.d` and `/usr/share/glvnd/egl_vendor.d`. The host
  Mesa's file in the last directory names a bare `libEGL_mesa.so.0`, which Nix's
  glibc does not search the host library directories for, and host drivers
  built against the host glibc would not load into a Nix-built process anyway.
  Only `/run/opengl-driver` (a Nix-built Mesa or NVIDIA) works.
- The wrapper does not add a driver path: it only suffixes `PATH` and
  `LD_LIBRARY_PATH` with D-Bus, Wayland, FFmpeg and the helpers.
- nixpkgs SDL3 3.4.18 has no window framebuffer on Wayland (no
  `CreateWindowFramebuffer` in `src/video/wayland`); its software renderer
  needs a working GL/GPU renderer for the texture path. So `LARPER_RENDERER=software`
  does not help either.
- Measured on lapwolf (NixOS) with an empty directory mounted over
  `/run/opengl-driver`'s target (`bwrap --dev-bind / / --tmpfs …`, which
  emulates a host with no Nix-visible driver): SDL logs
  `Couldn't create renderer opengl: Could not get EGL display`, `opengles2`
  the same, `vulkan: Installed Vulkan doesn't implement the VK_KHR_surface
  extension`, `gpu: No supported SDL_GPU backend found!`, `software: Window
  framebuffer support not available`, and the app exits with `error:
  SdlRenderer`. We did not test an X11 session without drivers, and did not
  have a real non-NixOS host to test the fixes below on.

Fixes, both from Home Manager (pinned here; `targets.genericLinux.gpu` and
`targets.genericLinux.nixGL` both exist in it):

```nix
{
  targets.genericLinux.enable = true;
  # Either: link Nix's Mesa at /run/opengl-driver once (run the printed
  # `sudo …/non-nixos-gpu-setup`); then no wrapper is needed.
  targets.genericLinux.gpu.enable = true;
  # NVIDIA needs the exact host driver version and hash:
  #   targets.genericLinux.gpu.nvidia = { enable = true; version = "…"; sha256 = "…"; };

  # Or: run larperCord through nixGL.
  # targets.genericLinux.nixGL.packages = inputs.nixGL.packages;
  # programs.larpercord.useNixGL = true;
}
```

`useNixGL` passes the final package (including the `tokenFile` wrapper) through
`config.lib.nixGL.wrap`. The `home-manager-nixgl` check builds that chain with a
stub in place of nixGL and runs `larpercord --version` through it, and checks
that `useNixGL` without `nixGL.packages` warns. It does not prove a GPU is used.
Leave it off on NixOS.

## CI

- `release-channels.yml`, `pr-checks.yml`, `scheduled-updates.yml`,
  `retry-unacquired-runners.yml` and the `ci/` helpers are generated by
  `dave-fork-ci/ci/install-channel-automation.py` from `ci/channels.json`.
  Regenerate them with that tool; do not edit them by hand.
- `vm-and-windows.yml` runs what the release gate cannot: the NixOS VM test
  with KVM, and the Nix-built Windows zip on a real `windows-latest` runner
  drawing one frame.
- `upstream-sync.yml` calls the pinned dave-fork-ci controller. It tracks
  upstream **releases** (`.fork-ci.json`) and stays inert until the repository
  variable `GUARDED_UPSTREAM_SYNC_ENABLED` is `true`.
- Upstream's own workflows (`ci.yml`, `linux-portable.yml`, `pages.yml`) are
  removed here: they publish upstream releases and the site, or rebuild on Arch
  outside Nix.

## Platform status

| Platform | Status |
|---|---|
| Linux x86_64 | Builds, tests, renders offscreen, NixOS VM test passes |
| Linux aarch64 | Builds and is checked natively in CI |
| Windows x86_64 | Cross-compiled; runtime smoke test on `windows-latest` |
| Linux, KDE Plasma 6 on Wayland | Verified live on lapwolf (KWin 6.8.2, 2026-11-17); see below |
| macOS (nix-darwin) | Not supported upstream; port in progress on a separate branch |

### KDE Plasma 6 Wayland: what was run

`nix build .#larpercord`, then `larpercord --demo` with a throwaway
`XDG_CONFIG_HOME` (no account, no token) on a real Plasma session. Evidence
(screenshots, D-Bus captures) was kept outside the repository.

| Item | Result |
|---|---|
| Native Wayland, GPU renderer | `SDL video: wayland, renderer: opengl`. The process held `/dev/dri/renderD129` with `drm-driver: amdgpu` and a growing `drm-engine-gfx`, and mapped Mesa's `libgallium`: hardware GL, not llvmpipe. The GL renderer string itself is not logged by the app |
| Server-side decorations | KWin drew the Breeze title bar (`noBorder: false`; `spectacle -b -n -a` of the window shows it) |
| `app_id` | KWin reports `resourceClass`/`desktopFile` `dev.larpercord`, equal to the desktop file's name and `StartupWMClass`. The package was not installed into the session, so Plasma's own taskbar lookup of the installed desktop file was not exercised; the window also supplies its own icon |
| Tray | The `--tray-helper` process registered `org.kde.StatusNotifierItem-<pid>-1` with the `StatusNotifierWatcher` (Active, `Communications`, menu `/MenuBar`). A click or the menu was not driven |
| Notifications | A demo plugin's `larper.notify(..., {desktop = true})` made `notify-send --app-name=larperCord` call `org.freedesktop.Notifications.Notify` on plasmashell. Ordinary message notifications are off in demo mode, so that path was not run |
| Dark/light | With theme mode "system" the window followed `org.freedesktop.appearance color-scheme`: dark under Plasma's real portal, and light, dark, light again on a private bus carrying a mock portal (live `SettingChanged`, so Plasma's own colors were never touched) |
| File picker | `OpenFile` went to `org.freedesktop.portal.Desktop` and on to the KDE backend; the dialog was the KDE "Open File" window, transient to the app, with no `zenity` process. The click was replaced by a throwaway build that fires the same `pickFiles` action; the dialog was closed by ending the app |
| Secret Service | `accounts_store.storeToken`/`tokenFor`/`forgetToken` from a throwaway build: store, lookup (value matched) and delete reached KWallet as `CreateItem`, `SearchItems` and `Delete`; nothing was left behind. The login screen itself was not driven |


# larperCord fork

Upstream: https://github.com/RshaCuDeVidro/larperCord (GPL-3.0-only)

Base: upstream release `v0.6.6` (`9624c551988557aefce292e53c30583357c9dda6`).
Upstream history and authorship are kept. The fork adds Nix packaging,
modules and CI, plus the small, upstreamable source fixes listed under
[Source patches](#source-patches).

When this fork was created (2026-11-17) nobody had published a Nix package or
flake for larperCord. We checked GitHub code search, all 20 public forks, NUR
and nixpkgs. `shortpie3/maclarperCord` has an unmerged macOS port (two commits on
an old base). The macOS port here was written fresh against v0.6.6 but takes
several approaches from it (credited under [Source patches](#source-patches)).

## Outputs

| Output | What it is |
|---|---|
| `packages.{x86_64,aarch64}-linux.larpercord` | Native Linux client, built from source with nixpkgs Zig 0.17, SDL3, curl (with WebSocket), OpenSSL |
| `packages.aarch64-darwin.larpercord` | Native macOS client: `Applications/larperCord.app` (bundle id `dev.larpercord`) and `bin/larpercord` |
| `packages.{x86_64-linux,aarch64-darwin}.larpercord-windows` | Windows x86_64 build cross-compiled by Zig (`bin/larpercord.exe`, its three DLLs, and a portable zip) |
| `overlays.default` | Adds `pkgs.larpercord` |
| `nixosModules.default` | `programs.larpercord`: the package, emoji/CJK fonts, and an opt-in GNOME Keyring (`keyring.enable`) for desktops without a Secret Service provider |
| `darwinModules.default` | nix-darwin `programs.larpercord`: the package (its app linked into `/Applications/Nix Apps`) and emoji/CJK fonts |
| `homeModules.default` | `programs.larpercord`: package, declarative themes and Lua plugins, `tokenFile`, autostart (XDG on Linux, a launchd agent on macOS) |
| `checks.<system>.*` | Package build (runs `zig build test`), notices, WebSocket libcurl, an offscreen frame of the demo, the Home Manager module with a rendered theme, and the NixOS module (Linux) or nix-darwin module (macOS) |
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

nix-darwin:

```nix
{
  imports = [ inputs.larpercord.darwinModules.default ];
  programs.larpercord.enable = true;
}
```

Home Manager (Linux and macOS):

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

On macOS the client reads `~/Library/Application Support/larpercord` (and caches
in `~/Library/Caches/larpercord`), so the module puts themes and plugins there.
Activation installs a real copy of the bundle in `~/Applications/larperCord.app`
(not a store link), and `larpercord` on `PATH` runs that copy. Its Info.plist
passes `tokenFile` as `LARPER_TOKEN_FILE`, so Finder, Spotlight, Dock and login
launches read the token too; the path travels, never the token. `autostart` is a
launchd agent that opens that copy at login.

To keep macOS privacy grants (the microphone for voice calls) across rebuilds,
sign the copy with a stable Keychain identity. The command is run as
`<command> dev.larpercord <app>`, which fits flakey's `monke-tcc-sign sign` (the
shared `rotna Code Signing` identity) or a plain `codesign` call:

```nix
programs.larpercord.macos.codeSign.command =
  "${lib.getExe osConfig.monke.codeSigning.package} sign";
# or "/usr/bin/codesign --force --sign 'My Code Signing' --timestamp=none --identifier"
```

TCC then keys the grant to the certificate and `dev.larpercord`, not to the
ad-hoc signature of each build. Without a command the copy keeps the linker's
ad-hoc signatures and macOS asks again after updates.

## Source patches

| Files | Why |
|---|---|
| `src/platform/sys.zig`, `src/qa_lsp_server.zig` | Ignore SIGPIPE/SIGTERM via `std.posix.sigaction` instead of `c.signal(..., c.SIG_IGN)`: translate-c rejects the `SIG_IGN` cast on aarch64, so upstream did not build for aarch64-linux (or macOS). |
| `src/c.h` | macOS: `sys/event.h` (kqueue), `mach-o/dyld.h`, `mach/mach.h`; no `sys/inotify.h` or `malloc.h`. |
| `src/platform/sys.zig`, `src/net/rpc_ipc.zig` | macOS has no `SOCK_CLOEXEC`: `socketCloexec` sets `FD_CLOEXEC` with `fcntl`. Rich Presence uses the BSD `sockaddr_un` layout and `MSG_DONTWAIT` value. |
| `src/platform/sys.zig` | macOS folders: `~/Library/Application Support` and `~/Library/Caches`, ignoring the XDG variables (a Finder launch never sees them; a shell that sets them would split the config by launch method). Temp files in the per-user `$TMPDIR`. `selfExe` via `_NSGetExecutablePath` + `realpath`; process memory via `TASK_VM_INFO`; the tray needs no D-Bus probe. |
| `src/platform/sys.zig`, `src/net/accounts_store.zig`, `src/platform/apagar.zig`, `src/net/discord.zig` | Keychain: tokens go to the login Keychain through `/usr/bin/security` as service `larpercord-account`, account = account ID, like the Linux `secret-tool` entry. The secret goes over stdin (`security -i`), never argv, and only `[A-Za-z0-9._-]` values are accepted. The Apple-signed CLI keeps each item's ACL stable across updates; Security.framework would tie it to the ad-hoc-signed binary, which changes with every build, and macOS would ask again after each update. "Delete all data" removes every `larpercord-account` item. The pre-multi-account legacy entry is Linux-only, as on Windows. |
| `src/net/discord.zig` | `LARPER_TOKEN_FILE`: a path to an owner-only file read once at startup like `LARPER_TOKEN`, then both variables are removed from the environment. Launches without a shell (an app bundle's `LSEnvironment`, launchd agents) can pass the path; the token never goes into a plist or an environment. |
| `src/app.zig` | Notifications through `osascript` `display notification`, title and body passed as script arguments. |
| `src/platform/tray.zig` | macOS uses `SDL_CreateTray` (a menu bar item) like Windows, not the Linux D-Bus helper process. |
| `src/platform/vigia.zig` | Theme/mascot folders are watched with kqueue: the folders and every file in them, re-armed after each event. |
| `src/platform/ffmpeg_busca.zig`, `src/platform/ffmpeg.zig` | FFmpeg `libavX.N.dylib` names. macOS loads only by absolute path, because `dlopen` of a bare name also tries the working directory: the bundle's `Contents/Frameworks`, then `/opt/homebrew/lib`, `/usr/local/lib`, `/opt/local/lib`, then `PATH` folders. |
| `src/platform/window.zig` | SDL forces OpenGL on new macOS windows, and the `offscreen` driver only has OpenGL through EGL, which macOS lacks. With that driver (screenshots, CI) the window is created with an external graphics context, and the software renderer draws normally. Window-creation failures now log SDL's error. |
| `src/net/updater.zig` | Upstream publishes no macOS build, so installing would put the Linux binary in place. macOS counts as system-managed ("update through your package manager"). |

From `shortpie3/maclarperCord`: the fcntl CLOEXEC sockets, the
`~/Library` folders, the kqueue watcher idea, `osascript` notifications, the SDL
tray on macOS, the dylib names and the memory query. It used Security.framework
for the Keychain and a different updater; those parts were not taken.
| `src/net/discord.zig`, `src/main.zig` | Read `LARPER_TOKEN` once at startup and remove it from the libc and SDL environments, so helpers the app spawns (`notify-send`, `secret-tool`, `xdg-open`) do not inherit the token. The Home Manager `tokenFile` wrapper passes the token this way. |

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
- The in-app updater needs no patch on Linux. Upstream already detects a
  read-only install directory and shows "Installed by a package manager:
  update through it" instead of installing.
- macOS (`aarch64-darwin` only; nixpkgs 26.11 dropped x86_64-darwin):
  fontconfig gets a generated `FONTCONFIG_FILE` (overridable). Nix's fontconfig looks for `/etc/fonts`, which macOS lacks;
  the generated config reads `/System/Library/Fonts`, `/Library/Fonts` and
  `~/Library/Fonts`, where nix-darwin and Home Manager put fonts. FFmpeg's
  dylibs are linked into `Contents/Frameworks`. CA certificates come from
  `/etc/ssl/cert.pem` (part of macOS) or nix-darwin's
  `/etc/ssl/certs/ca-certificates.crt`, through upstream's bundle list.
  The bundle's executable is the client itself, not a wrapper: whatever signs
  the bundle signs the process that runs and asks for the microphone. Finder and
  `open` launches get `FONTCONFIG_FILE` from `LSEnvironment`; `bin/larpercord`
  is a binary wrapper outside the bundle. Only the five FFmpeg libraries the
  client uses are in `Contents/Frameworks`.
  Keychain, notifications and links (`SDL_OpenURL` → NSWorkspace) use the
  system's own tools. The `.icns` is rendered from `assets/icon-terminal.svg`.
  The store bundle keeps the linker's ad-hoc signatures and is not notarized;
  the Home Manager copy can be signed with a stable identity (see above).
- `larpercord-windows` also builds on aarch64-darwin. It is the same target and
  inputs, but not byte-identical to the x86_64-linux build (the Zig hosts
  differ). The `windows-latest` runtime smoke test runs the Linux-built zip.
- The Windows build uses exactly the pinned MSYS2 packages, SDL3 and curl
  release builds, and FreeType source from `tools/windows_deps.sh`, as
  fixed-output fetches. Those DLLs and static libraries are upstream
  prebuilt binaries; `meta.sourceProvenance` says so.
- Both packages install the GPL license and the notices of every vendored
  library under `share/licenses/larpercord`; the Windows zip carries them in
  `licenses/`, with the notices of the DLLs and static libraries it ships.
- The source passed to Zig excludes `nix/`, `ci/`, `.github/`, `site/` and the
  flake files, so packaging edits do not rebuild the client.

## CI

- `release-channels.yml`, `pr-checks.yml`, `scheduled-updates.yml`,
  `retry-unacquired-runners.yml` and the `ci/` helpers are generated by
  `dave-fork-ci/ci/install-channel-automation.py` from `ci/channels.json`.
  Regenerate them with that tool; do not edit them by hand.
- `runtime.yml` (formerly `vm-and-windows.yml`) runs what the release gate
  cannot: `nix flake check` natively on x86_64-linux, aarch64-linux and
  aarch64-darwin, the NixOS VM test with KVM, the Nix-built Windows zip on a
  real `windows-latest` runner drawing one frame, and `macos-runtime` on
  `macos-15`. That job opens the bundle through LaunchServices and draws a frame,
  runs the demo and captures the screen, starts the Home Manager token bundle
  from the launchd agent and checks the token reaches the app, and runs
  `nix/macos-probe`. The probe is compiled against the client's own
  `sys.zig`/`ffmpeg.zig`: a Keychain round trip under a test service (deleted
  afterwards), FFmpeg loaded from a bundle's `Contents/Frameworks`, and
  `SDL_OpenURL`. It also installs the Home Manager copy, signs it with a
  throwaway self-signed identity made the way `monke-tcc-sign` makes its own,
  checks the signature carries `certificate leaf` and `dev.larpercord`, and
  starts it from the launchd agent with `LARPER_TOKEN_FILE`.
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
| macOS aarch64 | Fork-only port (upstream supports Linux and Windows). Builds, tests and renders offscreen on aarch64-darwin (rotna and CI); the `macos-runtime` CI job covers the GUI session, Keychain, FFmpeg and links |

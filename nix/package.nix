{
  lib,
  stdenv,
  zig_0_17,
  pkg-config,
  makeWrapper,
  sdl3,
  freetype,
  fontconfig,
  curl,
  zlib,
  libwebp,
  libopus,
  openssl,
  dbus,
  wayland,
  libsecret,
  libnotify,
  xdg-utils,
  ffmpeg-headless,
  withFfmpeg ? true,
  # Builds the headless QA robot (`--qa`) into the binary.
  withQa ? false,
  larpercordSource ? import ./source.nix { inherit lib; },
  version ? import ./version.nix,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "larpercord";
  inherit version;

  src = larpercordSource;

  nativeBuildInputs = [
    zig_0_17.hook
    pkg-config
    makeWrapper
  ];

  buildInputs = [
    sdl3
    freetype
    fontconfig
    curl
    zlib
    libwebp
    libopus
    openssl
  ];

  # The project parses its own -Doptimize values (debug/safe/fast/small) and
  # does not use b.standardOptimizeOption, so the hook's --release flag is wrong.
  dontSetZigDefaultFlags = true;
  zigBuildFlags = [
    "-Dcpu=baseline"
    "-Doptimize=fast"
    "-Dqa=${lib.boolToString withQa}"
  ];
  zigCheckFlags = [ "-Dcpu=baseline" ];

  # `zig build test` covers the pure parts (KDL, markdown, store, themes,
  # protobuf, APNG); it needs neither a display nor the network.
  doCheck = true;

  postInstall = ''
    install -Dm644 packaging/aur/dev.larpercord.desktop \
      $out/share/applications/dev.larpercord.desktop
    for s in 32 64 128; do
      install -Dm644 assets/icon-$s.png \
        $out/share/icons/hicolor/''${s}x''${s}/apps/larpercord.png
      install -Dm644 assets/icon-$s.png \
        $out/share/icons/hicolor/''${s}x''${s}/apps/dev.larpercord.png
    done
    install -Dm644 assets/logo-mark.svg \
      $out/share/icons/hicolor/scalable/apps/larpercord.svg
    source ${./install-notices.sh}
    installNotices $out/share/licenses/larpercord
  '';

  # Runtime-only helpers: the keyring (secret-tool), notifications
  # (notify-send), links (xdg-open) and libraries opened with SDL_LoadObject
  # (D-Bus for the tray, Wayland activation, FFmpeg for video).
  postFixup = ''
    wrapProgram $out/bin/larpercord \
      --suffix PATH : ${
        lib.makeBinPath [
          libsecret
          libnotify
          xdg-utils
        ]
      } \
      --suffix LD_LIBRARY_PATH : ${
        lib.makeLibraryPath (
          [
            dbus
            wayland
          ]
          ++ lib.optional withFfmpeg ffmpeg-headless
        )
      }
  '';

  passthru = {
    inherit withFfmpeg;
  };

  meta = {
    description = "Native Discord client in Zig, with SDL3 and Dear ImGui";
    homepage = "https://github.com/RshaCuDeVidro/larperCord";
    license = lib.licenses.gpl3Only;
    mainProgram = "larpercord";
    platforms = lib.platforms.linux;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
})

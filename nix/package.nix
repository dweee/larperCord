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
  brotli,
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
  fetchurl,
}:

let
  # Upstream's TLS profile advertises Brotli certificate compression. The app
  # sets it on curl's SSL_CTX, so both must link the same Brotli-enabled OpenSSL.
  opensslBrotli = openssl.overrideAttrs (old: {
    buildInputs = (old.buildInputs or [ ]) ++ [ brotli ];
    configureFlags = old.configureFlags ++ [
      "enable-brotli"
      "--with-brotli-include=${lib.getDev brotli}/include"
      "--with-brotli-lib=${lib.getLib brotli}/lib"
    ];
  });
  # The Discord gateway and voice connections use curl_ws_*: libcurl must be
  # built with WebSocket support, which nixpkgs leaves off by default.
  curlWs = curl.override {
    openssl = opensslBrotli;
    websocketSupport = true;
  };
  thirdPartyLicenses = import ./third-party-licenses.nix { inherit fetchurl; };
in
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
    curlWs
    zlib
    libwebp
    libopus
    opensslBrotli
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
    export nlohmannJsonLicense=${thirdPartyLicenses.nlohmann-json}
    export mparkVariantLicense=${thirdPartyLicenses.mpark-variant}
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
    curl = curlWs;
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

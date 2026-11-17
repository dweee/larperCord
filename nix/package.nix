{
  lib,
  stdenv,
  zig_0_17,
  pkg-config,
  makeWrapper,
  makeBinaryWrapper,
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
  makeFontsConf,
  librsvg,
  python3,
  writeText,
  withFfmpeg ? true,
  # Builds the headless QA robot (`--qa`) into the binary.
  withQa ? false,
  larpercordSource ? import ./source.nix { inherit lib; },
  version ? import ./version.nix,
  fetchurl,
}:

let
  inherit (stdenv.hostPlatform) isDarwin isLinux;

  # The Discord gateway and voice connections use curl_ws_*: libcurl must be
  # built with WebSocket support, which nixpkgs leaves off by default.
  curlWs = curl.override { websocketSupport = true; };
  thirdPartyLicenses = import ./third-party-licenses.nix { inherit fetchurl; };

  # macOS has no /etc/fonts, so Nix's fontconfig finds no configuration there.
  # This one reads the system, local and per-user font folders; nix-darwin
  # (`fonts.packages`) and Home Manager install fonts under the latter two.
  darwinFontsConf = makeFontsConf {
    fontDirectories = [
      "/System/Library/Fonts"
      "/Library/Fonts"
      "~/Library/Fonts"
    ];
  };

  app = "$out/Applications/larperCord.app";

  infoPlist = writeText "Info.plist" (
    lib.generators.toPlist { escape = true; } {
      CFBundleDevelopmentRegion = "en";
      CFBundleDisplayName = "larperCord";
      CFBundleExecutable = "larpercord";
      CFBundleIconFile = "larperCord";
      CFBundleIdentifier = "dev.larpercord";
      CFBundleInfoDictionaryVersion = "6.0";
      CFBundleName = "larperCord";
      CFBundlePackageType = "APPL";
      CFBundleShortVersionString = version;
      CFBundleVersion = version;
      LSApplicationCategoryType = "public.app-category.social-networking";
      LSMinimumSystemVersion = stdenv.hostPlatform.darwinMinVersion;
      NSHighResolutionCapable = true;
      NSSupportsAutomaticGraphicsSwitching = true;
      # Voice calls: without this macOS refuses the microphone outright.
      NSMicrophoneUsageDescription = "larperCord uses the microphone in voice calls.";
    }
  );
in
stdenv.mkDerivation (finalAttrs: {
  pname = "larpercord";
  inherit version;

  src = larpercordSource;

  nativeBuildInputs = [
    zig_0_17.hook
    pkg-config
  ]
  ++ lib.optional isLinux makeWrapper
  ++ lib.optionals isDarwin [
    makeBinaryWrapper
    librsvg
    (python3.withPackages (ps: [ ps.pillow ]))
  ];

  buildInputs = [
    sdl3
    freetype
    fontconfig
    curlWs
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

  postInstall =
    lib.optionalString isLinux ''
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
    ''
    # A real bundle, so Finder, the Dock, Spotlight, Launchpad and launchd see
    # an app (and macOS can ask for the microphone). bin/larpercord points
    # into it. The icon is the default (Terminal) mascot.
    + lib.optionalString isDarwin ''
      mkdir -p ${app}/Contents/MacOS ${app}/Contents/Resources
      mv $out/bin/larpercord ${app}/Contents/MacOS/larpercord
      install -m644 ${infoPlist} ${app}/Contents/Info.plist
      printf 'APPL????' > ${app}/Contents/PkgInfo
      rsvg-convert -w 1024 -h 1024 assets/icon-terminal.svg -o icon-1024.png
      python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).save(sys.argv[2])' \
        icon-1024.png ${app}/Contents/Resources/larperCord.icns
      ln -s ../Applications/larperCord.app/Contents/MacOS/larpercord $out/bin/larpercord
    ''
    + ''
      source ${./install-notices.sh}
      export nlohmannJsonLicense=${thirdPartyLicenses.nlohmann-json}
      export mparkVariantLicense=${thirdPartyLicenses.mpark-variant}
      installNotices $out/share/licenses/larpercord
    '';

  # Linux: runtime-only helpers: the keyring (secret-tool), notifications
  # (notify-send), links (xdg-open) and libraries opened with SDL_LoadObject
  # (D-Bus for the tray, Wayland activation, FFmpeg for video).
  # macOS: the Keychain (`security`), notifications (`osascript`) and links
  # (NSWorkspace) are the system's own. FFmpeg goes in the bundle's
  # Contents/Frameworks, where the client looks for it, and fontconfig gets a
  # configuration that knows the macOS font folders.
  postFixup =
    lib.optionalString isLinux ''
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
    ''
    + lib.optionalString isDarwin (
      ''
        wrapProgram ${app}/Contents/MacOS/larpercord \
          --set-default FONTCONFIG_FILE ${darwinFontsConf}
      ''
      + lib.optionalString withFfmpeg ''
        mkdir -p ${app}/Contents/Frameworks
        for lib in ${lib.getLib ffmpeg-headless}/lib/lib*.dylib; do
          ln -s "$lib" ${app}/Contents/Frameworks/
        done
      ''
    );

  passthru = {
    inherit withFfmpeg;
    curl = curlWs;
    fontsConf = if isDarwin then darwinFontsConf else null;
  };

  meta = {
    description = "Native Discord client in Zig, with SDL3 and Dear ImGui";
    homepage = "https://github.com/RshaCuDeVidro/larperCord";
    license = lib.licenses.gpl3Only;
    mainProgram = "larpercord";
    # Nixpkgs 26.11 dropped x86_64-darwin.
    platforms = lib.platforms.linux ++ [ "aarch64-darwin" ];
    sourceProvenance = [ lib.sourceTypes.fromSource ];
  };
})

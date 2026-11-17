# Windows x86_64 build, cross-compiled by Zig from any Nix host. Mirrors
# tools/windows_deps.sh: the same pinned MSYS2 packages, SDL3 and curl builds
# and FreeType source, fetched as fixed-output derivations instead of curl.
{
  lib,
  stdenvNoCC,
  fetchurl,
  zig_0_17,
  zstd,
  gnutar,
  unzip,
  zip,
  larpercordSource ? import ./source.nix { inherit lib; },
  version ? import ./version.nix,
}:
let
  msys =
    name: hash:
    fetchurl {
      url = "https://repo.msys2.org/mingw/ucrt64/${name}";
      sha256 = hash;
    };
  msysPackages = [
    (msys "mingw-w64-ucrt-x86_64-opus-1.6.1-2-any.pkg.tar.zst" "bb114bcf26225f50f874497ebfd6b8224fff2a20bda3f8ee45cd07ce5f02657b")
    (msys "mingw-w64-ucrt-x86_64-zlib-1.3.2-3-any.pkg.tar.zst" "130e6ef04c654fc2150a177600aa5ed0035087665a893479d2c85ba7485d5704")
    (msys "mingw-w64-ucrt-x86_64-libwebp-1.6.0-1-any.pkg.tar.zst" "34ff8396c403d484c8777ad49ad0fc06dfb94fadf6f14bcf84d50c45bc6fd17e")
    (msys "mingw-w64-ucrt-x86_64-openssl-3.6.5-1-any.pkg.tar.zst" "773e021ebad83f14b5c103db467411e8ff064663e1c7e7f730e2be72f4117064")
  ];
  sdl3 = fetchurl {
    url = "https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-devel-3.4.20-mingw.tar.gz";
    sha256 = "d2d3bf3fb97a90b22e908a306d7362631ef1bab229d988fe6669595dc29cd9ed";
  };
  curl = fetchurl {
    url = "https://curl.se/windows/dl-8.23.0_8/curl-8.23.0_8-win64-mingw.zip";
    sha256 = "ca5b0fd6e7a6dbde210281f545c73a89784f2e88104a2cdfe0b73ea3dfed5b3a";
  };
  freetype = fetchurl {
    url = "https://download.savannah.gnu.org/releases/freetype/freetype-2.15.0.tar.xz";
    sha256 = "93cd47eb719c325107f2d3cf087d06299e944c3b48a40b55537302304dea1dd5";
  };
  shippedDlls = [
    "SDL3.dll"
    "libcurl-x64.dll"
    "libcrypto-3-x64.dll"
  ];
in
stdenvNoCC.mkDerivation {
  pname = "larpercord-windows";
  inherit version;
  src = larpercordSource;

  nativeBuildInputs = [
    zig_0_17.hook
    zstd
    gnutar
    unzip
    zip
  ];

  # Assemble .deps/windows exactly as tools/windows_deps.sh lays it out.
  postPatch = ''
    out_deps=.deps/windows
    mkdir -p $out_deps/include $out_deps/lib $out_deps/bin $out_deps/src/freetype $out_deps/licenses
    for p in ${lib.escapeShellArgs msysPackages}; do
      t=$(mktemp -d)
      tar --zstd -xf "$p" -C "$t"
      cp -r "$t"/ucrt64/include/. $out_deps/include/ 2>/dev/null || true
      find "$t/ucrt64/lib" -maxdepth 1 -name '*.a' -exec cp {} $out_deps/lib/ \;
      find "$t/ucrt64/bin" -maxdepth 1 -name '*.dll' -exec cp {} $out_deps/bin/ \; 2>/dev/null || true
      # Static libraries (opus, zlib, libwebp) end up in the .exe and OpenSSL ships
      # as a DLL: their notices travel with the build.
      cp -r "$t"/ucrt64/share/licenses/. $out_deps/licenses/
      rm -rf "$t"
    done

    t=$(mktemp -d); tar -xf ${sdl3} -C "$t"
    cp -r "$t"/SDL3-*/x86_64-w64-mingw32/include/. $out_deps/include/
    cp "$t"/SDL3-*/x86_64-w64-mingw32/lib/libSDL3.dll.a $out_deps/lib/
    cp "$t"/SDL3-*/x86_64-w64-mingw32/bin/SDL3.dll $out_deps/bin/
    install -Dm644 "$t"/SDL3-*/LICENSE.txt $out_deps/licenses/SDL3/LICENSE.txt
    rm -rf "$t"

    t=$(mktemp -d); unzip -q ${curl} -d "$t"
    cp -r "$t"/curl-*/include/curl $out_deps/include/
    cp "$t"/curl-*/lib/libcurl.dll.a $out_deps/lib/
    cp "$t"/curl-*/bin/libcurl-x64.dll $out_deps/bin/
    # The official curl build links its dependencies into the DLL.
    install -Dm644 "$t"/curl-*/COPYING.txt $out_deps/licenses/curl/COPYING.txt
    root=$PWD
    (cd "$t"/curl-*/dep && find . -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' \) \
      -exec install -Dm644 {} "$root/$out_deps/licenses/curl/dep/{}" \;)
    rm -rf "$t"

    tar -xf ${freetype} -C $out_deps/src/freetype --strip-components=1
    # FreeType is compiled into the .exe under its FreeType License.
    install -Dm644 $out_deps/src/freetype/LICENSE.TXT $out_deps/licenses/freetype/LICENSE.TXT
    install -Dm644 $out_deps/src/freetype/docs/FTL.TXT $out_deps/licenses/freetype/FTL.TXT

    find $out_deps/bin -name '*.dll' ${
      lib.concatMapStringsSep " " (d: "! -name ${lib.escapeShellArg d}") shippedDlls
    } -delete
    rm -f $out_deps/lib/libssl* $out_deps/lib/libcurl.a
  '';

  dontSetZigDefaultFlags = true;
  zigBuildFlags = [
    "-Dtarget=x86_64-windows-gnu"
    "-Doptimize=fast"
  ];
  # Windows binaries cannot run on the build host.
  doCheck = false;
  dontFixup = true;

  postInstall = ''
    source ${./install-notices.sh}
    installNotices $out/share/licenses/larpercord
    cp -r .deps/windows/licenses $out/share/licenses/larpercord/windows

    # A portable zip, laid out like the upstream release (the executable and
    # its DLLs side by side) plus the notices. Fixed timestamps and order, no
    # extra fields, so identical inputs give an identical archive.
    stage=$TMPDIR/zip
    mkdir -p $stage
    cp $out/bin/larpercord.exe ${lib.concatMapStringsSep " " (d: "$out/bin/${d}") shippedDlls} $stage/
    cp -r $out/share/licenses/larpercord $stage/licenses
    find $stage -exec touch -h -d @$SOURCE_DATE_EPOCH {} +
    (cd $stage && find . -type f -printf '%P\n' | LC_ALL=C sort | zip -q -9 -X -D $out/larpercord-windows-x86_64.zip -@)
  '';

  meta = {
    description = "Native Discord client in Zig (Windows x86_64 build)";
    homepage = "https://github.com/RshaCuDeVidro/larperCord";
    license = lib.licenses.gpl3Only;
    # Cross-compiled by Zig: buildable on Linux and macOS hosts.
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    sourceProvenance = [
      lib.sourceTypes.fromSource
      # SDL3, libcurl, OpenSSL and the static MSYS2 libraries are upstream
      # prebuilt Windows binaries, as in the upstream release.
      lib.sourceTypes.binaryNativeCode
    ];
  };
}

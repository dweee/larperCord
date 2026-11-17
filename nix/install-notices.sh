# shellcheck shell=bash
# installNotices DEST: the program license and the notices of every library
# vendored in third_party/ and compiled into the binary. Run from the source
# root. Header-only libraries carry their notice inside the header, so the
# relevant block is copied out next to the full license text, which the caller
# passes as $nlohmannJsonLicense and $mparkVariantLicense.
installNotices() {
  local dest=$1 f
  install -Dm644 LICENSE "$dest/LICENSE"
  for f in third_party/*/LICENSE* third_party/*/COPYING* third_party/*/AUTHORS; do
    [ -f "$f" ] && install -Dm644 "$f" "$dest/$f"
  done
  install -d "$dest/third_party/nlohmann" "$dest/third_party/stb" "$dest/third_party/mlspp-variant"
  sed -n '1,10p' third_party/nlohmann/json.hpp > "$dest/third_party/nlohmann/NOTICE"
  sed -n '/^ALTERNATIVE A - MIT License/,$p' third_party/stb/stb_image.h > "$dest/third_party/stb/LICENSE"
  sed -n '1,7p' third_party/mlspp/third_party/variant.hpp > "$dest/third_party/mlspp-variant/NOTICE"
  install -m644 "$nlohmannJsonLicense" "$dest/third_party/nlohmann/LICENSE.MIT"
  install -m644 "$mparkVariantLicense" "$dest/third_party/mlspp-variant/LICENSE.md"
  grep -q 'SPDX-License-Identifier: MIT' "$dest/third_party/nlohmann/NOTICE"
  grep -q 'Permission is hereby granted' "$dest/third_party/nlohmann/LICENSE.MIT"
  grep -q 'Public Domain' "$dest/third_party/stb/LICENSE"
  grep -q 'Permission is hereby granted' "$dest/third_party/stb/LICENSE"
  grep -q 'Boost Software License' "$dest/third_party/mlspp-variant/NOTICE"
  grep -q 'Permission is hereby granted' "$dest/third_party/mlspp-variant/LICENSE.md"
}

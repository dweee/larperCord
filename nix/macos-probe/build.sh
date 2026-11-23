#!/usr/bin/env bash
# Builds the probe from the checkout root, in the dev shell (zig, pkg-config, SDL3):
#   nix develop -c bash nix/macos-probe/build.sh OUT
set -euo pipefail
out=${1:?output path}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp" src/macos_probe.zig' EXIT
# A module may only import files under its own directory: the probe sits in src/.
cp nix/macos-probe/probe.zig src/macos_probe.zig
# shellcheck disable=SC2046
zig translate-c nix/macos-probe/c.h -lc $(pkg-config --cflags sdl3) > "$tmp/c.zig"
sdl=$(pkg-config --variable=libdir sdl3)
zig build-exe -O ReleaseSafe -lc -L"$sdl" -rpath "$sdl" -lSDL3 --dep c -Mroot=src/macos_probe.zig -Mc="$tmp/c.zig" \
  -femit-bin="$out" --cache-dir "$tmp/cache"

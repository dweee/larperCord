# The client source without packaging, CI, site files and local build output:
# editing those must not rebuild the binary. Built from the tree itself rather
# than `lib.fileset.gitTracked`, which rejects a `path:` flake whose source
# still contains `.git`. A `git+file:` or GitHub source holds tracked files only.
{ lib }:
let
  root = ../.;
  maybe = lib.fileset.maybeMissing;
in
lib.fileset.toSource {
  inherit root;
  fileset = lib.fileset.difference root (
    lib.fileset.unions [
      ../nix
      ../flake.nix
      ../flake.lock
      ../.github
      ../site
      (maybe ../.git)
      (maybe ../.forgejo)
      (maybe ../.fork-ci)
      (maybe ../.fork-ci.json)
      (maybe ../FORK.md)
      (maybe ../ci)
      # Local build output and downloads (tools/windows_deps.sh).
      (maybe ../.zig-cache)
      (maybe ../zig-out)
      (maybe ../.deps)
      (maybe ../result)
    ]
  );
}

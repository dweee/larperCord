# The client source without packaging, CI and site files: editing those must
# not rebuild the binary.
{ lib }:
let
  root = ../.;
in
lib.fileset.toSource {
  inherit root;
  fileset = lib.fileset.difference (lib.fileset.gitTracked root) (
    lib.fileset.unions [
      ../nix
      ../flake.nix
      ../flake.lock
      ../.github
      ../site
      (lib.fileset.maybeMissing ../.forgejo)
      (lib.fileset.maybeMissing ../.fork-ci.json)
      (lib.fileset.maybeMissing ../FORK.md)
      (lib.fileset.maybeMissing ../ci)
    ]
  );
}

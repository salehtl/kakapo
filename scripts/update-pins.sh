#!/usr/bin/env bash
# Move the pin that `nix flake update` cannot: the cf CLI in pkgs/cf, packaged
# from an npm tarball with a committed lock. Run from the repo root; it edits
# files in place and leaves validation to the caller (the weekly
# update-flake-lock workflow runs `nix flake check` and builds kakapo right
# after).
#
#   nix shell nixpkgs#nodejs nixpkgs#jq nixpkgs#curl -c scripts/update-pins.sh
set -euo pipefail

# cf: npm's `latest` dist-tag, following the recipe in pkgs/cf/package.nix.
pkg=pkgs/cf/package.nix
current=$(grep -oE 'version = "[^"]+"' "$pkg" | head -1 | cut -d'"' -f2)
meta=$(curl -fsS https://registry.npmjs.org/cf/latest)
latest=$(jq -r .version <<<"$meta")
if [ "$latest" != "$current" ]; then
  integrity=$(jq -r .dist.integrity <<<"$meta")
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  curl -fsSL "$(jq -r .dist.tarball <<<"$meta")" | tar -xz -C "$work"
  (
    cd "$work/package"
    jq 'del(.devDependencies, .scripts)' package.json >package.json.new
    mv package.json.new package.json
    npm install --package-lock-only --ignore-scripts --no-audit --no-fund >/dev/null
  )
  cp "$work/package/package-lock.json" pkgs/cf/package-lock.json
  sed -i "s|version = \"$current\"|version = \"$latest\"|; s|hash = \"sha512-[^\"]*\"|hash = \"$integrity\"|" "$pkg"
  echo "cf: $current -> $latest"
else
  echo "cf: $current is current"
fi

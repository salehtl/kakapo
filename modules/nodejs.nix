{ pkgs, ... }:
{
  # Temporary (2026-10-07): Node.js + npm for ad-hoc use by saleh. Kept in its
  # own module so removing it is one line — drop the `../../modules/nodejs.nix`
  # import in hosts/kakapo/default.nix (and delete this file).
  environment.systemPackages = [ pkgs.nodejs ];
}

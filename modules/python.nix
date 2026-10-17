{ pkgs, ... }:
{
  # Python 3 for ad-hoc use by saleh (2026-10-14). Projects still get their
  # Python from their own flake. Kept in its own module so removing it is one
  # line — drop the `../../modules/python.nix` import in hosts/kakapo/default.nix
  # (and delete this file).
  environment.systemPackages = [ pkgs.python3 ];
}

{ pkgs, ... }:
{
  # Python 3 for ad-hoc use by saleh; projects get theirs from their own flake.
  # To remove it, drop the import in hosts/kakapo/default.nix and delete this
  # file.
  environment.systemPackages = [ pkgs.python3 ];
}

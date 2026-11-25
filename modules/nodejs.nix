{ pkgs, ... }:
{
  # Temporary: Node.js + npm for ad-hoc use by saleh. To remove it, drop the
  # import in hosts/kakapo/default.nix and delete this file.
  environment.systemPackages = [ pkgs.nodejs ];
}

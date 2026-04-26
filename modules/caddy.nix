{
  config,
  lib,
  pkgs,
  ...
}:
let
  mkRP = sub: port: {
    "${sub}.salehtl.com".extraConfig = ''
      reverse_proxy localhost:${toString port}
    '';
  };
in
{
  services.caddy = {
    enable = true;
    email = "salehtl@icloud.com";

    # Name subdomains by function, not software.
    # e.g. (mkRP "tv" 8096) for Jellyfin, (mkRP "vault" 8222) for Vaultwarden.
    virtualHosts = lib.mkMerge [
    ];
  };
}

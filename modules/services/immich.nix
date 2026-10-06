# Immich 3 (package and module from nixpkgs-unstable, see flake.nix): photo
# and video backup, a Google Photos replacement, served at
# https://photos.salehtl.com by the LAN proxy (modules/services/lan-proxy.nix).
#
# Login:   Immich's own accounts. The first account created in the web UI
#          becomes the admin; create it straight after deploying.
# Storage: originals, thumbnails and transcodes on the media SSD at
#          /mnt/media/immich (0700, immich). Immich writes its own nightly
#          database dumps to /mnt/media/immich/backups. Postgres (with
#          VectorChord) and Redis are local to the module, on unix sockets.
# ML:      Face recognition and smart search run on the CPU. GPU inference
#          would need onnxruntime built with CUDA on the host, which
#          CLAUDE.md rules out (and cache.nixos.org does not carry).
# Ports:   127.0.0.1 only: server 2283, machine learning 3003 (localhost).
# Admin settings (external domain, jobs, storage template) live in the web UI
# and the database, not here: setting `services.immich.settings` would make
# all of them read-only in the UI.
{ config, pkgs, ... }:
let
  mediaLocation = "/mnt/media/immich";
in
{
  services.immich = {
    enable = true;
    # 26.05's pkgs.immich is the insecure 2.7.5; see flake.nix.
    package = pkgs.unstable.immich;
    host = "127.0.0.1";
    inherit mediaLocation;
  };

  # The module only fixes permissions on an existing directory.
  systemd.tmpfiles.settings.immich-media.${mediaLocation}.d = {
    inherit (config.services.immich) user group;
    mode = "0700";
  };

  # Never start against an unmounted /mnt/media: uploads would land on the
  # root disk and vanish behind the mount on the next boot.
  systemd.services.immich-server.unitConfig.RequiresMountsFor = [ mediaLocation ];
}

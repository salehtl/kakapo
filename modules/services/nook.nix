# nook: Saleh's reading-room planner, and the trainer for room scans from the
# nook-scan iPhone app (github.com/salehtl/nook; the module is nix/module.nix
# there, and this file is kakapo's instance of it). The app uploads a capture;
# nook-scan trains it on the RTX 2060 (gsplat over CUDA) and writes the room
# straight into the folder the planner serves, so a scan shows up with no
# manual step.
#
# Units:   nook-scan (jobs server, 127.0.0.1:8095, one training at a time) and
#          nook-web (the planner, 127.0.0.1:8096; it proxies /api/scan/* to
#          nook-scan, so the LAN proxy has a single upstream).
# State:   /var/lib/nook (rooms, uploads, layouts, library, renders). Scans
#          show the inside of the house.
# Ingress: https://nook.salehtl.com through the LAN proxy's `proxied` list:
#          house network and tailnet, no login (Saleh's choice, 2026-10-26;
#          see lan-proxy.nix), with large unbuffered uploads
#          (serverExtra.nook there).
# Deploy:  change the nook rev in flake.nix, commit, push; the 04:00 upgrade
#          applies it.
# Secrets: FAL_KEY for the planner's paid calls (library adds from photos,
#          Render), from secrets/nook.yaml as an EnvironmentFile
#          (`nook/fal_env`, one line `FAL_KEY=...`). Spend is capped per UTC
#          day in nook-web (dailySpendUsd).
{ config, ... }:
{
  # Splat counts: nook v4 (0.3.0) sizes training to each capture and caps it
  # per GPU class (2M on the RTX 2060), delivering at most 1.5M to the
  # browser, so the old fixed maxSplats is gone: it would cap retrains too.
  services.nook = {
    enable = true;
    # The LAN proxy's name for the planner; anything else is refused (DNS
    # rebinding guard).
    allowedHosts = [ "nook.salehtl.com" ];
    falKeyFile = config.sops.secrets."nook/fal_env".path;
    dailySpendUsd = 2;
  };

  sops.secrets."nook/fal_env" = {
    sopsFile = ../../secrets/nook.yaml;
    key = "nook/fal_env";
    owner = "nook";
    restartUnits = [ "nook-web.service" ];
  };

  # Evals over ssh (nook's evals/remote.sh) take /run/nook/gpu.lock, the lock
  # nook-scan's worker holds while training, so they never share the GPU.
  users.users.saleh.extraGroups = [ "nook" ];
}

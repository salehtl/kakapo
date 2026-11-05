# midstudy: Saleh's furniture planner on a single room photo (a fork of nook
# without the room scan; github.com/salehtl/midstudy, the module is
# nix/module.nix there, the hosting notes docs/HANDOFF.md).
#
# Unit:    midstudy (the web app, 127.0.0.1:8780). It runs midstudy-calib
#          (MoGe-2 on the RTX 2060, about 10 s per photo, one at a time) for
#          each uploaded photo and midstudy-add for each library item.
# State:   /var/lib/midstudy (scenes, library, layouts, renders). Each scene
#          keeps the upload as given (`source.*`, EXIF and location included);
#          it is never served. Uploaded photos show the inside of the house.
# Ingress: https://midstudy.salehtl.com through the LAN proxy's `proxied`
#          list: house network and tailnet, no login (Saleh's choice,
#          2026-11-05; see lan-proxy.nix).
# Deploy:  change the midstudy rev in flake.nix in a PR; merging it deploys.
# fal:     furniture from photos and Render are paid fal calls, from
#          secrets/midstudy.yaml as an EnvironmentFile (`midstudy/fal_env`,
#          one line `FAL_KEY=...`). Spend is capped per UTC day
#          (dailySpendUsd). Until secrets/midstudy.yaml exists, midstudy runs
#          without a key: those calls answer "FAL_KEY not set", and photo
#          calibration and GLB/OBJ furniture still work.
{ config, lib, ... }:
let
  hasFalKey = builtins.pathExists ../../secrets/midstudy.yaml;
in
{
  services.midstudy = {
    enable = true;
    webPort = 8780;
    # The LAN proxy's name for the app; anything else is refused (DNS
    # rebinding guard).
    allowedHosts = [ "midstudy.salehtl.com" ];
    falKeyFile = if hasFalKey then config.sops.secrets."midstudy/fal_env".path else null;
    dailySpendUsd = 2;
    # CUDA when torch sees the GPU; a failed CUDA inference is retried on the
    # CPU.
    calibDevice = "auto";
  };

  sops.secrets = lib.optionalAttrs hasFalKey {
    "midstudy/fal_env" = {
      sopsFile = ../../secrets/midstudy.yaml;
      key = "midstudy/fal_env";
      restartUnits = [ "midstudy.service" ];
    };
  };
}

# nook: Saleh's reading-room planner, and the trainer for room scans from the
# nook-scan iPhone app (github.com/salehtl/nook; the module is nix/module.nix
# there, and this file is kakapo's instance of it). The app uploads a capture;
# nook-scan trains it on the RTX 2060 (Brush over Vulkan) and writes the room
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
_: {
  services.nook = {
    enable = true;
    # 6 GB of VRAM: cap the splat count so a whole room trains without running
    # out of GPU memory.
    maxSplats = 1200000;
  };
}

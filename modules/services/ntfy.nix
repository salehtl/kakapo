# ntfy: push notifications to phones and desktops, at https://ntfy.salehtl.com.
#
# Access:  the house and the tailnet, through the LAN proxy's `proxied` list
#          (modules/services/lan-proxy.nix), so alerts still arrive when the
#          phone's Tailscale is off. Reading needs a login (saleh, from
#          secrets/ntfy.yaml); anonymous visitors may only publish, and the
#          proxy refuses publishing, so only kakapo's own services, posting
#          straight to 127.0.0.1:2586, can send.
# Alerts:  kakapo's alerts publish to the `kakapo` topic as well as email
#          (modules/notify.nix, dns-health in modules/services/adguard.nix).
#          Subscribe to it in the ntfy app with server https://ntfy.salehtl.com
#          and the saleh login (Settings -> Users).
# iOS:     Apple only lets ntfy.sh's own server wake the iOS app, so
#          upstream-base-url forwards a poll request (a hash of the topic, no
#          message content) to ntfy.sh, and the phone then fetches the message
#          from here.
# State:   /var/lib/ntfy-sh (message cache, attachments, user.db; DynamicUser).
# Ports:   127.0.0.1:2586 only.
{ config, ... }:
{
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.salehtl.com";
      listen-http = "127.0.0.1:2586";
      behind-proxy = true;
      upstream-base-url = "https://ntfy.sh";
      auth-default-access = "deny-all";
      # The user itself (name and bcrypt hash) is NTFY_AUTH_USERS in the
      # environment file, so the hash stays out of the store.
      auth-access = [
        "everyone:kakapo:write-only"
        "saleh:kakapo:read-only"
      ];
    };
    environmentFile = config.sops.secrets."ntfy/env".path;
  };
}

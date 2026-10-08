# ntfy: push notifications to phones and desktops, at https://ntfy.salehtl.com.
#
# Access:  tailnet devices only, through the LAN proxy's tailnetOnly list
#          (tailscale-nginx-auth, modules/services/lan-proxy.nix); kakapo's own
#          services publish straight to 127.0.0.1:2586. ntfy's own auth is left
#          at its default (open), so the gate is the access control, and a
#          topic name is the only thing separating one feed from another.
# Alerts:  kakapo's alerts publish to the `kakapo` topic as well as email
#          (modules/notify.nix, dns-health in modules/services/adguard.nix).
#          Subscribe to it in the ntfy app with server https://ntfy.salehtl.com.
# iOS:     Apple only lets ntfy.sh's own server wake the iOS app, so
#          upstream-base-url forwards a poll request (a hash of the topic, no
#          message content) to ntfy.sh, and the phone then fetches the message
#          from here over the tailnet.
# State:   /var/lib/ntfy-sh (message cache, attachments; DynamicUser).
# Ports:   127.0.0.1:2586 only.
{
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.salehtl.com";
      listen-http = "127.0.0.1:2586";
      behind-proxy = true;
      upstream-base-url = "https://ntfy.sh";
    };
  };
}

# CLIProxyAPI (github.com/router-for-me/CLIProxyAPI, 2026-11-19): turns the
# OAuth logins of subscription CLIs (Claude Code, Codex, ...) into OpenAI-,
# Anthropic- and Gemini-compatible HTTP APIs, so Saleh's other machines can
# point their tools at kakapo. Package and NixOS module from nixpkgs-unstable
# (not in 26.05; the module is imported in flake.nix).
#
# State:   /var/lib/cliproxyapi (0700, cliproxyapi): the provider OAuth tokens
#          and config.yaml, which the module regenerates at every start.
# Secrets: secrets/cliproxyapi.yaml (modules/sops.nix): `api_key`, the key
#          every client sends, and `management_key` for the management API.
#          Both reach the unit only through LoadCredential=.
# Ingress: tailnet only, https://cliproxy.salehtl.com via the LAN proxy's
#          `tailnetOnly` list (tailscale-nginx-auth) plus the API key. The
#          proxy refuses the management API and its web panel
#          (serverExtra.cliproxy in lan-proxy.nix), so provider logins and
#          settings are changed only from kakapo itself, on 127.0.0.1:8317.
# Logins:  out of band, once per provider, on kakapo (CLAUDE.md, "CLIProxyAPI").
{ config, pkgs, ... }:
let
  cfg = config.services.cliproxyapi;
  secret = name: { _secret = config.sops.secrets."cliproxyapi/${name}".path; };
in
{
  services.cliproxyapi = {
    enable = true;
    package = pkgs.unstable.cliproxyapi;
    settings = {
      # The module leaves host empty, which binds every interface.
      server = {
        host = "127.0.0.1";
        port = 8317;
      };
      access.api-keys = [ (secret "api_key") ];
      management = {
        allow-remote = false;
        secret-key = secret "management_key";
        # The panel downloads its code from GitHub at run time. Logins use the
        # CLI or the management API instead.
        disable-control-panel = true;
      };
      # Never write prompts or responses to disk or the journal.
      observability = {
        logs = {
          debug = false;
          logging-to-file = false;
          request-log = false;
        };
        # Per-account and per-model request and token counts, so the load
        # balancing across logins is visible in the TUI and the management
        # API (2026-11-23, Saleh's choice). Counts only, no prompts, kept in
        # memory and lost at each restart.
        usage.usage-statistics-enabled = true;
      };
    };
  };

  # `cliproxyapi -config ... -claude-login` for the out-of-band logins.
  environment.systemPackages = [ cfg.package ];

  assertions = [
    {
      assertion = cfg.settings.server.host == "127.0.0.1" && !cfg.openFirewall;
      message = "CLIProxyAPI must listen on 127.0.0.1 only, with no firewall opening; it is reached through the LAN proxy's tailnetOnly list.";
    }
    {
      assertion = !(cfg.settings.management.allow-remote or false);
      message = "CLIProxyAPI's management API must stay local (management.allow-remote = false).";
    }
  ];
}

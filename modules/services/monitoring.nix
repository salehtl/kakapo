# Health dashboard: Prometheus scrapes the exporters below and Grafana shows
# them, tailnet only, at https://kakapo.<tailnet>.ts.net:8443/.
#
# Login:   tailscale serve passes the caller's tailnet login in the
#          Tailscale-User-Login header and Grafana trusts it (auth.proxy).
#          Only the admin user below exists and sign-up is off, so other
#          tailnet users and tagged devices get 401. No passwords.
# State:   /var/lib/grafana (incl. secret_key, generated on first start),
#          /var/lib/prometheus2 (90 days of metrics)
# Ports:   127.0.0.1 only: Grafana 3000, Prometheus 9090, exporters
#          node 9100, nvidia-gpu 9835, smartctl 9633
{
  config,
  lib,
  pkgs,
  ...
}:
let
  host = "kakapo.marmoset-paradise.ts.net";
  servePort = 8443; # tailscale serve allows 443 (ledger), 8443 and 10000
  grafanaPort = 3000;
  inherit (config.services.grafana) dataDir;
  inherit (config.services.prometheus) exporters;

  # Community dashboards from grafana.com, pinned by revision.
  fetchDashboard =
    id: rev: hash:
    pkgs.fetchurl {
      url = "https://grafana.com/api/dashboards/${toString id}/revisions/${toString rev}/download";
      inherit hash;
    };
  dashboards = pkgs.linkFarm "grafana-dashboards" {
    "node-exporter-full.json" =
      fetchDashboard 1860 45
        "sha256-GExrdAnzBtp1Ul13cvcZRbEM6iOtFrXXjEaY6g6lGYY=";
    "nvidia-gpu.json" = fetchDashboard 14574 15 "sha256-L1yXeL3LLnyPHlS0l30075gO+WS/WE3zXD8eNeR1r80=";
    # This one expects its data source to be picked at import time.
    "smartctl.json" =
      pkgs.runCommand "smartctl.json"
        { src = fetchDashboard 22604 3 "sha256-gpm/4rzcNv6br8L8cs9O6iWEScojfImWUi1uRXW8UpM="; }
        ''
          substitute $src $out --replace-fail ${lib.escapeShellArg "\${DS_PROMETHEUS}"} prometheus
        '';
  };
in
{
  services.prometheus = {
    enable = true;
    listenAddress = "127.0.0.1";
    retentionTime = "90d";
    globalConfig.scrape_interval = "15s";

    exporters = {
      node = {
        enable = true;
        listenAddress = "127.0.0.1";
        enabledCollectors = [ "systemd" ];
      };
      nvidia-gpu = {
        enable = true;
        listenAddress = "127.0.0.1";
      };
      smartctl = {
        enable = true;
        listenAddress = "127.0.0.1";
      };
    };

    scrapeConfigs =
      map
        (job: {
          job_name = job;
          static_configs = [ { targets = [ "127.0.0.1:${toString exporters.${job}.port}" ]; } ];
        })
        [
          "node"
          "nvidia-gpu"
          "smartctl"
        ];
  };

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = grafanaPort;
        domain = host;
        root_url = "https://${host}:${toString servePort}/";
      };
      "auth.proxy" = {
        enabled = true;
        header_name = "Tailscale-User-Login";
        header_property = "username";
        headers = "Name:Tailscale-User-Name";
        auto_sign_up = false;
        # tailscale serve connects from loopback.
        whitelist = "127.0.0.1, ::1";
      };
      auth = {
        disable_login_form = true;
        disable_signout_menu = true;
      };
      "auth.basic".enabled = false;
      users = {
        allow_sign_up = false;
        allow_org_create = false;
      };
      security = {
        # Matches the Tailscale-User-Login of Saleh's devices.
        admin_user = "salehtl@github";
        # Unused (no login form, no basic auth), but must not be the default.
        admin_password = "$__file{${dataDir}/admin_password}";
        secret_key = "$__file{${dataDir}/secret_key}";
        cookie_secure = true;
        disable_gravatar = true;
      };
      analytics = {
        reporting_enabled = false;
        check_for_updates = false;
        check_for_plugin_updates = false;
        feedback_links_enabled = false;
      };
      news.news_feed_enabled = false;
    };

    provision = {
      enable = true;
      datasources.settings = {
        apiVersion = 1;
        datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            uid = "prometheus";
            url = "http://127.0.0.1:${toString config.services.prometheus.port}";
            isDefault = true;
            editable = false;
          }
        ];
      };
      dashboards.settings.providers = [
        {
          name = "kakapo";
          options.path = dashboards;
          disableDeletion = true;
        }
      ];
    };
  };

  # Generate Grafana's secrets on the host the first time it starts.
  systemd.services.grafana.preStart = lib.mkAfter ''
    for f in secret_key admin_password; do
      if [ ! -s ${dataDir}/$f ]; then
        (umask 077; head -c 32 /dev/urandom | base64 -w0 > ${dataDir}/$f)
      fi
    done
  '';

  # Same pattern as ledger-tailscale-serve, on its own HTTPS port.
  systemd.services.grafana-tailscale-serve = {
    description = "Serve Grafana to the tailnet over HTTPS";
    after = [
      "tailscaled.service"
      "grafana.service"
    ];
    wants = [ "tailscaled.service" ];
    wantedBy = [ "multi-user.target" ];
    path = [ config.services.tailscale.package ];
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
      TimeoutStartSec = 60;
    };
    script = "tailscale serve --bg --https=${toString servePort} http://127.0.0.1:${toString grafanaPort}";
    preStop = "tailscale serve --https=${toString servePort} off";
  };
}

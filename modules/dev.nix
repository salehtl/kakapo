{ pkgs, ... }:
{
  config = {
    services.nginx = {
      enable = true;
      recommendedTlsSettings = true;
      recommendedProxySettings = true;
      recommendedOptimisation = true;
      virtualHosts = {
        "git.sirdab.ae" = {
          locations."/" = {
            proxyPass = "http://127.0.0.1:3939";
          };
          extraConfig = ''
            # allow large file uploads for lfs
            client_max_body_size 50000M;
          '';
        };
      };
    };
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_17;
      extensions =
        ps: with ps; [
          postgis
          pgvector
        ];
      settings = {
        max_connections = 200;
      };
    };

    services.forgejo = {
      enable = true;
      package = pkgs.forgejo; # default is lts
      database.type = "postgres";
      lfs.enable = true;
      settings = {
        DEFAULT.APP_NAME = "git.sirdab.ae";
        server = {
          DOMAIN = "git.sirdab.ae";
          ROOT_URL = "https://git.sirdab.ae/";
          HTTP_PORT = 3939;
          SSH_LISTEN_PORT = 2222;
          SSH_PORT = 22;
          START_SSH_SERVER = true;

          LANDING_PAGE = "explore";
        };
        service = {
          DISABLE_REGISTRATION = true;
          REQUIRE_SIGNIN_VIEW = true;
        };
        repository = {
          DEFAULT_PRIVATE = "private";
          FORCE_PRIVATE = true;
          ENABLE_PUSH_CREATE_USER = true;
          ENABLE_PUSH_CREATE_ORG = true;
        };
        "repository.pull-request" = {
          DEFAULT_MERGE_STYLE = "rebase";
        };
        other = {
          SHOW_FOOTER_TEMPLATE_LOAD_TIME = false;
          SHOW_FOOTER_VERSION = false;
        };
        "ui.meta" = {
          AUTHOR = "git.sirdab.ae";
          DESCRIPTION = "A private software forge";
        };
      };
    };
  };
}

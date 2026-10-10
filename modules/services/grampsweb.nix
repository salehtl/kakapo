# Gramps Web: genealogy (family trees) in the browser, at https://gw.salehtl.com
# through the LAN proxy, for the house and the tailnet. Its own accounts: the
# first account created in the web UI becomes the owner.
#
# Not in nixpkgs (only the desktop Gramps is), so this runs the project's
# official image the way its docker-compose example does: the web app, a
# Celery worker from the same image, and Valkey as the queue, on a private
# Docker network. Only the web app is published, on 127.0.0.1.
#
# Images: pinned by digest; update by hand (the weekly flake bump does not move
#         them): new tag and `docker buildx imagetools inspect <image>:<tag>`.
# State:  /var/lib/grampsweb/<volume>, bind-mounted: the family tree database
#         (grampsdb), users, media, search index, caches, and the Flask secret
#         (generated on first start).
# Ports:  127.0.0.1:5000 only.
{ lib, pkgs, ... }:
let
  image = "ghcr.io/gramps-project/grampsweb:26.10.0@sha256:27017b77784ebc8fe9b4b84e3baab8fa529f1f715f4691bc5d1979b874c216ec";
  valkey = "docker.io/valkey/valkey:8-alpine@sha256:081c2f5cb575efc901aa80ff9cdbd1ec6a301682fd35e1ebb4b0990a4a4a8507";
  network = "grampsweb";
  state = "/var/lib/grampsweb";
  volumes = {
    users = "/app/users";
    indexdir = "/app/indexdir";
    thumbnail_cache = "/app/thumbnail_cache";
    cache = "/app/cache";
    secret = "/app/secret";
    grampsdb = "/root/.gramps/grampsdb";
    media = "/app/media";
    tmp = "/tmp";
  };
  app = {
    inherit image;
    networks = [ network ];
    volumes = lib.mapAttrsToList (dir: path: "${state}/${dir}:${path}") volumes;
    environment = {
      GRAMPSWEB_TREE = "Gramps Web"; # created empty on first start
      GRAMPSWEB_BASE_URL = "https://gw.salehtl.com";
      GRAMPSWEB_CELERY_CONFIG__broker_url = "redis://grampsweb-redis:6379/0";
      GRAMPSWEB_CELERY_CONFIG__result_backend = "redis://grampsweb-redis:6379/0";
      GRAMPSWEB_RATELIMIT_STORAGE_URI = "redis://grampsweb-redis:6379/1";
    };
  };
in
{
  # Docker, which kakapo already runs; the module would default to Podman.
  virtualisation.oci-containers.backend = "docker";
  virtualisation.oci-containers.containers = {
    grampsweb-redis = {
      image = valkey;
      networks = [ network ];
    };
    grampsweb = app // {
      ports = [ "127.0.0.1:5000:5000" ];
      dependsOn = [ "grampsweb-redis" ];
    };
    grampsweb-celery = app // {
      cmd = [
        "celery"
        "-A"
        "gramps_webapi.celery"
        "worker"
        "--loglevel=INFO"
        "--concurrency=2"
      ];
      dependsOn = [
        "grampsweb"
        "grampsweb-redis"
      ];
    };
  };

  # Each container's entrypoint migrates the user database, and the app creates
  # the tree if it is missing. Started together on 2026-10-10, the two raced:
  # the user database was left in a state no later start could migrate (both
  # crash-looped) and two empty trees were created. dependsOn only orders the
  # starts, so the worker also waits until the web app answers (`/`: gunicorn
  # only starts after the migration; the API itself needs a login).
  systemd.services.docker-grampsweb-celery = {
    path = [ pkgs.curl ];
    preStart = lib.mkAfter ''
      for _ in $(seq 120); do
        curl -fs -o /dev/null http://127.0.0.1:5000/ && exit 0
        sleep 2
      done
      echo "Gramps Web did not answer within 4 minutes" >&2
      exit 1
    '';
  };

  # The containers' private network, created before any of them starts.
  systemd.services.docker-network-grampsweb = {
    description = "Docker network for Gramps Web";
    after = [ "docker.service" ];
    requires = [ "docker.service" ];
    before = map (c: "docker-${c}.service") [
      "grampsweb-redis"
      "grampsweb"
      "grampsweb-celery"
    ];
    requiredBy = map (c: "docker-${c}.service") [
      "grampsweb-redis"
      "grampsweb"
      "grampsweb-celery"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      /run/current-system/sw/bin/docker network inspect ${network} >/dev/null 2>&1 \
        || /run/current-system/sw/bin/docker network create ${network}
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${state} 0700 root root -"
  ]
  ++ map (dir: "d ${state}/${dir} 0750 root root -") (lib.attrNames volumes);
}

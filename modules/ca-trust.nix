# Which root certificates this host trusts, and making sure every program on it
# uses that one list.
#
# Distrust (2026-10-21): nixos-26.05 ships nss-cacert 3.126, which still trusts
# two roots that bad chains lead to (Hasala security review finding R69). Until
# nixpkgs ships the fixed list (NSS 3.131.1), they are removed from the system
# bundle here, for the whole host. This came in first through Hasala's module
# (services.hasala.hardening.distrustedCARoots); it lives here now, because it
# changes trust for everything on kakapo, and must not depend on Hasala being
# enabled. To close: after a flake.lock bump brings cacert >= 3.131.1, check the
# new bundle no longer has these roots, then delete `distrusted` (and the
# assertion).
#
# One list: the system bundle (/etc/ssl/certs/ca-certificates.crt) is what
# OpenSSL, curl, nix, Go programs and nixpkgs' Node (built with
# --openssl-use-def-ca-store) read. Two kinds of program carry their own copy
# and ignore it:
#   - Nix's Python certifi (requests, httpx: Immich machine learning, saleh's
#     python3) falls back to a cacert.pem built from the stock nss-cacert,
#     unless NIX_SSL_CERT_FILE names a bundle. Set below for shells and for
#     the one Python service. Not systemd.globalEnvironment: that rewrites
#     every unit, so one activation would restart all of them, AdGuard too. A
#     new Python service sets it itself.
#   - Containers bring their distribution's list. Gramps Web gets the host
#     bundle mounted in (modules/services/grampsweb.nix).
{ config, lib, ... }:
let
  distrusted = [
    "Comodo AAA Services root"
    "emSign ECC Root CA - G3"
  ];
  bundle = "/etc/ssl/certs/ca-certificates.crt";
in
{
  security.pki.caCertificateBlacklist = distrusted;
  services.hasala.hardening.distrustedCARoots = [ ];

  systemd.services.immich-machine-learning.environment.NIX_SSL_CERT_FILE = bundle;
  environment.variables.NIX_SSL_CERT_FILE = bundle;

  assertions = [
    {
      assertion = lib.all (r: lib.elem r config.security.pki.caCertificateBlacklist) distrusted;
      message = "security.pki.caCertificateBlacklist must keep ${lib.concatStringsSep ", " distrusted} until nixpkgs ships nss-cacert >= 3.131.1 (modules/ca-trust.nix).";
    }
  ];
}

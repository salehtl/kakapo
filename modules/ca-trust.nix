# Which root certificates this host trusts, and making sure every program on it
# uses that one list.
#
# Distrust: nixpkgs owns the list now. security/ca.nix blacklists "Comodo AAA
# Services root" itself, and nss-cacert 3.131.1 dropped the emSign roots. Never
# name a root here that nss-cacert does not ship: the build fails with "Certs in
# blocklist but not in cert store" (it broke the flake.lock bump of 2026-11-01).
# Hasala's module still blacklists both roots by default, and it fails the same
# way, so services.hasala.hardening.distrustedCARoots stays empty below.
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
_:
let
  bundle = "/etc/ssl/certs/ca-certificates.crt";
in
{
  services.hasala.hardening.distrustedCARoots = [ ];

  systemd.services.immich-machine-learning.environment.NIX_SSL_CERT_FILE = bundle;
  environment.variables.NIX_SSL_CERT_FILE = bundle;
}

# kakapo: accepted risks and known false positives

Read this before grading a finding. Each item below is deliberate, approved
by Saleh, or a tool artefact. Mention an accepted risk in the report only
under "Accepted (unchanged)", and only if it changed shape (for example a new
service on loopback that trusts a header). Re-check the source named for each
item: if the repo no longer says it, it is no longer accepted.

## Deliberate design (source: repo `CLAUDE.md`, "Conventions worth preserving")

| Item | Why it is accepted |
|------|--------------------|
| sshd on `0.0.0.0:22` and `[::]:22`, port 22 open on every interface | LAN fallback when Tailscale is down. Never recommend narrowing it to `tailscale0`. |
| AdGuard `*:53` tcp+udp | Firewall-scoped to the LAN NIC and `tailscale0`, plus `dns.allowed_clients` and `ratelimit` (assertions in `modules/services/adguard.nix`). |
| AdGuard UI on `adguard.salehtl.com` with no login | Saleh's choice, 2026-10-05. |
| `security.sudo.wheelNeedsPassword = false`; sudoers `%wheel ... NOPASSWD:SETENV: ALL` | Users have no passwords; the SSH key (YubiKey, `sk-ssh-ed25519`) is the only factor. |
| `saleh` and `humaid` in `wheel` and `docker` | Declared in `hosts/kakapo/default.nix`. `docker` is root-equivalent; that is known. A *third* member is a finding. |
| `INPUT` policy `ACCEPT` | NixOS normal: protection is the `-j nixos-fw` jump, which ends in `nixos-fw-log-refuse`. Missing jump = finding. |
| `ts-input` accepts all of `tailscale0` before `nixos-fw` | tailscaled installs it. It means interface scoping protects the LAN only; on the tailnet, loopback binding is the control (tailnet policy is allow-all). Not a finding by itself, but it is why any wildcard bind is tailnet-exposed. |
| Local processes can reach Grafana `127.0.0.1:3000`, ledger `:8090`, ntfy `:2586` without nginx | "Known residual risk" under "Tailnet identity" in `CLAUDE.md`. |
| `deny` lines for kakapo and homeassistant tailnet addresses on gated vhosts | `untaggedDeny` stopgap until both nodes are tagged in Tailscale (out of band, Saleh's to do). Report "still untagged" as Info, not a new finding. |
| kakapo is a Tailscale exit node and advertises `10.0.0.215/32`; IP forwarding on, `FORWARD` policy `ACCEPT` | The exit node exists for `modules/services/zapret.nix` (`--advertise-exit-node` follows `services.zapret.enable` in `modules/base.nix`); the route is the away path to the LAN proxy (`lan-proxy.nix`). Residual risk: with the allow-all tailnet policy, an exit-node client can reach the whole house LAN. Re-check the exact routes each audit; any extra route is a finding. |
| Hasala public tunnel (`cloudflared-hasala`, `api.hasala.app`) | Approved 2026-10-11, path allowlist asserted by the hasala module. Any *other* public ingress is a finding. |
| `immich` from nixpkgs-unstable | 26.05's Immich is marked insecure; unstable is the fix, not the risk. |
| CA blacklist in `modules/ca-trust.nix` | Stopgap until nss-cacert >= 3.131.1. Report as Info once a lock bump brings the fix (the module says to remove it then). |

## Known tailnet devices (on 2026-10-22)

| Device (`DNSName`) | Owner | Note |
|--------------------|-------|------|
| `rabbit` | `salehtl@github` | Saleh's Mac |
| `salehs-phone` | `salehtl@github` | Saleh's phone |
| `salehs-old-phone` | `salehtl@github` | Last seen 2026-09-28. Report Low after 30 days unseen. |
| `anoa` | `humaidq@github` | Humaid's machine (also a `wheel` user) |
| `homeassistant` | `salehtl@github` | Untagged; see `untaggedDeny` above |

Any other device or owner is a finding (Step 1, "Tailnet devices").

## Not findings: tool artefacts

- **Stock `nixos-fw` rules**: `-i lo`, `RELATED,ESTABLISHED`, IPv4 ICMP
  echo (`--icmp-type 8`), IPv6 `ipv6-icmp` (after the type 137 and 139
  drops) and `-d fe80::/64 -p udp --dport 546` (DHCPv6 client). NixOS adds
  them by default.
- **`Defaults env_keep+=...` lines in `/etc/sudoers`**: NixOS stock. Compare
  the file with `/etc/static/sudoers`, not by reading it.
- **`PAM: Authentication failure for saleh` from Saleh's own address**,
  next to his key logins: an SSH client trying keyboard-interactive. Info.

- **`ss -u` shows cloudflared on `*:<ephemeral>`**: outbound QUIC sockets of
  the Hasala tunnel (unconnected UDP). `scripts/exposure.py` marks them
  EXPECTED. A cloudflared **tcp** listener off loopback is a finding.
- **tailscaled on its own `100.x`/`fd7a:` address** (peerapi) and udp `41641`
  (WireGuard): Tailscale's own.
- **docker-proxy on `127.0.0.1:5000`**: Gramps Web, published on loopback only.
  Check `sudo docker ps --format '{{.Names}}\t{{.Ports}}'`: any `0.0.0.0:` or
  `:::` mapping bypasses `nixos-fw` (Docker DNATs in the nat table) and is a
  Critical finding.
- **gitleaks `generic-api-key` in `modules/sops.nix` on `key = "..."`**: that
  is a sops *key path* (for example `grampsweb/env`), not a credential.
- **`nixbld1..32`, `nm-*`, service users in `/etc/passwd`**: NixOS creates
  them from module declarations; compare against the evaluated
  `users.users`, not against "human users".
- **vulnix, vulnxscan, grype**: match by package name and version against NVD or OSV, so they report
  CVEs nixpkgs already patched (patches do not change the version) and CVEs
  for other products with the same name. Check the nixpkgs package's
  `patches` or the NixOS security tracker before grading High or Critical.

## Open hardening items to re-check each audit

These are NixOS defaults, not decisions recorded in the repo. Report them
(Medium/Low) until a PR closes them or the repo records a decision:

- `KbdInteractiveAuthentication yes` in `sshd -T` (NixOS default
  `services.openssh.settings.KbdInteractiveAuthentication = true`). With no
  user passwords PAM cannot succeed today, but one declared `hashedPassword`
  would enable password login over SSH despite `PasswordAuthentication no`.
- `AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u`
  (`services.openssh.authorizedKeysInHomedir = true`). Any user, or any
  process running as that user, can add a key the flake does not know. A file
  that exists is High; the setting alone is Medium.
